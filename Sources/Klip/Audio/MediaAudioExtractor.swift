import Foundation
import AVFoundation
import CoreAudio
import UniformTypeIdentifiers

/// Extracts the audio track of a VIDEO file into a small temporary audio file the transcriber accepts.
/// WhisperKit/AVAudioFile can't decode video containers (.mov/.mkv, and .mp4 with a video track).
/// The output is 16 kHz mono AAC .m4a — Whisper's native rate and the EXACT shape of
/// the app's own voice notes (see Recorder.start), so WhisperKit already decodes it. Uses AVAssetReader → AVAssetWriter
/// (not AVAssetExportSession) because only the reader/writer pair allows fixing sample rate + channels + codec,
/// and it stays within the macOS 14 deployment floor (the async export() overload is macOS 15+).
enum MediaAudioExtractor {

    /// Video containers we ACCEPT for upload (drop filter + file picker). Overlaps with the audio upload
    /// list (mp4/mpeg/webm can be either) are resolved precisely by `audioForTranscription`, which probes the tracks.
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "qt", "avi", "mkv", "webm", "mpg", "mpeg", "m2v",
        "m2ts", "mts", "ts", "3gp", "3g2", "flv", "wmv", "ogv", "mxf", "dv", "asf", "vob"
    ]

    enum ExtractionError: Error, LocalizedError {
        case drmProtected
        case noAudioTrack
        case unreadable
        case readFailed(Error?)
        case writeFailed

        /// L10n key shown on the failed row of the Upload window (mapped by Recorder's catch).
        var uploadErrorKey: String {
            switch self {
            case .drmProtected:     return "upload.videoProtected"
            case .noAudioTrack:     return "upload.noAudioTrack"
            case .unreadable, .readFailed, .writeFailed: return "upload.extractFailed"
            }
        }

        var errorDescription: String? {
            switch self {
            case .drmProtected:      return "This video is protected and its audio can't be read."
            case .noAudioTrack:      return "This video has no audio track to transcribe."
            case .unreadable:        return "Couldn't read this video file."
            case .readFailed(let e): return "Failed while reading the video's audio. \(e?.localizedDescription ?? "")"
            case .writeFailed:       return "Failed while extracting the audio."
            }
        }
    }

    /// Coarse admission check for the drop filter / file picker: is `url` plausibly a video container?
    /// Prefers the OS's real content type; an audio UTI wins. Falls back to the extension set for containers
    /// macOS doesn't register (mkv/webm). Over-including is harmless — `audioForTranscription` makes the real
    /// extract-vs-pass-through decision by probing the actual tracks.
    static func isVideo(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            if type.conforms(to: .audio) { return false }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// The pipeline entry point. Returns `url` UNCHANGED when it's already a decodable audio-only file (the
    /// common m4a/mp3/wav case — a cheap no-op). Otherwise extracts the audio track of a video container into a
    /// temporary .m4a that the CALLER must delete after transcription. Throws a specific ExtractionError (shown as
    /// a localized failed row) for DRM'd / audio-less / unreadable inputs.
    static func audioForTranscription(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        // DRM: FairPlay-protected media can't be decoded by us.
        if (try? await asset.load(.hasProtectedContent)) == true { throw ExtractionError.drmProtected }

        // No visible video track → treat it as audio and hand the ORIGINAL file to the transcriber unchanged.
        // WhisperKit reads common audio directly. This covers audio-only .mp4 (no needless re-encode — and,
        // once saved, it stays playable in history). Only a REAL video track gets demuxed.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        if videoTracks.isEmpty { return url }

        // A real video: pull out its audio track. Distinguish an unreadable file (load throws) from one that is
        // readable but genuinely has no audio (a silent screen recording) so the failed row is specific.
        let audioTracks: [AVAssetTrack]
        do { audioTracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw ExtractionError.unreadable }
        guard let track = audioTracks.first else { throw ExtractionError.noAudioTrack }

        return try await extract(asset: asset, track: track)
    }

    // MARK: - Extraction (AVAssetReader → AVAssetWriter, 16 kHz mono AAC .m4a)

    private static func extract(asset: AVAsset, track: AVAssetTrack) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlipVideoAudio-\(UUID().uuidString).m4a")
        return try await render(asset: asset,
                                output: AVAssetReaderTrackOutput(track: track, outputSettings: monoPCMSettings),
                                to: outURL, queue: "klip.audio-extraction") { failure in
            switch failure {
            case .unreadable:        return ExtractionError.unreadable
            case .readFailed(let e): return ExtractionError.readFailed(e)
            case .writeFailed:       return ExtractionError.writeFailed
            }
        }
    }

    // MARK: - Shared render (also used by MeetingRecorder's mic+system mix)

    /// Where a `render` run failed, so each caller maps it onto its OWN error type.
    enum RenderFailure {
        case unreadable          // the reader couldn't be created, wired up or started
        case readFailed(Error?)  // the reader died mid-pump
        case writeFailed         // the writer refused a buffer, or failed to start/finalize
    }

    /// One mono channel layout, applied to BOTH the reader's downmix and the AAC encoder (double
    /// insurance so a multichannel/5.1 source gets downmixed regardless of which stage honors it).
    static var monoLayout: Data {
        var mono = AudioChannelLayout(); mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        return Data(bytes: &mono, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// Reader-side settings: what the source decodes into before the AAC encode in `render`.
    static var monoPCMSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: monoLayout,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Pumps `output` (built with `monoPCMSettings`, from a track or an audio mix of `asset`) into a
    /// 16 kHz mono AAC .m4a at `outURL`. Callers map a failure onto their own error type through
    /// `mapError`; cancellation always surfaces as CancellationError. On any throw the partial file
    /// is removed, so nothing is orphaned in the temp directory.
    static func render(asset: AVAsset, output: AVAssetReaderOutput, to outURL: URL,
                       queue label: String,
                       error mapError: @escaping @Sendable (RenderFailure) -> Error) async throws -> URL {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outURL, fileType: .m4a)
        } catch { throw mapError(.unreadable) }

        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw mapError(.unreadable) }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: monoLayout,
            AVEncoderBitRateKey: 32_000,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw mapError(.writeFailed) }
        writer.add(input)

        guard reader.startReading() else { throw mapError(.unreadable) }
        guard writer.startWriting() else { throw mapError(.writeFailed) }
        writer.startSession(atSourceTime: .zero)

        // The pump runs in a dispatch callback with NO current Task, so Task.isCancelled is useless there;
        // a lock-protected flag flipped by the cancellation handler is checked on every pass.
        let cancelled = Flag()
        let queue = DispatchQueue(label: label)

        // AVFoundation types aren't Sendable, but the entire pump runs on the serial queue above
        // (the cancellation handler only touches the Flag), so wrapping them in an @unchecked Sendable box is safe.
        let box = PumpBox(reader: reader, writer: writer, input: input, output: output)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    box.input.requestMediaDataWhenReady(on: queue) {
                        while box.input.isReadyForMoreMediaData {
                            if cancelled.value {
                                box.reader.cancelReading(); box.input.markAsFinished(); box.writer.cancelWriting()
                                cont.resume(throwing: CancellationError()); return
                            }
                            guard let buf = box.output.copyNextSampleBuffer() else {
                                box.input.markAsFinished()
                                if box.reader.status == .failed {
                                    box.writer.cancelWriting()
                                    cont.resume(throwing: mapError(.readFailed(box.reader.error))); return
                                }
                                box.writer.finishWriting {
                                    if box.writer.status == .completed { cont.resume() }
                                    else { cont.resume(throwing: mapError(.writeFailed)) }
                                }
                                return
                            }
                            if !box.input.append(buf) {
                                box.reader.cancelReading(); box.writer.cancelWriting()
                                cont.resume(throwing: mapError(.writeFailed)); return
                            }
                        }
                    }
                }
            } onCancel: {
                cancelled.set()
            }
        } catch {
            try? FileManager.default.removeItem(at: outURL)   // never orphan a partial temp file
            throw error
        }

        return outURL
    }

    /// Tiny lock-protected Bool touched from two threads (cancellation handler + render pump).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// Box to pass the (non-Sendable) reader/writer objects into the pump's @Sendable closure.
    /// Safe because all of them are used only on the serial render queue.
    private struct PumpBox: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
    }
}
