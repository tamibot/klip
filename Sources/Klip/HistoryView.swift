import SwiftUI
import AppKit

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, text, image, voice, credential, pinned
    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .all: "filter.all"; case .text: "filter.text"; case .image: "filter.image"
        case .voice: "filter.voice"; case .credential: "filter.cred"; case .pinned: "filter.pinned"
        }
    }
    var icon: String {
        switch self {
        case .all: "square.grid.2x2"; case .text: "doc.text"; case .image: "photo"
        case .voice: "waveform"; case .credential: "key.fill"; case .pinned: "pin.fill"
        }
    }
}

/// Interfaz del panel: encabezado, filtros por tipo, lista y guía.
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

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var filter: HistoryFilter = .all
    @State private var ocrResultID: UUID?
    @State private var ocrText = ""
    @State private var ocrRunning = false

    static let appLogo: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()

    private var sortedItems: [ClipboardItem] {
        manager.items.sorted { ($0.pinned ? 1 : 0, $0.createdAt) > ($1.pinned ? 1 : 0, $1.createdAt) }
    }

    private func matches(_ item: ClipboardItem, _ f: HistoryFilter) -> Bool {
        switch f {
        case .all: return true
        case .text: return item.kind == .text && item.isVoiceNote != true && item.isCredential != true
        case .image: return item.kind == .image
        case .voice: return item.isVoiceNote == true
        case .credential: return item.isCredential == true
        case .pinned: return item.pinned
        }
    }

    private var filtered: [ClipboardItem] {
        var base = sortedItems.filter { matches($0, filter) }
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        base = base.filter { ($0.text ?? "").lowercased().contains(q) || $0.preview.lowercased().contains(q) }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterRow
            Divider()
            if filtered.isEmpty { emptyState } else { list }
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 460)
        .background(Color.clear)
        .onAppear { syncVisible(); searchFocused = true }
        .onChange(of: search) { _, _ in syncVisible() }
        .onChange(of: filter) { _, _ in syncVisible() }
        .onChange(of: manager.items) { _, _ in syncVisible() }
        .onChange(of: selection.openToken) { _, _ in
            search = ""; filter = .all
            selection.updateVisible(sortedItems.map(\.id))
            selection.selectedIndex = sortedItems.isEmpty ? -1 : 0
            searchFocused = true
        }
    }

    private func syncVisible() { selection.updateVisible(filtered.map(\.id)) }

    // MARK: - Encabezado

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let logo = Self.appLogo {
                    Image(nsImage: logo).resizable().frame(width: 22, height: 22)
                }
                Text("Klip").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { onOpenPreferences() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(L10n.t("act.prefs"))
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
            HStack(spacing: 8) {
                micChip
                actionChip("waveform.badge.plus", L10n.t("act.upload")) { onUploadAudio() }
                actionChip("doc.richtext", L10n.t("act.copyallmd")) { onCopyAllMarkdown() }
                Spacer()
            }
        }
        .padding(12)
    }

    @ViewBuilder private var micChip: some View {
        switch recorder.state {
        case .recording:
            actionChip("stop.fill", "Detener", tint: .red) { onVoiceRecord() }
        case .transcribing:
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text(L10n.t("rec.transcribing")).font(.system(size: 11)) }
                .padding(.horizontal, 9).padding(.vertical, 5)
        default:
            actionChip("mic", L10n.t("rec.record")) { onVoiceRecord() }
        }
    }

    private func actionChip(_ icon: String, _ label: String, tint: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: icon); Text(label).font(.system(size: 11)) }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.16)))
                .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.plain)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HistoryFilter.allCases) { f in
                    let sel = filter == f
                    Button { filter = f } label: {
                        HStack(spacing: 4) {
                            Image(systemName: f.icon).font(.system(size: 10))
                            Text(L10n.t(f.labelKey)).font(.system(size: 11))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(sel ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                        .overlay(Capsule().stroke(sel ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
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
                                onCopyMarkdown: onCopyMarkdown, onOCR: { runOCR(item) })
                            .id(item.id)
                        if ocrResultID == item.id { ocrBox }
                    }
                }
                .padding(8)
            }
            .onChange(of: selection.selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(newID, anchor: .center) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { onShowGuide() } label: {
                HStack(spacing: 4) { Image(systemName: "questionmark.circle"); Text(L10n.t("act.guide")).font(.system(size: 11)) }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .credential ? "key" : "doc.on.clipboard")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text(!search.isEmpty || filter != .all
                 ? (filter == .credential ? L10n.t("empty.cred") : L10n.t("empty.noresults"))
                 : L10n.t("empty.title"))
                .foregroundStyle(.secondary)
            if search.isEmpty && filter == .all {
                Text(L10n.t("empty.sub")).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private var ocrBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ocrRunning ? L10n.t("rec.transcribing") : "OCR:")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !ocrRunning {
                Text(ocrText.isEmpty ? "—" : ocrText)
                    .font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    private func runOCR(_ item: ClipboardItem) {
        ocrResultID = item.id; ocrText = ""; ocrRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = manager.extractText(from: item) ?? ""
            DispatchQueue.main.async {
                ocrRunning = false; ocrText = text
                if !text.isEmpty { manager.setClipboardText(text) }
            }
        }
    }
}

/// Una fila del historial. Las imágenes se muestran en grande (imagen arriba, datos abajo).
struct ItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let resetToken: Int
    @ObservedObject var manager: ClipboardManager
    var onPick: (ClipboardItem) -> Void
    var onSaveImage: (ClipboardItem) -> Void
    var onCopyMarkdown: (ClipboardItem) -> Void
    var onOCR: () -> Void

    @State private var hovering = false
    @State private var revealed = false

    private var isCredential: Bool { item.isCredential == true }

    private var displayedPreview: String {
        if isCredential, !revealed, let t = item.text { return CredentialDetector.masked(t) }
        return item.preview.isEmpty ? "(vacío)" : item.preview
    }

    var body: some View {
        Group {
            if item.kind == .image { imageCard } else { standardRow }
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.20)
                  : (hovering ? Color.primary.opacity(0.07) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor.opacity(0.6)
                    : (isCredential ? Color.yellow.opacity(0.4) : Color.clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onPick(item) }
        .onChange(of: resetToken) { _, _ in revealed = false }   // re-enmascarar al reabrir el panel
    }

    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fn = item.imageFileName, let img = Storage.shared.loadImage(fileName: fn) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).frame(height: 150)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                    Text("\(Int(img.size.width))×\(Int(img.size.height))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            HStack(spacing: 6) {
                metadata
                Spacer(minLength: 4)
                if hovering { actions } else if item.pinned { pinDot }
            }
        }
        .padding(8)
    }

    private var standardRow: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(displayedPreview)
                    .lineLimit(2).font(.system(size: 13, design: isCredential ? .monospaced : .default))
                metadata
            }
            Spacer(minLength: 4)
            if hovering { actions }
            else if isCredential { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.system(size: 10)) }
            else if item.pinned { pinDot }
        }
        .padding(8)
    }

    private var pinDot: some View { Image(systemName: "pin.fill").foregroundStyle(.orange).font(.system(size: 10)) }

    @ViewBuilder private var thumbnail: some View {
        if isCredential {
            Image(systemName: "key.fill").font(.system(size: 18))
                .frame(width: 46, height: 46).foregroundStyle(.yellow)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.14)))
        } else if item.isVoiceNote == true {
            Image(systemName: "waveform").font(.system(size: 20))
                .frame(width: 46, height: 46).foregroundStyle(.purple)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.12)))
        } else {
            Image(systemName: "doc.text").font(.system(size: 18))
                .frame(width: 46, height: 46).foregroundStyle(.secondary)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var metadata: some View {
        Text(Self.timeLabel(item.createdAt)).font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            iconButton("doc.on.doc", L10n.t("row.copy")) { onPick(item) }
            if item.kind == .image {
                iconButton("square.and.arrow.down", L10n.t("row.save")) { onSaveImage(item) }
                iconButton("text.viewfinder", L10n.t("row.ocr")) { onOCR() }
            } else {
                iconButton("doc.richtext", L10n.t("row.markdown")) { onCopyMarkdown(item) }
                if isCredential {
                    iconButton(revealed ? "eye.slash" : "eye", L10n.t("row.reveal")) { revealed.toggle() }
                }
                iconButton(isCredential ? "key.slash" : "key",
                           L10n.t(isCredential ? "row.unmarkcred" : "row.markcred")) { manager.toggleCredential(item) }
            }
            iconButton(item.pinned ? "pin.slash" : "pin", L10n.t(item.pinned ? "row.unpin" : "row.pin")) {
                manager.togglePin(item)
            }
            iconButton("trash", L10n.t("row.delete")) { manager.delete(item) }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)) }
            .buttonStyle(.borderless).help(help)
    }

    static func timeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: Settings.shared.uiLanguage == "en" ? "en" : "es")
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(date) { f.dateFormat = "'·' HH:mm" }
        else { f.dateFormat = "d MMM HH:mm" }
        return f.string(from: date)
    }
}
