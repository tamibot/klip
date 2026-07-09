import SwiftUI

/// UI for the dedicated voice-recording popup (separate from the history panel).
struct RecordingView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings = Settings.shared   // re-localize live when the UI language changes
    var onStop: () -> Void
    var onCancel: () -> Void
    var onClose: () -> Void
    var onOpenPreferences: () -> Void

    /// Armed by the first Cancel/Esc on a long recording: the button reads "Discard?" until it auto-resets.
    @State private var confirmDiscard = false

    /// Long recordings (>10 s) need a second Cancel/Esc within ~3 s — one stray Esc shouldn't
    /// destroy minutes of audio. Short recordings keep the instant cancel. The Cancel buttons carry
    /// .cancelAction, so the click and the Esc key both land here.
    private func requestCancel() {
        if recorder.duration > 10, !confirmDiscard {
            confirmDiscard = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDiscard = false }
        } else {
            confirmDiscard = false
            onCancel()
        }
    }

    var body: some View {
        VStack(spacing: 16) { content }
            .frame(width: 360, height: 320)
            .onChange(of: recorder.state) { _, s in
                if case .idle = s { onClose() }
            }
    }

    @ViewBuilder private var content: some View {
        switch recorder.state {
        case .recording:
            if recorder.silenceWarning {
                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 34)).foregroundStyle(.orange)
                    Text(L10n.t("rec.stillthere")).font(.headline)
                    Text(L10n.t("rec.silence.info"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L10n.t("rec.continue.recording")) { recorder.continueRecording() }
                        .keyboardShortcut(.defaultAction)
                    HStack(spacing: 12) {
                        Button(confirmDiscard ? L10n.t("rec.discard.confirm") : L10n.t("common.cancel"),
                               action: requestCancel)
                            .keyboardShortcut(.cancelAction)
                            .tint(confirmDiscard ? .red : nil)
                        Button(L10n.t("rec.stop"), action: onStop)
                    }
                }.padding()
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 11, height: 11)
                            .opacity(recorder.level > 0.12 ? 1 : 0.5)
                        Text(L10n.t("rec.recording")).font(.headline)
                    }
                    Text(timeString(recorder.duration))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    levelBars
                    HStack(spacing: 12) {
                        Button(action: requestCancel) {
                            Label(confirmDiscard ? L10n.t("rec.discard.confirm") : L10n.t("common.cancel"),
                                  systemImage: confirmDiscard ? "trash" : "xmark")
                        }
                        .keyboardShortcut(.cancelAction)
                        .tint(confirmDiscard ? .red : nil)
                        Button(action: onStop) {
                            Label(L10n.t("rec.stop"), systemImage: "stop.fill")
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    }
                }.padding()
            }

        case .missingAPIKey:
            VStack(spacing: 12) {
                Image(systemName: "key.slash").font(.system(size: 34)).foregroundStyle(.orange)
                Text(L10n.t("rec.nokey.title")).font(.headline)
                Text(L10n.t("rec.nokey.info"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(L10n.t("common.close")) { recorder.reset() }
                    Button(L10n.t("rec.openprefs")) { onOpenPreferences(); recorder.reset() }
                        .buttonStyle(.borderedProminent)
                }
            }.padding()

        case .micDenied:
            VStack(spacing: 12) {
                Image(systemName: "mic.slash.fill").font(.system(size: 34)).foregroundStyle(.orange)
                Text(L10n.t("perm.mic.title")).font(.headline)
                Text(L10n.t("perm.mic.info"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(L10n.t("common.close")) { recorder.reset() }
                    Button(L10n.t("perm.screen.open")) {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(u)
                        }
                        recorder.reset()
                    }.buttonStyle(.borderedProminent)
                }
            }.padding()

        case .error(let m):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
                Text(L10n.t("common.error")).font(.headline)
                Text(m).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                Button(L10n.t("common.close")) { recorder.reset() }.buttonStyle(.borderedProminent)
            }.padding()

        case .idle:
            Color.clear
        }
    }

    private var levelBars: some View {
        let active = Int((recorder.level * 18).rounded())
        return HStack(spacing: 3) {
            ForEach(0..<18, id: \.self) { i in
                Capsule()
                    .fill(i < active ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 4, height: i < active ? 10 + CGFloat((i % 4) * 6) : 6)
            }
        }
        .frame(height: 34)
        .animation(.linear(duration: 0.1), value: recorder.level)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
