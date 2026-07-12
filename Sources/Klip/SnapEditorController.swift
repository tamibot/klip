import AppKit

/// Borderless toolbar tool button with a subtle rounded hover wash. The controller marks the
/// active tool via `isSelectedTool` (accent fill + white glyph); hover only shows when not selected.
private final class HoverToolButton: NSButton {
    var isSelectedTool = false { didSet { refreshBackground() } }
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshBackground() }

    private func refreshBackground() {
        // Subtle, Shottr-style states: the active tool gets a soft accent tint (the icon carries
        // the accent), never a heavy solid fill.
        let color: NSColor = isSelectedTool ? .controlAccentColor.withAlphaComponent(0.16)
            : hovering ? .labelColor.withAlphaComponent(0.07) : .clear
        layer?.backgroundColor = color.cgColor
    }
}

/// Snapshot editor window: tool toolbar + canvas. On copy/save it returns the annotated image;
/// on close without saving it returns nil.
final class SnapEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let canvas: AnnotationCanvasView
    private let onFinish: (NSImage?) -> Void
    private var toolButtons: [SnapTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var colorIndex = 0
    private var lastToolWasMarker = false
    /// Buttons whose ⌘-key equivalents must be released while the user types into the in-place text field
    /// (otherwise ⌘C/⌘Z/⌘S/Esc hit the toolbar instead of the field editor).
    private var keyEquivControls: [(button: NSButton, key: String, mods: NSEvent.ModifierFlags)] = []
    /// Palette for normal drawing and a palette of highlighter tones (used with the marker).
    private let normalColors: [NSColor] = [.systemRed, .systemBlue, .black, .white]
    private let markerColors: [NSColor] = [.systemYellow, .systemGreen, .systemPink, .systemOrange]
    private var palette: [NSColor] { canvas.currentTool == .marker ? markerColors : normalColors }
    private var finished = false
    private weak var scrollView: NSScrollView?
    private weak var zoomButton: NSButton?
    // Contextual controls (Shottr-style: only the options that apply to the active tool/selection
    // are visible). Each group hides together with the separator that precedes it.
    private weak var strokeControl: NSSegmentedControl?
    private weak var strokeSeparator: NSView?
    private weak var blurSlider: NSSlider?
    private weak var blurSeparator: NSView?
    private var textSizeButtons: [NSButton] = []
    private weak var textSizeSeparator: NSView?
    /// REAL pixel size of the capture for the toolbar readout (canvas points × backing scale would lie
    /// on retina — reuses the same pixelDimensions logic as the history dimension badge).
    private let imagePixelSize: NSSize

    init(image: NSImage, onFinish: @escaping (NSImage?) -> Void) {
        self.canvas = AnnotationCanvasView(image: image)
        self.onFinish = onFinish
        self.imagePixelSize = image.pixelDimensions
        super.init()
    }

    func present() {
        let imgSize = canvas.bounds.size
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minBarWidth: CGFloat = 1220  // minimum width so the toolbar doesn't overlap itself (11 tools + info cluster)
        let maxW = screen.width * 0.9, maxH = screen.height * 0.85 - 46
        let scale = min(1, min(maxW / imgSize.width, maxH / imgSize.height))
        let contentW = max(minBarWidth, imgSize.width * scale)
        let contentH = imgSize.height * scale + 46   // 46 = toolbar

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L10n.t("win.editor")
        win.minSize = NSSize(width: minBarWidth, height: 240)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))

        // Canvas inside a scroll view (in case the capture is large).
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH - 46))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        // Classic transparency checkerboard so the image "floats" on the surround, Shottr-style.
        scroll.backgroundColor = NSColor(patternImage: Self.checkerPattern)
        // Large captures: allow zooming and open fitted so the WHOLE image is visible (1x if it fits).
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 4
        if scale < 1 { scroll.magnify(toFit: canvas.frame) }
        self.scrollView = scroll
        // Live zoom readout: pinch magnification ends → refresh the toolbar's percentage label.
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification,
                                               object: scroll)
        content.addSubview(scroll)

        let toolbar = buildToolbar(width: contentW)
        toolbar.frame = NSRect(x: 0, y: contentH - 46, width: contentW, height: 46)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        win.contentView = content
        win.alphaValue = 0
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(canvas)
        // Quick fade-in, same curve as the main HUD panel.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
        }
        canvas.currentLineWidth = 3   // default stroke: visible but not heavy
        selectTool(.arrow)
        // When the selection changes, reflect its color in the palette and swap the contextual
        // controls (blur slider / text size) to match what is selected.
        canvas.onSelectionChange = { [weak self] in
            self?.syncColorSelectionFromCanvas()
            self?.refreshContextualControls()
        }
        // While typing into the in-place text field, release the toolbar's ⌘C/⌘Z/⌘S/Esc so they edit the
        // text (copy/undo/cancel) instead of firing the toolbar actions.
        canvas.onTextEditingChanged = { [weak self] editing in self?.setKeyEquivalents(enabled: !editing) }
        self.window = win
    }

    /// Enables/disables the toolbar buttons' key equivalents (used to free them while editing text).
    private func setKeyEquivalents(enabled: Bool) {
        for c in keyEquivControls {
            c.button.keyEquivalent = enabled ? c.key : ""
            c.button.keyEquivalentModifierMask = enabled ? c.mods : []
        }
    }

    // MARK: - Toolbar

    private func buildToolbar(width: CGFloat) -> NSView {
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 46))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        let size: CGFloat = 30

        // Left group: tools + color + thickness + undo.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 4
        leading.alignment = .centerY
        leading.translatesAutoresizingMaskIntoConstraints = false

        for tool in SnapTool.allCases {
            let b = makeToolButton(tool)
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true   // 32pt: 11 tools now, 36 overflowed
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            // Shottr-style single-letter shortcut: a bare letter selects the tool. Registered in
            // keyEquivControls so the letters return to the field while typing in-place text.
            let key = Self.toolKey(tool)
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = []
            b.toolTip = "\(tool.tooltip) (\(key.uppercased()))"
            keyEquivControls.append((b, key, []))
            toolButtons[tool] = b
            leading.addArrangedSubview(b)
            // Shottr-style grouping: [select] | [draw tools + text] | [blur spotlight counter].
            if tool == .select || tool == .text { addSeparator(to: leading) }
        }

        addSeparator(to: leading)

        // Colors: 4 presets (they switch to highlighter tones with the marker) + "more" for the rest.
        for i in 0..<4 {
            let b = makeColorButton(tag: i)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorButtons.append(b)
            leading.addArrangedSubview(b)
        }
        let more = makeActionButton(symbol: "ellipsis.circle", tip: L10n.t("editor.morecolors"), action: #selector(moreColorTapped))
        more.translatesAutoresizingMaskIntoConstraints = false
        more.widthAnchor.constraint(equalToConstant: 30).isActive = true
        leading.addArrangedSubview(more)

        strokeSeparator = addSeparator(to: leading)

        // Thickness: only two levels (thin / thick). Contextual — visible for drawing tools only.
        let widths = NSSegmentedControl(images: [lineImage(3), lineImage(6)],
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(widthChanged(_:)))
        widths.setWidth(40, forSegment: 0); widths.setWidth(40, forSegment: 1)
        widths.selectedSegment = 0
        widths.toolTip = L10n.t("editor.strokewidth")
        strokeControl = widths
        leading.addArrangedSubview(widths)

        blurSeparator = addSeparator(to: leading)

        // Blur intensity (block coarseness). Contextual — visible while the blur tool is active
        // or a blur annotation is selected; updates the selection live (one undo per slide).
        let blur = NSSlider(value: 12, minValue: 6, maxValue: 28,
                            target: self, action: #selector(blurLevelChanged(_:)))
        blur.isContinuous = true
        blur.controlSize = .small
        blur.toolTip = L10n.t("editor.blurIntensity")
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.widthAnchor.constraint(equalToConstant: 96).isActive = true
        blurSlider = blur
        leading.addArrangedSubview(blur)

        textSizeSeparator = addSeparator(to: leading)

        // Text size (affects the selected text or the next one you type). Contextual — text only.
        let smaller = makeActionButton(symbol: "textformat.size.smaller", tip: L10n.t("editor.textsmaller"), action: #selector(textSmaller))
        let larger = makeActionButton(symbol: "textformat.size.larger", tip: L10n.t("editor.textlarger"), action: #selector(textLarger))
        for b in [smaller, larger] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: size).isActive = true
            leading.addArrangedSubview(b)
        }
        textSizeButtons = [smaller, larger]

        addSeparator(to: leading)

        let undo = makeActionButton(symbol: "arrow.uturn.backward", tip: L10n.t("editor.undo"), action: #selector(undoTapped))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = [.command]
        undo.translatesAutoresizingMaskIntoConstraints = false
        undo.widthAnchor.constraint(equalToConstant: size).isActive = true
        leading.addArrangedSubview(undo)
        keyEquivControls.append((undo, "z", [.command]))

        let redo = makeActionButton(symbol: "arrow.uturn.forward", tip: L10n.t("editor.redo"), action: #selector(redoTapped))
        redo.keyEquivalent = "Z"; redo.keyEquivalentModifierMask = [.command, .shift]
        redo.translatesAutoresizingMaskIntoConstraints = false
        redo.widthAnchor.constraint(equalToConstant: size).isActive = true
        leading.addArrangedSubview(redo)
        keyEquivControls.append((redo, "Z", [.command, .shift]))

        // Right group: info cluster (pixel size + zoom) + copy + save + close.
        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.alignment = .centerY
        trailing.translatesAutoresizingMaskIntoConstraints = false

        // Shottr-style readout: the capture's REAL pixel size and the live zoom (click resets to 100%).
        let sizeLabel = NSTextField(labelWithString:
            "\(Int(imagePixelSize.width)) × \(Int(imagePixelSize.height)) px")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.toolTip = L10n.t("editor.imagesize")
        trailing.addArrangedSubview(sizeLabel)

        let zoom = NSButton(title: "100%", target: self, action: #selector(zoomResetTapped))
        zoom.isBordered = false
        zoom.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoom.contentTintColor = .secondaryLabelColor
        zoom.toolTip = L10n.t("editor.zoom.reset")
        zoomButton = zoom
        updateZoomLabel()   // reflect the initial magnify(toFit:) done in present()
        trailing.addArrangedSubview(zoom)

        addSeparator(to: trailing)

        let copy = makeTextButton(title: L10n.t("editor.copy"), tip: L10n.t("editor.copy.tip"), action: #selector(copyTapped))
        copy.keyEquivalent = "c"; copy.keyEquivalentModifierMask = [.command]
        let save = makeTextButton(title: L10n.t("editor.save"), tip: L10n.t("editor.save.tip"), action: #selector(saveTapped))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        let close = makeActionButton(symbol: "xmark", tip: L10n.t("editor.close"), action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"   // Esc
        close.translatesAutoresizingMaskIntoConstraints = false
        close.widthAnchor.constraint(equalToConstant: size).isActive = true
        keyEquivControls.append((copy, "c", [.command]))
        keyEquivControls.append((save, "s", [.command]))
        keyEquivControls.append((close, "\u{1b}", []))
        trailing.addArrangedSubview(copy)
        trailing.addArrangedSubview(save)
        trailing.addArrangedSubview(close)

        bar.addSubview(leading)
        bar.addSubview(trailing)
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -16)
        ])
        return bar
    }

    private func makeActionButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let b = HoverToolButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    private func makeTextButton(title: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        b.keyEquivalent = ""
        return b
    }

    // MARK: - Toolbar actions

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = SnapTool.allCases[sender.tag]
        selectTool(tool)
    }

    private func selectTool(_ tool: SnapTool) {
        canvas.currentTool = tool
        for (t, b) in toolButtons {
            let on = (t == tool)
            (b as? HoverToolButton)?.isSelectedTool = on   // soft accent tint lives in the button
            b.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        }
        refreshColorSwatches()                                // the marker shows highlighter tones
        // Only re-apply the DEFAULT color when the PALETTE changes type (normal↔marker). Between normal
        // tools the chosen color is preserved. Use setDefaultColor so a tool switch never recolors a
        // committed selected text annotation.
        let isMarker = (tool == .marker)
        if isMarker != lastToolWasMarker {
            if colorIndex < 0 { colorIndex = 0 }              // snap a custom color to a swatch on palette change
            refreshColorSwatches()
            canvas.setDefaultColor(palette[min(colorIndex, palette.count - 1)])
        }
        lastToolWasMarker = isMarker
        refreshContextualControls()
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        canvas.currentLineWidth = sender.selectedSegment == 1 ? 6 : 3   // thick / thin
    }

    @objc private func blurLevelChanged(_ sender: NSSlider) {
        // A slide starts with a mouse-down (or a single arrow-key press): re-arm the coalescing
        // there so the whole continuous drag collapses into ONE undo step (color-panel pattern).
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDown || type == .keyDown { canvas.armBlurCoalescing() }
        canvas.setBlurLevelCoalesced(CGFloat(sender.doubleValue))
    }

    /// Shows only the options that apply to the active tool / selection (Shottr-style contextual
    /// bar): stroke width for drawing tools, intensity for blur, size buttons for text.
    private func refreshContextualControls() {
        let tool = canvas.currentTool
        let selected = canvas.selectedAnnotationTool
        let showStroke: Bool
        switch tool {
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker: showStroke = true
        default: showStroke = false
        }
        let showBlur = tool == .blur || selected == .blur
        let showText = tool == .text || selected == .text
        strokeControl?.isHidden = !showStroke
        strokeSeparator?.isHidden = !showStroke
        blurSlider?.isHidden = !showBlur
        blurSeparator?.isHidden = !showBlur
        textSizeButtons.forEach { $0.isHidden = !showText }
        textSizeSeparator?.isHidden = !showText
        if showBlur { blurSlider?.doubleValue = Double(canvas.effectiveBlurLevel) }
    }

    // MARK: - Color

    @objc private func colorTapped(_ sender: NSButton) {
        colorIndex = sender.tag
        canvas.setColor(palette[min(colorIndex, palette.count - 1)])
        refreshColorSwatches()
    }

    @objc private func moreColorTapped() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.color = canvas.effectiveColor
        panel.isContinuous = true
        canvas.armColorCoalescing()   // the continuous drag that follows is ONE undo step, not dozens
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        colorIndex = -1                                        // custom color: no preset marked
        canvas.setColorCoalesced(sender.color)
        refreshColorSwatches()
    }

    /// If the selected text uses a palette color, mark that swatch (otherwise none).
    private func syncColorSelectionFromCanvas() {
        colorIndex = palette.firstIndex(where: { Self.approxEqual($0, canvas.effectiveColor) }) ?? -1
        refreshColorSwatches()
    }

    private func refreshColorSwatches() {
        let colors = palette
        for (i, b) in colorButtons.enumerated() {
            b.image = Self.swatchImage(i < colors.count ? colors[i] : .clear)
            b.layer?.cornerRadius = 12
            let on = (i == colorIndex)
            b.layer?.borderWidth = on ? 1.5 : 0
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    // MARK: - Control builders

    private func makeToolButton(_ tool: SnapTool) -> NSButton {
        let b = HoverToolButton(title: "", target: self, action: #selector(toolTapped(_:)))
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        b.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.tooltip)?
            .withSymbolConfiguration(cfg)
        b.toolTip = tool.tooltip
        b.tag = SnapTool.allCases.firstIndex(of: tool) ?? 0
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func makeColorButton(tag: Int) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
        b.isBordered = false
        b.wantsLayer = true
        b.tag = tag
        b.toolTip = L10n.t("editor.color")
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// Adds a hairline separator with even 8pt breathing room on both sides
    /// (the stack's default 4pt reads cramped next to a 1px line).
    /// Returns the separator so contextual groups can hide it along with their controls.
    @discardableResult
    private func addSeparator(to stack: NSStackView) -> NSView {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(8, after: last) }
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(box)
        stack.setCustomSpacing(8, after: box)
        return box
    }

    private static func swatchImage(_ color: NSColor) -> NSImage {
        let d: CGFloat = 20
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: d - 4, height: d - 4)).fill()
        NSColor.separatorColor.setStroke()                     // border so white is visible
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: d - 4, height: d - 4))
        ring.lineWidth = 1; ring.stroke()
        img.unlockFocus()
        return img
    }

    private func lineImage(_ thickness: CGFloat) -> NSImage {
        let w: CGFloat = 24, h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor.labelColor.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 4, y: h / 2)); p.line(to: NSPoint(x: w - 4, y: h / 2))
        p.lineWidth = thickness; p.lineCapStyle = .round; p.stroke()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private static func approxEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.02
            && abs(x.greenComponent - y.greenComponent) < 0.02
            && abs(x.blueComponent - y.blueComponent) < 0.02
    }

    @objc private func textSmaller() { canvas.bumpFontSize(-4) }
    @objc private func textLarger() { canvas.bumpFontSize(+4) }

    @objc private func undoTapped() { canvas.undo() }
    @objc private func redoTapped() { canvas.redo() }

    /// Bare-letter tool shortcuts (Shottr parity): V select, A arrow, P pencil, L line, R rectangle,
    /// O ellipse, H highlighter, T text, B blur, S spotlight, C counter. Bare letters never clash with
    /// the ⌘-modified equivalents (⌘S save, ⌘C copy) — the modifier mask disambiguates.
    private static func toolKey(_ tool: SnapTool) -> String {
        switch tool {
        case .select:    return "v"
        case .pencil:    return "p"
        case .line:      return "l"
        case .arrow:     return "a"
        case .rectangle: return "r"
        case .ellipse:   return "o"
        case .marker:    return "h"
        case .text:      return "t"
        case .blur:      return "b"
        case .spotlight: return "s"
        case .counter:   return "c"
        }
    }

    // MARK: - Zoom readout

    @objc private func zoomResetTapped() {
        scrollView?.magnification = 1
        updateZoomLabel()
    }

    @objc private func liveMagnifyEnded(_ note: Notification) { updateZoomLabel() }

    private func updateZoomLabel() {
        guard let scroll = scrollView else { return }
        zoomButton?.title = "\(Int(round(scroll.magnification * 100)))%"
    }

    /// Classic transparency checkerboard tile for the canvas surround.
    /// ponytail: fixed mid-grays readable in both themes — NSColor(patternImage:) can't adapt live.
    private static let checkerPattern: NSImage = {
        let square: CGFloat = 8
        let img = NSImage(size: NSSize(width: square * 2, height: square * 2))
        img.lockFocus()
        NSColor(white: 0.53, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: square * 2, height: square * 2).fill()
        NSColor(white: 0.60, alpha: 1).setFill()
        NSRect(x: 0, y: square, width: square, height: square).fill()
        NSRect(x: square, y: 0, width: square, height: square).fill()
        img.unlockFocus()
        return img
    }()

    @objc private func copyTapped() {
        let image = canvas.flattened()
        finish(with: image)
    }

    @objc private func saveTapped() {
        guard let window else { return }
        let image = canvas.flattened()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = L10n.t("editor.savefilename")
        // Sheet anchored to the editor window (not floating) so it isn't orphaned if it closes.
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let url = panel.url else { return }   // cancel: the editor stays open
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                self.showError(L10n.t("editor.err.png")); return
            }
            do {
                try png.write(to: url)
                self.finish(with: image)
            } catch {
                // Write failure (disk full, read-only path…): warn and do NOT close the editor,
                // so we don't lose the annotation thinking it was saved.
                self.showError(String(format: L10n.t("editor.err.save"), error.localizedDescription))
            }
        }
    }

    private func showError(_ msg: String) {
        let a = NSAlert(); a.messageText = L10n.t("editor.err.title"); a.informativeText = msg
        a.addButton(withTitle: L10n.t("common.ok")); a.runModal()
    }

    @objc private func closeTapped() {
        guard confirmDiscardIfNeeded() else { return }
        finish(with: nil)
    }

    /// Annotations take real work: closing with any on the canvas asks first (an empty canvas closes
    /// instantly). Esc reaches here via the close button's key equivalent; the title-bar close goes
    /// through windowShouldClose.
    private func confirmDiscardIfNeeded() -> Bool {
        guard !canvas.annotations.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = L10n.t("editor.discard.title")
        a.informativeText = L10n.t("editor.discard.info")
        let discard = a.addButton(withTitle: L10n.t("editor.discard.confirm"))
        discard.hasDestructiveAction = true
        a.addButton(withTitle: L10n.t("common.cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardIfNeeded() }

    /// When closing the editor, also close the shared NSColorPanel (if it was opened via "more colors"):
    /// otherwise it would keep floating over a menu-bar app with no windows, pointing to an
    /// already-destroyed editor.
    private func dismissColorUI() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
    }

    private func finish(with image: NSImage?) {
        guard !finished else { return }
        finished = true
        dismissColorUI()
        window?.orderOut(nil)
        window = nil
        onFinish(image)
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        dismissColorUI()
        onFinish(nil)
    }
}
