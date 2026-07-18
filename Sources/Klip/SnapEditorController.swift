import AppKit

/// Borderless toolbar tool button with a subtle rounded hover wash. The controller marks the
/// active tool via `isSelectedTool` (accent fill + white glyph); hover only shows when not selected.
private final class HoverToolButton: NSButton {
    var isSelectedTool = false { didSet { refreshBackground() } }
    private var hovering = false

    /// Our own hover area, tracked so we can replace ONLY it on relayout.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only OUR area. `trackingAreas.forEach(removeTrackingArea)` also destroys the
        // tracking area AppKit installs for `toolTip`, which silently kills every tooltip on the
        // toolbar — the hover effect was eating the help text.
        if let a = hoverArea { removeTrackingArea(a); hoverArea = nil }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshBackground() }

    private func refreshBackground() {
        // Klip selection language: the active tool is a SOLID accent chip (the controller sets the
        // glyph white to match), never a faint tint — same as the filter chips. Hover shows a faint
        // primary wash only on the inactive tools.
        let color: NSColor = isSelectedTool ? .controlAccentColor
            : hovering ? .labelColor.withAlphaComponent(0.06) : .clear
        // View-backed layers disable implicit animations, so ease the wash in/out explicitly.
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(anim, forKey: "backgroundColor")
        layer?.backgroundColor = color.cgColor
    }
}

/// Canvas surround that keeps its checkerboard legible in both themes. A pattern image bakes its
/// pixels, so — unlike a semantic NSColor — it cannot follow a light↔dark switch on its own; it has
/// to be regenerated and reassigned whenever the effective appearance changes.
private final class CheckerScrollView: NSScrollView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCheckerBackground()
    }

    func applyCheckerBackground() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        backgroundColor = NSColor(patternImage: SnapEditorController.checkerPattern(dark: dark))
    }
}

/// Window content view that rejoins Esc to the canvas. Esc is no longer the Close button's key
/// equivalent (it walks the layered ladder in `AnnotationCanvasView.cancelOperation` instead), and the
/// responder chain from a focused toolbar control — the blur slider, say — never passes through the
/// canvas. This is the one ancestor every control in the window does share.
private final class EditorContentView: NSView {
    weak var escapeResponder: AnnotationCanvasView?
    override func cancelOperation(_ sender: Any?) { escapeResponder?.cancelOperation(sender) }
}

/// Snapshot editor window: tool toolbar + canvas. On copy/save it returns the annotated image;
/// on close without saving it returns nil.
final class SnapEditorController: NSObject, NSWindowDelegate {
    /// One chip grid across the whole toolbar: every well is this size, so the hover washes of the
    /// tools, the steppers and the actions all line up on one row instead of stepping 30/32.
    private static let chipSize: CGFloat = 32
    /// Toolbar height. The canvas is inset by exactly this much, so present() and buildToolbar must
    /// agree — naming it keeps the window arithmetic and the bar from drifting apart.
    private static let barHeight: CGFloat = 46

    private var window: NSWindow?
    private let canvas: AnnotationCanvasView
    private let onFinish: (NSImage?) -> Void
    private var toolButtons: [SnapTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var colorIndex = 0
    private var lastToolWasMarker = false
    /// Buttons whose key equivalents must be released while the user types into the in-place text field
    /// (otherwise the tool letters and ⌘C/⌘Z/⌘S/⌘±/⌘0 hit the toolbar instead of the field editor).
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
    /// Trailing readout (the capture's pixel size). Pure information, no action — so it's the first
    /// thing dropped when the window is narrow, and it never counts toward the window's minimum width.
    /// The zoom cluster next to it stays: those three carry ⌘−/⌘0/⌘+, and a hidden button is a dead
    /// key equivalent.
    private var infoViews: [NSView] = []
    /// Toolbar width (measured, not guessed) below which `infoViews` hide.
    private var infoHideWidth: CGFloat = 0
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
        // Build the toolbar ONCE (it populates the button/shortcut/swatch state) and ask it what it
        // ACTUALLY needs, instead of the old hard-coded 1220 — a conservative guess that made a small
        // capture open in a huge window padded with dead checkerboard. +24 for breathing room.
        let toolbar = buildToolbar(width: 2000)
        // Two measurements: with the readout (the width at which it can stay) and without it (the
        // REAL floor — every remaining control is an action, so nothing else may be dropped).
        infoHideWidth = toolbar.fittingSize.width + 24
        setInfoHidden(true)
        toolbar.layoutSubtreeIfNeeded()   // settle the stack's collapse before re-measuring
        let minBarWidth = min(toolbar.fittingSize.width + 24, screen.width)
        let maxW = screen.width * 0.9, maxH = screen.height * 0.85 - Self.barHeight
        let scale = min(1, min(maxW / imgSize.width, maxH / imgSize.height))
        // Clamp to the screen so the trailing Copy/Save/Close cluster never opens off-screen on
        // narrow displays (the toolbar's contextual hiding absorbs the narrower bar).
        let contentW = min(max(minBarWidth, imgSize.width * scale), screen.width)
        let contentH = imgSize.height * scale + Self.barHeight
        setInfoHidden(contentW < infoHideWidth)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = L10n.t("win.editor")
        win.minSize = NSSize(width: min(minBarWidth, screen.width), height: 240)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let content = EditorContentView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        content.escapeResponder = canvas

        // Canvas inside a scroll view (in case the capture is large).
        let scroll = CheckerScrollView(frame: NSRect(x: 0, y: 0, width: contentW,
                                                     height: contentH - Self.barHeight))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        // Classic transparency checkerboard so the image "floats" on the surround, Shottr-style.
        scroll.applyCheckerBackground()
        // Large captures: allow zooming and open fitted so the WHOLE image is visible (1x if it fits).
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 4
        if scale < 1 { scroll.magnify(toFit: canvas.frame) }
        self.scrollView = scroll
        // The toolbar is built before this point (it has to be measured to size the window), so the
        // updateZoomLabel() inside buildToolbar ran while scrollView was still nil and bailed out.
        updateZoomLabel()
        // Live zoom readout. `magnification` only settles at the END of a pinch, so the percentage
        // used to jump in one step; the clip view's bounds, on the other hand, change every frame —
        // tracking those between the two live-magnify notifications is what makes it follow the gesture.
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyStarted),
                                               name: NSScrollView.willStartLiveMagnifyNotification,
                                               object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification,
                                               object: scroll)
        content.addSubview(scroll)

        // (built once above, to measure the window's real minimum width)
        toolbar.frame = NSRect(x: 0, y: contentH - Self.barHeight,
                               width: contentW, height: Self.barHeight)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        win.contentView = content
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        win.alphaValue = reduceMotion ? 1 : 0
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(canvas)
        // Quick fade-in, same curve as the main HUD panel.
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }
        // Restore last-used tool state across editor sessions (defaults: 3pt stroke, arrow, swatch 0).
        let defaults = UserDefaults.standard
        let storedWidth = defaults.double(forKey: "klip.editor.lineWidth")
        canvas.currentLineWidth = storedWidth > 0 ? CGFloat(storedWidth) : 3
        strokeControl?.selectedSegment = canvas.currentLineWidth >= 6 ? 1 : 0
        colorIndex = max(0, defaults.integer(forKey: "klip.editor.colorIndex"))
        selectTool(SnapTool(rawValue: defaults.string(forKey: "klip.editor.tool") ?? "") ?? .arrow)
        canvas.setDefaultColor(palette[min(colorIndex, palette.count - 1)])
        refreshColorSwatches()
        // When the selection changes, reflect its color in the palette and swap the contextual
        // controls (blur slider / text size) to match what is selected.
        canvas.onSelectionChange = { [weak self] in
            self?.syncColorSelectionFromCanvas()
            self?.refreshContextualControls()
        }
        // While typing into the in-place text field, release the toolbar's shortcuts so they edit the
        // text (copy/undo/cancel) instead of firing the toolbar actions.
        canvas.onTextEditingChanged = { [weak self] editing in self?.setKeyEquivalents(enabled: !editing) }
        // Last rung of the canvas's Esc ladder: nothing left there to dismiss → close the editor
        // (through the same discard confirmation the Close button uses).
        canvas.onEscape = { [weak self] in self?.closeTapped() }
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
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: Self.barHeight))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        // The bar sits flush under the titlebar and reads as part of it: forcing .active kept it
        // fully saturated while the titlebar above greyed out on deactivation, splitting the window
        // into two apparent activation states.
        bar.state = .followsWindowActiveState

        // Left group: tools + color + thickness + undo.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 4
        leading.alignment = .centerY
        leading.translatesAutoresizingMaskIntoConstraints = false

        for tool in SnapTool.allCases {
            let b = makeToolButton(tool)
            // chipSize (32pt) is also the ceiling here: at 11 tools, 36 overflowed the bar.
            pinChip(b)
            // Shottr-style single-letter shortcut: a bare letter selects the tool. Registered in
            // keyEquivControls so the letters return to the field while typing in-place text.
            let key = Self.toolKey(tool)
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = []
            // Name + shortcut, then what it actually does — hovering should teach the tool.
            b.toolTip = "\(tool.tooltip) (\(key.uppercased()))\n\(tool.hint)"
            keyEquivControls.append((b, key, []))
            toolButtons[tool] = b
            leading.addArrangedSubview(b)
            // Shottr-style grouping: [select] | [draw tools + text] | [blur spotlight counter].
            if tool == .select || tool == .text { addSeparator(to: leading) }
        }

        addSeparator(to: leading)

        // Colors: 4 presets (they switch to highlighter tones with the marker) + "more" for the rest.
        // Swatches stay 24pt — they are discs, not chips, and the stack's .centerY centers them on
        // the 32pt row.
        for i in 0..<4 {
            let b = makeColorButton(tag: i)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorButtons.append(b)
            leading.addArrangedSubview(b)
        }
        let more = makeActionButton(symbol: "ellipsis.circle", tip: L10n.t("editor.morecolors"), action: #selector(moreColorTapped))
        pinChip(more)
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
            pinChip(b)
            leading.addArrangedSubview(b)
        }
        textSizeButtons = [smaller, larger]

        addSeparator(to: leading)

        let undo = makeActionButton(symbol: "arrow.uturn.backward", tip: L10n.t("editor.undo"), action: #selector(undoTapped))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = [.command]
        pinChip(undo)
        leading.addArrangedSubview(undo)
        keyEquivControls.append((undo, "z", [.command]))

        let redo = makeActionButton(symbol: "arrow.uturn.forward", tip: L10n.t("editor.redo"), action: #selector(redoTapped))
        redo.keyEquivalent = "Z"; redo.keyEquivalentModifierMask = [.command, .shift]
        pinChip(redo)
        leading.addArrangedSubview(redo)
        keyEquivControls.append((redo, "Z", [.command, .shift]))

        // Right group: pixel-size readout + zoom cluster + copy + save + close.
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

        // Zoom out / percentage / zoom in. These carry ⌘− / ⌘0 / ⌘+, so unlike the pixel-size label
        // they are ACTIONS and never join `infoViews` — a hidden NSButton stops answering its key
        // equivalent, and a small capture (which hides the readout) is exactly when zoom matters.
        let zoomOut = makeActionButton(symbol: "minus.magnifyingglass", tip: "⌘−",
                                       action: #selector(zoomOutTapped))
        zoomOut.keyEquivalent = "-"; zoomOut.keyEquivalentModifierMask = [.command]
        pinChip(zoomOut)
        trailing.addArrangedSubview(zoomOut)
        keyEquivControls.append((zoomOut, "-", [.command]))

        let zoom = NSButton(title: "100%", target: self, action: #selector(zoomResetTapped))
        zoom.isBordered = false
        zoom.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoom.contentTintColor = .secondaryLabelColor
        zoom.toolTip = L10n.t("editor.zoom.reset")
        zoom.keyEquivalent = "0"; zoom.keyEquivalentModifierMask = [.command]
        // The percentage now re-renders on every frame of a pinch: pin it to the widest value the
        // 0.2–4 magnification range can produce so the trailing actions can never shuffle sideways
        // while the user zooms (the title stays centered, so nothing inside the button moves either).
        zoom.translatesAutoresizingMaskIntoConstraints = false
        zoom.title = "400%"
        zoom.widthAnchor.constraint(equalToConstant: ceil(zoom.fittingSize.width)).isActive = true
        zoom.title = "100%"
        zoomButton = zoom
        updateZoomLabel()   // no-op on the first build (scrollView is still nil); present() calls it again
        trailing.addArrangedSubview(zoom)
        keyEquivControls.append((zoom, "0", [.command]))

        // ⌘+ is physically ⌘⇧= on the keyboards this ships to, so the mask has to say so — same shape
        // as Redo's ⇧⌘Z above.
        let zoomIn = makeActionButton(symbol: "plus.magnifyingglass", tip: "⌘+",
                                      action: #selector(zoomInTapped))
        zoomIn.keyEquivalent = "+"; zoomIn.keyEquivalentModifierMask = [.command, .shift]
        pinChip(zoomIn)
        trailing.addArrangedSubview(zoomIn)
        keyEquivControls.append((zoomIn, "+", [.command, .shift]))

        addSeparator(to: trailing)
        infoViews = [sizeLabel]

        let copy = makeCompactButton(symbol: "doc.on.doc", title: L10n.t("editor.copy"),
                                     tip: L10n.t("editor.copy.tip"), action: #selector(copyTapped))
        copy.bezelColor = .controlAccentColor   // the window's one prominent primary (accent), Save stays secondary
        copy.keyEquivalent = "c"; copy.keyEquivalentModifierMask = [.command]
        let save = makeCompactButton(symbol: "square.and.arrow.down", title: L10n.t("editor.save"),
                                     tip: L10n.t("editor.save.tip"), action: #selector(saveTapped))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        // No Esc key equivalent here on purpose: a button would swallow Esc before the canvas could
        // run its ladder (color panel → deselect → this). AnnotationCanvasView.cancelOperation calls
        // back into closeTapped for the last rung, so the tooltip's "(Esc)" stays true.
        let close = makeActionButton(symbol: "xmark", tip: L10n.t("editor.close"), action: #selector(closeTapped))
        pinChip(close)
        keyEquivControls.append((copy, "c", [.command]))
        keyEquivControls.append((save, "s", [.command]))
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

    /// Pins a control to the bar's square chip well. Width-only pinning let the hover wash take its
    /// height from the glyph, so the chips rendered at different heights across one row.
    private func pinChip(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.chipSize).isActive = true
        view.heightAnchor.constraint(equalToConstant: Self.chipSize).isActive = true
    }

    private func makeActionButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let b = HoverToolButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.cornerCurve = .continuous
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.preferringHierarchical())
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    /// Bezeled trailing action, icon-only. The two titles ("Copy and close" / "Save") were the widest
    /// thing in the toolbar and set the window's floor; the glyph keeps the prominent accent bezel
    /// while the tooltip keeps the action named and reachable.
    private func makeCompactButton(symbol: String, title: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .rounded
        b.imageScaling = .scaleProportionallyDown
        // accessibilityDescription is what VoiceOver reads for an icon-only button — keep it the title.
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        // `tip` is already "<title> (<shortcut>)" in every locale — prefixing `title` would print the
        // name twice ("Copy & close\nCopy & close (⌘C)"). The tip alone names the action AND its key.
        b.toolTip = tip
        b.keyEquivalent = ""
        return b
    }

    /// Hides/shows the pixel-size readout (see `infoViews`).
    private func setInfoHidden(_ hidden: Bool) {
        for v in infoViews where v.isHidden != hidden { v.isHidden = hidden }
    }

    /// The readout comes back as soon as the window is wide enough to hold it.
    func windowDidResize(_ notification: Notification) {
        guard let w = window?.contentView else { return }
        setInfoHidden(w.frame.width < infoHideWidth)
    }

    // MARK: - Toolbar actions

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = SnapTool.allCases[sender.tag]
        selectTool(tool)
    }

    private func selectTool(_ tool: SnapTool) {
        canvas.currentTool = tool
        // Single choke point for every tool change (buttons, letter shortcuts, restored defaults), so
        // it is also where the canvas's per-tool cursor rects and hover tracking get rebuilt.
        canvas.toolDidChange()
        canvas.window?.invalidateCursorRects(for: canvas)
        for (t, b) in toolButtons {
            let on = (t == tool)
            (b as? HoverToolButton)?.isSelectedTool = on   // solid accent chip lives in the button
            b.contentTintColor = on ? .white : .secondaryLabelColor   // white glyph on the accent fill
            // The highlighter and the pencil are both pen-shaped and sit side by side — at 15pt they
            // read as the same tool. Apple's multicolor variant gives the highlighter its yellow nib,
            // so it's identifiable at a glance (dropped while selected: white on accent wins).
            if t == .marker {
                b.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.tooltip)?
                    .withSymbolConfiguration(on
                        ? .init(pointSize: 15, weight: .regular)
                        : .init(pointSize: 15, weight: .regular).applying(.preferringMulticolor()))
            }
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
        UserDefaults.standard.set(tool.rawValue, forKey: "klip.editor.tool")
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        canvas.currentLineWidth = sender.selectedSegment == 1 ? 6 : 3   // thick / thin
        UserDefaults.standard.set(Double(canvas.currentLineWidth), forKey: "klip.editor.lineWidth")
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
        let apply = {
            self.strokeControl?.isHidden = !showStroke
            self.strokeSeparator?.isHidden = !showStroke
            self.blurSlider?.isHidden = !showBlur
            self.blurSeparator?.isHidden = !showBlur
            self.textSizeButtons.forEach { $0.isHidden = !showText }
            self.textSizeSeparator?.isHidden = !showText
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply()
        } else {
            // NSStackView fades + reflows hidden arranged subviews when animated implicitly.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                apply()
            }
        }
        if showBlur { blurSlider?.doubleValue = Double(canvas.effectiveBlurLevel) }
    }

    // MARK: - Color

    @objc private func colorTapped(_ sender: NSButton) {
        colorIndex = sender.tag
        canvas.setColor(palette[min(colorIndex, palette.count - 1)])
        refreshColorSwatches()
        UserDefaults.standard.set(colorIndex, forKey: "klip.editor.colorIndex")
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
        // Each panel gesture (drag or hex/component field edit) starts with a mouse-down or a
        // key-down: re-arm there so every recolor stays ONE undo step (same as the blur slider).
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDown || type == .keyDown { canvas.armColorCoalescing() }
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
        b.layer?.cornerCurve = .continuous
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        b.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.tooltip)?
            .withSymbolConfiguration(cfg)
        b.toolTip = "\(tool.tooltip)\n\(tool.hint)"
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

    /// One zoom step, matching the ratio a pinch covers in a comfortable gesture.
    private static let zoomStep: CGFloat = 1.25

    @objc private func zoomResetTapped() { applyMagnification(1) }
    @objc private func zoomInTapped() { zoomBy(Self.zoomStep) }
    @objc private func zoomOutTapped() { zoomBy(1 / Self.zoomStep) }

    private func zoomBy(_ factor: CGFloat) {
        guard let scroll = scrollView else { return }
        applyMagnification(min(scroll.maxMagnification,
                               max(scroll.minMagnification, scroll.magnification * factor)))
    }

    /// Zoom travels instead of teleporting — the canvas is the only thing on screen, so a snap makes
    /// the user re-find their place. Reduce Motion gets the plain set.
    private func applyMagnification(_ target: CGFloat) {
        guard let scroll = scrollView else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            scroll.magnification = target
            updateZoomLabel()
            return
        }
        beginLiveZoomTracking()   // so the percentage counts along with the animation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scroll.animator().magnification = target
        }, completionHandler: { [weak self] in self?.endLiveZoomTracking() })
    }

    @objc private func liveMagnifyStarted(_ note: Notification) { beginLiveZoomTracking() }
    @objc private func liveMagnifyEnded(_ note: Notification) { endLiveZoomTracking() }
    @objc private func clipBoundsChanged(_ note: Notification) { updateZoomLabel() }

    /// True while the clip view's per-frame bounds changes are feeding the percentage label.
    private var trackingLiveZoom = false

    private func beginLiveZoomTracking() {
        guard !trackingLiveZoom, let clip = scrollView?.contentView else { return }
        trackingLiveZoom = true
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    private func endLiveZoomTracking() {
        if trackingLiveZoom, let clip = scrollView?.contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                      object: clip)
        }
        trackingLiveZoom = false
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        guard let scroll = scrollView else { return }
        zoomButton?.title = "\(Int(round(scroll.magnification * 100)))%"
    }

    /// Classic transparency checkerboard tile for the canvas surround. The tile bakes fixed greys, so
    /// the theme has to be passed in and the pattern rebuilt on appearance changes (CheckerScrollView
    /// does that): mid-greys that read as "surround" in light mode glow like a lightbox in dark.
    fileprivate static func checkerPattern(dark: Bool) -> NSImage {
        let square: CGFloat = 8
        let base: CGFloat = dark ? 0.22 : 0.53
        let alt: CGFloat = dark ? 0.28 : 0.60
        let img = NSImage(size: NSSize(width: square * 2, height: square * 2))
        img.lockFocus()
        NSColor(white: base, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: square * 2, height: square * 2).fill()
        NSColor(white: alt, alpha: 1).setFill()
        NSRect(x: 0, y: square, width: square, height: square).fill()
        NSRect(x: square, y: 0, width: square, height: square).fill()
        img.unlockFocus()
        return img
    }

    @objc private func copyTapped() {
        let image = canvas.flattened()
        finish(with: image)
    }

    /// Saves straight to ~/Downloads with a timestamped name — no save dialog. The toast's
    /// "Show in Finder" action covers finding the file afterwards.
    @objc private func saveTapped() {
        let image = canvas.flattened()
        guard let png = Storage.shared.pngData(from: image) else {
            showError(L10n.t("editor.err.png")); return
        }
        do {
            let url = try Storage.shared.exportPNGToDownloads(png)
            MainActor.assumeIsolated {   // @objc button action: always on the main thread
                SoundFX.play(.save)
                ToastHUD.show(L10n.t("toast.imageSaved"), detail: url.lastPathComponent,
                              actionTitle: L10n.t("toast.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            finish(with: image)
        } catch {
            // Write failure (disk full, read-only path…): warn and do NOT close the editor,
            // so we don't lose the annotation thinking it was saved.
            showError(String(format: L10n.t("editor.err.save"), error.localizedDescription))
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
    /// instantly). Esc reaches here as the last rung of the canvas's ladder (canvas.onEscape); the
    /// title-bar close goes through windowShouldClose.
    private func confirmDiscardIfNeeded() -> Bool {
        // Typed-but-uncommitted text is work too: guard it like committed annotations.
        guard !canvas.annotations.isEmpty || canvas.hasPendingText else { return true }
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
