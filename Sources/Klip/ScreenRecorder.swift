import AppKit
import ScreenCaptureKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import IOKit.pwr_mgt

/// Records a screen region to an H.264 .mov with ScreenCaptureKit — the video sibling of
/// MeetingRecorder's audio stream (same SCStream + AVAssetWriter shape, same own-app exclusion).
///
/// Video-only on purpose: the target use is a silent demo or a GIF for a chat, and audio is the
/// single most-patched area of every screen recorder's changelog — it arrives separately, reusing
/// MeetingRecorder's already-debugged audio path. Container is QuickTime (.mov), not .mp4:
/// AVAssetWriter's movieFragmentInterval only fragments QuickTime files, and periodic fragments are
/// what make a crash mid-recording leave a playable file instead of a corrupt one.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// The finished recording, already moved to ~/Downloads. nil = failed (an error toast is the caller's job).
    var onFinished: ((URL?) -> Void)?

    private var stream: SCStream?
    private var videoWriter: VideoWriter?
    private var sleepAssertion: IOPMAssertionID = 0

    enum RecordingError: Error { case startFailed }

    /// Starts recording `region` (top-left-origin points, as the capture overlay hands it over) of
    /// `screen`. Recording begins immediately — the overlay has already been dismissed, and Klip's
    /// own windows (menu-bar item included) are excluded from the stream.
    func start(screen: NSScreen, region: CGRect) async throws {
        guard !isRecording else { return }

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

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("klip-rec-\(UUID().uuidString).mov")
        let writer = try VideoWriter(url: tempURL, width: config.width, height: config.height)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()

        self.stream = stream
        self.videoWriter = writer
        self.startedAt = Date()
        self.isRecording = true

        // Long recordings must survive the display trying to sleep (idle keyboard is the norm
        // while recording another app). Released in stop().
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Klip screen recording" as CFString, &sleepAssertion)
    }

    /// Stops, finalizes and moves the file to ~/Downloads. Safe to call redundantly.
    func stop() async {
        guard isRecording, let stream, let writer = videoWriter else { return }
        isRecording = false
        self.stream = nil
        self.videoWriter = nil
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }

        try? await stream.stopCapture()
        let tempURL = await writer.finish()
        startedAt = nil
        guard let tempURL else { onFinished?(nil); return }
        let exported = try? Storage.shared.exportFileToDownloads(from: tempURL, ext: "mov")
        if exported == nil { try? FileManager.default.removeItem(at: tempURL) }
        onFinished?(exported)
    }

    // MARK: - GIF export

    /// Transcodes a finished recording to an animated GIF next to it (same collision-safe naming).
    /// Streams frame by frame — decode one, downscale, append, release — so a long recording never
    /// holds its frames in memory. 10 fps and ≤1000 px wide: the classic chat-friendly tradeoff.
    static func exportGIF(from movie: URL) async throws -> URL {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.startFailed
        }
        let size = try await track.load(.naturalSize)
        let fps: Double = 10
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
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps],
        ] as CFDictionary

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var nextPTS = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= nextPTS, let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextPTS = pts + 1.0 / fps
            var ci = CIImage(cvPixelBuffer: pixel)
            if outScale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: outScale, y: outScale)) }
            guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: outW, height: outH))
            else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
        }
        guard reader.status == .completed, CGImageDestinationFinalize(dest) else {
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
        guard w.canAdd(i) else { throw ScreenRecorder.RecordingError.startFailed }
        w.add(i)
        guard w.startWriting() else { throw ScreenRecorder.RecordingError.startFailed }
        writer = w; input = i
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        // ScreenCaptureKit delivers status frames (idle/blank) too — only append complete ones.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else { return }
        // Session starts at the FIRST sample's PTS, never .zero — a mismatch freezes the opening
        // frames of the movie.
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }   // realtime: drop when back-pressured
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
                self.writer.finishWriting {
                    cont.resume(returning: self.writer.status == .completed ? self.url : nil)
                }
            }
        }
    }
}
