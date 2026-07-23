import SwiftUI
import AppKit
import AVFAudio   // AVAudioApplication (microphone permission)

/// First-run onboarding. Explains what Klip does and — importantly for privacy / App Store review —
/// discloses that it keeps a local clipboard history and never sends anything off the Mac
/// (voice notes are transcribed on-device). Shown once (Settings.hasSeenWelcome).
struct WelcomeView: View {
    @ObservedObject var settings = Settings.shared   // re-localize live + show the current shortcuts
    var onStart: () -> Void

    /// Drives the staggered fade-in of the feature rows on first appear (visual only).
    @State private var rowsVisible = false

    // Live permission statuses (refreshed when the window becomes key again,
    // so returning from System Settings updates the chips).
    @State private var micGranted = false
    @State private var screenGranted = false
    @State private var axGranted = false

    private var appLogo: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 8) {   // tightened so features + permissions fit one compact window
            if let logo = appLogo {
                Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
            }
            Text(L10n.t("welcome.title")).font(.title2).bold().tracking(-0.3)
            Text(L10n.t("welcome.tagline"))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                row(0, "doc.on.clipboard", L10n.t("welcome.history.title"), L10n.t("welcome.history.body"))
                row(1, "lock.shield", L10n.t("welcome.privacy.title"), L10n.t("welcome.privacy.body"))
                row(2, "keyboard", L10n.t("welcome.shortcuts.title")) { shortcutsRows }
                row(3, "mic", L10n.t("welcome.voice.title"), L10n.t("welcome.voice.body"))
            }

            permissionsSection

            Spacer(minLength: 4)
            Button(L10n.t("welcome.start")) { onStart() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text(L10n.t("welcome.prefsHint"))
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        // Width-fixed only: the height is whatever the (localized, wrapping) content needs, and the
        // window is sized from it. A hardcoded height clips the logo or the primary button.
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { rowsVisible = true; refreshPermissions() }
        // Re-check when any window becomes key: covers coming back from System Settings.
        // ponytail: app-wide notification, cheap enough — no per-window filter or timer needed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Permissions (granted up front so no feature surprise-prompts on first use)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("welcome.perms.title")).font(.system(size: 13, weight: .semibold))
                Text(L10n.t("welcome.perms.info"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Grouped inset card: material fill + hairline dividers (native macOS list style).
            VStack(spacing: 0) {
                permRow("mic.fill", L10n.t("welcome.perms.mic"), granted: micGranted) {
                    AVAudioApplication.requestRecordPermission { ok in
                        DispatchQueue.main.async { micGranted = ok }
                    }
                }
                Divider()
                permRow("rectangle.dashed.badge.record", L10n.t("welcome.perms.screen"),
                        granted: screenGranted,
                        note: screenGranted ? nil : L10n.t("welcome.perms.relaunch")) {
                    _ = ScreenCapturer.requestPermission()   // macOS applies it after relaunch (see note)
                    screenGranted = ScreenCapturer.hasPermission()
                }
                Divider()
                permRow("accessibility", L10n.t("welcome.perms.ax"), granted: axGranted) {
                    axGranted = Paster.ensureAccessibilityPermission(prompt: true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func permRow(_ icon: String, _ name: String, granted: Bool,
                         note: String? = nil, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if granted {
                Label(L10n.t("welcome.perms.granted"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
            } else {
                Button(L10n.t("welcome.perms.grant"), action: grant)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func refreshPermissions() {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
        screenGranted = ScreenCapturer.hasPermission()
        axGranted = Paster.hasAccessibilityPermission
    }

    // id derived from the label (stable across body passes and shortcut rebinds).
    private struct ShortcutHint: Identifiable { let keys: String; let label: String; var id: String { label } }

    /// Onboarding shows only the four shortcuts a first-run user needs; the full set lives in the
    /// guide. Labels are the menu/guide ones, so a shortcut is never named two different things.
    private var shortcutHints: [ShortcutHint] {
        [ShortcutHint(keys: settings.combo.displayString, label: L10n.t("menu.show")),
         ShortcutHint(keys: settings.captureCombo.displayString, label: L10n.t("capture.annotate")),
         ShortcutHint(keys: settings.voiceCombo.displayString, label: L10n.t("rec.record")),
         ShortcutHint(keys: settings.textCaptureCombo.displayString, label: L10n.t("menu.captureText"))]
    }

    /// Chip + label rows on the guide's column metric. The chord widths vary per binding, so the
    /// labels only line up against a fixed-width chip — padding them with spaces cannot.
    private var shortcutsRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shortcutHints) { hint in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    KeyChip(keys: hint.keys, width: KeyChip.columnWidth)
                    Text(hint.label).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ index: Int, _ icon: String, _ title: String, _ body: String) -> some View {
        row(index, icon, title) {
            Text(body).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Detail: View>(_ index: Int, _ icon: String, _ title: String,
                                   @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                detail()
            }
            Spacer(minLength: 0)
        }
        // Staggered fade-in: 0.05s per row, everything settled by ~0.3s.
        .opacity(rowsVisible ? 1 : 0)
        .offset(y: rowsVisible ? 0 : 6)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                   ? nil : .easeOut(duration: 0.15).delay(Double(index) * 0.05), value: rowsVisible)
    }
}
