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

/// One optical left edge for the whole list: day headers, text rows, image rows and the OCR card all
/// start at the same x. The list keeps `gutter` between the row backgrounds and the panel wall, and
/// every row insets its content by `inset` inside that background.
enum RowMetrics {
    static let gutter: CGFloat = 6
    static let inset: CGFloat = 12
}

/// Panel UI: header, type filters, list and guide.
struct HistoryView: View {
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var selection: SelectionModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings = Settings.shared
    var onPick: (ClipboardItem) -> Void
    var onSaveImage: (ClipboardItem) -> Void
    var onAnnotate: (ClipboardItem) -> Void
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
    var onDragSession: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var filter: HistoryFilter = .all
    @State private var collectionFilter: String?
    @State private var selecting = false
    @State private var selectedBatch: Set<UUID> = []
    /// Origin of a Shift-click range. Every plain check (and the Cmd-click that opens batch mode) moves
    /// it; Shift-click itself never does, so repeated Shift-clicks re-extend from the same row.
    @State private var batchAnchor: UUID?
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
            // Scroll-edge effect instead of a hard divider (Apple: a rule under floating chrome is
            // decorative; a soft edge separates the chrome from the scrolling content).
            LinearGradient(colors: [Color.primary.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
                .allowsHitTesting(false)
            if filtered.isEmpty { emptyState } else { list }
            if selecting { batchBar }
        }
        // No container animations at all: an ambient animation transaction here can bleed into the
        // list (e.g. the scroll on a new clip), which reads as the text sliding. The user wants zero
        // text movement, so the batch bar / empty-state just swap instantly.
        .frame(minWidth: 420, minHeight: 460)
        // MUST stay truly clear: any fill here stacks ON TOP of the window's vibrancy and collapses
        // the glass to a flat box (NSVisualEffectView doesn't affect content drawn over it).
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
            if !newValue && selecting { selecting = false; selectedBatch = []; batchAnchor = nil }
        }
        // Return in batch mode: the controller only knows which row the cursor is on, the batch lives here.
        .onChange(of: selection.toggleCheckToken) { _, _ in
            guard selecting, let id = selection.selectedID else { return }
            toggleCheck(id)
        }
        // Esc with text in the search field: clear it (second back-out layer, before closing).
        .onChange(of: selection.clearSearchToken) { _, _ in search = ""; searchFocused = true }
        .onChange(of: selection.openToken) { _, _ in
            search = ""; filter = .all; collectionFilter = nil
            selecting = false; selectedBatch = []; batchAnchor = nil
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
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if let logo = Self.appLogo {
                    Image(nsImage: logo).resizable().frame(width: 22, height: 22)
                }
                Text("Klip").font(.title2.bold()).tracking(-0.3)   // tighten large display text (Apple type)
                Spacer(minLength: 8)
                if recorder.transcribingCount > 0 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("\(recorder.transcribingCount)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))   // same pill as the item counter
                    .help(L10n.t("rec.transcribing"))
                    .padding(.trailing, 2)
                }
                // Action icons: uniform size and generous spacing so they don't overlap.
                HStack(spacing: 16) {
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
                            .symbolEffect(.pulse, isActive: recorder.state == .recording)
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
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                if !manager.items.isEmpty {
                    Text(filtered.count == manager.items.count ? "\(manager.items.count)"
                         : "\(filtered.count)/\(manager.items.count)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
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
        // Soft trailing fade: the chip row scrolls, and a hard clip mid-word ("Credencial|") reads as
        // broken. Fading the edge is Apple's scroll-edge cue for "there's more this way".
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.93),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        )
        .padding(.bottom, 8)
    }

    private func chip(_ text: String, icon: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            // Native segmented-selection feel: the active chip is a solid accent capsule with white
            // content; the rest are a faint, borderless material pill.
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(.quaternary))
            )
            .animation(.snappy(duration: 0.2, extraBounce: 0), value: selected)   // critically-damped selection swap
        }
        .buttonStyle(PressableButtonStyle())   // press-down feedback (Apple: respond on press)
    }

    // MARK: - Batch selection (vibe coders)

    private func toggleSelecting() {
        selecting.toggle()
        if !selecting { selectedBatch = []; batchAnchor = nil }
    }
    private func toggleCheck(_ id: UUID) {
        if selectedBatch.contains(id) { selectedBatch.remove(id) } else { selectedBatch.insert(id) }
        batchAnchor = id
    }
    /// Cmd-click on a row outside batch mode: the Finder-style shortcut into multi-select, with that
    /// row already checked — otherwise the only way in is the header button.
    private func commandSelect(_ id: UUID) {
        selecting = true
        selectedBatch = [id]
        batchAnchor = id
    }
    /// Shift-click inside batch mode: (un)checks the whole contiguous run between the anchor and this
    /// row in FILTERED order — what the user sees is what gets checked. The clicked end decides the
    /// direction, so Shift-clicking a checked row clears the run instead of re-checking it.
    private func rangeSelect(_ id: UUID) {
        let ids = filtered.map(\.id)
        guard let to = ids.firstIndex(of: id) else { return }
        let from = batchAnchor.flatMap { ids.firstIndex(of: $0) } ?? to
        let run = Set(ids[min(from, to)...max(from, to)])
        if selectedBatch.contains(id) { selectedBatch.subtract(run) } else { selectedBatch.formUnion(run) }
    }
    /// The ids the "Select all" toggle acts on: only what the current search/filter actually shows,
    /// so the control can never silently sweep in clips the user can't see.
    private var visibleBatchIDs: Set<UUID> { Set(filtered.map(\.id)) }
    private var allVisibleChecked: Bool {
        !visibleBatchIDs.isEmpty && visibleBatchIDs.isSubset(of: selectedBatch)
    }
    private func toggleSelectAll() {
        let ids = visibleBatchIDs
        if allVisibleChecked { selectedBatch.subtract(ids) } else { selectedBatch.formUnion(ids) }
    }
    // VISIBLE order (newest first) — not manager.items' insertion order — so that
    // the PDF/ZIP comes out in the same order the user sees and checks the items. Includes selected
    // items even if a filter change has hidden them from `filtered`.
    private var batchItems: [ClipboardItem] { sortedItems.filter { selectedBatch.contains($0.id) } }

    private var batchBar: some View {
        VStack(spacing: 0) {
            // Mirror of the header's scroll-edge gradient, flipped for a bottom edge: the bar floats over
            // the list, so it gets a soft edge, never a rule (a hard divider on glass reads as decoration).
            LinearGradient(colors: [.clear, Color.primary.opacity(0.10)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                Text(String(format: L10n.t("sel.count"), selectedBatch.count)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                // Sits next to the counter it changes. Only the button's own width moves when the label
                // flips — the counter is leading and the Spacer eats the rest, so no text shifts.
                Button(allVisibleChecked ? L10n.t("sel.none")
                                         : String(format: L10n.t("sel.all"), filtered.count)) {
                    toggleSelectAll()
                }
                .buttonStyle(.link).font(.system(size: 11))
                .disabled(filtered.isEmpty)
                Spacer()
                batchButton("doc.richtext", "PDF") { onCombinePDF(batchItems) }
                batchButton("doc.zipper", "ZIP") { onExportZip(batchItems) }
                batchButton("folder.badge.plus", L10n.t("sel.collection")) { onAssignCollection(batchItems) }
                Button(L10n.t("sel.done")) { selecting = false; selectedBatch = [] }
                    .buttonStyle(.link).font(.system(size: 13))
            }
            .padding(.horizontal, RowMetrics.inset).padding(.vertical, 8)
            // A vibrancy-safe fill, NOT a second material: stacking another blur on the panel's own
            // glass flattens both (the top layer only ever gets fills, transparency and vibrancy).
            .background(Color.primary.opacity(0.04))
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))   // slides in via the container's animation on `selecting`
    }

    private func batchButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: icon); Text(label).font(.system(size: 11)) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedBatch.isEmpty)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                        // Date section header (Notes/Photos-style) whenever the day changes. Uses the
                        // flat `filtered` order, so keyboard nav over `filtered` is unaffected.
                        if idx == 0 || !ItemRow.sameDay(filtered[idx - 1].createdAt, item.createdAt) {
                            Text(ItemRow.daySection(item.createdAt))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, idx == 0 ? 2 : 12).padding(.bottom, 4)
                                .padding(.leading, RowMetrics.inset)
                                .accessibilityAddTraits(.isHeader)   // lets the VoiceOver rotor jump day to day
                        }
                        ItemRow(item: item,
                                isSelected: item.id == selection.selectedID,
                                resetToken: selection.openToken,
                                manager: manager,
                                onPick: onPick, onSaveImage: onSaveImage, onAnnotate: onAnnotate,
                                onCopyMarkdown: onCopyMarkdown, onOCR: { runOCR(item) },
                                onRename: onRename, onDelete: onDelete,
                                onRetryTranscription: onRetryTranscription,
                                onSaveAsFile: onSaveAsFile, onCopyAsCode: onCopyAsCode,
                                searchTerm: search,
                                selecting: selecting, isChecked: selectedBatch.contains(item.id),
                                onToggleCheck: { toggleCheck(item.id) },
                                keyboardActive: selection.hasNavigated,
                                onCommandSelect: { commandSelect(item.id) },
                                onRangeSelect: { rangeSelect(item.id) },
                                onDragSession: onDragSession)
                            .id(item.id)
                        if ocrResultID == item.id { ocrBox }
                    }
                }
                .padding(.horizontal, RowMetrics.gutter).padding(.vertical, 4)
                // No list layout animation: a new clip must appear in place, never slide the rows
                // (text must not move — the user copies constantly). Only the OCR box fades.
                .animation(.easeOut(duration: 0.13), value: ocrResultID)
            }
            .scrollContentBackground(.hidden)   // let the window's glass material show through the list
            .onChange(of: selection.selectedID) { _, newID in
                guard let newID else { return }
                // Hard-disable animation on the scroll: a new clip changes the selection constantly,
                // and any ambient animation transaction would make the whole list (text) slide.
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { proxy.scrollTo(newID, anchor: .center) }
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
                Text(L10n.t("empty.title")).font(.title3.weight(.semibold))
                Text(L10n.t("empty.sub")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    kbdHint(settings.combo.displayString, L10n.t("hint.open"))
                    kbdHint(settings.voiceCombo.displayString, L10n.t("rec.record"))
                }
                .padding(.top, 2)
                Text(L10n.t("empty.hover")).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: filter == .credential ? "key" : "magnifyingglass")
                    .font(.system(size: 30)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                Text(filter == .credential ? L10n.t("empty.cred") : L10n.t("empty.noresults"))
                    .foregroundStyle(.secondary)
                // One-click way out of a "falsely empty" list caused by an active search/filter.
                if !search.isEmpty || filter != .all || collectionFilter != nil {
                    Button(L10n.t("empty.clear")) { search = ""; filter = .all; collectionFilter = nil }
                        .buttonStyle(.link).font(.system(size: 11))
                }
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
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !ocrRunning {
                Text(ocrText.isEmpty ? "—" : ocrText)
                    .font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(RowMetrics.inset)
        // No extra horizontal inset: the card is a continuation of the row it belongs to, so its
        // accent background must share that row background's edges.
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
        .padding(.bottom, 4)
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
    var onAnnotate: (ClipboardItem) -> Void
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
    /// True once the arrow keys have driven the selection: the selected row then shows the same action
    /// strip hover gives, so the strip stops being pointer-only.
    var keyboardActive: Bool = false
    var onCommandSelect: () -> Void = {}
    var onRangeSelect: () -> Void = {}
    /// Told at the start of a drag out of the panel so the controller can keep the transient panel
    /// alive until the drop lands.
    var onDragSession: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var revealed = false
    /// Counts every copy click. Rapid clicks must each get their own bounce + tick, and each pending
    /// revert must be able to tell whether it still owns the icon — a Bool can't express either.
    @State private var copyGeneration = 0
    /// The generation whose checkmark is on screen (0 = showing the copy glyph).
    @State private var shownCopyGeneration = 0

    private var isCredential: Bool { item.isCredential == true }
    private var hasText: Bool { !(item.text?.isEmpty ?? true) }
    /// The row reads as "current" for two different reasons — the batch check and the keyboard cursor —
    /// and they are mutually exclusive by mode.
    private var isRowSelected: Bool { (selecting && isChecked) || (!selecting && isSelected) }
    /// The hover strip also belongs to the keyboard cursor. No animation on the swap: this fires while
    /// the user arrows through the list, and an animated strip would settle the row's text sideways.
    private var showsActions: Bool { (hovering || (isSelected && keyboardActive)) && !selecting }
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
            m.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(0.45)
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
        return item.preview.isEmpty ? L10n.t("item.empty") : Self.cleanPreview(item.preview)
    }

    /// Strips Markdown emphasis syntax from the PREVIEW so "**DealLost**" reads as "DealLost".
    /// Only paired markers are removed — lone underscores stay so identifiers like GN_MASIVO_X
    /// are never mangled. Display-only; the stored text and search are untouched.
    static func cleanPreview(_ s: String) -> String {
        var t = s
        for p in [#"\*\*(.+?)\*\*"#, #"__(.+?)__"#, #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, "`(.+?)`"] {
            t = t.replacingOccurrences(of: p, with: "$1", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        return t
    }

    var body: some View {
        accessibleRow(rowCore)
    }

    private var rowCore: some View {
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
        // Single, clean selection: one rounded accent-tint fill — no border, no rail. Tuned for the
        // panel's light glass.
        // Concentric with the panel (Apple: inner_radius = parent_radius - padding → 12 - 6).
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isRowSelected ? Color.accentColor.opacity(0.20)
                  : (hovering ? Color.primary.opacity(0.06) : Color.clear)))
        .contentShape(Rectangle())
        .contextMenu {
            // Right-click mirrors the hover actions: copy + star, then everything the ⋯ menu offers.
            if item.isVoiceNote != true || hasText {   // same condition as the hover copy button
                Button { manager.copyToPasteboard(item) } label: { Label(L10n.t("row.copyonly"), systemImage: "doc.on.doc") }
            }
            Button { manager.togglePin(item) } label: { Label(L10n.t(item.pinned ? "row.unpin" : "row.pin"), systemImage: item.pinned ? "star.fill" : "star") }
                // Display only — the real handler is PanelController's key monitor. Without this the
                // monitor's shortcuts are invisible and read as undiscoverable trivia.
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            moreMenu
        }
        // Animated so the hover highlight and the inline actions fade instead of popping in.
        .onHover { h in hovering = h }   // instant — no animated "text settling" as the row's actions appear
        .onTapGesture { handleTap() }
        .modifier(RowDrag(enabled: canDrag, provider: { self.makeDragProvider() }, onStart: onDragSession))
        .onChange(of: resetToken) { _, _ in revealed = false }   // re-mask when reopening the panel
        .onChange(of: hovering) { _, h in if !h { revealed = false } }   // re-mask once the pointer leaves the row (covers search/filter/scroll)
    }

    /// Modifier flags decide the click's meaning, Finder-style: Cmd opens batch mode on this row, Shift
    /// extends the run inside it. `NSApp.currentEvent` is the only place SwiftUI's tap gesture exposes them.
    private func handleTap() {
        let mods = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if selecting {
            if mods.contains(.shift) { onRangeSelect() } else { onToggleCheck() }
        } else if mods.contains(.command) {
            onCommandSelect()
        } else {
            onPick(item)
        }
    }

    // MARK: - Drag out of the panel

    /// Whether this row has something real to hand a drop target. Credentials are excluded outright:
    /// a token must never leave the panel by drag, revealed or not.
    private var canDrag: Bool {
        guard !isCredential else { return false }
        if item.kind == .image { return item.imageFileName != nil }
        if voiceAudioFile != nil { return true }
        return item.linkURL != nil || hasText
    }

    /// Media vends its file URL (so a Finder drop writes a real file); links vend a URL and text the
    /// stored string, not the trimmed preview.
    private func makeDragProvider() -> NSItemProvider {
        if item.kind == .image, let fn = item.imageFileName {
            return NSItemProvider(contentsOf: Storage.shared.imageURL(for: fn)) ?? NSItemProvider()
        }
        if let af = voiceAudioFile {
            return NSItemProvider(contentsOf: Storage.shared.audioURL(for: af)) ?? NSItemProvider()
        }
        if let u = item.linkURL { return NSItemProvider(object: u as NSURL) }
        return NSItemProvider(object: (item.text ?? "") as NSString)
    }

    // MARK: - VoiceOver

    /// What VoiceOver reads for the row: type, then the user's name for the clip or its preview, then
    /// how long ago it was captured. A credential contributes its masked placeholder and nothing else —
    /// `displayedPreview` turns into cleartext while revealed and must never reach this string.
    private var a11yLabel: String {
        let kind: String
        if isCredential { kind = L10n.t("a11y.kind.cred") }
        else if item.kind == .image { kind = L10n.t("a11y.kind.image") }
        else if item.isVoiceNote == true { kind = L10n.t("a11y.kind.voice") }
        else if item.linkURL != nil { kind = L10n.t("a11y.kind.link") }
        else { kind = L10n.t("a11y.kind.text") }
        let content = customName ?? (isCredential ? CredentialDetector.maskedPlaceholder : displayedPreview)
        return "\(kind), \(content), \(Self.relativeTime(item.createdAt))"
    }

    /// One VoiceOver element per row (the checkmark, preview and metadata are decoration around a single
    /// activatable thing). In batch mode the row IS the checkbox, so it takes the toggle semantics that
    /// the ignored checkmark image can no longer carry.
    @ViewBuilder private func accessibleRow<V: View>(_ content: V) -> some View {
        if selecting {
            labelledRow(content)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(Text(L10n.t(isChecked ? "a11y.on" : "a11y.off")))
                .accessibilityHint(Text(L10n.t("a11y.hint.batch")))
        } else {
            typeActions(labelledRow(content))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(L10n.t("a11y.hint.row")))
                .accessibilityAction(named: Text(L10n.t(item.pinned ? "row.unpin" : "row.pin"))) { manager.togglePin(item) }
                .accessibilityAction(named: Text(L10n.t("row.rename"))) { onRename(item) }
                .accessibilityAction(named: Text(L10n.t("row.delete"))) { onDelete(item) }
        }
    }

    private func labelledRow<V: View>(_ content: V) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(a11yLabel))
            .accessibilityAddTraits(isRowSelected ? AccessibilityTraits.isSelected : [])
    }

    /// The per-type half of the hover strip, re-exposed as rotor actions. Same conditions and the same
    /// closures as `actions` — the two paths must never be able to offer different things.
    @ViewBuilder private func typeActions<V: View>(_ content: V) -> some View {
        if item.isVoiceNote == true {
            if voiceAudioFile != nil, !hasText, !isTranscribing {
                content.accessibilityAction(named: Text(L10n.t("voice.retry"))) { onRetryTranscription(item) }
            } else if hasText {
                content.accessibilityAction(named: Text(L10n.t("row.copyonly"))) { manager.copyToPasteboard(item) }
            } else {
                content
            }
        } else if isCredential {
            content
                .accessibilityAction(named: Text(L10n.t("row.reveal"))) { revealed.toggle() }
                .accessibilityAction(named: Text(L10n.t("row.copyonly"))) { manager.copyToPasteboard(item) }
        } else if item.kind == .image {
            content
                .accessibilityAction(named: Text(L10n.t("row.annotate"))) { onAnnotate(item) }
                .accessibilityAction(named: Text(L10n.t("row.save"))) { onSaveImage(item) }
                .accessibilityAction(named: Text(L10n.t("row.copyonly"))) { manager.copyToPasteboard(item) }
        } else {
            content.accessibilityAction(named: Text(L10n.t("row.copyonly"))) { manager.copyToPasteboard(item) }
        }
    }

    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fn = item.imageFileName, let img = Storage.shared.cachedImage(fileName: fn) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).frame(height: 150)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                    // Same readout badge as the capture overlay (solid black capsule, white monospaced),
                    // not a material: a blur here would be a second glass layer sitting on the panel's.
                    Text({ let p = img.pixelDimensions; return "\(Int(p.width))×\(Int(p.height))" }())
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let nm = customName {
                    Text(nm).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    metadata
                    Spacer(minLength: 4)
                    if showsActions { actions } else if item.pinned { pinDot }
                }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, RowMetrics.inset)
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 10) {
            // A color clip leads with a real swatch; a not-yet-transcribed voice note leads with its
            // play button. Every other type is text-forward — the type is an inline glyph in the title.
            if let c = swatchColor {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: c))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.12)))
                    .padding(.top, 1)
            } else if item.isVoiceNote == true, !hasText, let af = voiceAudioFile {
                VoicePlayButton(fileName: af, large: false).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let nm = customName {
                    Text(Self.highlight(nm, searchTerm)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    titleText.font(.system(size: 11, design: isCredential ? .monospaced : .default))
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    titleText.font(.system(size: 13, design: isCredential ? .monospaced : .default)).lineLimit(2)
                }
                metadata
            }
            Spacer(minLength: 4)
            if showsActions { actions }
            else if item.pinned { pinDot }
        }
        .padding(.vertical, 7).padding(.horizontal, RowMetrics.inset)
    }

    private var pinDot: some View { Image(systemName: "star.fill").foregroundStyle(.orange).font(.system(size: 11, weight: .semibold)) }

    /// Text-forward title: the preview text, with a small inline SF Symbol marking non-text types
    /// (link ↗ in accent, credential 🔑 in orange, transcribed voice ∿ in purple). Plain text — the
    /// common case — gets no glyph so the content leads, macOS-list style.
    private var titleText: Text {
        let body = Text(Self.highlight(displayedPreview, searchTerm))
        if item.linkURL != nil {
            // `highlight` only paints a background, so the accent tint and the glyph survive it.
            return Text(Image(systemName: "arrow.up.right")).foregroundColor(.accentColor)
                 + Text("  ") + body.foregroundColor(.accentColor)
        } else if isCredential {
            return Text(Image(systemName: "key.fill")).foregroundColor(.orange) + Text("  ") + body
        } else if item.isVoiceNote == true && hasText {
            return Text(Image(systemName: "waveform")).foregroundColor(.purple) + Text("  ") + body
        }
        return body
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(Self.timeShort(item.createdAt)).font(.system(size: 11)).foregroundStyle(.secondary)
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
            } else if item.kind == .image {
                iconButton("pencil.tip.crop.circle", L10n.t("row.annotate")) { onAnnotate(item) }
                iconButton("square.and.arrow.down", L10n.t("row.save")) { onSaveImage(item) }
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
            Button { onAnnotate(item) } label: { Label(L10n.t("row.annotate"), systemImage: "pencil.tip.crop.circle") }
            Button { onSaveImage(item) } label: { Label(L10n.t("row.save"), systemImage: "square.and.arrow.down") }
            Button { onOCR() } label: { Label(L10n.t("row.ocr"), systemImage: "text.viewfinder") }
        } else if isCredential {
            Button { manager.toggleCredential(item) } label: { Label(L10n.t("row.unmarkcred"), systemImage: "key.slash") }
        } else {
            Button { manager.setClipboardText(Markdownify.toWhatsApp(item.text ?? "")); ToastHUD.show(L10n.t("toast.copied")) } label: { Label(L10n.t("row.whatsapp"), systemImage: "message") }
            Button { manager.copyForEmail(item.text ?? ""); ToastHUD.show(L10n.t("toast.copied")) } label: { Label(L10n.t("row.email"), systemImage: "envelope") }
            Button { onCopyAsCode(item) } label: { Label(L10n.t("row.code"), systemImage: "chevron.left.forwardslash.chevron.right") }
                .keyboardShortcut(.return, modifiers: .command)   // display only (see the star in contextMenu)
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
            .keyboardShortcut(.delete, modifiers: .command)   // display only (see the star in contextMenu)
    }

    /// Copy WITHOUT pasting or closing (unlike the row click / Return): the panel stays open and
    /// the icon flashes a checkmark as feedback.
    private var copyButton: some View {
        iconButton(shownCopyGeneration == copyGeneration && copyGeneration > 0 ? "checkmark" : "doc.on.doc",
                   L10n.t("row.copyonly")) {
            manager.copyToPasteboard(item)
            copyGeneration &+= 1
            let generation = copyGeneration
            shownCopyGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // A newer click owns the icon now: let ITS revert clear the tick, not this stale one,
                // or the second click's feedback would be cut short by the first click's timer.
                guard copyGeneration == generation else { return }
                shownCopyGeneration = 0
            }
        }
        // Under Reduce Motion the value never changes, so the bounce never fires (the tick still swaps).
        .symbolEffect(.bounce, value: reduceMotion ? 0 : copyGeneration)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                // Smooth symbol swap (copy→checkmark flash, eye/star toggles) instead of a hard pop.
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.12), value: symbol)
        }
        .buttonStyle(PressableButtonStyle()).help(help)   // press-down feedback (Apple: respond on press)
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

    /// Just the time ("20:46" / "8:46 PM") — the day now lives in the list's section header.
    static func timeShort(_ date: Date) -> String {
        let en = Settings.shared.uiLanguage == "en"
        return df(en ? "h:mm a" : "HH:mm", en).string(from: date)
    }

    /// Day-level section title for the grouped list: "Hoy" / "Ayer" / weekday / date (no time).
    static func daySection(_ date: Date) -> String {
        let cal = Calendar.current
        let en = Settings.shared.uiLanguage == "en"
        if cal.isDateInToday(date)     { return L10n.t("date.today") }
        if cal.isDateInYesterday(date) { return L10n.t("date.yesterday") }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let fmt = en ? (sameYear ? "EEEE, MMM d" : "MMM d, yyyy")
                     : (sameYear ? "EEEE d 'de' MMMM" : "d 'de' MMMM yyyy")
        return df(fmt, en).string(from: date)
    }

    /// Two dates fall in the same calendar day (drives section breaks).
    static func sameDay(_ a: Date, _ b: Date) -> Bool { Calendar.current.isDate(a, inSameDayAs: b) }

    /// Age in words, for VoiceOver only. The visible row shows a bare clock time, which read aloud out
    /// of its day section is just a number with no anchor.
    static func relativeTime(_ date: Date) -> String {
        rdf().localizedString(for: date, relativeTo: Date())
    }

    /// Cached per UI language, same reason as `dfCache`: this runs once per visible row per render.
    private static var rdfCache: [String: RelativeDateTimeFormatter] = [:]
    private static func rdf() -> RelativeDateTimeFormatter {
        let lang = L10n.lang
        if let f = rdfCache[lang] { return f }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: lang)
        f.unitsStyle = .full
        rdfCache[lang] = f
        return f
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

/// Attaches `.onDrag` only to rows that have something to vend. A modifier (not an inline `if`) because
/// SwiftUI's `.onDrag` has no "nothing to drag" return: handing it an empty provider would still lift the
/// row and start a drag no destination can accept — and for a credential there must be no drag at all.
private struct RowDrag: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider
    let onStart: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrag { onStart(); return provider() }
        } else {
            content
        }
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
            .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let d = duration {
            Text(mmss(d)).font(.system(size: 11)).foregroundStyle(.secondary)
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
