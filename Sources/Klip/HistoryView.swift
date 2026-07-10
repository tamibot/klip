import SwiftUI
import AppKit

enum HistoryFilter: String, CaseIterable, Identifiable {
    // Display order. Favorites sits right after All: at the end of the row it scrolls out of sight,
    // and it's the filter that answers "where did my starred clip go?" (stars don't float to the top).
    case all, pinned, text, link, image, voice, credential
    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .all: "filter.all"; case .text: "filter.text"; case .link: "filter.link"; case .image: "filter.image"
        case .voice: "filter.voice"; case .credential: "filter.cred"; case .pinned: "filter.pinned"
        }
    }
    var icon: String {
        switch self {
        case .all: "square.grid.2x2"; case .text: "doc.text"; case .link: "link"; case .image: "photo"
        case .voice: "waveform"; case .credential: "key.fill"; case .pinned: "star.fill"
        }
    }
}

/// Panel UI: header, type filters, list and guide.
struct HistoryView: View {
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var selection: SelectionModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings = Settings.shared
    var onPick: (ClipboardItem) -> Void
    var onSaveImage: (ClipboardItem) -> Void
    var onCopyMarkdown: (ClipboardItem) -> Void
    var onCopyAllMarkdown: () -> Void
    var onOpenPreferences: () -> Void
    var onUploadAudio: () -> Void
    var onVoiceRecord: () -> Void
    var onShowGuide: () -> Void
    var onRename: (ClipboardItem) -> Void
    var onDelete: (ClipboardItem) -> Void
    var onRetryTranscription: (ClipboardItem) -> Void
    var onSaveAsFile: (ClipboardItem) -> Void
    var onCopyAsCode: (ClipboardItem) -> Void
    var onCaptureAnnotate: () -> Void
    var onCombinePDF: ([ClipboardItem]) -> Void
    var onExportZip: ([ClipboardItem]) -> Void
    var onAssignCollection: ([ClipboardItem]) -> Void

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var filter: HistoryFilter = .all
    @State private var collectionFilter: String?
    @State private var selecting = false
    @State private var selectedBatch: Set<UUID> = []
    @State private var ocrResultID: UUID?
    @State private var ocrText = ""
    @State private var ocrRunning = false

    static let appLogo: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()

    private var sortedItems: [ClipboardItem] {
        // Newest first. A starred item is NOT floated to the top — the star is just a mark you can filter by.
        manager.items.sorted { $0.createdAt > $1.createdAt }
    }

    private func matches(_ item: ClipboardItem, _ f: HistoryFilter) -> Bool {
        switch f {
        case .all: return true
        case .text: return item.kind == .text && item.isVoiceNote != true && item.isCredential != true
        case .link: return item.linkURL != nil
        case .image: return item.kind == .image
        case .voice: return item.isVoiceNote == true
        case .credential: return item.isCredential == true
        case .pinned: return item.pinned
        }
    }

    /// Only the filters that currently have items (plus "All"): a user who only copied text
    /// won't see empty Image/Voice/Credential chips that look like they "don't work".
    private var availableFilters: [HistoryFilter] {
        HistoryFilter.allCases.filter { f in
            f == .all || manager.items.contains { matches($0, f) }
        }
    }

    private var filtered: [ClipboardItem] {
        var base = sortedItems.filter { matches($0, filter) }
        if let cf = collectionFilter { base = base.filter { $0.collection == cf } }
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        base = base.filter {
            // Don't match the cleartext of a credential (the preview is masked) — otherwise typing part
            // of a known token would surface/confirm the secret.
            let inText = $0.isCredential == true ? false : ($0.text ?? "").lowercased().contains(q)
            return ($0.name ?? "").lowercased().contains(q) || inText || $0.preview.lowercased().contains(q)
        }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !manager.items.isEmpty { filterRow }
            Divider()
            if filtered.isEmpty { emptyState } else { list }
            if selecting { batchBar }
        }
        // Gentle fades for list<->empty swap and the batch bar slide; scoped by value so nothing else animates.
        .animation(.easeOut(duration: 0.13), value: filtered.isEmpty)
        .animation(.easeOut(duration: 0.15), value: selecting)
        .frame(minWidth: 420, minHeight: 460)
        .background(Color.clear)
        .onAppear { syncVisible(); searchFocused = true }
        .onChange(of: search) { _, newValue in selection.searchHasText = !newValue.isEmpty; syncVisible() }
        .onChange(of: filter) { _, _ in syncVisible() }
        .onChange(of: collectionFilter) { _, _ in syncVisible() }
        .onChange(of: manager.items) { _, _ in
            // If the filtered collection no longer exists (its last item was deleted/renamed), drop the
            // filter: otherwise the list would look falsely empty with no visible chip to clear it.
            if let cf = collectionFilter, !manager.collections.contains(cf) { collectionFilter = nil }
            // If the filtered type no longer has items, its chip disappears: fall back to "All" so we
            // don't end up with an empty list and no visible selected chip.
            if !availableFilters.contains(filter) { filter = .all }
            // Prune from the batch the ids that no longer exist (e.g. auto-trim by maxItems when new clips
            // come in): keeps the "N sel." counter in sync with what will actually be exported.
            if !selectedBatch.isEmpty {
                let pruned = selectedBatch.intersection(Set(manager.items.map(\.id)))
                if pruned.count != selectedBatch.count { selectedBatch = pruned }
            }
            syncVisible()
        }
        .onChange(of: selecting) { _, newValue in selection.selecting = newValue }
        // Esc in multi-select: the controller flips selection.selecting off; drop the batch here.
        .onChange(of: selection.selecting) { _, newValue in
            if !newValue && selecting { selecting = false; selectedBatch = [] }
        }
        // Esc with text in the search field: clear it (second back-out layer, before closing).
        .onChange(of: selection.clearSearchToken) { _, _ in search = ""; searchFocused = true }
        .onChange(of: selection.openToken) { _, _ in
            search = ""; filter = .all; collectionFilter = nil
            selecting = false; selectedBatch = []
            ocrResultID = nil; ocrText = ""; ocrRunning = false   // don't show a stale OCR box on reopen
            selection.updateVisible(sortedItems.map(\.id))
            selection.selectedIndex = sortedItems.isEmpty ? -1 : 0
            searchFocused = true
        }
        .onChange(of: selection.focusToken) { _, _ in searchFocused = true }   // re-focus without clearing the search
    }

    private func syncVisible() { selection.updateVisible(filtered.map(\.id)) }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if let logo = Self.appLogo {
                    Image(nsImage: logo).resizable().frame(width: 22, height: 22)
                }
                Text("Klip").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                if recorder.transcribingCount > 0 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("\(recorder.transcribingCount)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))   // same pill as the item counter
                    .help(L10n.t("rec.transcribing"))
                    .padding(.trailing, 2)
                }
                // Action icons: uniform size and generous spacing so they don't overlap.
                HStack(spacing: 15) {
                    Button { toggleSelecting() } label: {
                        Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(selecting ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.borderless).help(L10n.t("sel.toggle"))
                    Button { onCaptureAnnotate() } label: { Image(systemName: "camera.viewfinder") }
                        .buttonStyle(.borderless).help(L10n.t("capture.annotate"))
                    Button { onVoiceRecord() } label: {
                        Image(systemName: recorder.state == .recording ? "mic.fill" : "mic")
                            .foregroundStyle(recorder.state == .recording ? .red : .primary)
                    }
                    .buttonStyle(.borderless).help(L10n.t("rec.record"))
                    Button { onUploadAudio() } label: { Image(systemName: "waveform.badge.plus") }
                        .buttonStyle(.borderless).help(L10n.t("act.upload"))
                    Menu {
                        Button { onCopyAllMarkdown() } label: { Label(L10n.t("act.copyallmd"), systemImage: "doc.richtext") }
                        Divider()
                        Button { onShowGuide() } label: { Label(L10n.t("act.guide"), systemImage: "questionmark.circle") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.t("act.more"))
                    Button { onOpenPreferences() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help(L10n.t("act.prefs"))
                }
                .font(.system(size: 15))
                .imageScale(.medium)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.t("search"), text: $search)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                if !manager.items.isEmpty {
                    Text(filtered.count == manager.items.count ? "\(manager.items.count)"
                         : "\(filtered.count)/\(manager.items.count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
        }
        .padding(12)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableFilters) { f in
                    chip(L10n.t(f.labelKey), icon: f.icon, selected: filter == f && collectionFilter == nil) {
                        filter = f; collectionFilter = nil
                    }
                }
                ForEach(manager.collections, id: \.self) { name in
                    chip(name, icon: "folder", selected: collectionFilter == name) {
                        let now = (collectionFilter == name ? nil : name)
                        collectionFilter = now
                        // When activating a collection, drop the type filter: otherwise an invisible `.image`
                        // (or other) would keep hiding items in the collection without any chip showing it.
                        if now != nil { filter = .all }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private func chip(_ text: String, icon: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(text).font(.system(size: 11))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: selected)   // soften the selected-chip swap
        }
        .buttonStyle(.plain)
    }

    // MARK: - Batch selection (vibe coders)

    private func toggleSelecting() {
        selecting.toggle()
        if !selecting { selectedBatch = [] }
    }
    private func toggleCheck(_ id: UUID) {
        if selectedBatch.contains(id) { selectedBatch.remove(id) } else { selectedBatch.insert(id) }
    }
    // VISIBLE order (newest first) — not manager.items' insertion order — so that
    // the PDF/ZIP comes out in the same order the user sees and checks the items. Includes selected
    // items even if a filter change has hidden them from `filtered`.
    private var batchItems: [ClipboardItem] { sortedItems.filter { selectedBatch.contains($0.id) } }

    private var batchBar: some View {
        HStack(spacing: 8) {
            Text(String(format: L10n.t("sel.count"), selectedBatch.count)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            batchButton("doc.richtext", "PDF") { onCombinePDF(batchItems) }
            batchButton("doc.zipper", "ZIP") { onExportZip(batchItems) }
            batchButton("folder.badge.plus", L10n.t("sel.collection")) { onAssignCollection(batchItems) }
            Button(L10n.t("sel.done")) { selecting = false; selectedBatch = [] }
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
        .transition(.move(edge: .bottom).combined(with: .opacity))   // slides in via the container's animation on `selecting`
    }

    private func batchButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: icon); Text(label).font(.system(size: 11)) }
        }
        .controlSize(.small)
        .disabled(selectedBatch.isEmpty)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filtered) { item in
                        ItemRow(item: item,
                                isSelected: item.id == selection.selectedID,
                                resetToken: selection.openToken,
                                manager: manager,
                                onPick: onPick, onSaveImage: onSaveImage,
                                onCopyMarkdown: onCopyMarkdown, onOCR: { runOCR(item) },
                                onRename: onRename, onDelete: onDelete,
                                onRetryTranscription: onRetryTranscription,
                                onSaveAsFile: onSaveAsFile, onCopyAsCode: onCopyAsCode,
                                searchTerm: search,
                                selecting: selecting, isChecked: selectedBatch.contains(item.id),
                                onToggleCheck: { toggleCheck(item.id) })
                            .id(item.id)
                        if ocrResultID == item.id { ocrBox }
                    }
                }
                .padding(8)
                // Keyed on ids (not items) so new/removed clips fade+move, but in-place content
                // updates (e.g. a transcription finishing) don't trigger a layout animation.
                .animation(.easeOut(duration: 0.2), value: filtered.map(\.id))
                .animation(.easeOut(duration: 0.13), value: ocrResultID)
            }
            .onChange(of: selection.selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(newID, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if manager.items.isEmpty && search.isEmpty && filter == .all {
                // First run: welcome with the actual (configured) shortcuts and a tip.
                if let logo = Self.appLogo {
                    Image(nsImage: logo).resizable().frame(width: 46, height: 46).opacity(0.9)
                }
                Text(L10n.t("empty.title")).font(.system(size: 15, weight: .semibold))
                Text(L10n.t("empty.sub")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    kbdHint(settings.combo.displayString, L10n.t("hint.open"))
                    kbdHint(settings.voiceCombo.displayString, L10n.t("rec.record"))
                }
                .padding(.top, 2)
                Text(L10n.t("empty.hover")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: filter == .credential ? "key" : "magnifyingglass")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                Text(filter == .credential ? L10n.t("empty.cred") : L10n.t("empty.noresults"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        .transition(.opacity)   // fades in via the container's animation on `filtered.isEmpty`
    }

    private func kbdHint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var ocrBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ocrRunning ? L10n.t("rec.transcribing") : L10n.t("ocr.label"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !ocrRunning {
                Text(ocrText.isEmpty ? "—" : ocrText)
                    .font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
        .padding(.horizontal, 8).padding(.bottom, 4)
        .transition(.opacity)   // fades in via the list's animation on `ocrResultID`
    }

    private func runOCR(_ item: ClipboardItem) {
        ocrResultID = item.id; ocrText = ""; ocrRunning = true
        let pbCount = NSPasteboard.general.changeCount   // don't clobber a clip the user makes during OCR
        DispatchQueue.global(qos: .userInitiated).async {   // Storage.loadImage + OCR are both off-main safe
            let img = item.imageFileName.flatMap { Storage.shared.loadImage(fileName: $0) }
            let text = img.map { OCR.recognizeText(in: $0) } ?? ""
            DispatchQueue.main.async {
                ocrRunning = false; ocrText = text
                // Only push the recognized text to the clipboard if the user hasn't copied something else
                // meanwhile (the result is still shown in the UI either way).
                if !text.isEmpty, NSPasteboard.general.changeCount == pbCount { manager.setClipboardText(text) }
            }
        }
    }
}

/// A single history row. Images are shown large (image on top, metadata below).
struct ItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let resetToken: Int
    @ObservedObject var manager: ClipboardManager
    var onPick: (ClipboardItem) -> Void
    var onSaveImage: (ClipboardItem) -> Void
    var onCopyMarkdown: (ClipboardItem) -> Void
    var onOCR: () -> Void
    var onRename: (ClipboardItem) -> Void
    var onDelete: (ClipboardItem) -> Void
    var onRetryTranscription: (ClipboardItem) -> Void
    var onSaveAsFile: (ClipboardItem) -> Void
    var onCopyAsCode: (ClipboardItem) -> Void
    var searchTerm: String = ""
    var selecting: Bool = false
    var isChecked: Bool = false
    var onToggleCheck: () -> Void = {}

    @State private var hovering = false
    @State private var revealed = false
    @State private var justCopied = false

    private var isCredential: Bool { item.isCredential == true }
    private var hasText: Bool { !(item.text?.isEmpty ?? true) }
    private var customName: String? {
        guard let nm = item.name, !nm.isEmpty else { return nil }
        return nm
    }

    /// Playable audio of a voice note (only if the file is still on disk).
    private var voiceAudioFile: String? {
        guard item.isVoiceNote == true, let af = item.audioFileName,
              Storage.shared.audioExists(fileName: af) else { return nil }
        return af
    }
    private var isTranscribing: Bool { item.transcribing == true }

    /// Color if the item's text is a hex value (#RGB / #RRGGBB / #RRGGBBAA) → shows a swatch.
    private var swatchColor: NSColor? {
        guard item.kind == .text, item.isVoiceNote != true, item.isCredential != true,
              let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return NSColor(klipHex: t)
    }

    /// Highlights search matches in a text (yellow background).
    static func highlight(_ text: String, _ term: String) -> AttributedString {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var idx = text.startIndex
        while idx < text.endIndex, let r = text.range(of: q, options: .caseInsensitive, range: idx..<text.endIndex) {
            result += AttributedString(String(text[idx..<r.lowerBound]))
            var m = AttributedString(String(text[r.lowerBound..<r.upperBound]))
            m.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.45)
            result += m
            idx = r.upperBound
        }
        result += AttributedString(String(text[idx...]))
        return result
    }


    private var displayedPreview: String {
        // The eye toggles masked/real (item.preview is always masked for credentials).
        if isCredential, let t = item.text {
            // Sealed-but-undecryptable (credential encrypted on another Mac): never show the raw token,
            // even when "revealed" — show the stored placeholder.
            if CredentialCrypto.isSealed(t) { return item.preview.isEmpty ? CredentialDetector.maskedPlaceholder : item.preview }
            return revealed ? t : CredentialDetector.masked(t)
        }
        return item.preview.isEmpty ? L10n.t("item.empty") : item.preview
    }

    var body: some View {
        HStack(spacing: 8) {
            if selecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(isChecked ? Color.accentColor : .secondary)
                    .padding(.leading, 6)
            }
            Group {
                if item.kind == .image { imageCard } else { standardRow }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((selecting && isChecked) || (!selecting && isSelected) ? Color.accentColor.opacity(0.20)
                  : (hovering ? Color.primary.opacity(0.07) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected && !selecting ? Color.accentColor.opacity(0.6)
                    : (isCredential ? Color.yellow.opacity(0.4) : Color.clear), lineWidth: 1))
        .contentShape(Rectangle())
        .contextMenu {
            // Right-click mirrors the hover actions: copy + star, then everything the ⋯ menu offers.
            if item.isVoiceNote != true || hasText {   // same condition as the hover copy button
                Button { manager.copyToPasteboard(item) } label: { Label(L10n.t("row.copyonly"), systemImage: "doc.on.doc") }
            }
            Button { manager.togglePin(item) } label: { Label(L10n.t(item.pinned ? "row.unpin" : "row.pin"), systemImage: item.pinned ? "star.fill" : "star") }
            Divider()
            moreMenu
        }
        // Animated so the hover highlight and the inline actions fade instead of popping in.
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { if selecting { onToggleCheck() } else { onPick(item) } }
        .onChange(of: resetToken) { _, _ in revealed = false }   // re-mask when reopening the panel
        .onChange(of: hovering) { _, h in if !h { revealed = false } }   // re-mask once the pointer leaves the row (covers search/filter/scroll)
    }

    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fn = item.imageFileName, let img = Storage.shared.cachedImage(fileName: fn) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).frame(height: 150)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                    Text({ let p = img.pixelDimensions; return "\(Int(p.width))×\(Int(p.height))" }())
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let nm = customName {
                    Text(nm).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    metadata
                    Spacer(minLength: 4)
                    if hovering && !selecting { actions } else if item.pinned { pinDot }
                }
            }
        }
        .padding(8)
    }

    private var standardRow: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                if let nm = customName {
                    Text(Self.highlight(nm, searchTerm)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(Self.highlight(displayedPreview, searchTerm))
                        .lineLimit(1).font(.system(size: 11, design: isCredential ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.highlight(displayedPreview, searchTerm))
                        .lineLimit(2).font(.system(size: 13, design: isCredential ? .monospaced : .default))
                }
                metadata
            }
            Spacer(minLength: 4)
            if hovering && !selecting { actions }
            else if isCredential { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.system(size: 10)) }
            else if item.pinned { pinDot }
        }
        .padding(8)
    }

    private var pinDot: some View { Image(systemName: "star.fill").foregroundStyle(.orange).font(.system(size: 10)) }

    @ViewBuilder private var thumbnail: some View {
        if isCredential {
            Image(systemName: "key.fill").font(.system(size: 18))
                .frame(width: 46, height: 46).foregroundStyle(.yellow)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.14)))
        } else if item.isVoiceNote == true {
            // No text (transcribing/failed) + audio: ▶ button, consistent with the row tap (plays).
            // With text: static icon (the row tap pastes the text; playback lives in the actions).
            if !hasText, let af = voiceAudioFile {
                VoicePlayButton(fileName: af, large: true)
            } else {
                Image(systemName: "waveform").font(.system(size: 20))
                    .frame(width: 46, height: 46).foregroundStyle(.purple)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.12)))
            }
        } else if let c = swatchColor {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: c))
                .frame(width: 46, height: 46)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        } else {
            Image(systemName: "doc.text").font(.system(size: 18))
                .frame(width: 46, height: 46).foregroundStyle(.secondary)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(Self.timeLabel(item.createdAt)).font(.system(size: 10)).foregroundStyle(.secondary)
            if let af = voiceAudioFile {
                VoicePlaybackInfo(fileName: af, duration: item.audioDuration)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            // Inline: only the type's primary action + copy + star. Everything else lives in the ⋯ menu so
            // the row stays readable (icons alone weren't clear).
            if item.isVoiceNote == true {
                if let af = voiceAudioFile {
                    if hasText { VoicePlayButton(fileName: af, large: false) }
                    else if !isTranscribing { iconButton("arrow.clockwise", L10n.t("voice.retry")) { onRetryTranscription(item) } }
                }
                if hasText { copyButton }
            } else if isCredential {
                iconButton(revealed ? "eye.slash" : "eye", L10n.t("row.reveal")) { revealed.toggle() }
                copyButton
            } else {
                copyButton
            }
            // Star: a filterable mark — it does NOT float the item to the top.
            iconButton(item.pinned ? "star.fill" : "star", L10n.t(item.pinned ? "row.unpin" : "row.pin")) { manager.togglePin(item) }
            Menu { moreMenu } label: { Image(systemName: "ellipsis.circle").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.t("act.more"))
        }
        .transition(.opacity)   // fade with the row's hover animation
    }

    /// The ⋯ menu: every secondary action, with text labels so it's clear (unlike the bare icons).
    @ViewBuilder private var moreMenu: some View {
        if item.isVoiceNote == true {
            if let af = voiceAudioFile {
                Button { NSWorkspace.shared.activateFileViewerSelecting([Storage.shared.audioURL(for: af)]) } label: { Label(L10n.t("voice.reveal"), systemImage: "folder") }
            }
            if hasText { Button { onCopyMarkdown(item) } label: { Label(L10n.t("row.markdown"), systemImage: "doc.richtext") } }
        } else if item.kind == .image {
            if let fn = item.imageFileName {
                Button { NSWorkspace.shared.open(Storage.shared.imageURL(for: fn)) } label: { Label(L10n.t("row.viewbig"), systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            Button { onSaveImage(item) } label: { Label(L10n.t("row.save"), systemImage: "square.and.arrow.down") }
            Button { onOCR() } label: { Label(L10n.t("row.ocr"), systemImage: "text.viewfinder") }
        } else if isCredential {
            Button { manager.toggleCredential(item) } label: { Label(L10n.t("row.unmarkcred"), systemImage: "key.slash") }
        } else {
            Button { manager.setClipboardText(Markdownify.toWhatsApp(item.text ?? "")); ToastHUD.show(L10n.t("toast.copied")) } label: { Label(L10n.t("row.whatsapp"), systemImage: "message") }
            Button { manager.copyForEmail(item.text ?? ""); ToastHUD.show(L10n.t("toast.copied")) } label: { Label(L10n.t("row.email"), systemImage: "envelope") }
            Button { onCopyAsCode(item) } label: { Label(L10n.t("row.code"), systemImage: "chevron.left.forwardslash.chevron.right") }
            if let u = item.linkURL {
                Button { NSWorkspace.shared.open(u) } label: { Label(L10n.t("row.openlink"), systemImage: "arrow.up.right.square") }
            }
            Button { onCopyMarkdown(item) } label: { Label(L10n.t("row.markdown"), systemImage: "doc.richtext") }
            Button { onSaveAsFile(item) } label: { Label(L10n.t("row.savefile"), systemImage: "square.and.arrow.down") }
            Button { manager.toggleCredential(item) } label: { Label(L10n.t("row.markcred"), systemImage: "key") }
        }
        Divider()
        Button { onRename(item) } label: { Label(L10n.t("row.rename"), systemImage: "tag") }
        Button(role: .destructive) { onDelete(item) } label: { Label(L10n.t("row.delete"), systemImage: "trash") }
    }

    /// Copy WITHOUT pasting or closing (unlike the row click / Return): the panel stays open and
    /// the icon flashes a checkmark as feedback.
    private var copyButton: some View {
        iconButton(justCopied ? "checkmark" : "doc.on.doc", L10n.t("row.copyonly")) {
            manager.copyToPasteboard(item)
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { justCopied = false }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                // Smooth symbol swap (copy→checkmark flash, eye/star toggles) instead of a hard pop.
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.12), value: symbol)
        }
        .buttonStyle(.borderless).help(help)
    }

    /// Human-readable date label: "Hoy · 10:43", "Ayer · 10:43" or "martes 04 de julio · 10:43".
    static func timeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let en = Settings.shared.uiLanguage == "en"
        let time = df(en ? "h:mm a" : "HH:mm", en).string(from: date)
        if cal.isDateInToday(date)     { return "\(L10n.t("date.today")) · \(time)" }
        if cal.isDateInYesterday(date) { return "\(L10n.t("date.yesterday")) · \(time)" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let fmt = en ? (sameYear ? "EEEE, MMM d" : "EEEE, MMM d, yyyy")
                     : (sameYear ? "EEEE dd 'de' MMMM" : "EEEE dd 'de' MMMM yyyy")
        return "\(df(fmt, en).string(from: date)) · \(time)"
    }

    /// DateFormatters cached by (language, format, time zone) — avoids recreating them on every render, while
    /// still reflecting a system time-zone change mid-session (the TZ in the key busts a stale formatter).
    private static var dfCache: [String: DateFormatter] = [:]
    private static func df(_ format: String, _ en: Bool) -> DateFormatter {
        let cacheKey = "\(en ? "en" : "es")|\(format)|\(TimeZone.current.identifier)"
        if let f = dfCache[cacheKey] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: en ? "en_US" : "es_ES")
        f.timeZone = .current
        f.dateFormat = format
        dfCache[cacheKey] = f
        return f
    }
}

extension NSColor {
    /// Parses a hex color (#RGB, #RRGGBB, #RRGGBBAA, with or without #). nil if it isn't a valid hex.
    convenience init?(klipHex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard [3, 6, 8].contains(s.count), s.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        func byte(_ sub: Substring) -> CGFloat { CGFloat(Int(sub, radix: 16) ?? 0) / 255.0 }
        let chars = Array(s)
        let r, g, b: CGFloat
        var a: CGFloat = 1
        if s.count == 3 {
            r = byte(Substring(String(repeating: chars[0], count: 2)))
            g = byte(Substring(String(repeating: chars[1], count: 2)))
            b = byte(Substring(String(repeating: chars[2], count: 2)))
        } else {
            r = byte(s.prefix(2))
            g = byte(s.dropFirst(2).prefix(2))
            b = byte(s.dropFirst(4).prefix(2))
            if s.count == 8 { a = byte(s.dropFirst(6).prefix(2)) }
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Formats seconds as m:ss (0:14, 1:05…) or h:mm:ss for long uploaded audios (1:02:03).
func mmss(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Shows the audio duration and, while THAT file is playing, the elapsed time + progress bar.
/// Observes AudioPlayer.shared: all visible VoicePlaybackInfo re-evaluate ~5/s while something is playing
/// (acceptable because the body is trivial and LazyVStack limits it to the on-screen rows).
struct VoicePlaybackInfo: View {
    let fileName: String
    let duration: Double?
    @ObservedObject private var audio = AudioPlayer.shared

    var body: some View {
        if audio.isPlaying(fileName) {
            let total = audio.total > 0 ? audio.total : (duration ?? 0)
            HStack(spacing: 5) {
                Text("\(mmss(audio.elapsed)) / \(mmss(total))").monospacedDigit()
                ProgressView(value: total > 0 ? min(1, audio.elapsed / total) : 0)
                    .frame(width: 54).controlSize(.mini)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        } else if let d = duration {
            Text(mmss(d)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// ▶/⏹ button for a voice note. Observes AudioPlayer.shared (like VoicePlaybackInfo): keeps the
/// observation out of ItemRow so the whole row isn't recomputed on every playback change.
struct VoicePlayButton: View {
    let fileName: String
    var large: Bool = false
    @ObservedObject private var audio = AudioPlayer.shared

    var body: some View {
        let icon = audio.isPlaying(fileName) ? "stop.fill" : "play.fill"
        Group {
            if large {
                Button { AudioPlayer.shared.toggle(fileName: fileName) } label: {
                    Image(systemName: icon).font(.system(size: 18))
                        .frame(width: 46, height: 46).foregroundStyle(.purple)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.12)))
                }
                .buttonStyle(.plain)
            } else {
                Button { AudioPlayer.shared.toggle(fileName: fileName) } label: {
                    Image(systemName: icon).font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
        }
        .help(L10n.t("voice.play"))
    }
}
