import SwiftUI
import AppKit
import AVFAudio    // AVAudioApplication (microphone permission)
import WhisperKit  // WhisperKit.download — the speech-model row's "get it now" (with progress)

/// First-run onboarding. Explains what Klip does and — importantly for privacy / App Store review —
/// discloses that it keeps a local clipboard history and never sends anything off the Mac
/// (voice notes are transcribed on-device). Shown once (Settings.hasSeenWelcome).
struct WelcomeView: View {
    @ObservedObject var settings = Settings.shared   // re-localize live + show the current shortcuts
    var onStart: () -> Void

    /// Drives the staggered fade-in of the feature rows on first appear (visual only).
    @State private var rowsVisible = false

    // Live permission state, keyed by the System Settings pane (one key per row — see `Pane`).
    // Refreshed when the window becomes key again, so returning from System Settings updates the rows.
    @State private var granted: Set<String> = []
    @State private var pending: Set<String> = []   // an ask is in flight (row shows a spinner)
    @State private var bounced: Set<String> = []   // the ask was a no-op, we sent them to System Settings

    // Speech model (offered, never a gate).
    @State private var modelReady = false
    @State private var modelProgress: Double?      // non-nil while downloading
    @State private var modelFailed = false

    /// The Privacy anchors of the three permissions Klip asks for up front. Also the row identity.
    private enum Pane {
        static let mic = "Privacy_Microphone"
        static let screen = "Privacy_ScreenCapture"
        static let ax = "Privacy_Accessibility"
    }

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
        .padding(.horizontal, 24).padding(.vertical, 16)
        // Width-fixed only: the height is whatever the (localized, wrapping) content needs, and the
        // window is sized from it. A hardcoded height clips the logo or the primary button.
        // 540, not 440: at 440 the eight shortcuts only fit in one column and the window grew past
        // 900pt — taller than a 13" laptop screen. The extra 100pt buys the second column back.
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { rowsVisible = true; refresh() }
        // Re-check when any window becomes key: covers coming back from System Settings.
        // ponytail: app-wide notification, cheap enough — no per-window filter or timer needed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
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
            card {
                permRow("mic.fill", L10n.t("welcome.perms.mic"), pane: Pane.mic,
                        request: { AVAudioApplication.requestRecordPermission { _ in } },
                        isGranted: { AVAudioApplication.shared.recordPermission == .granted })
                Divider()
                // Screen Recording only takes effect for an already-running app after a relaunch,
                // hence the standing note while it isn't granted yet.
                permRow("rectangle.dashed.badge.record", L10n.t("welcome.perms.screen"), pane: Pane.screen,
                        note: L10n.t("welcome.perms.relaunch"),
                        request: { _ = ScreenCapturer.requestPermission() },
                        isGranted: { ScreenCapturer.hasPermission() })
                Divider()
                permRow("accessibility", L10n.t("welcome.perms.ax"), pane: Pane.ax,
                        request: { Paster.ensureAccessibilityPermission(prompt: true) },
                        isGranted: { Paster.hasAccessibilityPermission })
            }
            // Separate card: the speech model is a download, not a permission — and never a gate.
            card { modelRow }
        }
    }

    /// Asks for a permission and NEVER dead-ends.
    ///
    /// WHY the polling: `CGRequestScreenCaptureAccess` and `AXIsProcessTrustedWithOptions` raise their
    /// dialog at most ONCE per app identity — with any TCC record already on file (including a stale one
    /// bound to a previous signature) they silently return the current value and show nothing. And the AX
    /// dialog is non-modal, so it returns before the user has clicked anything. Either way an immediate
    /// re-read reports "not granted" and the row would just sit there. So: poll for ~2 s, flip the row the
    /// moment it flips, and if it still hasn't, open the exact System Settings pane.
    private func ask(_ pane: String, request: @escaping () -> Void, isGranted: @escaping () -> Bool) {
        pending.insert(pane)
        request()
        Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard isGranted() else { continue }
                granted.insert(pane); pending.remove(pane); return
            }
            pending.remove(pane)
            bounced.insert(pane)   // the ask was a no-op: from now on the button goes straight to Settings
            openPrivacySettings(pane)
        }
    }

    /// The same deep link SnapController, MeetingRecorder and RecordingView use.
    /// ponytail: kept local — sharing it would mean editing three files owned by someone else.
    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func permRow(_ icon: String, _ name: String, pane: String, note: String? = nil,
                         request: @escaping () -> Void,
                         isGranted: @escaping () -> Bool) -> some View {
        let ok = granted.contains(pane)
        let sentToSettings = bounced.contains(pane)
        let notes = ok ? [] : [sentToSettings ? L10n.t("welcome.perms.openSettings") : nil, note].compactMap { $0 }
        return statusRow(icon, name, note: notes.isEmpty ? nil : notes.joined(separator: " · ")) {
            if ok {
                grantedLabel(L10n.t("welcome.perms.granted"))
            } else if pending.contains(pane) {
                ProgressView().controlSize(.small)
            } else if sentToSettings {
                actionButton(L10n.t("perm.screen.open")) { openPrivacySettings(pane) }
            } else {
                actionButton(L10n.t("welcome.perms.grant")) {
                    ask(pane, request: request, isGranted: isGranted)
                }
            }
        }
    }

    // MARK: - Speech model

    private var modelRow: some View {
        statusRow("waveform", L10n.t("welcome.model.title"),
                  note: modelFailed ? L10n.t("welcome.model.failed") : L10n.t("welcome.model.body")) {
            if modelReady {
                grantedLabel(L10n.t("welcome.model.ready"))
            } else if let p = modelProgress {
                // WhisperKit's download reports a real Progress, so this is a true percentage.
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: p).frame(width: 80)
                    Text("\(Int(p * 100))%").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                // Size straight from LocalTranscriber's table via Recorder's tested parser (ModelSizeTests).
                actionButton(String(format: L10n.t("welcome.model.get"),
                                    Recorder.modelSize(settings.localModel)), action: downloadModel)
            }
        }
    }

    private func downloadModel() {
        let id = settings.localModel.isEmpty ? LocalTranscriber.defaultModel : settings.localModel
        modelFailed = false
        modelProgress = 0
        Task {
            do {
                _ = try await WhisperKit.download(variant: id) { p in
                    Task { @MainActor in modelProgress = p.fractionCompleted }
                }
                await LocalTranscriber.shared.prewarm(model: id)   // loaded now → first voice note is instant
            } catch {
                await MainActor.run { modelFailed = true }
            }
            await MainActor.run { modelProgress = nil; modelReady = LocalTranscriber.isModelReady(id) }
        }
    }

    // MARK: - Shared row chrome

    /// Grouped inset card: material fill + hairline border (native macOS list style).
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }

    /// Icon + name (+ optional note) on the left, one trailing control on the right.
    private func statusRow<Trailing: View>(_ icon: String, _ name: String, note: String?,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 40)   // uniform row height, so the dividers sit on an even rhythm
    }

    private func grantedLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.green)
            .fixedSize()
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()   // otherwise a long localized title truncates to "Desc…" inside the row
    }

    private func refresh() {
        set(Pane.mic, AVAudioApplication.shared.recordPermission == .granted)
        set(Pane.screen, ScreenCapturer.hasPermission())
        set(Pane.ax, Paster.hasAccessibilityPermission)
        modelReady = LocalTranscriber.isModelReady(settings.localModel)
    }

    private func set(_ pane: String, _ ok: Bool) {
        if ok { granted.insert(pane) } else { granted.remove(pane) }
    }

    // MARK: - Shortcuts

    // id derived from the label (stable across body passes and shortcut rebinds).
    private struct ShortcutHint: Identifiable { let keys: String; let label: String; var id: String { label } }

    /// The user-facing name of each shortcut — the menu/guide one, so a shortcut is never named two
    /// different things. A `switch` over the enum on purpose: a ninth `ShortcutKind` stops compiling
    /// here instead of quietly going missing from onboarding, which is exactly how the hand-written
    /// list of four survived four new shortcuts.
    private func label(for kind: ShortcutKind) -> String {
        switch kind {
        case .panel:       return L10n.t("menu.show")
        case .voice:       return L10n.t("rec.record")
        case .capture:     return L10n.t("capture.annotate")
        case .textCapture: return L10n.t("menu.captureText")
        case .upload:      return L10n.t("act.upload")
        case .meeting:     return L10n.t("meeting.record")
        case .screenRec:   return L10n.t("menu.recordScreen")
        case .scroll:      return L10n.t("menu.scrollCapture")
        }
    }

    /// All eight shortcuts, live from Settings via ShortcutKind's own key paths.
    private var shortcutHints: [ShortcutHint] {
        ShortcutKind.allCases.map {
            ShortcutHint(keys: settings[keyPath: $0.combo].displayString, label: label(for: $0))
        }
    }

    /// Two columns of four: eight in one column made the window taller than a 13" screen.
    /// A Grid, not two VStacks — a label that wraps (German, mostly) then grows BOTH columns' row,
    /// so the two columns keep a shared baseline instead of drifting apart.
    private var shortcutsRows: some View {
        let hints = shortcutHints
        let half = (hints.count + 1) / 2
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(0..<half, id: \.self) { i in
                GridRow {
                    shortcutCell(hints[i])
                    if half + i < hints.count { shortcutCell(hints[half + i]) }
                }
            }
        }
    }

    /// Chip + label. The chord widths vary per binding, so the labels only line up against a
    /// fixed-width chip — padding them with spaces cannot. Narrower than KeyChip.columnWidth
    /// on purpose: the guide's 90pt column also has to fit "⌘⇧⌃4", these are all ⌥⇧-chords.
    private func shortcutCell(_ hint: ShortcutHint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            KeyChip(keys: hint.keys, width: 40)
            Text(hint.label).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
