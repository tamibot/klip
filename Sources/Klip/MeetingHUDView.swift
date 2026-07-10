import SwiftUI

/// Floating HUD shown while a meeting records: live level meters for BOTH sources (proof that
/// your mic AND the meeting's system audio are being heard), elapsed time, and stop/discard.
struct MeetingHUDView: View {
    @ObservedObject var recorder: MeetingRecorder
    var onStop: () -> Void
    var onDiscard: () -> Void

    @State private var pulse = false
    /// Last time the system side showed real signal — drives the "no meeting audio yet" hint.
    @State private var lastSystemSignal = Date()

    private var mmss: String {
        let s = Int(recorder.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 12) {
            if recorder.finishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("meeting.finishing")).font(.system(size: 12, weight: .medium))
                }
                .padding(.vertical, 6)
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                        .opacity(pulse ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    Text(L10n.t("meeting.recording")).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(mmss).font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L10n.t("meeting.autostop.tip"))
                }

                meter(label: L10n.t("meeting.me"), icon: "mic.fill", level: recorder.micLevel, tint: .accentColor)
                meter(label: L10n.t("meeting.them"), icon: "speaker.wave.2.fill", level: recorder.systemLevel, tint: .teal)

                // One-line legend: first-time users shouldn't have to guess what the two bars are.
                Text(L10n.t("meeting.sources.hint"))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The system side heard nothing for a while: surface it — this is exactly the doubt
                // ("is it capturing them at all?") this HUD exists to answer.
                if Date().timeIntervalSince(lastSystemSignal) > 10, recorder.elapsed > 8 {
                    Label(L10n.t("meeting.nosystem"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button(role: .destructive) { onDiscard() } label: {
                        Text(L10n.t("editor.discard.confirm")).font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Spacer(minLength: 8)
                    Button { onStop() } label: {
                        Label(L10n.t("rec.stop"), systemImage: "stop.fill").font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 264)
        // Cross-fade into the finishing state instead of jumping.
        .animation(.easeOut(duration: 0.13), value: recorder.finishing)
        .onAppear { pulse = true; lastSystemSignal = Date() }
        .onChange(of: recorder.systemLevel) { _, lvl in
            if lvl > 0.06 { lastSystemSignal = Date() }
        }
    }

    private func meter(label: String, icon: String, level: Float, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                        // Subtle rounded track highlight: gives the empty track a defined edge.
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                    Capsule().fill(tint)
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, level))))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
