import Foundation
import WhisperKit

/// On-device transcription with WhisperKit (Whisper on Core ML) — the only transcription engine, so no
/// audio ever leaves the Mac. The Core ML model is downloaded once on first use and cached; the pipeline
/// is kept in memory and reused while the chosen model doesn't change.
actor LocalTranscriber {
    static let shared = LocalTranscriber()

    private var pipe: WhisperKit?
    private var loadedModel: String?
    /// Flips to true once a pipeline has finished loading this session. The first on-device load pays a
    /// one-time Core ML / Neural-Engine specialization (~20 s, cached on disk afterwards); the UI reads this
    /// (best-effort, hence nonisolated) to show "Preparing model…" instead of a bare spinner until ready.
    nonisolated(unsafe) static private(set) var pipelineReady = false
    /// Serializes on-device decodes: the shared WhisperKit instance has mutable state (progress, timings,
    /// Core ML decoder) that is NOT safe to run concurrently. Dropping several audio files at once would
    /// otherwise race. Each call chains after the previous one's decode.
    private var serialTail: Task<Void, Never> = Task {}

    /// Friendly model name → WhisperKit model identifier. Each id is a folder name in the
    /// argmaxinc/whisperkit-coreml HF repo (WhisperKit globs `*<id>/*` against it), so a typo here is a
    /// download that 404s on first use. Sizes are the summed blob sizes of that folder — measured, not
    /// guessed: the old table claimed "~1.5 GB" for large-v3_turbo, which actually pulls 3 GB.
    static let models: [(id: String, label: String, note: String)] = [
        ("tiny",        "Tiny",        "~75 MB · fastest · lowest accuracy"),
        ("base",        "Base",        "~145 MB · faster · decent accuracy"),
        ("small",       "Small",       "~464 MB · balanced"),
        ("large-v3-v20240930_turbo_632MB", "Large v3 Turbo (compact)",
                                       "~616 MB · recommended · near-best accuracy for ~150 MB more than Small"),
        ("large-v3_turbo", "Large v3 Turbo (full)",
                                       "~3.0 GB · best accuracy · 5× the download of the compact one"),
    ]
    /// What a FRESH install is seeded with (see Settings.init). Quantized Large v3 Turbo: the accuracy of
    /// large-v3 on mixed-language speech and proper nouns, at 1/5 the download of the full turbo weights.
    static let recommendedModel = "large-v3-v20240930_turbo_632MB"
    /// Stand-in for an empty stored id AND the fallback when the chosen model fails to load/download.
    /// Deliberately NOT `recommendedModel`: a fallback that itself needs a 616 MB download is no fallback.
    /// Kept equal to what Settings registers, so existing installs have exactly one answer.
    static let defaultModel = "small"

    /// Loads an ALREADY-DOWNLOADED model into memory so the first voice note is instant. Best-effort, on
    /// launch. It deliberately does NOT trigger a first-use download here — pulling a multi-hundred-MB model
    /// silently at app launch would surprise users on metered/slow links; that download happens lazily on the
    /// first voice note (with the "Downloading model…" status).
    func prewarm(model: String) async {
        let id = model.isEmpty ? Self.defaultModel : model
        guard Self.isModelReady(id) else { return }
        _ = try? await pipeline(for: id)
    }

    /// Whether the model's CoreML weights are actually on disk (not just a folder created mid-download).
    /// Used to (a) skip the launch prewarm for un-downloaded models and (b) show "Downloading model…".
    nonisolated static func isModelReady(_ model: String) -> Bool {
        let id = model.isEmpty ? defaultModel : model
        guard let base = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false) else { return false }
        let dir = base.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        // Exact folder name, not a prefix: WhisperKit names the folder "openai_whisper-<id>" verbatim, and a
        // prefix match makes one variant claim another's download ("large-v3_turbo" would accept the
        // "…_954MB" folder, "base" the "base.en" one) → "Ready" for a model that isn't there.
        let folder = "openai_whisper-\(id)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              entries.contains(folder) else { return false }
        // Require the actual weights: an interrupted download leaves only metadata (generation_config.json).
        let modelDir = dir.appendingPathComponent(folder)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: modelDir.appendingPathComponent($0).path)
        }
    }

    /// Transcribes an audio file fully on-device. `model` is a WhisperKit model name (see `models`).
    /// `vocabulary` (context words/names) biases recognition via Whisper prompt tokens.
    /// `strict` forbids the fallback to `defaultModel` when the requested model can't be loaded — set it
    /// when the CALLER picked the model on purpose and a different one would be worse than an error
    /// (Recorder.improve overwrites an existing transcript with the result).
    /// Public entry: serializes decodes on the shared pipeline (see `serialTail`).
    func transcribe(audioURL: URL, model: String, language: String?, vocabulary: String,
                    strict: Bool = false) async throws -> String {
        let previous = serialTail
        let job = Task<String, Error> {
            _ = await previous.value   // wait for any in-flight decode before touching the shared WhisperKit
            let results = try await self.performTranscribe(audioURL: audioURL, model: model, language: language,
                                                           vocabulary: vocabulary, strict: strict)
            return results.map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        serialTail = Task { _ = try? await job.value }   // next call chains after this one
        return try await job.value
    }

    /// Like `transcribe`, but returns the raw segments with their start timestamps — used by meeting
    /// notes to interleave the mic and system tracks chronologically ("Me:"/"Them:" labels).
    func transcribeSegments(audioURL: URL, model: String, language: String?, vocabulary: String) async throws -> [(start: TimeInterval, text: String)] {
        let previous = serialTail
        let job = Task<[(start: TimeInterval, text: String)], Error> {
            _ = await previous.value
            let results = try await self.performTranscribe(audioURL: audioURL, model: model, language: language,
                                                           vocabulary: vocabulary, timestamps: true)
            return results.flatMap { $0.segments }
                .map { (start: TimeInterval($0.start), text: $0.text) }
        }
        serialTail = Task { _ = try? await job.value }
        return try await job.value
    }

    private func performTranscribe(audioURL: URL, model: String, language: String?, vocabulary: String,
                                   timestamps: Bool = false, strict: Bool = false) async throws -> [TranscriptionResult] {
        let wk = try await pipeline(for: model.isEmpty ? Self.defaultModel : model, strict: strict)
        var opts = DecodingOptions()
        opts.task = .transcribe
        opts.skipSpecialTokens = true
        opts.withoutTimestamps = !timestamps
        // SPEED: split long audio at silence (energy VAD) and decode chunks in parallel
        // (concurrentWorkerCount defaults to 16). Short clips stay one chunk → no overhead; long uploads
        // transcribe much faster. The model is loaded once and reused (see `pipeline`).
        opts.chunkingStrategy = .vad
        if let language, !language.isEmpty {
            opts.language = language          // explicit audio language
            opts.detectLanguage = false
        } else {
            opts.detectLanguage = true        // "auto-detect"
        }
        // Bias toward the user's context words/names: encode them as
        // Whisper prompt tokens. WhisperKit also strips special tokens and caps length internally.
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty, let tok = wk.tokenizer {
            let ids = tok.encode(text: " " + vocab).filter { $0 < tok.specialTokens.specialTokenBegin }
            if !ids.isEmpty {
                opts.promptTokens = Array(ids.suffix(200))
                opts.usePrefillPrompt = true
                // Once per transcription, so the context-words feature is verifiable in Console.app.
                NSLog("Klip LocalTranscriber: biasing decode with %d context-word prompt tokens", opts.promptTokens?.count ?? 0)
            }
        }
        return try await wk.transcribe(audioPath: audioURL.path, decodeOptions: opts)
    }

    /// Remembers a model id that failed to load → the id it fell back to, so we don't re-attempt the
    /// failing download on every subsequent transcription.
    private var fallbackFor: [String: String] = [:]

    private func pipeline(for model: String, strict: Bool = false) async throws -> WhisperKit {
        // A remembered fallback is a convenience for the automatic path only: when the caller asked for
        // THIS model explicitly, honour the request (and fail loudly if it still can't be loaded).
        let effective = strict ? model : (fallbackFor[model] ?? model)
        if let pipe, loadedModel == effective { return pipe }
        let wk: WhisperKit
        do {
            wk = try await WhisperKit(WhisperKitConfig(model: effective))   // downloads the model on first use
            loadedModel = effective
        } catch {
            // A bad/unavailable model id (or a failed download for that variant) shouldn't break every
            // transcription — fall back to the default model and remember it (no repeated failed downloads).
            // Never under `strict`: that caller replaces an existing transcript with the result, so a
            // silent downgrade to a weaker model would be data loss wearing a success message.
            guard !strict, effective != Self.defaultModel else { throw error }
            wk = try await WhisperKit(WhisperKitConfig(model: Self.defaultModel))
            loadedModel = Self.defaultModel
            fallbackFor[model] = Self.defaultModel
        }
        pipe = wk
        Self.pipelineReady = true
        return wk
    }
}
