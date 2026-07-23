import AppKit
import ScreenCaptureKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import IOKit.pwr_mgt

/// Records a screen region to an H.264 .mov with ScreenCaptureKit — the video sibling of
/// MeetingRecorder's audio stream (same SCStream + AVAssetWriter shape, same own-app exclusion).
///
/// Video shipped first on purpose — audio is the single most-patched area of every screen
/// recorder's changelog — and system audio followed once it could reuse MeetingRecorder's
/// already-debugged path: `capturesAudio` below, muxed as an AAC track, with Klip's own interface
/// cues excluded so they never end up in the recording. Container is QuickTime (.mov), not .mp4:
/// AVAssetWriter's movieFragmentInterval only fragments QuickTime files, and periodic fragments are
/// what make a crash mid-recording leave a playable file instead of a corrupt one.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate {
    @Published private(set) var isRecording = false
    /// True from the moment a start is REQUESTED until the stream is actually capturing (or failed).
    /// The spin-up takes several hundred ms (SCShareableContent + startCapture), and the toggle must
    /// treat that window as "recording" — otherwise a stop press during it reopens the picker while
    /// the first recording runs on unnoticed.
    private(set) var isStarting = false
    /// Where the live recording is happening — the floating indicator draws its frame from these.
    private(set) var activeScreen: NSScreen?
    private(set) var activeRegion: CGRect?
    private var startTask: Task<Void, Never>?
    private(set) var startedAt: Date?

    /// The finished recording, still at its TEMP location, plus its wall-clock duration. The caller
    /// owns the move (into the history store) and the toasts. nil URL = failed.
    var onFinished: ((URL?, Double?) -> Void)?

    private var stream: SCStream?
    private var videoWriter: VideoWriter?
    private var sleepAssertion: IOPMAssertionID = 0

    enum RecordingError: Error { case startFailed }

    /// Requests a recording of `region` (top-left-origin points, as the capture overlay hands it
    /// over) of `screen`. Synchronous on purpose: `isStarting` flips immediately, closing the race
    /// window where a second ⌥⇧V could pass the toggle as a fresh start. Failures toast from here.
    func begin(screen: NSScreen, region: CGRect) {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        startTask = Task { @MainActor in
            do { try await self.startCapture(screen: screen, region: region) }
            catch {
                self.isStarting = false
                SoundFX.error(); ToastHUD.show(L10n.t("rec.screen.failed"), style: .failure)
            }
            self.startTask = nil
        }
    }

    private func startCapture(screen: NSScreen, region: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw RecordingError.startFailed
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = region
        // Output pixels = points × scale, forced EVEN — H.264 encodes 4:2:0 chroma in 2×2 blocks,
        // and odd dimensions make the encoder pad or fail. Rounding down loses at most 1 point.
        config.width  = max(2, Int(region.width  * scale) & ~1)
        config.height = max(2, Int(region.height * scale) & ~1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        // SYSTEM audio (what's playing — a video, a call) muxed into the movie. Klip's own cues are
        // excluded so a toast never lands in the recording. Mic capture is a separate feature (it
        // needs its own permission + pipeline) — the meeting recorder owns that path.
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("klip-rec-\(UUID().uuidString).mov")
        let writer = try VideoWriter(url: tempURL, width: config.width, height: config.height)

        // delegate: self — didStopWithError is ScreenCaptureKit's ONLY stream-death notification
        // (display unplugged, permission revoked). Without it isRecording latches true and the
        // display-sleep assertion is held forever. MeetingRecorder handles it the same way.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        do { try await stream.startCapture() } catch {
            _ = await writer.finish()   // cancels the writer and deletes the orphaned temp file
            throw error
        }

        self.stream = stream
        self.videoWriter = writer
        self.startedAt = Date()
        self.activeScreen = screen
        self.activeRegion = region
        self.isStarting = false
        self.isRecording = true

        // Long recordings must survive the display trying to sleep (idle keyboard is the norm
        // while recording another app). Released in stop().
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Klip screen recording" as CFString, &sleepAssertion)
    }

    /// The stream died underneath us (display unplugged, permission revoked mid-recording):
    /// salvage the partial file through the normal stop path, which also releases the
    /// display-sleep assertion and un-latches isRecording.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in await self.stop() }
    }

    /// Stops and finalizes. Safe to call redundantly. A stop that lands during the spin-up window
    /// waits for the start to settle, then tears it down — so a fast double-press cancels cleanly
    /// instead of being swallowed.
    func stop() async {
        if let pending = startTask { await pending.value }
        guard isRecording, let stream, let writer = videoWriter else { return }
        isRecording = false
        self.stream = nil
        self.videoWriter = nil
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }

        activeScreen = nil
        activeRegion = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        try? await stream.stopCapture()
        let tempURL = await writer.finish()
        startedAt = nil
        onFinished?(tempURL, duration)
    }

    // MARK: - GIF export

    /// Transcodes a finished recording to an animated GIF next to it (same collision-safe naming).
    /// `nonisolated`: the whole decode/render/encode stretch is synchronous, so on the main actor it
    /// would beachball the app for seconds per recorded minute — off-main it costs nothing visible.
    ///
    /// MEMORY REALITY (measured): CGImageDestination is NOT a streaming encoder — it buffers every
    /// added frame (~6 MB each at 1000 px) until Finalize. Frames are therefore CAPPED at 300
    /// (≈ 30 s of GIF at 10 fps, ~2 GB peak); a longer recording gets its first 30 s. The honest
    /// fix is a chunked GIF writer — do that if anyone actually records multi-minute GIFs.
    ///
    /// Each frame carries its REAL distance to the next selected frame (clamped 0.1–4 s): screen
    /// recordings are sparse (ScreenCaptureKit only delivers frames on content change), and a fixed
    /// delay would compress every idle stretch, playing the GIF back absurdly fast.
    nonisolated static func exportGIF(from movie: URL) async throws -> URL {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.startFailed
        }
        let size = try await track.load(.naturalSize)
        let fps: Double = 10
        let maxFrames = 300
        let maxWidth: CGFloat = 1000
        let outScale = min(1, maxWidth / max(1, size.width))
        let outW = Int(size.width * outScale), outH = Int(size.height * outScale)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { throw RecordingError.startFailed }

        let gifTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klip-gif-\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(gifTemp as CFURL, UTType.gif.identifier as CFString,
                                                         0, nil) else { throw RecordingError.startFailed }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],   // loop forever
        ] as CFDictionary)
        func append(_ cg: CGImage, delay: Double) {
            let d = min(max(delay, 1.0 / fps), 4.0)
            CGImageDestinationAddImage(dest, cg, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d],
            ] as CFDictionary)
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var nextPTS = 0.0
        var held: (cg: CGImage, pts: Double)?   // a frame's delay is only known at the NEXT frame
        var appended = 0
        while appended < maxFrames, let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= nextPTS, let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextPTS = pts + 1.0 / fps
            var ci = CIImage(cvPixelBuffer: pixel)
            if outScale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: outScale, y: outScale)) }
            guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: outW, height: outH))
            else { continue }
            if let h = held { append(h.cg, delay: pts - h.pts); appended += 1 }
            held = (cg, pts)
        }
        reader.cancelReading()   // harmless when already .completed; required by the frame cap
        if let h = held, appended < maxFrames { append(h.cg, delay: 1.0 / fps); appended += 1 }
        guard appended > 0, CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: gifTemp)
            throw RecordingError.startFailed
        }
        return try Storage.shared.exportFileToDownloads(from: gifTemp, ext: "gif")
    }
}

/// Appends the SCStream's video sample buffers to the .mov writer. Every access (stream callback +
/// finish) runs on its serial `queue`, so @unchecked Sendable is safe — the exact shape of
/// MeetingRecorder's SystemAudioWriter, with video in place of audio.
private final class VideoWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "klip.screenrec.video")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let url: URL
    private var sessionStarted = false

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Periodic fragments: a crash/force-quit mid-recording still leaves a playable movie.
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        i.expectsMediaDataInRealTime = true
        // System-audio track (AAC, same recipe as MeetingRecorder's SystemAudioWriter).
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(i), w.canAdd(a) else { throw ScreenRecorder.RecordingError.startFailed }
        w.add(i)
        w.add(a)
        guard w.startWriting() else { throw ScreenRecorder.RecordingError.startFailed }
        writer = w; input = i; audioInput = a
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit delivers status frames (idle/blank) too — only append complete ones.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete else { return }
            // Session starts at the FIRST sample's PTS (video or audio, whichever lands first),
            // never .zero — a mismatch freezes the opening frames of the movie.
            startSessionIfNeeded(at: sampleBuffer.presentationTimeStamp)
            if input.isReadyForMoreMediaData { input.append(sampleBuffer) }   // realtime: drop when back-pressured
        case .audio:
            startSessionIfNeeded(at: sampleBuffer.presentationTimeStamp)
            if audioInput.isReadyForMoreMediaData { audioInput.append(sampleBuffer) }
        default:
            return   // .microphone (macOS 15+) and any future outputs are not registered
        }
    }

    private func startSessionIfNeeded(at pts: CMTime) {
        guard !sessionStarted else { return }
        writer.startSession(atSourceTime: pts)
        sessionStarted = true
    }

    /// Finalizes the file. Returns nil when nothing usable was captured.
    func finish() async -> URL? {
        await withCheckedContinuation { cont in
            queue.async {
                guard self.sessionStarted, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    cont.resume(returning: nil)
                    return
                }
                self.input.markAsFinished()
                self.audioInput.markAsFinished()
                self.writer.finishWriting {
                    cont.resume(returning: self.writer.status == .completed ? self.url : nil)
                }
            }
        }
    }
}
