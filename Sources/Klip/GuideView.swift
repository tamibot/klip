import SwiftUI
import AppKit

/// Usage guide: Klip shortcuts + macOS screenshot shortcuts + how to use.
struct GuideView: View {
    @ObservedObject var settings = Settings.shared

    // id derived from `what` (stable across body passes + shortcut rebinds) — a fresh UUID() would
    // give every row a new identity each render, so ForEach would discard and rebuild the whole list.
    private struct Row: Identifiable { let keys: String; let what: String; var id: String { what } }

    private var klipShortcuts: [Row] {
        [
            Row(keys: settings.combo.displayString, what: L10n.t("guide.klip.toggle")),
            Row(keys: settings.voiceCombo.displayString, what: L10n.t("guide.klip.voice")),
            Row(keys: settings.meetingCombo.displayString, what: L10n.t("meeting.record")),
            Row(keys: settings.captureCombo.displayString, what: L10n.t("capture.annotate")),
            Row(keys: settings.textCaptureCombo.displayString, what: L10n.t("menu.captureText")),
            Row(keys: settings.uploadCombo.displayString, what: L10n.t("act.upload")),
            Row(keys: "↑ ↓", what: L10n.t("guide.klip.move")),
            Row(keys: "↩", what: L10n.t("guide.klip.choose")),
            Row(keys: "⌘↩", what: L10n.t("guide.copyAsCode")),
            Row(keys: "Esc", what: L10n.t("guide.klip.close")),
            Row(keys: "⌘,", what: L10n.t("guide.klip.prefs"))
        ]
    }

    private var macShortcuts: [Row] {
        [
            Row(keys: "⌘⇧3", what: L10n.t("guide.mac.full")),
            Row(keys: "⌘⇧4", what: L10n.t("guide.mac.area")),
            Row(keys: "⌘⇧5", what: L10n.t("guide.mac.tools")),
            Row(keys: "⌘⇧⌃4", what: L10n.t("guide.mac.clipboard"))
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section(L10n.t("guide.section.klip"), icon: "keyboard", klipShortcuts)
                section(L10n.t("guide.section.mac"), icon: "camera.viewfinder", macShortcuts,
                        footer: L10n.t("guide.mac.footer"))

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(L10n.t("guide.howto.title"), icon: "lightbulb")
                    bullet(L10n.t("guide.howto.copy"))
                    bullet(String(format: L10n.t("guide.howto.paste"), settings.combo.displayString))
                    bullet(L10n.t("guide.howto.creds"))
                    bullet(L10n.t("guide.howto.voice"))
                }
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = HistoryView.appLogo {
                Image(nsImage: logo).resizable().frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("win.guide")).font(.title2).bold().tracking(-0.3)
                Text("v\(AppInfo.version)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    // Section header: accent SF Symbol + primary title on the shared type ramp.
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .font(.system(size: 13, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }

    private func section(_ title: String, icon: String, _ rows: [Row], footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title, icon: icon)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // kbd-style chip: fixed width keeps the two columns aligned.
                    Text(r.keys)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                    Text(r.what).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.system(size: 13))
        }
    }
}
