import Foundation
import AVFoundation
import AppKit
import Combine

enum RecorderState: Equatable {
    case idle
    case recording
    case transcribing
    case finished(String)   // transcripción lista; el popup muestra el resultado
    case missingAPIKey
    case error(String)
}

/// Graba una nota de voz a .m4a y la transcribe con OpenAI (no en vivo: nota completa).
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// true cuando llevamos >2 min en silencio: la UI muestra "¿Sigues ahí?".
    @Published private(set) var silenceWarning = false

    /// Se invoca (en main) con el texto transcrito al terminar con éxito.
    var onTranscribed: ((String) -> Void)?

    // Detección de silencio (timer a 0.1 s): aviso a 2 min, corte a 3 min.
    private var silentTicks = 0
    private let silenceLevel: Float = 0.10
    private let warnTicks = 1200    // 120 s
    private let stopTicks = 1800    // 180 s

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentFileName: String?
    private let client = OpenAIClient.shared
    private let storage = Storage.shared

    /// Intención de grabar pendiente (cubre la ventana del permiso async).
    private var startRequested = false
    var isBusy: Bool { startRequested || state == .recording || state == .transcribing }

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
        guard !isBusy else { return }
        startRequested = true
        Task { @MainActor in
            guard client.hasAPIKey else { state = .missingAPIKey; startRequested = false; return }
            guard await requestMicPermission() else {
                state = .error("Permiso de micrófono denegado"); startRequested = false; return
            }
            guard startRequested else { return }   // stop()/cancel() durante la espera del permiso
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
                    state = .error("No se pudo iniciar la grabación"); startRequested = false; return
                }
                recorder = rec
                currentFileName = name
                duration = 0; level = 0
                silentTicks = 0; silenceWarning = false
                state = .recording
                startRequested = false
                startMeterTimer()
            } catch {
                state = .error(error.localizedDescription); startRequested = false
            }
        }
    }

    @MainActor
    func stop() {
        startRequested = false
        guard state == .recording, let rec = recorder else { return }
        stopMeterTimer()
        rec.stop()   // dispara audioRecorderDidFinishRecording
    }

    @MainActor
    func cancel() {
        startRequested = false
        stopMeterTimer()
        recorder?.delegate = nil   // evita que el delegate sobrescriba .idle con .error
        recorder?.stop()
        recorder = nil
        if let f = currentFileName { storage.deleteAudio(fileName: f) }
        currentFileName = nil
        state = .idle
    }

    /// Vuelve a .idle desde estados terminales (error o sin API key) para revalidar al reabrir.
    func reset() {
        switch state {
        case .error, .missingAPIKey, .finished: state = .idle
        default: break
        }
    }

    private func startMeterTimer() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder else { return }
            rec.updateMeters()
            self.duration = rec.currentTime
            let lvl = Self.normalized(power: rec.averagePower(forChannel: 0))
            self.level = lvl
            self.trackSilence(level: lvl)
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
            MainActor.assumeIsolated { stop() }   // corte por inactividad: finaliza y transcribe
        }
    }

    /// El usuario pulsa "Continuar": resetea el contador de silencio.
    func continueRecording() { silentTicks = 0; silenceWarning = false }

    /// Transcribe uno o varios archivos de audio subidos por el usuario.
    @MainActor
    func transcribeFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isBusy else { return }
        guard client.hasAPIKey else { state = .missingAPIKey; return }
        state = .transcribing
        Task { @MainActor in
            let model = Settings.shared.transcriptionModel
            let language = Settings.shared.transcriptionLanguage
            var okCount = 0
            var lastError: String?
            for url in urls {
                do {
                    let text = try await client.transcribe(audioURL: url, language: language, model: model)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onTranscribed?(trimmed); okCount += 1 }
                } catch let e as OpenAIError {
                    lastError = e.errorDescription
                } catch {
                    lastError = error.localizedDescription
                }
            }
            // Si al menos una salió bien, cerrar normal; solo error si fallaron todas.
            if okCount == 0, let lastError { state = .error(lastError) } else { state = .idle }
        }
    }

    private func stopMeterTimer() { meterTimer?.invalidate(); meterTimer = nil }

    private static func normalized(power db: Float) -> Float {
        let minDb: Float = -50
        if db < minDb { return 0 }
        return min(1, (db - minDb) / -minDb)
    }

    func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully ok: Bool) {
        Task { @MainActor in
            recorder = nil
            guard ok, let name = currentFileName else { state = .error("La grabación falló"); return }
            currentFileName = nil
            defer { storage.deleteAudio(fileName: name) }        // borrar el .m4a en TODOS los caminos
            let url = storage.audioURL(for: name)
            state = .transcribing
            let model = Settings.shared.transcriptionModel       // leídos en MainActor (evita data race)
            let language = Settings.shared.transcriptionLanguage
            do {
                let text = try await client.transcribe(audioURL: url, language: language, model: model)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    state = .error("No se detectó voz. Intenta de nuevo.")
                } else {
                    onTranscribed?(trimmed)     // guardar en el historial
                    state = .finished(trimmed)  // mostrar el resultado (no cerrar solo)
                }
            } catch let e as OpenAIError {
                state = .error(e.errorDescription ?? "Error de transcripción")
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
