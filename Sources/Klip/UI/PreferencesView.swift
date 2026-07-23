import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Klip's Preferences window.
struct PreferencesView: View {
    @ObservedObject var settings = Settings.shared
    var onHotKeyChange: (ShortcutKind, KeyCombo) -> Void
    // Kept for the AppDelegate wiring but intentionally never called: trimming on every
    // Stepper click deleted history (and media) per click. History self-trims on the next
    // capture via trimAndSave, so the new limit applies as new items arrive.
    var onMaxItemsChange: () -> Void

    @State private var launchAtLogin = LoginItem.shared.isEnabledOrPending
    @State private var loginError: String?
    @State private var accessibilityGranted = Paster.hasAccessibilityPermission

    // Dictation/audio languages passed to the transcriber (endonyms). "" = auto-detect.
    private let dictationLanguages = DictationLanguage.all

    /// Comma-separated entries in the context-words field ("Klip, GitHub" → 2).
    private var vocabWordCount: Int {
        settings.transcriptionVocabulary.split(separator: ",")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    private var appLogo: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 0) {
            aboutHeader
            Divider()
            form
        }
        .frame(width: 500, height: 700)
        .onAppear {
            launchAtLogin = LoginItem.shared.isEnabledOrPending
            accessibilityGranted = Paster.hasAccessibilityPermission
        }
        // Granting Accessibility happens in System Settings, which doesn't notify us; re-check
        // when the user comes back and our window becomes key so the warning clears itself.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            accessibilityGranted = Paster.hasAccessibilityPermission
        }
    }

    private var aboutHeader: some View {
        HStack(spacing: 12) {
            if let logo = appLogo {
                Image(nsImage: logo).resizable().frame(width: 54, height: 54)
            }
            VStack(alignment: .leading, spacing: 8) {
                // Title + version read as a single unit, so they stay tight; the links get the 8pt gap.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Klip").font(.title2.bold()).tracking(-0.3)
                    Text("v\(AppInfo.version) · \(L10n.t("app.tagline"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let u = URL(string: AppInfo.repoURL) {
                        Link(label: "chevron.left.forwardslash.chevron.right", text: "GitHub", url: u)
                    }
                    if let u = URL(string: AppInfo.issuesURL) {
                        Link(label: "lightbulb", text: L10n.t("prefs.suggestions"), url: u)
                    }
                }
                .font(.caption)
            }
            Spacer()
        }
        .padding(16)
    }

    /// Grouped-Form section header at the type ramp (13 semibold = `.headline` on macOS).
    private func sectionHeader(_ key: String) -> Text {
        Text(L10n.t(key)).font(.headline)
    }

    private var form: some View {
        Form {
            Section(header: sectionHeader("prefs.lang.section")) {
                Picker(L10n.t("prefs.lang.label"), selection: $settings.uiLanguage) {
                    ForEach(L10n.supported, id: \.code) { Text($0.name).tag($0.code) }
                }
            }

            Section(header: sectionHeader("prefs.general")) {
                Toggle(L10n.t("prefs.openAtLogin"), isOn: Binding(
                    get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(L10n.t("prefs.cleanpaste"), isOn: $settings.cleanCapture)
                Toggle(L10n.t("prefs.autopaste"), isOn: $settings.autoPaste)
                Toggle(L10n.t("prefs.sounds"), isOn: $settings.soundEffects)
                if settings.autoPaste && !accessibilityGranted {
                    // Calm info row: caption-sized icon + secondary text instead of a shouting warning.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Text(L10n.t("prefs.needAccessibility")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.t("prefs.grant")) { Paster.ensureAccessibilityPermission(prompt: true) }
                            .font(.caption).buttonStyle(.link)
                    }
                }
                Picker(L10n.t("prefs.captureDest"), selection: $settings.captureDestination) {
                    Text(L10n.t("prefs.captureDest.editor")).tag("editor")
                    Text(L10n.t("prefs.captureDest.clipboard")).tag("clipboard")
                }
                Stepper(String(format: L10n.t("prefs.maxItems"), settings.maxItems),
                        value: $settings.maxItems, in: 20...1000, step: 10)
                Text(L10n.t("prefs.maxItems.info"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: sectionHeader("prefs.shortcuts")) {
                shortcutRow(.panel, L10n.t("prefs.sc.show"), $settings.combo)
                shortcutRow(.voice, L10n.t("prefs.sc.voice"), $settings.voiceCombo)
                shortcutRow(.capture, L10n.t("prefs.sc.capture"), $settings.captureCombo)
                shortcutRow(.textCapture, L10n.t("prefs.sc.captureText"), $settings.textCaptureCombo)
                shortcutRow(.upload, L10n.t("prefs.sc.upload"), $settings.uploadCombo)
                shortcutRow(.meeting, L10n.t("prefs.sc.meeting"), $settings.meetingCombo)
                shortcutRow(.screenRec, L10n.t("prefs.sc.record"), $settings.screenRecCombo)
                shortcutRow(.scroll, L10n.t("prefs.sc.scroll"), $settings.scrollCombo)
                Text(L10n.t("prefs.sc.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: sectionHeader("prefs.voice.section")) {
                Picker(L10n.t("prefs.local.model"), selection: $settings.localModel) {
                    ForEach(LocalTranscriber.models, id: \.id) { Text("\($0.label) — \($0.note)").tag($0.id) }
                }
                Text(L10n.t("prefs.local.info"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L10n.t("prefs.audioLang"), selection: $settings.transcriptionLanguage) {
                    Text(L10n.t("lang.auto")).tag("")
                    ForEach(dictationLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("prefs.vocab.label")).font(.headline)
                    // Empty title + labelsHidden: with a non-empty title the grouped Form renders it as a
                    // leading label and squeezes the field into a cramped trailing column.
                    TextField("", text: $settings.transcriptionVocabulary,
                              prompt: Text(L10n.t("prefs.vocab.placeholder")), axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    HStack(alignment: .top) {
                        Text(L10n.t("prefs.vocab.info")).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        if vocabWordCount > 0 {
                            // Live count: immediate feedback that the words are registered.
                            Text(String(format: L10n.t("prefs.vocab.count"), vocabWordCount))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }

            Section(header: sectionHeader("prefs.privacy.section")) {
                Toggle(L10n.t("prefs.privacy.toggle"), isOn: $settings.ignoreSensitive)
                Text(L10n.t("prefs.privacy.info"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: sectionHeader("prefs.excluded.section")) {
                if settings.excludedBundleIDs.isEmpty {
                    Text(L10n.t("prefs.excluded.none"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(settings.excludedBundleIDs, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(size: 13)); Spacer()
                        Button(role: .destructive) { settings.removeExcludedApp(id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu {
                    ForEach(excludableRunningApps, id: \.processIdentifier) { app in
                        Button {
                            if let id = app.bundleIdentifier { settings.addExcludedApp(id) }
                        } label: {
                            Label {
                                Text(app.localizedName ?? app.bundleIdentifier ?? "")
                            } icon: {
                                // App icons ship at 512pt; menu items don't downscale them for us.
                                Image(nsImage: app.icon ?? NSImage())
                                    .resizable().frame(width: 16, height: 16)
                            }
                        }
                    }
                    Divider()
                    // Fallback for anything not running right now.
                    Button(L10n.t("prefs.excluded.choose")) { pickApp() }
                } label: {
                    Label(L10n.t("prefs.excluded.add"), systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()   // otherwise the grouped Form stretches it to the full row width
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)   // let the window's glass material show through
    }

    /// One shortcut row with a uniform height so all eight rows line up in the grouped Form.
    private func shortcutRow(_ kind: ShortcutKind, _ label: String, _ combo: Binding<KeyCombo>) -> some View {
        HStack {
            Text(label)
            Spacer()
            FilteredHotKeyField(combo: combo) { onHotKeyChange(kind, $0) }
        }
        .frame(height: 28)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        switch LoginItem.shared.toggle() {
        case .success:
            launchAtLogin = LoginItem.shared.isEnabledOrPending; loginError = nil
        case .failure(let err):
            if case .requiresApproval = err { LoginItem.shared.openSystemSettings() }
            loginError = err.localizedDescription
            launchAtLogin = LoginItem.shared.isEnabledOrPending
        }
    }

    /// Running apps worth excluding: Dock-visible ones, minus Klip itself and those
    /// already excluded. Read on menu open, so the list is always current.
    private var excludableRunningApps: [NSRunningApplication] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                guard $0.activationPolicy == .regular, let id = $0.bundleIdentifier else { return false }
                return id != own && !settings.excludedBundleIDs.contains(id)
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            settings.addExcludedApp(id)
        }
    }
}

/// HotKeyField variant whose suggestions menu hides combos already used by Klip's other
/// shortcuts — picking one of those was a beep dead-end (the recorder can't register a
/// duplicate). Lives here because only Preferences knows all five current combos;
/// HotKeyField in KeyRecorderView.swift stays generic (and is now unused).
private struct FilteredHotKeyField: View {
    @Binding var combo: KeyCombo
    var onChange: (KeyCombo) -> Void

    /// Combos held by the OTHER shortcuts (this field's own value is filtered out). Derived from
    /// ShortcutKind so a new shortcut can't be forgotten here — the hand-written list had gone stale
    /// twice, leaving the menu offering combos that screen-recording and scrolling capture already held.
    private var taken: [KeyCombo] {
        ShortcutKind.allCases.map { Settings.shared[keyPath: $0.combo] }.filter { $0 != combo }
    }

    var body: some View {
        HStack(spacing: 6) {
            KeyRecorderView(combo: $combo, onChange: onChange)
                .frame(width: 150, height: 28)
            Menu {
                ForEach(KeyCombo.suggestions.filter { !taken.contains($0) },
                        id: \.displayString) { c in
                    Button(c.displayString) { combo = c; onChange(c) }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help(L10n.t("hotkey.suggestions"))
        }
    }
}

/// Link with an icon that opens the browser.
private struct Link: View {
    let label: String
    let text: String
    let url: URL
    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 3) { Image(systemName: label); Text(text) }
        }
        .buttonStyle(.link)
    }
}
