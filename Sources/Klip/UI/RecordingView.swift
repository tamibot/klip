import SwiftUI

/// UI for the dedicated voice-recording popup (separate from the history panel).
struct RecordingView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings = Settings.shared   // re-localize live when the UI language changes
    var onStop: () -> Void
    var onCancel: () -> Void
    var onClose: () -> Void

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
            .frame(width: 320)   // fixed width; height sizes to content (no dead white space)
            .fixedSize(horizontal: false, vertical: true)
            // Cross-fade between states (recording ↔ silence warning ↔ errors) instead of jumping.
            .animation(.easeOut(duration: 0.13), value: recorder.state)
            .animation(.easeOut(duration: 0.13), value: recorder.silenceWarning)
            .onChange(of: recorder.state) { _, s in
                if case .idle = s { onClose() }
            }
    }

    @ViewBuilder private var content: some View {
        switch recorder.state {
        case .recording:
            if recorder.silenceWarning {
                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 34))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                    Text(L10n.t("rec.stillthere")).font(.system(size: 13, weight: .semibold))
                    Text(L10n.t("rec.silence.info"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L10n.t("rec.continue.recording")) { recorder.continueRecording() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).controlSize(.large)
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
                        Image(systemName: "circle.fill").font(.system(size: 9))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text(L10n.t("rec.recording")).font(.system(size: 13, weight: .semibold))
                    }
                    Text(timeString(recorder.duration))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    levelMeter
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
                    .controlSize(.large)
                }
                .padding()
            }

        case .micDenied:
            VStack(spacing: 12) {
                Image(systemName: "mic.slash.fill").font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                Text(L10n.t("perm.mic.title")).font(.system(size: 13, weight: .semibold))
                Text(L10n.t("perm.mic.info"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                Text(L10n.t("common.error")).font(.system(size: 13, weight: .semibold))
                Text(m).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                Button(L10n.t("common.close")) { recorder.reset() }.buttonStyle(.borderedProminent)
            }.padding()

        case .idle:
            Color.clear
        }
    }

    /// Horizontal capsule meter — same geometry, track, and motion as MeetingHUDView's meters,
    /// so the voice popup and the meeting HUD read as one family.
    private var levelMeter: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, recorder.level))))
                        .animation(.linear(duration: 0.1), value: recorder.level)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: 220)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
