import SwiftUI
import AppKit

/// First-run onboarding. Explains what Klip does and — importantly for privacy / App Store review —
/// discloses that it keeps a local clipboard history and never sends anything off the Mac unless the
/// user adds an AI key for voice transcription. Shown once (Settings.hasSeenWelcome).
struct WelcomeView: View {
    @ObservedObject var settings = Settings.shared   // re-localize live + show the current shortcuts
    var onStart: () -> Void

    private var appLogo: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 10) {   // tightened so the per-shortcut lines fit the fixed 580pt window
            if let logo = appLogo {
                Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
            }
            Text(L10n.t("welcome.title")).font(.title2).bold()
            Text(L10n.t("welcome.tagline"))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                row("doc.on.clipboard", L10n.t("welcome.history.title"), L10n.t("welcome.history.body"))
                row("lock.shield", L10n.t("welcome.privacy.title"), L10n.t("welcome.privacy.body"))
                row("keyboard", L10n.t("welcome.shortcuts.title"), shortcutsLine)
                row("mic", L10n.t("welcome.voice.title"), L10n.t("welcome.voice.body"))
            }
            .padding(.top, 4)

            Spacer(minLength: 8)
            Button(L10n.t("welcome.start")) { onStart() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text(L10n.t("welcome.prefsHint"))
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 440, height: 580)
    }

    private var shortcutsLine: String {
        // One labeled line per shortcut (same labels as the menu/guide) instead of bare chords.
        [(settings.combo, "menu.show"),
         (settings.voiceCombo, "rec.record"),
         (settings.captureCombo, "capture.annotate"),
         (settings.textCaptureCombo, "menu.captureText"),
         (settings.uploadCombo, "act.upload")]
            .map { "\($0.displayString)  \(L10n.t($1))" }.joined(separator: "\n")
    }

    private func row(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.tint)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
