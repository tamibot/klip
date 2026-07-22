import Foundation
import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records a meeting: the microphone AND the system audio output (the other participants) at the
/// same time, mixes both locally into one 16 kHz mono AAC .m4a and hands it to the existing
/// voice-note pipeline (history item + background transcription — on-device by default).
/// Manual start/stop; everything stays local. System audio comes from ScreenCaptureKit
/// (capturesAudio), which requires the Screen Recording permission the app already uses for capture.
@MainActor
final class MeetingRecorder: NSObject, ObservableObject, SCStreamDelegate, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Live input levels (0…1) for the recording HUD — proof that BOTH sides are being heard.
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// True from stop() until the mix + note handoff completes (the HUD shows "Mixing…").
    @Published private(set) var finishing = false
    /// Busy for the whole span of a meeting — including the async startup window (mic permission,
    /// SCShareableContent) and the stop/discard teardown. The mic/meeting mutual exclusion keys
    /// off this instead of isRecording alone (wired in AppDelegate).
    var isBusy: Bool { isRecording || startRequested || stopping }

    /// The mixed audio is already in the store: creates the voice-note item and returns its id
    /// (wired to manager.beginVoiceNote + rename). (audioFileName, duration) → item id.
    var onMeetingReady: ((String, Double?) -> UUID?)?
    /// Kicks off the transcription of the ready note through the existing Recorder path.
    /// (itemID, mixedAudioFileName, micTempURL, systemTempURL) — the temp track URLs let the local
    /// provider transcribe each side separately (Me/Them labels); the callee deletes them when done.
    var onTranscribe: ((UUID, String, URL?, URL?) -> Void)?
    /// The voice-note recorder owns the mic → refuse to start a meeting while it records.
    var isMicBusy: (() -> Bool)?

    enum MeetingError: Error, LocalizedError {
        case startFailed
        case nothingRecorded
        case mixFailed
        case saveFailed
        var errorDescription: String? {
            switch self {
            case .startFailed:      return "Couldn't start the meeting recording."
            case .nothingRecorded:  return "Nothing was recorded."
            case .mixFailed:        return "Failed while mixing the meeting audio."
            case .saveFailed:       return "Couldn't save the meeting audio."
            }
        }
    }

    private var stream: SCStream?
    private var systemWriter: SystemAudioWriter?
    private var micRecorder: AVAudioRecorder?
    private var micStopContinuation: CheckedContinuation<Void, Never>?
    /// Bumped per teardown so the 3s watchdog only resumes the continuation it was armed for —
    /// a stale watchdog must not cut short the NEXT teardown's finalization wait.
    private var micStopGeneration = 0
    private var timer: Timer?
    private var micURL: URL?
    private var systemURL: URL?
    /// Pending intent to record (covers the async permission/startup window).
    private var startRequested = false
    /// true from when stop is requested until the mix/handoff finishes.
    private var stopping = false
    /// Set when the system-audio stream dies mid-recording: the mic keeps going (a meeting note
    /// with only your side is still useful) and the mix uses whatever system audio was captured.
    private var systemStreamFailed = false
    /// "Last time we heard anything" on EITHER source — drives the auto-stop after 15 silent minutes.
    private let activity = ActivityClock()
    private static let silenceLevel: Float = 0.10          // same floor as Recorder's silence detection
    private static let autoStopAfterSilence: TimeInterval = 15 * 60
    private let storage = Storage.shared

    func start() {
        guard !isRecording, !startRequested, !stopping else { return }
        if isMicBusy?() == true {
            Self.alert(L10n.t("meeting.busy.title"), L10n.t("meeting.busy.info"))
            return
        }
        // Cloud provider without a key: fail BEFORE the meeting, not after an hour of recording
        // (local returns true, so the on-device default never hits this).
        guard AIProvider.hasKey else {
            Self.alert(L10n.t("rec.nokey.title"), L10n.t("rec.nokey.info"))
            return
        }
        // Same Screen Recording flow as SnapController (shared askedKey): the FIRST time only the
        // native system prompt; afterwards our own guide with a shortcut to System Settings.
        guard ScreenCapturer.hasPermission() else {
            promptForScreenPermission()
            return
        }
        startRequested = true
        Task { @MainActor in
            defer { startRequested = false }
            guard await Recorder.requestMicPermission() else {
                Self.alert(L10n.t("perm.mic.title"), L10n.t("perm.mic.info"))
                return
            }
            do {
                try await startStreams()
            } catch {
                _ = await teardownStreams()
                cleanupTempFiles()
                Self.alert(L10n.t("meeting.record"), error.localizedDescription)
                return
            }
            elapsed = 0
            activity.touch()
            isRecording = true
            startTimer()
            // No start chime on purpose: the mic track is already recording, so the cue would be baked
            // into the head of the meeting note. The meeting HUD signals the start.
        }
    }

    func stop() async {
        guard isRecording, !stopping else { return }
        stopping = true
        finishing = true
        SoundFX.play(.recordStop)
        timer?.invalidate(); timer = nil
        let duration = elapsed
        let systemOK = await teardownStreams()
        isRecording = false
        micLevel = 0; systemLevel = 0
        defer { stopping = false; finishing = false; cleanupTempFiles() }

        var sources: [URL] = []
        if let micURL { sources.append(micURL) }
        if systemOK, let systemURL { sources.append(systemURL) }
        do {
            let mixed = try await Self.mix(sources: sources)
            defer { try? FileManager.default.removeItem(at: mixed) }
            guard let stored = storage.importAudio(from: mixed) else { throw MeetingError.saveFailed }
            if let id = onMeetingReady?(stored, duration) {
                // Hand the temp TRACK files to the transcription (the local provider transcribes them
                // separately for Me/Them labels and deletes them when done). Anything not handed off
                // (a dead system file, or no note) is removed by cleanupTempFiles in the defer above.
                let mic = micURL; let sys = systemOK ? systemURL : nil
                micURL = nil; if systemOK { systemURL = nil }
                onTranscribe?(id, stored, mic, sys)
            }
        } catch {
            NSLog("Klip: meeting recording failed — %@", String(describing: error))
            Self.alert(L10n.t("meeting.record"), error.localizedDescription)
        }
    }

    /// Throws the recording away: tear everything down and delete the temp tracks — no mix, no note.
    func discard() async {
        guard isRecording, !stopping else { return }
        stopping = true
        timer?.invalidate(); timer = nil
        _ = await teardownStreams()
        isRecording = false
        micLevel = 0; systemLevel = 0
        cleanupTempFiles()
        stopping = false
    }

    /// Removes leftover temp tracks from a previous run that died mid-recording (crash/kill):
    /// they are unfinalized (often unplayable) and would otherwise pile up in the temp directory.
    static func sweepOrphanedTempFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for n in names where (n.hasPrefix("mic-") || n.hasPrefix("system-") || n.hasPrefix("meeting-")) && n.hasSuffix(".m4a") {
            try? fm.removeItem(at: tmp.appendingPathComponent(n))
        }
    }

    // MARK: - Capture (system audio via SCStream + mic via AVAudioRecorder)

    private func startStreams() async throws {
        systemStreamFailed = false

        // a) SYSTEM AUDIO: SCStream with audio capture on and video made as cheap as possible
        // (2×2 px, 1 fps, and no video output is ever added — the frames are just dropped).
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MeetingError.startFailed }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't record Klip's own sounds
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sysURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-\(UUID().uuidString).m4a")
        let writer = try SystemAudioWriter(url: sysURL, activity: activity)
        // Track the file BEFORE the throwing calls: cleanupTempFiles is nil-safe, so a failure in
        // addStreamOutput/startCapture no longer orphans system-*.m4a. Private audio → 0600.
        self.systemURL = sysURL
        Storage.restrict(sysURL.path, 0o600)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()
        self.stream = stream; self.systemWriter = writer

        // b) MIC: same shape as Recorder.start (AAC 16 kHz mono).
        let micURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let rec = try AVAudioRecorder(url: micURL, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true   // feeds the silence auto-stop (see startTimer)
        self.micURL = micURL           // track BEFORE the throwing guard so a record() failure is cleaned up
        guard rec.prepareToRecord(), rec.record() else { throw MeetingError.startFailed }
        Storage.restrict(micURL.path, 0o600)   // the recording contains the user's voice
        self.micRecorder = rec
    }

    /// Stops mic + system stream and finalizes the system writer. Returns whether the system
    /// audio file is usable. Safe to call on a partially-started state (start failure path).
    private func teardownStreams() async -> Bool {
        if let rec = micRecorder {
            if rec.isRecording {
                // Wait for AVAudioRecorder to finalize the file (delegate fires after stop()) — with a
                // safety resume: if the delegate never fires, a hung wait here would freeze the whole
                // meeting flow forever (stopping=true blocks every further toggle).
                micStopGeneration += 1
                let generation = micStopGeneration
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    micStopContinuation = cont
                    rec.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.micStopGeneration == generation else { return }
                        self.micStopContinuation?.resume()
                        self.micStopContinuation = nil
                    }
                }
            } else {
                // Already stopped on its own (encode error, device loss): stop() is a no-op and the
                // delegate will never fire — awaiting here would hang the meeting forever.
                rec.stop()
            }
            micRecorder = nil
        }
        if let stream {
            // stopCapture is known to hang when the stream is in a bad state: race it against a
            // timeout. The writer below finalizes whatever was captured either way.
            await Self.withTimeout(seconds: 4) { try? await stream.stopCapture() }
            self.stream = nil
        }
        var ok = false
        if let writer = systemWriter {
            ok = await Self.withTimeout(seconds: 5, fallback: false) { await writer.finish() }
        }
        systemWriter = nil
        return ok
    }

    /// Runs `op` but gives up after `seconds` (the orphaned task is abandoned, not cancelled —
    /// SCStream/AVAssetWriter calls aren't cancellable anyway). Void variant.
    private static func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async {
        _ = await withTimeout(seconds: seconds, fallback: true) { await op(); return true }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, fallback: T,
                                                 _ op: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }

    private func cleanupTempFiles() {
        for url in [micURL, systemURL] where url != nil { try? FileManager.default.removeItem(at: url!) }
        micURL = nil; systemURL = nil
    }

    private func promptForScreenPermission() {
        let askedKey = "klip.askedScreenRecording"   // shared with SnapController so the prompts never overlap
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            ScreenCapturer.requestPermission()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("perm.screen.title")
        alert.informativeText = L10n.t("perm.screen.info")
        alert.addButton(withTitle: L10n.t("perm.screen.open"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTimer() {
        var tick = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {   // runs on RunLoop.main
                guard let self, self.isRecording else { return }
                // Live levels for the HUD: mic via metering (Recorder's pattern); system via the
                // peak reported from SystemAudioWriter's sample callback.
                if let rec = self.micRecorder {
                    rec.updateMeters()
                    let lvl = Recorder.normalized(power: rec.averagePower(forChannel: 0))
                    self.micLevel = lvl
                    if lvl >= Self.silenceLevel { self.activity.touch() }
                }
                self.systemLevel = self.activity.currentLevel
                tick += 1
                guard tick % 10 == 0 else { return }
                self.elapsed += 1
                // Auto-stop after 15 continuous minutes of silence on BOTH sources (the meeting ended
                // and the user forgot): finalize normally so nothing recorded is lost.
                if Date().timeIntervalSince(self.activity.lastActivity) >= Self.autoStopAfterSilence {
                    Task { @MainActor in await self.stop() }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func alert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - Delegates

    /// System stream died mid-recording (display sleep, etc.): keep the mic going — your side of
    /// the meeting is still useful. The partial system file is finalized and mixed in at stop().
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.isRecording else { return }
            self.systemStreamFailed = true
            NSLog("Klip: system-audio stream died mid-meeting (mic keeps recording) — %@", String(describing: error))
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // A late callback from an already-torn-down recorder must not resume the next
            // teardown's continuation.
            guard recorder === self.micRecorder else { return }
            self.micStopContinuation?.resume()
            self.micStopContinuation = nil
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        // The recorder dies without a didFinishRecording: release any waiter so stop() can't hang.
        Task { @MainActor in
            NSLog("Klip: meeting mic encode error — %@", String(describing: error))
            guard recorder === self.micRecorder else { return }   // stale callback, see above
            self.micStopContinuation?.resume()
            self.micStopContinuation = nil
        }
    }

    // MARK: - Mix (mic + system → one 16 kHz mono AAC .m4a)

    /// Overlays the source files with an AVMutableComposition (both inserted at .zero) and renders
    /// the mix through AVAssetReaderAudioMixOutput → AVAssetWriter, 16 kHz mono AAC — the exact
    /// shape of the app's own voice notes. The reader/writer pump is MediaAudioExtractor.render
    /// (see there for why reader/writer instead of AVAssetExportSession); every failure of it is a
    /// mixFailed here.
    private static func mix(sources: [URL]) async throws -> URL {
        let comp = AVMutableComposition()
        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration > .zero,
                  let compTrack = comp.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }   // a dead/empty capture: mix whatever else we have
            try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        let tracks = comp.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MeetingError.nothingRecorded }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-\(UUID().uuidString).m4a")
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks,
                                                 audioSettings: MediaAudioExtractor.monoPCMSettings)
        return try await MediaAudioExtractor.render(asset: comp, output: output, to: outURL,
                                                    queue: "klip.meeting-mix") { _ in MeetingError.mixFailed }
    }
}

/// Lock-protected "last time we heard anything" timestamp, touched from the main timer (mic
/// metering) and the SCStream sample queue (system audio). Drives the 15-min silence auto-stop.
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var level: Float = 0
    private var levelAt = Date.distantPast
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    /// Records the system side's current peak (for the HUD meter) and, above the noise floor,
    /// also counts as activity for the silence auto-stop.
    func report(level newLevel: Float, isActivity: Bool) {
        lock.lock()
        level = newLevel; levelAt = Date()
        if isActivity { last = Date() }
        lock.unlock()
    }
    var lastActivity: Date { lock.lock(); defer { lock.unlock() }; return last }
    /// Latest reported level; decays to 0 when no buffer arrived recently (stream stalled/quiet).
    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(levelAt) < 0.5 ? level : 0
    }
}

/// Appends the SCStream's audio sample buffers to an .m4a writer (AAC 48 kHz stereo). Every
/// access (stream callback + finish) runs on its serial `queue`, so @unchecked Sendable is safe.
private final class SystemAudioWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "klip.meeting.system-audio")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let activity: ActivityClock
    private var sessionStarted = false

    init(url: URL, activity: ActivityClock) throws {
        self.activity = activity
        let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { throw MeetingRecorder.MeetingError.startFailed }
        w.add(i)
        guard w.startWriting() else { throw MeetingRecorder.MeetingError.startFailed }
        writer = w; input = i
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }   // realtime: drop when back-pressured
        let peak = Self.peak(sampleBuffer)
        activity.report(level: peak, isActivity: peak > 0.01)   // HUD meter + silence auto-stop
    }

    /// Cheap peak estimate over a strided subset of the Float32 PCM samples. Layout (interleaved
    /// or not) doesn't matter for a level indicator / presence detection.
    private static func peak(_ sb: CMSampleBuffer) -> Float {
        guard let block = sb.dataBuffer, let data = try? block.dataBytes() else { return 0 }
        return data.withUnsafeBytes { raw -> Float in
            let floats = raw.bindMemory(to: Float32.self)
            var m: Float = 0
            var i = 0
            while i < floats.count {
                let v = abs(floats[i])
                if v > m { m = v }
                i += 32
            }
            return min(1, m * 1.4)   // slight boost so normal speech reads as a healthy bar
        }
    }

    /// Finalizes the file. Returns false when nothing usable was captured (no session/failed writer).
    func finish() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                guard self.sessionStarted, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    cont.resume(returning: false); return
                }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    cont.resume(returning: self.writer.status == .completed)
                }
            }
        }
    }
}
