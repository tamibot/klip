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

/// The transcription of an uploaded audio file, shown live in the Upload window. `text == nil` while it runs.
struct UploadTranscription: Identifiable, Equatable {
    let id: UUID            // the voice note item's id
    let name: String        // original file name
    var text: String?       // filled in when the transcription finishes
    var failed: Bool = false
    var errorKey: String? = nil   // L10n key for a SPECIFIC failure (no audio track / DRM / too large); nil → generic
    var audioFileName: String? = nil   // set when the note kept its audio (upload copy or audio-only container) → retryable
    var sourceURL: URL? = nil          // original video URL (videos aren't stored) → a failed row can re-extract from it
    var language: String? = nil        // per-upload language override at enqueue time → a retry keeps it
    var allowAutoCopy: Bool = true     // false for batch rows → a retry must not re-arm the clipboard auto-copy
}

/// Records a voice note to .m4a and transcribes it with OpenAI (not live: the whole note at once).
/// Transcription runs in the background: once stopped, the recorder is free to record another.
@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// true once we've been silent for >2 min: the UI shows "Are you still there?".
    @Published private(set) var silenceWarning = false
    /// Number of transcriptions running in the background (for the header indicator).
    @Published private(set) var transcribingCount = 0
    /// True while an on-device transcription waits for the model to load for the first time this
    /// session (the one-time ~20 s Neural Engine warm-up). Lets the UI say "Preparing model…"
    /// so the first note doesn't look stuck on a plain "Transcribing…" spinner.
    @Published private(set) var preparingModel = false
    /// Transcriptions of files dropped/picked in the Upload window, newest first — so the
    /// result shows up right there when done (not just in the history). Capped; cleared when a new upload session opens.
    @Published private(set) var uploadResults: [UploadTranscription] = []
    /// Number of uploads currently DEMUXING a video's audio track (before transcription starts).
    /// Feeds the "Extracting audio…" state so a long video doesn't look stuck on a plain "Transcribing…" spinner.
    @Published private(set) var extractingCount = 0

    /// The audio is already saved: creates the voice note item (placeholder) and returns its id.
    /// `audioFileName` may be nil if the file could not be saved (the transcription is stored anyway).
    var onVoiceNoteStarted: ((String?, Double?, Bool) -> UUID?)?   // (audioFileName, duration, allowAutoCopy)
    /// Fills in the transcription on the already-created item.
    var onVoiceNoteTranscribed: ((UUID, String) -> Void)?
    /// Fills in the audio duration once read off the main thread (keeps the UI from freezing on bulk uploads).
    var onVoiceNoteDuration: ((UUID, Double) -> Void)?
    /// Transcription failed or there was no speech: the item keeps the audio for playback/recovery.
    var onVoiceNoteFailed: ((UUID) -> Void)?
    /// Retry: marks an existing item as "Transcribing…" again. The Bool carries the original
    /// allowAutoCopy decision (false for batch-upload rows: don't re-arm the clipboard per retried file).
    var onVoiceNoteRetrying: ((UUID, Bool) -> Void)?
    /// First on-device use: the model is downloading, so a distinct state is shown instead of "Transcribing…".
    var onVoiceNoteDownloadingModel: ((UUID) -> Void)?
    /// An upload classified as video turned out to be pure audio (audio-only .mp4, etc.): its audio was stored, so
    /// attach it to the note so playback/retry keep working (real videos are intentionally not stored).
    var onVoiceNoteAudioStored: ((UUID, String) -> Void)?

    // Silence detection (0.1 s timer): warns at 2 min, stops at 3 min.
    private var silentTicks = 0
    private let silenceLevel: Float = 0.10
    private let warnTicks = 1200    // 120 s
    private let stopTicks = 1800    // 180 s

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentFileName: String?
    private let storage = Storage.shared
    /// CoreAudio listener to detect default microphone changes (e.g. plugging in headphones).
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Pending intent to record (covers the async permission window).
    private var startRequested = false
    /// true from when stop is requested until the delegate finishes (state stays .recording in that window).
    private(set) var finishing = false
    /// Only blocks starting another RECORDING; transcribing in the background doesn't count as busy.
    var isRecording: Bool { startRequested || state == .recording }

    /// Shared with MeetingRecorder, which records the mic on the same terms.
    static func requestMicPermission() async -> Bool {
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
            guard await Self.requestMicPermission() else {
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
                    storage.deleteAudio(fileName: name)   // prepareToRecord() created the file; record() failed → don't leave it orphaned
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
                // No start chime on purpose: rec.record() is already live above, so the cue would be
                // picked up by the mic and baked into the head of the note. The HUD signals the start.
            } catch {
                state = .error(error.localizedDescription); startRequested = false
            }
        }
    }

    @MainActor
    func stop() {
        startRequested = false
        guard state == .recording, !finishing, let rec = recorder else { return }   // ignore double stop
        finishing = true
        stopMeterTimer()
        removeDeviceListener()
        SoundFX.play(.recordStop)
        rec.stop()   // fires audioRecorderDidFinishRecording
    }

    @MainActor
    func cancel() {
        startRequested = false
        finishing = false
        stopMeterTimer()
        removeDeviceListener()
        recorder?.delegate = nil   // keeps the delegate from overwriting .idle with .error
        recorder?.stop()
        recorder = nil
        if let f = currentFileName { storage.deleteAudio(fileName: f) }
        currentFileName = nil
        state = .idle
    }

    // MARK: - Input device change (headphones)

    /// Watches the default microphone. If it changes DURING recording (e.g. you plug in headphones),
    /// AVAudioRecorder stays on the old device and the meter freezes → we finish the note
    /// cleanly (what was recorded so far is saved and transcribed) instead of leaving a broken state.
    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // The block is dispatched on DispatchQueue.main (passed below), so it already runs on the main
        // thread — assert MainActor directly instead of an extra async hop.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleInputDeviceChange() }
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
        stopMeterTimer()   // never stack a second timer: a leaked one would double-tick trackSilence
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
            SoundFX.warning()
        } else if silentTicks >= stopTicks {
            stop()   // stop due to inactivity: finish and transcribe (already on MainActor via the meter timer)
        }
    }

    /// The user taps "Continue": resets the silence counter.
    func continueRecording() { silentTicks = 0; silenceWarning = false }

    /// Transcribes one or more audio files uploaded by the user (in the background).
    /// Each audio is copied into our store so it can be played back and kept afterwards.
    /// `language` overrides the spoken-language hint for THIS upload only (e.g. the user dropped a French
    /// audio while the app default is Spanish). Pass "" for auto-detect, nil to use the global default.
    @MainActor
    func transcribeFiles(_ urls: [URL], language: String? = nil) {
        guard !urls.isEmpty else { return }
        guard AIProvider.hasKey else {
            // `state` is shared with a live recording (RecordingView/UploadView both observe it). Only
            // report "missing key" through it when idle, so a keyless upload doesn't kill an in-progress note.
            if state != .recording && !finishing { state = .missingAPIKey }
            return
        }
        // No forced auto-copy: finishVoiceNote already puts the transcription on the clipboard when it's
        // safe (changeCount guard — doesn't clobber what the user copied in the meantime — and never a secret).
        let allowAutoCopy = urls.count == 1   // a batch would rewrite the clipboard once per file
        Task { @MainActor in
            for url in urls {
                // Video: don't copy the (often large) file into the audio store — transcribe straight from the
                // original (the app is not sandboxed, so the URL stays readable) and let the transcription
                // bottleneck demux its audio to a temp file. The resulting note is text-only
                // (no playback/retry), which is honest because we deliberately don't keep the
                // video. Audio keeps the copy-to-store so it stays playable/retryable in the history.
                let isVideo = MediaAudioExtractor.isVideo(url)
                // The store copy is a real byte copy when the source lives on another volume: run it off the
                // main actor (same reason the duration read is detached) so a bulk drop doesn't freeze the UI.
                // Sequential awaits keep the enqueue order matching the drop order.
                let stored = isVideo ? nil : await Task.detached(priority: .userInitiated) {
                    Storage.shared.importAudio(from: url)                       // copies to audio/ (nil on failure)
                }.value
                let transcribeURL = stored.map { storage.audioURL(for: $0) } ?? url
                enqueueTranscription(audioFileName: stored, transcribeURL: transcribeURL,
                                     uploadName: url.lastPathComponent, language: language,
                                     allowAutoCopy: allowAutoCopy)
            }
        }
    }

    /// Clears the Upload window's results list (called when a new upload session opens, see PanelController).
    @MainActor func clearUploadResults() { uploadResults.removeAll() }

    private func fillUploadResult(_ id: UUID, text: String?, failed: Bool, errorKey: String? = nil) {
        guard let i = uploadResults.firstIndex(where: { $0.id == id }) else { return }   // not an upload: no-op
        uploadResults[i].text = text
        uploadResults[i].failed = failed
        uploadResults[i].errorKey = errorKey
    }

    /// Creates the voice note item with its audio already saved and kicks off the transcription.
    /// The audio is NEVER deleted here: it stays accessible even if the transcription fails.
    /// `state` returns to .idle immediately → the recorder is free to record another note.
    @MainActor
    private func ingest(audioFileName name: String) {
        storage.protectAudio(fileName: name)   // 0600: the recording contains the user's voice
        enqueueTranscription(audioFileName: name, transcribeURL: storage.audioURL(for: name))
        state = .idle
    }

    /// Kicks off a background transcription: creates the placeholder item and fills it in when done.
    /// Doesn't touch `state` (only the counter), so it doesn't interfere with a new recording in progress.
    @MainActor
    private func enqueueTranscription(audioFileName: String?, transcribeURL: URL, uploadName: String? = nil, language: String? = nil, allowAutoCopy: Bool = true) {
        let id = onVoiceNoteStarted?(audioFileName, nil, allowAutoCopy)
        // Reading the duration builds an AVAudioPlayer (parses the file) — do it off the main actor so
        // a bulk upload doesn't freeze the UI, then fill it in. The imminent transcription save persists it.
        if let id {
            Task { @MainActor in
                if let dur = await Task.detached(priority: .utility, operation: { AudioPlayer.duration(of: transcribeURL) }).value {
                    onVoiceNoteDuration?(id, dur)
                }
            }
        }
        if let uploadName, let id {   // show this file's progress + result in the Upload window
            // No stored audio means a real video: keep its source URL so a failed row can retry (re-extract).
            uploadResults.insert(UploadTranscription(id: id, name: uploadName, audioFileName: audioFileName,
                                                     sourceURL: audioFileName == nil ? transcribeURL : nil,
                                                     language: language, allowAutoCopy: allowAutoCopy), at: 0)
            // List cap: prefer evicting a COMPLETED/failed entry (never an in-flight one — that
            // would orphan its fillUploadResult). If ALL are still in flight, a hard cap drops the
            // oldest so the list doesn't grow unbounded.
            if uploadResults.count > 25 {
                if let i = uploadResults.lastIndex(where: { $0.text != nil || $0.failed }) { uploadResults.remove(at: i) }
                else if uploadResults.count > 50 { uploadResults.removeLast() }
            }
        }
        transcribeInBackground(id: id, url: transcribeURL, languageOverride: language)
    }

    /// Transcribes the already-stored audio of an already-created item (meeting recordings: the
    /// item was created via beginVoiceNote — already "Transcribing…" — so no state to flip first).
    @MainActor
    func transcribeExisting(itemID: UUID, audioFileName: String) {
        transcribeInBackground(id: itemID, url: storage.audioURL(for: audioFileName))
    }

    /// Meeting note transcription. On-device (the default): the mic and system TRACKS are transcribed
    /// SEPARATELY with segment timestamps and interleaved into a "Me:"/"Them:" labeled transcript
    /// (Granola-style, all local). Cloud providers transcribe the stored MIXED file instead (no labels —
    /// same as the retry path). Owns the temp track files: they are deleted when transcription finishes.
    @MainActor
    func transcribeMeetingTracks(itemID: UUID, micURL: URL?, systemURL: URL?, mixedFileName: String) {
        func deleteTemps() {
            for u in [micURL, systemURL] where u != nil { try? FileManager.default.removeItem(at: u!) }
        }
        guard Settings.shared.aiProvider == "local" else {
            deleteTemps()
            transcribeExisting(itemID: itemID, audioFileName: mixedFileName)
            return
        }
        transcribingCount += 1
        let model = Settings.shared.localModel
        let language = Settings.shared.transcriptionLanguage
        let vocabulary = Settings.shared.transcriptionVocabulary
        if !LocalTranscriber.isModelReady(model) { onVoiceNoteDownloadingModel?(itemID) }
        if !LocalTranscriber.pipelineReady { preparingModel = true }
        Task { @MainActor in
            defer {
                transcribingCount -= 1
                if transcribingCount == 0 || LocalTranscriber.pipelineReady { preparingModel = false }
                deleteTemps()
            }
            // Each track is best-effort: a dead system capture must not kill the whole meeting note.
            // If BOTH yield nothing, the note fails (its mixed audio stays playable + retryable).
            var segments: [(start: TimeInterval, source: Int, text: String)] = []
            if let micURL, let segs = try? await LocalTranscriber.shared.transcribeSegments(
                audioURL: micURL, model: model, language: language, vocabulary: vocabulary) {
                segments += segs.map { ($0.start, 0, $0.text) }
            }
            if let systemURL, let segs = try? await LocalTranscriber.shared.transcribeSegments(
                audioURL: systemURL, model: model, language: language, vocabulary: vocabulary) {
                segments += segs.map { ($0.start, 1, $0.text) }
            }
            let text = Self.mergeMeetingSegments(segments)
            if text.isEmpty { onVoiceNoteFailed?(itemID) }
            else { onVoiceNoteTranscribed?(itemID, text) }
        }
    }

    /// Interleaves mic (source 0 → "Me") and system (source 1 → "Them") segments chronologically,
    /// grouping consecutive segments of the same source under one label. Blank line between groups.
    private static func mergeMeetingSegments(_ segments: [(start: TimeInterval, source: Int, text: String)]) -> String {
        var groups: [(source: Int, texts: [String])] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            // Strip any leaked Whisper timestamp tokens (<|0.00|>) — decoding runs WITH timestamps here.
            let clean = seg.text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if groups.last?.source == seg.source { groups[groups.count - 1].texts.append(clean) }
            else { groups.append((seg.source, [clean])) }
        }
        return groups.map {
            L10n.t($0.source == 0 ? "meeting.me" : "meeting.them") + ": " + $0.texts.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    /// Retries transcribing the audio of an existing item (a failed note with its audio).
    /// The defaults fit the history retry path (global language, auto-copy on); the Upload-window
    /// retry passes the row's original language override and allowAutoCopy decision through.
    @MainActor
    func retry(itemID: UUID, audioFileName: String, languageOverride: String? = nil, allowAutoCopy: Bool = true) {
        onVoiceNoteRetrying?(itemID, allowAutoCopy)
        transcribeInBackground(id: itemID, url: storage.audioURL(for: audioFileName), languageOverride: languageOverride)
    }

    /// Retries a failed Upload-window row in place: stored audio goes through the normal retry path;
    /// a real video (deliberately not stored) is re-enqueued from its source URL, extracting the audio again.
    /// fillUploadResult (called by transcribeInBackground) updates the same row when it finishes.
    @MainActor
    func retryUpload(_ r: UploadTranscription) {
        guard let i = uploadResults.firstIndex(where: { $0.id == r.id }), uploadResults[i].failed else { return }
        let row = uploadResults[i]
        if let af = row.audioFileName, storage.audioExists(fileName: af) {
            uploadResults[i].failed = false; uploadResults[i].errorKey = nil   // row shows the spinner again
            retry(itemID: row.id, audioFileName: af, languageOverride: row.language, allowAutoCopy: row.allowAutoCopy)
        } else if let src = row.sourceURL, FileManager.default.fileExists(atPath: src.path) {
            uploadResults[i].failed = false; uploadResults[i].errorKey = nil
            onVoiceNoteRetrying?(row.id, row.allowAutoCopy)
            transcribeInBackground(id: row.id, url: src, languageOverride: row.language)   // video: demuxes the audio track again
        } else {
            // Neither the stored audio nor the original video is on disk any more (moved/deleted/ejected
            // volume): the retry can never succeed. Say so instead of returning silently, and drop the
            // stale refs so the row stops offering a retry button that does nothing. Stays .failed.
            uploadResults[i].errorKey = "upload.sourceMissing"
            uploadResults[i].audioFileName = nil
            uploadResults[i].sourceURL = nil
        }
    }

    /// Core of the background transcription (shared by record, upload and retry). Doesn't touch `state`.
    @MainActor
    private func transcribeInBackground(id: UUID?, url: URL, languageOverride: String? = nil) {
        transcribingCount += 1
        // Resolve the active provider's model here, on the MainActor (avoids reading Settings.shared
        // from the transcription thread). Gemini and OpenAI each have their own model setting.
        // Resolve the provider + its model here, on the MainActor (a single snapshot — avoids both a data race
        // reading Settings.shared off-thread and a provider/model TOCTOU). Each provider uses its own
        // key, so there is no cross-provider fallback (recording is already gated on AIProvider.hasKey for the selection).
        let provider = Settings.shared.aiProvider
        let model = provider == "gemini" ? Settings.shared.geminiModel
                  : provider == "local"  ? Settings.shared.localModel
                  : Settings.shared.transcriptionModel
        let language = languageOverride ?? Settings.shared.transcriptionLanguage   // the per-upload override wins
        let vocabulary = Settings.shared.transcriptionVocabulary
        // First on-device use downloads the model: show "Downloading model…" so it doesn't look stuck.
        if provider == "local", !LocalTranscriber.isModelReady(model), let id { onVoiceNoteDownloadingModel?(id) }
        // The session's first on-device transcription pays a one-time Core ML / Neural Engine
        // warm-up (~20 s, then cached): surface it as "Preparing model…" instead of a plain "Transcribing…" spinner.
        if provider == "local", !LocalTranscriber.pipelineReady { preparingModel = true }
        Task { @MainActor in
            // Clear "Preparing…" when the counter empties OR the pipeline is already warm (an overlapping
            // transcription is then actually transcribing, not preparing).
            defer { transcribingCount -= 1; if transcribingCount == 0 || LocalTranscriber.pipelineReady { preparingModel = false } }
            do {
                // VIDEO NORMALIZATION: WhisperKit/AVAudioFile can't decode video containers, so
                // first demux the audio track to a temp 16 kHz mono AAC .m4a. Only runs for
                // video inputs; audio (record / retry / audio upload) skips it entirely. Runs
                // off the MainActor → the await suspends without blocking the UI. Upstream of the provider switch,
                // so local + both clouds receive decodable audio (and fixes the latent bug where an .mp4 with a video track failed silently on the local path).
                let mediaURL: URL
                if MediaAudioExtractor.isVideo(url) {
                    extractingCount += 1
                    do { mediaURL = try await MediaAudioExtractor.audioForTranscription(from: url) }
                    catch { extractingCount -= 1; throw error }
                    extractingCount -= 1
                    // Passthrough (mediaURL == url) means it was audio in a movie-typed container
                    // (e.g. an audio-only .mp4), NOT a real video — so store it now so the note stays
                    // playable/retryable (a real video is deliberately not stored, see transcribeFiles).
                    // Guards: (1) don't re-import on a retry (the source already lives in the store — it would duplicate the
                    // file on every retry); (2) only with a CONFIRMED audio track — a container that
                    // AVFoundation can't demux (mkv/wmv/vob…) also falls into passthrough, and without this
                    // check we'd copy the whole video into the store as unplayable "audio".
                    if mediaURL == url, let id,
                       !url.path.hasPrefix(storage.audioBaseURL.path),
                       (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio))?.isEmpty == false,
                       // Real byte copy when the source is on another volume: offload it like the sibling
                       // path at transcribeFiles, so an audio-in-movie-container from an external drive
                       // doesn't freeze the UI on the main actor.
                       // (operation: passed explicitly — a trailing closure inside an `if` condition
                       // is ambiguous with the `if` body, and the compiler warns about exactly that.)
                       let stored = await Task.detached(priority: .userInitiated,
                                                        operation: { Storage.shared.importAudio(from: url) }).value {
                        onVoiceNoteAudioStored?(id, stored)
                        // Also remember it on the upload row so a failed row retries from the stored audio.
                        if let j = uploadResults.firstIndex(where: { $0.id == id }) { uploadResults[j].audioFileName = stored }
                    }
                } else {
                    mediaURL = url
                }
                let cleanupTemp = (mediaURL != url)
                defer { if cleanupTemp { try? FileManager.default.removeItem(at: mediaURL) } }

                // Cloud size pre-check: 16 kHz mono AAC is ~14 MB/h, so a very long clip
                // can still exceed the cloud caps. OpenAI sends raw bytes (~25 MB limit → 24 MB floor);
                // Gemini sends base64 inline_data (~4/3 inflation against a ~20 MB request cap → ~15 MB of raw audio).
                // Turn the opaque HTTP failure into a clear "too large — switch to on-device" row. Local
                // (WhisperKit) has no size limit → skip.
                let cloudLimit = provider == "gemini" ? 15_000_000 : 24_000_000
                if provider != "local",
                   let sz = try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int,
                   sz > cloudLimit {
                    throw MediaAudioExtractor.ExtractionError.tooLargeForCloud
                }

                let text = try await AIProvider.transcribe(provider: provider, audioURL: mediaURL, language: language, model: model, vocabulary: vocabulary)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { if let id { onVoiceNoteFailed?(id); fillUploadResult(id, text: nil, failed: true) } }
                else { if let id { onVoiceNoteTranscribed?(id, trimmed); fillUploadResult(id, text: trimmed, failed: false) } }
            } catch {
                NSLog("Klip: transcription failed — %@", String(describing: error))   // make it visible, don't fail silently
                let key = (error as? MediaAudioExtractor.ExtractionError)?.uploadErrorKey
                if let id { onVoiceNoteFailed?(id); fillUploadResult(id, text: nil, failed: true, errorKey: key) }   // the audio stays in the history for retry/recovery
            }
        }
    }

    private func stopMeterTimer() { meterTimer?.invalidate(); meterTimer = nil }

    /// dB (AVAudioRecorder metering) → 0…1 bar height. Shared with MeetingRecorder's mic meter.
    static func normalized(power db: Float) -> Float {
        let minDb: Float = -50
        if db < minDb { return 0 }
        return min(1, (db - minDb) / -minDb)
    }

    nonisolated func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully ok: Bool) {
        Task { @MainActor in
            stopMeterTimer()         // the delegate can fire on its own (encode error/disk full): don't leak the 10 Hz timer
            removeDeviceListener()   // ensures the listener is removed even if the delegate fires on its own
            finishing = false
            recorder = nil
            guard let name = currentFileName else { return }   // cancelled: not an error, just bail
            currentFileName = nil
            guard ok else { state = .error(L10n.t("rec.err.failed")); return }
            ingest(audioFileName: name)   // keeps the .m4a and transcribes
        }
    }

    deinit {
        // Safety net. deinit is nonisolated and can't call the @MainActor method, so remove the
        // CoreAudio listener inline (accessing the instance's own stored property in deinit is allowed).
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
