import Foundation
import AVFoundation
import CoreAudio
import UniformTypeIdentifiers

/// Extracts the audio track of a VIDEO file into a small temp audio file that BOTH transcription paths accept.
/// WhisperKit/AVAudioFile can't decode video containers (.mov/.mkv, and video-track .mp4), and the cloud
/// uploads are size-capped. Output is 16 kHz mono AAC .m4a — Whisper's native rate and the EXACT shape of the
/// app's own voice notes (see Recorder.start), so WhisperKit already decodes it, OpenAI accepts it as
/// audio/mp4, and at ~14 MB/hour a normal clip stays under the cloud caps. Uses AVAssetReader → AVAssetWriter
/// (not AVAssetExportSession) because only the reader/writer pair lets us pin sample rate + channels + codec,
/// and it stays on the macOS 14 deployment floor (the async export() overload is macOS 15+).
enum MediaAudioExtractor {

    /// Video containers we ADMIT for upload (drop filter + file picker). Overlaps with the audio-upload list
    /// (mp4/mpeg/webm can be either) are resolved precisely by `audioForTranscription`, which probes tracks.
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
        case tooLargeForCloud

        /// L10n key shown in the Upload window's failed row (mapped by Recorder's catch).
        var uploadErrorKey: String {
            switch self {
            case .drmProtected:     return "upload.videoProtected"
            case .noAudioTrack:     return "upload.noAudioTrack"
            case .tooLargeForCloud: return "upload.tooLarge"
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
            case .tooLargeForCloud:  return "The audio is too large for cloud transcription."
            }
        }
    }

    /// Coarse admission check for the drop filter / file picker: is `url` plausibly a video container?
    /// Prefers the OS's real content type; an audio UTI wins. Falls back to the extension set for containers
    /// macOS doesn't register (mkv/webm). Over-inclusion is harmless — `audioForTranscription` makes the real
    /// extract-vs-passthrough decision by probing the actual tracks.
    static func isVideo(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            if type.conforms(to: .audio) { return false }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// The pipeline entry point. Returns `url` UNCHANGED when it's already a decodable audio-only file (the
    /// common m4a/mp3/wav case — a cheap no-op). Otherwise extracts the audio track of a video container into a
    /// temp .m4a the CALLER must delete after transcription. Throws a specific ExtractionError (surfaced as a
    /// localized failed row) for DRM / no-audio / unreadable inputs.
    static func audioForTranscription(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        // DRM: FairPlay-protected media can't be decoded by us or the cloud.
        if (try? await asset.load(.hasProtectedContent)) == true { throw ExtractionError.drmProtected }

        // No video track we can see → treat it as audio and hand the ORIGINAL file to the provider unchanged.
        // WhisperKit reads common audio directly, and the cloud APIs accept webm/ogg/mp3/mp4-audio/etc. This
        // covers audio-only .mp4 (no needless re-encode — and, once stored, it stays playable in history) and
        // containers AVFoundation can't demux but the cloud still accepts. Only a REAL video track is demuxed.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        if videoTracks.isEmpty { return url }

        // A real video: pull its audio track. Distinguish an unreadable file (load throws) from one that is
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

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outURL, fileType: .m4a)
        } catch { throw ExtractionError.unreadable }

        // One mono channel layout, shared by the reader's downmix and the AAC encoder (belt-and-suspenders so
        // a multichannel/5.1 source is downmixed regardless of which stage honors the layout).
        var mono = AudioChannelLayout(); mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layout = Data(bytes: &mono, count: MemoryLayout<AudioChannelLayout>.size)

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layout,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError.unreadable }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layout,
            AVEncoderBitRateKey: 32_000,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExtractionError.writeFailed }
        writer.add(input)

        guard reader.startReading() else { throw ExtractionError.unreadable }
        guard writer.startWriting() else { throw ExtractionError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        // The pump runs in a dispatch callback with NO current Task, so Task.isCancelled is useless there;
        // a lock-guarded flag flipped by the cancellation handler is checked each pass.
        let cancelled = Flag()
        let queue = DispatchQueue(label: "klip.audio-extraction")

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    input.requestMediaDataWhenReady(on: queue) {
                        while input.isReadyForMoreMediaData {
                            if cancelled.value {
                                reader.cancelReading(); input.markAsFinished(); writer.cancelWriting()
                                cont.resume(throwing: CancellationError()); return
                            }
                            guard let buf = output.copyNextSampleBuffer() else {
                                input.markAsFinished()
                                if reader.status == .failed {
                                    writer.cancelWriting()
                                    cont.resume(throwing: ExtractionError.readFailed(reader.error)); return
                                }
                                writer.finishWriting {
                                    if writer.status == .completed { cont.resume() }
                                    else { cont.resume(throwing: ExtractionError.writeFailed) }
                                }
                                return
                            }
                            if !input.append(buf) {
                                reader.cancelReading(); writer.cancelWriting()
                                cont.resume(throwing: ExtractionError.writeFailed); return
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

    /// Tiny lock-guarded bool touched from two threads (cancellation handler + extraction pump).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }
}
