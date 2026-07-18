import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Window to upload audio files and transcribe them: drop zone + file picker.
struct UploadView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings = Settings.shared   // re-localize live when the UI language changes
    var onChoose: (String) -> Void
    var onFiles: ([URL], String) -> Void
    var onClose: () -> Void
    var onOpenPreferences: () -> Void
    var onCopy: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovering = false
    /// true after a drop with no accepted file: shows the "unsupported format" caption under the drop zone.
    @State private var dropRejected = false
    /// nil = follow the global/platform language (stays reactive); set = override for this upload session.
    @State private var languageOverride: String?
    private var effectiveLanguage: String { languageOverride ?? settings.transcriptionLanguage }

    // Formats the transcribers actually accept. (Dropped aac/aiff: OpenAI rejects them and they'd fail
    // silently; .m4b is treated as .m4a on upload.)
    private let exts = ["m4a", "m4b", "mp3", "wav", "mp4", "flac", "ogg", "oga", "opus",
                        "webm", "mpga", "mpeg"]

    var body: some View {
        VStack(spacing: 16) {
            switch recorder.state {
            case .missingAPIKey:
                Image(systemName: "key.slash").font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                Text(L10n.t("rec.nokey.title")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(L10n.t("common.close")) { onClose() }
                    Button(L10n.t("rec.openprefs")) { onOpenPreferences(); onClose() }.buttonStyle(.borderedProminent)
                }
            case .error(let m):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                Text(m).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.t("common.close")) { recorder.reset(); onClose() }
            default:
                Text(L10n.t("upload.title")).font(.title2.bold()).tracking(-0.3)
                dropZone
                if dropRejected {
                    Text(L10n.t("upload.unsupported"))
                        .font(.system(size: 11)).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                languagePicker
                Text(L10n.t("upload.info"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if recorder.transcribingCount > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(recorder.extractingCount > 0
                             ? L10n.t("upload.extracting")
                             : recorder.preparingModel
                               ? L10n.t("upload.preparing")
                               : String(format: L10n.t(recorder.transcribingCount == 1 ? "upload.transcribing.one" : "upload.transcribing.many"), recorder.transcribingCount))
                    }
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                if !recorder.uploadResults.isEmpty { resultsSection }
                Button(L10n.t("common.close")) { onClose() }
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .top)
        .padding()
        // Fade in the rejected-drop caption and the transcribing pill; slide result rows in as they land.
        .animation(.easeOut(duration: 0.13), value: dropRejected)
        .animation(.easeOut(duration: 0.13), value: recorder.transcribingCount)
        .animation(.easeOut(duration: 0.2), value: recorder.uploadResults)
        // Each fresh upload session (results cleared by uploadAudio) starts back at the global language.
        .onChange(of: recorder.uploadResults.isEmpty) { _, empty in if empty { languageOverride = nil } }
    }

    /// The transcriptions of the just-uploaded files, filled in live as each one finishes.
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("upload.results")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(recorder.uploadResults) { resultRow($0) }
                }
            }
            .frame(maxHeight: .infinity)   // take the remaining space → the Close button stays pinned + reachable
        }
    }

    private func resultRow(_ r: UploadTranscription) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(r.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if r.text == nil && !r.failed {
                    ProgressView().controlSize(.small)
                } else if r.failed {
                    // Retryable rows: audio kept in the store, or a real video whose source is still readable.
                    if r.audioFileName != nil || r.sourceURL != nil {
                        Button { recorder.retryUpload(r) } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(PressableButtonStyle()).help(L10n.t("voice.retry"))
                    }
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                } else {
                    Button { copyText(r.text ?? "") } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(PressableButtonStyle()).help(L10n.t("row.copy"))
                }
            }
            if let t = r.text {
                Text(t).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(8)
            } else if r.failed {
                Text(L10n.t(r.errorKey ?? "upload.failed")).font(.system(size: 11)).foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
    }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        onCopy(text)   // route through the manager so the poll doesn't re-capture it as a duplicate item
    }

    /// Per-upload language: defaults to the platform/global language but can be overridden for this specific
    /// audio (e.g. a French clip while the app default is Spanish).
    private var languagePicker: some View {
        Picker(L10n.t("upload.audioLang"), selection: Binding(
            get: { effectiveLanguage },
            set: { languageOverride = $0 }
        )) {
            Text(L10n.t("lang.auto")).tag("")
            ForEach(DictationLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill").font(.system(size: 38))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
            Text(L10n.t("upload.drop")).font(.system(size: 13, weight: .semibold))
            Text(L10n.t("upload.or")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L10n.t("upload.choose")) { dropRejected = false; onChoose(effectiveLanguage) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity).frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hovering ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.quaternary)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.5)))
        // Ease the highlight in/out instead of the instant color swap.
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onDrop(of: [UTType.fileURL], isTargeted: $hovering) { providers in
            handleDrop(providers); return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // loadItem delivers its callback on an arbitrary internal queue and the providers run in
                // parallel: accumulating on main serializes the appends (Array is not thread-safe).
                let resolved: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? URL)
                DispatchQueue.main.async {
                    if let resolved { urls.append(resolved) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            // Accept audio (exts) and video (MediaAudioExtractor is the single source of truth for video, so the
            // drop filter and the file picker admit the same set); a video's audio is extracted before transcribing.
            let media = urls.filter { exts.contains($0.pathExtension.lowercased()) || MediaAudioExtractor.isVideo($0) }
            if !media.isEmpty {
                dropRejected = false
                if media.count < urls.count {
                    // Mixed drop: the supported files proceed, but don't silently swallow the rest.
                    MainActor.assumeIsolated {
                        SoundFX.warning()
                        ToastHUD.show(String(format: L10n.t("upload.skipped"), urls.count - media.count),
                                      style: .failure)
                    }
                }
                onFiles(media, effectiveLanguage)
            } else if !urls.isEmpty {
                // Everything dropped was unsupported: don't swallow it silently.
                MainActor.assumeIsolated { SoundFX.error() }
                dropRejected = true
            }
        }
    }
}
