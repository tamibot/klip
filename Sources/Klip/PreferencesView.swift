import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// ObservableObject bridge for an API key (OpenAI or Gemini), stored in a local 0600 file.
@MainActor
final class APIKeyModel: ObservableObject {
    let key: SecretStore.Key
    @Published private(set) var isConfigured = false
    @Published private(set) var last4: String?
    @Published var errorMessage: String?
    @Published var savedOK = false

    init(_ key: SecretStore.Key = .openai) { self.key = key; refresh() }

    func refresh() {
        isConfigured = SecretStore.hasKey(key)
        last4 = SecretStore.last4(key)
    }

    @discardableResult
    func save(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = L10n.t("key.err.empty")
            savedOK = false
            return false
        }
        do {
            let ok = try SecretStore.set(trimmed, key)   // writes and RE-READS to confirm
            if ok {
                errorMessage = nil; savedOK = true
            } else {
                errorMessage = L10n.t("key.err.unconfirmed"); savedOK = false
            }
            refresh()
            return ok
        } catch {
            errorMessage = String(format: L10n.t("key.err.save"), error.localizedDescription)
            savedOK = false
            refresh()
            return false
        }
    }

    func delete() {
        SecretStore.delete(key); errorMessage = nil; savedOK = false
        refresh()
    }
}

/// Klip's Preferences window.
struct PreferencesView: View {
    @ObservedObject var settings = Settings.shared
    var onHotKeyChange: (KeyCombo) -> Void
    var onVoiceHotKeyChange: (KeyCombo) -> Void
    var onCaptureHotKeyChange: (KeyCombo) -> Void
    var onUploadHotKeyChange: (KeyCombo) -> Void
    var onTextCaptureHotKeyChange: (KeyCombo) -> Void
    var onMeetingHotKeyChange: (KeyCombo) -> Void
    // Kept for the AppDelegate wiring but intentionally never called: trimming on every
    // Stepper click deleted history (and media) per click. History self-trims on the next
    // capture via trimAndSave, so the new limit applies as new items arrive.
    var onMaxItemsChange: () -> Void

    @StateObject private var apiKey = APIKeyModel(.openai)
    @StateObject private var geminiKey = APIKeyModel(.gemini)
    @State private var draftKey = ""
    @State private var showKey = false
    @State private var draftGeminiKey = ""
    @State private var showGeminiKey = false
    @State private var launchAtLogin = LoginItem.shared.isEnabledOrPending
    @State private var loginError: String?
    @State private var accessibilityGranted = Paster.hasAccessibilityPermission

    private let models = ["gpt-4o-mini-transcribe", "whisper-1"]
    // Gemini models. The "-latest" aliases avoid 404s from deprecation; pinned
    // versions are also included for anyone who wants stable behavior.
    private let geminiModels = ["gemini-flash-latest", "gemini-flash-lite-latest",
                                "gemini-pro-latest", "gemini-2.5-flash", "gemini-2.5-pro"]
    // Dictation/audio languages passed to the transcription provider (endonyms). "" = auto-detect.
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
            apiKey.refresh(); geminiKey.refresh()
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
                shortcutRow(L10n.t("prefs.sc.show"), $settings.combo, onHotKeyChange)
                shortcutRow(L10n.t("prefs.sc.voice"), $settings.voiceCombo, onVoiceHotKeyChange)
                shortcutRow(L10n.t("prefs.sc.capture"), $settings.captureCombo, onCaptureHotKeyChange)
                shortcutRow(L10n.t("prefs.sc.captureText"), $settings.textCaptureCombo, onTextCaptureHotKeyChange)
                shortcutRow(L10n.t("prefs.sc.upload"), $settings.uploadCombo, onUploadHotKeyChange)
                shortcutRow(L10n.t("prefs.sc.meeting"), $settings.meetingCombo, onMeetingHotKeyChange)
                Text(L10n.t("prefs.sc.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: sectionHeader("prefs.voice.section")) {
                Picker(L10n.t("prefs.provider"), selection: $settings.aiProvider) {
                    Text(L10n.t("prefs.provider.local")).tag("local")
                    Text("OpenAI").tag("openai")
                    Text("Gemini").tag("gemini")
                }
                .pickerStyle(.segmented)
                // Explain the choice right under the picker: which option is free/offline vs. needs a key.
                Text(settings.aiProvider == "local" ? L10n.t("prefs.local.info")
                     : settings.aiProvider == "gemini" ? L10n.t("prefs.voice.useGemini")
                     : L10n.t("prefs.voice.useOpenAI"))
                    .font(.caption).foregroundStyle(.secondary)
                if settings.aiProvider == "local" {
                    Picker(L10n.t("prefs.local.model"), selection: $settings.localModel) {
                        ForEach(LocalTranscriber.models, id: \.id) { Text("\($0.label) — \($0.note)").tag($0.id) }
                    }
                } else if settings.aiProvider == "openai" {
                    Picker(L10n.t("prefs.model"), selection: $settings.transcriptionModel) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Picker(L10n.t("prefs.model"), selection: $settings.geminiModel) {
                        ForEach(geminiModels, id: \.self) { Text($0).tag($0) }
                    }
                }
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

            if settings.aiProvider == "openai" {
            Section(header: sectionHeader("prefs.openai.section")) {
                keyStatus(apiKey)
                HStack {
                    if showKey {
                        TextField("sk-…", text: $draftKey).textFieldStyle(.roundedBorder)
                            .onSubmit { saveOpenAI() }
                    } else {
                        SecureField("sk-…", text: $draftKey).textFieldStyle(.roundedBorder)
                            .onSubmit { saveOpenAI() }
                    }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(PressableButtonStyle()).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L10n.t("common.save")) { saveOpenAI() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.t("common.delete"), role: .destructive) { apiKey.delete() }
                        .buttonStyle(.bordered).disabled(!apiKey.isConfigured)
                    if apiKey.savedOK { Label(L10n.t("prefs.saved"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption).symbolEffect(.bounce, options: .nonRepeating, value: apiKey.savedOK) }
                }
                if let err = apiKey.errorMessage { Text(err).font(.caption).foregroundStyle(.red) }
            }
            }

            if settings.aiProvider == "gemini" {
            Section(header: sectionHeader("prefs.gemini.section")) {
                keyStatus(geminiKey)
                HStack {
                    if showGeminiKey {
                        TextField("AIza…", text: $draftGeminiKey).textFieldStyle(.roundedBorder)
                            .onSubmit { saveGemini() }
                    } else {
                        SecureField("AIza…", text: $draftGeminiKey).textFieldStyle(.roundedBorder)
                            .onSubmit { saveGemini() }
                    }
                    Button { showGeminiKey.toggle() } label: { Image(systemName: showGeminiKey ? "eye.slash" : "eye") }
                        .buttonStyle(PressableButtonStyle()).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L10n.t("common.save")) { saveGemini() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(draftGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.t("common.delete"), role: .destructive) { geminiKey.delete() }
                        .buttonStyle(.bordered).disabled(!geminiKey.isConfigured)
                    if geminiKey.savedOK { Label(L10n.t("prefs.saved"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption).symbolEffect(.bounce, options: .nonRepeating, value: geminiKey.savedOK) }
                }
                if let err = geminiKey.errorMessage { Text(err).font(.caption).foregroundStyle(.red) }
                Text(L10n.t("prefs.gemini.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            }

            // Switching provider hides the other provider's key section; keep its stored
            // key visible (and deletable) so it isn't stranded on disk with no UI.
            if (settings.aiProvider != "openai" && apiKey.isConfigured)
                || (settings.aiProvider != "gemini" && geminiKey.isConfigured) {
                Section {
                    if settings.aiProvider != "openai" && apiKey.isConfigured {
                        storedKeyRow("OpenAI", apiKey)
                    }
                    if settings.aiProvider != "gemini" && geminiKey.isConfigured {
                        storedKeyRow("Gemini", geminiKey)
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
        // Provider-dependent sections (model picker, key sections) fade/slide in place
        // instead of snapping when the segmented picker changes.
        .animation(.easeOut(duration: 0.15), value: settings.aiProvider)
    }

    /// One shortcut row with a uniform height so all six rows line up in the grouped Form.
    private func shortcutRow(_ label: String, _ combo: Binding<KeyCombo>,
                             _ onChange: @escaping (KeyCombo) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            FilteredHotKeyField(combo: combo, onChange: onChange)
        }
        .frame(height: 28)
    }

    /// Forces the focused field to commit its edit BEFORE reading the binding.
    /// SwiftUI doesn't always propagate the pasted text to `draftKey` before the button's
    /// action runs (field inside a .grouped Form, still the first responder): when the
    /// NSTextField finishes editing, the in-progress value is flushed to the binding.
    /// Without this, `save` was reading the old value.
    private func commitFocusedField() {
        if let window = NSApp.keyWindow {
            window.makeFirstResponder(nil)   // endEditing → flushes the text to the binding
        }
    }

    private func saveOpenAI() {
        commitFocusedField()
        // After flushing the binding in this runloop cycle, read the now-updated value.
        DispatchQueue.main.async {
            if apiKey.save(draftKey) { SoundFX.play(.success); draftKey = ""; showKey = false }
        }
    }

    private func saveGemini() {
        commitFocusedField()
        DispatchQueue.main.async {
            if geminiKey.save(draftGeminiKey) { SoundFX.play(.success); draftGeminiKey = ""; showGeminiKey = false }
        }
    }

    /// Compact "<provider> key stored · Delete" row for a provider whose section is hidden.
    private func storedKeyRow(_ name: String, _ model: APIKeyModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill").font(.caption).foregroundStyle(.secondary)
            Text(String(format: L10n.t("prefs.key.stored"), name))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("common.delete"), role: .destructive) { model.delete() }
                .buttonStyle(.link).font(.caption)
        }
    }

    @ViewBuilder
    private func keyStatus(_ model: APIKeyModel) -> some View {
        HStack(spacing: 6) {
            if model.isConfigured {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(L10n.t("prefs.key.configured"))
                if let l4 = model.last4 {
                    Text("••••\(l4)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.t("prefs.key.none")).foregroundStyle(.secondary)
            }
        }
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

    /// Combos held by the OTHER shortcuts (this field's own value is filtered out).
    private var taken: [KeyCombo] {
        let s = Settings.shared
        return [s.combo, s.voiceCombo, s.captureCombo, s.uploadCombo, s.textCaptureCombo, s.meetingCombo]
            .filter { $0 != combo }
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
