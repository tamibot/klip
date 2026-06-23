import Foundation
import AVFoundation
import AppKit
import Combine
import CoreAudio

enum RecorderState: Equatable {
    case idle
    case recording
    case missingAPIKey
    case micDenied          // microphone permission denied → guide to System Settings
    case error(String)      // error BEFORE recording starts (permission/key). Transcription runs in the background.
}

/// Records a voice note to .m4a and transcribes it with OpenAI (not live: the whole note at once).
/// Transcription runs in the background: once stopped, the recorder is free to record another.
@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// true once we've gone >2 min in silence: the UI shows "¿Sigues ahí?".
    @Published private(set) var silenceWarning = false
    /// Number of transcriptions running in the background (for the header indicator).
    @Published private(set) var transcribingCount = 0

    /// The audio is already saved: creates the voice-note item (placeholder) and returns its id.
    /// `audioFileName` may be nil if the file couldn't be saved (the transcription is still saved).
    var onVoiceNoteStarted: ((String?, Double?) -> UUID?)?
    /// Fills in the transcription on the already-created item.
    var onVoiceNoteTranscribed: ((UUID, String) -> Void)?
    /// The transcription failed or there was no speech: the item keeps the audio to play back/recover.
    var onVoiceNoteFailed: ((UUID) -> Void)?
    /// Retry: marks an existing item as "Transcribiendo…" again.
    var onVoiceNoteRetrying: ((UUID) -> Void)?
    /// First on-device use: the model is downloading, so show a distinct status instead of "Transcribing…".
    var onVoiceNoteDownloadingModel: ((UUID) -> Void)?

    // Silence detection (timer at 0.1 s): warn at 2 min, stop at 3 min.
    private var silentTicks = 0
    private let silenceLevel: Float = 0.10
    private let warnTicks = 1200    // 120 s
    private let stopTicks = 1800    // 180 s

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentFileName: String?
    private let storage = Storage.shared
    /// CoreAudio listener to detect changes to the default microphone (e.g. plugging in headphones).
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Pending intent to record (covers the async permission window).
    private var startRequested = false
    /// true from when a stop is requested until the delegate finishes (state stays .recording in that gap).
    private(set) var finishing = false
    /// Only blocks starting another RECORDING; transcribing in the background doesn't count as busy.
    var isRecording: Bool { startRequested || state == .recording }

    private func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied:  return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
        @unknown default: return false
        }
    }

    @MainActor
    func start() {
        guard !isRecording else { return }
        startRequested = true
        Task { @MainActor in
            guard AIProvider.hasKey else { state = .missingAPIKey; startRequested = false; return }
            guard await requestMicPermission() else {
                state = .micDenied; startRequested = false; return
            }
            guard startRequested else { return }   // stop()/cancel() while waiting for permission
            let name = "\(UUID().uuidString).m4a"
            let url = storage.audioURL(for: name)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            do {
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.delegate = self
                rec.isMeteringEnabled = true
                guard rec.prepareToRecord(), rec.record() else {
                    state = .error(L10n.t("rec.err.start")); startRequested = false; return
                }
                recorder = rec
                currentFileName = name
                duration = 0; level = 0
                silentTicks = 0; silenceWarning = false
                state = .recording
                startRequested = false
                startMeterTimer()
                installDeviceListener()
            } catch {
                state = .error(error.localizedDescription); startRequested = false
            }
        }
    }

    @MainActor
    func stop() {
        startRequested = false
        guard state == .recording, !finishing, let rec = recorder else { return }   // ignore double-stop
        finishing = true
        stopMeterTimer()
        removeDeviceListener()
        rec.stop()   // triggers audioRecorderDidFinishRecording
    }

    @MainActor
    func cancel() {
        startRequested = false
        finishing = false
        stopMeterTimer()
        removeDeviceListener()
        recorder?.delegate = nil   // prevent the delegate from overwriting .idle with .error
        recorder?.stop()
        recorder = nil
        if let f = currentFileName { storage.deleteAudio(fileName: f) }
        currentFileName = nil
        state = .idle
    }

    // MARK: - Input device change (headphones)

    /// Watches the default microphone. If it changes DURING recording (e.g. you plug in headphones),
    /// AVAudioRecorder stays on the old device and the meter freezes → we finish the note
    /// cleanly (whatever was recorded is saved and transcribed) instead of leaving a broken state.
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleInputDeviceChange() } }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        if status == noErr { deviceListener = block }
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        deviceListener = nil
    }

    @MainActor
    private func handleInputDeviceChange() {
        guard state == .recording, !finishing else { return }
        stop()   // finish and transcribe what was recorded up to the device change
    }

    /// Returns to .idle from terminal states (error or missing API key) to revalidate on reopen.
    func reset() {
        switch state {
        case .error, .missingAPIKey, .micDenied: state = .idle
        default: break
        }
    }

    private func startMeterTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {   // runs on RunLoop.main; assert it for the compiler
                guard let self, let rec = self.recorder else { return }
                rec.updateMeters()
                self.duration = rec.currentTime
                let lvl = Self.normalized(power: rec.averagePower(forChannel: 0))
                self.level = lvl
                self.trackSilence(level: lvl)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func trackSilence(level lvl: Float) {
        if lvl >= silenceLevel {
            silentTicks = 0
            if silenceWarning { silenceWarning = false }
            return
        }
        silentTicks += 1
        if silentTicks == warnTicks {
            silenceWarning = true
            NSSound.beep()
        } else if silentTicks >= stopTicks {
            MainActor.assumeIsolated { stop() }   // stop due to inactivity: finish and transcribe
        }
    }

    /// The user taps "Continuar": resets the silence counter.
    func continueRecording() { silentTicks = 0; silenceWarning = false }

    /// Transcribes one or more audio files uploaded by the user (in the background).
    /// Each audio is copied to our store so it can be played back and kept afterwards.
    @MainActor
    func transcribeFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard AIProvider.hasKey else { state = .missingAPIKey; return }
        for url in urls {
            let stored = storage.importAudio(from: url)                       // copies to audio/ (nil if it fails)
            let transcribeURL = stored.map { storage.audioURL(for: $0) } ?? url
            enqueueTranscription(audioFileName: stored, transcribeURL: transcribeURL)
        }
    }

    /// Creates the voice-note item with its audio already saved and kicks off the transcription.
    /// The audio is NEVER deleted here: it stays accessible even if the transcription fails.
    /// `state` returns to .idle immediately → the recorder is free to record another note.
    @MainActor
    private func ingest(audioFileName name: String) {
        storage.protectAudio(fileName: name)   // 0600: the recording contains the user's voice
        enqueueTranscription(audioFileName: name, transcribeURL: storage.audioURL(for: name))
        state = .idle
    }

    /// Kicks off a background transcription: creates the placeholder item and fills it in when done.
    /// Doesn't touch `state` (only the counter), so it won't interfere with a new recording in progress.
    @MainActor
    private func enqueueTranscription(audioFileName: String?, transcribeURL: URL) {
        let duration = AudioPlayer.duration(of: transcribeURL)
        let id = onVoiceNoteStarted?(audioFileName, duration)
        transcribeInBackground(id: id, url: transcribeURL)
    }

    /// Retries transcribing the audio of an item that already exists (a failed note with its audio).
    @MainActor
    func retry(itemID: UUID, audioFileName: String) {
        onVoiceNoteRetrying?(itemID)
        transcribeInBackground(id: itemID, url: storage.audioURL(for: audioFileName))
    }

    /// Core of the background transcription (shared by record, upload and retry). Doesn't touch `state`.
    @MainActor
    private func transcribeInBackground(id: UUID?, url: URL) {
        transcribingCount += 1
        // Resolve the active provider's model here, on the MainActor (avoids reading Settings.shared
        // from the transcription thread). Gemini and OpenAI each have their own model setting.
        // Resolve the provider + its model here, on the MainActor (one snapshot — avoids both a data race
        // reading Settings.shared off-thread and a provider/model TOCTOU). Each provider uses its own key,
        // so no cross-provider fallback (recording is already gated on AIProvider.hasKey for the selection).
        let provider = Settings.shared.aiProvider
        let model = provider == "gemini" ? Settings.shared.geminiModel
                  : provider == "local"  ? Settings.shared.localModel
                  : Settings.shared.transcriptionModel
        let language = Settings.shared.transcriptionLanguage
        let vocabulary = Settings.shared.transcriptionVocabulary
        // First on-device use downloads the model: show "Downloading model…" so it doesn't look stuck.
        if provider == "local", !LocalTranscriber.isModelReady(model), let id { onVoiceNoteDownloadingModel?(id) }
        Task { @MainActor in
            defer { transcribingCount -= 1 }
            do {
                let text = try await AIProvider.transcribe(provider: provider, audioURL: url, language: language, model: model, vocabulary: vocabulary)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { if let id { onVoiceNoteFailed?(id) } }
                else { if let id { onVoiceNoteTranscribed?(id, trimmed) } }
            } catch {
                NSLog("Klip: transcription failed — %@", String(describing: error))   // surface, don't fail silently
                if let id { onVoiceNoteFailed?(id) }   // the audio stays in history to retry/recover
            }
        }
    }

    private func stopMeterTimer() { meterTimer?.invalidate(); meterTimer = nil }

    private static func normalized(power db: Float) -> Float {
        let minDb: Float = -50
        if db < minDb { return 0 }
        return min(1, (db - minDb) / -minDb)
    }

    nonisolated func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully ok: Bool) {
        Task { @MainActor in
            removeDeviceListener()   // ensures the listener is also removed if the delegate fires on its own
            finishing = false
            recorder = nil
            guard let name = currentFileName else { return }   // cancelled: not an error, just exit
            currentFileName = nil
            guard ok else { state = .error(L10n.t("rec.err.failed")); return }
            ingest(audioFileName: name)   // keeps the .m4a and transcribes
        }
    }

    deinit {
        // Safety net. deinit is nonisolated and can't call the @MainActor method, so remove the CoreAudio
        // listener inline (accessing the instance's own stored property in deinit is allowed).
        if let block = deviceListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
    }
}
