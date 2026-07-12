import AppKit

/// Editor canvas: draws the base capture and the annotations on top. Handles live drawing,
/// in-place text (a temporary NSTextField — supports accents), universal select/move/delete of
/// any annotation (.select tool), blur/spotlight/counter rendering, and for text: re-editing
/// and resizing. Flattens everything to a full-resolution image.
final class AnnotationCanvasView: NSView {
    private let baseImage: NSImage
    /// Base capture as CGImage, resolved once: the blur tool pixelates regions of it.
    private lazy var baseCG: CGImage? = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    private(set) var annotations: [Annotation] = []
    private var draft: Annotation?

    // In-place text / selection.
    private var activeTextField: NSTextField?
    private var editingID: UUID?              // text annotation currently being re-edited
    private var editFontSize: CGFloat = 20
    private var editColor: NSColor = .systemRed
    private(set) var selectedID: UUID?        // selected annotation (dashed outline); any type via .select
    private var movingID: UUID?               // annotation currently being dragged
    private var lastDragPoint = CGPoint.zero  // previous drag location (moves translate by delta)
    private var movedDuringDrag = false
    /// Full-state undo snapshots: add / move / edit / recolor / resize / delete are all reversible.
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var preMoveSnapshot: [Annotation]?
    /// Fired when in-place text editing starts (true) / ends (false), so the editor can disable its
    /// ⌘C/⌘Z/⌘S/Esc key equivalents while the user types into the field (otherwise they hijack editing).
    var onTextEditingChanged: ((Bool) -> Void)?

    var currentTool: SnapTool = .arrow
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 3
    var currentFontSize: CGFloat = 20
    var currentBlurLevel: CGFloat = 12   // pixel-block divisor for NEW blurs; higher = coarser

    /// Notifies selection changes (so the toolbar reflects the size of the selected text).
    var onSelectionChange: (() -> Void)?

    init(image: NSImage) {
        self.baseImage = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        drawAnnotationLayers(forCanvas: true)
        draft?.draw(base: baseCG, canvasSize: bounds.size)
        drawSelectionHighlight()
    }

    /// Annotation pass shared by the canvas and both flatten paths, so the export renders exactly
    /// what the canvas shows: the spotlight dim layer first (ONE layer with a clear hole per
    /// spotlight), then every annotation in array order. Counter numbers are derived here from
    /// each counter's ordinal among counters, so deleting/undoing one renumbers the rest.
    /// The text being re-edited is hidden from the canvas (the NSTextField on top shows it);
    /// that way an Undo/cancel during re-editing restores the original instead of losing it.
    private func drawAnnotationLayers(forCanvas: Bool) {
        drawSpotlightDim(includeDraft: forCanvas)
        var counterNumber = 0
        for a in annotations {
            if forCanvas, a.id == editingID { continue }
            if a.tool == .counter { counterNumber += 1 }
            a.draw(base: baseCG, canvasSize: bounds.size, number: counterNumber)
        }
    }

    /// Dims everything outside the spotlight rects: black wash over the whole image, then the
    /// base region re-drawn inside each rect. Re-drawing the base "punches" the holes, which makes
    /// overlapping spotlights union cleanly (an even-odd path would invert where rects overlap).
    private func drawSpotlightDim(includeDraft: Bool) {
        var rects = annotations
            .filter { $0.tool == .spotlight }
            .map { $0.dragRect }
        if includeDraft, let d = draft, d.tool == .spotlight, d.points.count > 1 {
            rects.append(d.dragRect)   // live preview while dragging a new spotlight
        }
        guard !rects.isEmpty else { return }
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill(using: .sourceOver)
        for r in rects {
            let hole = r.intersection(bounds)
            guard !hole.isEmpty else { continue }
            // baseImage.size == bounds.size, so the view rect doubles as the source rect.
            baseImage.draw(in: hole, from: hole, operation: .copy, fraction: 1)
        }
    }

    private func drawSelectionHighlight() {
        guard let id = selectedID,
              let ann = annotations.first(where: { $0.id == id }),
              let box = ann.selectionBounds()?.insetBy(dx: -4, dy: -4) else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if currentTool == .select {
            // Universal select & move: hit-test ALL annotations, topmost first. Never creates
            // a draft — this tool only selects, drags, and (via ⌫) deletes existing annotations.
            commitActiveText()
            if let ann = annotations.last(where: { $0.hitTest(p) }) {
                selectedID = ann.id
                movingID = ann.id
                lastDragPoint = p
                preMoveSnapshot = annotations   // snapshot in case the drag moves it (undoable)
                movedDuringDrag = false
            } else {
                selectedID = nil
            }
            onSelectionChange?()
            needsDisplay = true
            return
        }

        if currentTool == .counter {
            // Click stamps a numbered badge — no drag, no draft. The displayed number is derived
            // from array order at draw time, so undo/delete renumbers the remaining counters.
            selectedID = nil
            onSelectionChange?()
            commitActiveText()
            pushUndo()
            annotations.append(Annotation(tool: .counter, color: currentColor,
                                          lineWidth: currentLineWidth, points: [p], text: nil))
            needsDisplay = true
            return
        }

        if currentTool == .text {
            commitActiveText()
            // Click on an existing text? (top to bottom)
            if let idx = annotations.lastIndex(where: {
                $0.tool == .text && ($0.textBounds()?.insetBy(dx: -6, dy: -6).contains(p) ?? false)
            }) {
                let ann = annotations[idx]
                if event.clickCount >= 2 {
                    // Double click → re-edit. It is NOT removed from the array: it's hidden via
                    // editingID while editing (draw skips it), so an Undo/cancel restores the original text.
                    editingID = ann.id
                    selectedID = nil
                    beginTextEditing(at: ann.start, existing: ann)
                } else {
                    // Single click → select and prepare to drag.
                    selectedID = ann.id
                    movingID = ann.id
                    lastDragPoint = p
                    preMoveSnapshot = annotations   // snapshot in case the drag moves it (undoable)
                    movedDuringDrag = false
                    onSelectionChange?()
                }
                needsDisplay = true
                return
            }
            // Empty space → new text.
            selectedID = nil
            onSelectionChange?()   // with no text selected, the toolbar reflects the current color/size
            beginTextEditing(at: p, existing: nil)
            needsDisplay = true
            return
        }

        // Drawing tools (including blur/spotlight: drag rects, normalized in Annotation.dragRect).
        selectedID = nil
        onSelectionChange?()
        commitActiveText()
        draft = Annotation(tool: currentTool, color: currentColor,
                           lineWidth: currentLineWidth, points: [p], text: nil,
                           blurLevel: currentBlurLevel)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // Move the grabbed annotation: translate ALL its points by the drag delta (works for
        // single-point text/counters and multi-point strokes alike).
        if let movingID, let idx = annotations.firstIndex(where: { $0.id == movingID }) {
            let dx = p.x - lastDragPoint.x, dy = p.y - lastDragPoint.y
            annotations[idx].points = annotations[idx].points.map {
                CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
            lastDragPoint = p
            movedDuringDrag = true
            needsDisplay = true
            return
        }

        guard var d = draft else { return }
        if d.tool == .pencil || d.tool == .marker {
            d.points.append(p)
        } else {
            d.points = [d.points.first ?? p, p]
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if movingID != nil {
            if movedDuringDrag, let snap = preMoveSnapshot { pushUndo(snap) }   // ONE undo per completed drag
            movingID = nil; preMoveSnapshot = nil; movedDuringDrag = false
            return
        }
        guard let d = draft else { return }
        draft = nil
        // Require an actual stroke: a no-drag click (count == 1) must not create an invisible annotation
        // that silently consumes an Undo press.
        if d.points.count > 1 {
            pushUndo()
            annotations.append(d)
        }
        needsDisplay = true
    }

    // MARK: - In-place text

    private func beginTextEditing(at point: NSPoint, existing: Annotation?) {
        let fontSize = existing?.fontSize ?? currentFontSize
        let color = existing?.color ?? currentColor
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let lineHeight = font.ascender - font.descender
        let fieldHeight = max(24, lineHeight + 8)
        // Position the field so that, on commit, the drawn text lands at `point`.
        let field = NSTextField(frame: NSRect(x: point.x - 4,
                                              y: point.y - (fieldHeight - lineHeight) / 2,
                                              width: 260, height: fieldHeight))
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = .white.withAlphaComponent(0.92)
        field.font = font
        field.textColor = color
        field.focusRingType = .none
        field.placeholderString = L10n.t("editor.text.placeholder")
        field.stringValue = existing?.text ?? ""
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
        editFontSize = fontSize
        editColor = color
        onTextEditingChanged?(true)   // let the toolbar release ⌘C/⌘Z/⌘S/Esc while typing
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) { commitActiveText() }

    private func commitActiveText() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = field.frame
        let font = field.font ?? NSFont.systemFont(ofSize: editFontSize, weight: .semibold)
        let id = editingID
        activeTextField = nil
        editingID = nil
        field.removeFromSuperview()
        onTextEditingChanged?(false)   // restore the toolbar key equivalents
        // Record undo only if this commit actually changes the annotations (new text, or re-edit).
        if !text.isEmpty || id != nil { pushUndo() }
        // If a text was being re-edited, remove the original: we replace it below, or (if it ended up
        // empty) we delete it by committing empty.
        if let id { annotations.removeAll { $0.id == id } }
        guard !text.isEmpty else { needsDisplay = true; return }
        let lineHeight = font.ascender - font.descender
        let drawY = frame.minY + (frame.height - lineHeight) / 2
        let origin = CGPoint(x: frame.minX + 4, y: drawY)
        var ann = Annotation(tool: .text, color: editColor, lineWidth: currentLineWidth,
                             points: [origin], text: text, fontSize: editFontSize)
        if let id { ann.id = id }   // preserves identity when re-editing
        annotations.append(ann)
        selectedID = ann.id
        onSelectionChange?()
        needsDisplay = true
    }

    // MARK: - Font size

    /// Effective size to show in the toolbar: that of the selected text, or the current one.
    /// (Only text has a font size; a selected shape doesn't override the toolbar value.)
    var effectiveFontSize: CGFloat {
        if let id = selectedID, let a = annotations.first(where: { $0.id == id }),
           a.tool == .text { return a.fontSize }
        return currentFontSize
    }

    /// Effective color to reflect in the toolbar: that of the selected annotation, or the current one.
    var effectiveColor: NSColor {
        if let id = selectedID, let a = annotations.first(where: { $0.id == id }) { return a.color }
        return currentColor
    }

    /// Tool of the selected annotation (nil if none) — lets the toolbar show contextual controls.
    var selectedAnnotationTool: SnapTool? {
        guard let id = selectedID else { return nil }
        return annotations.first(where: { $0.id == id })?.tool
    }

    /// Effective blur level to show in the slider: that of the selected blur, or the current one.
    var effectiveBlurLevel: CGFloat {
        if let id = selectedID, let a = annotations.first(where: { $0.id == id }),
           a.tool == .blur { return a.blurLevel }
        return currentBlurLevel
    }

    /// Applies a new size: to the selected text (if any) and as the default size for the next one.
    func setFontSize(_ size: CGFloat) {
        let clamped = max(10, min(120, size))
        currentFontSize = clamped
        if let field = activeTextField {
            field.font = NSFont.systemFont(ofSize: clamped, weight: .semibold)
            editFontSize = clamped
        }
        if let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }),
           annotations[idx].tool == .text {   // font size only means something for text
            pushUndo()
            annotations[idx].fontSize = clamped
        }
        needsDisplay = true
    }

    func bumpFontSize(_ delta: CGFloat) { setFontSize(effectiveFontSize + delta) }

    /// Sets the current color and, if there is a selected annotation or text being edited,
    /// recolors it. Use for explicit user color actions (tapping a swatch / the color panel).
    func setColor(_ color: NSColor) {
        currentColor = color
        if let field = activeTextField { field.textColor = color; editColor = color }
        if let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) {
            pushUndo()
            annotations[idx].color = color
        }
        needsDisplay = true
    }

    /// Color-panel drags fire continuously (isContinuous), so a plain setColor per tick would flood the
    /// 50-entry undo stack and wipe real history. armColorCoalescing() re-arms before a drag; the FIRST
    /// coalesced change snapshots once, the rest recolor in place.
    private var colorCoalescingArmed = false
    func armColorCoalescing() { colorCoalescingArmed = true }

    func setColorCoalesced(_ color: NSColor) {
        if colorCoalescingArmed {
            colorCoalescingArmed = false
            if selectedID != nil { pushUndo() }   // one snapshot for the whole drag
        }
        currentColor = color
        if let field = activeTextField { field.textColor = color; editColor = color }
        if let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) {
            annotations[idx].color = color   // no pushUndo: already snapshotted at drag start
        }
        needsDisplay = true
    }

    /// Blur-intensity slider drags fire continuously too — same coalescing pattern as the color
    /// panel: arm once at slide start, the FIRST change snapshots, the rest update in place.
    private var blurCoalescingArmed = false
    func armBlurCoalescing() { blurCoalescingArmed = true }

    /// Sets the blur level for FUTURE blurs and, if a blur annotation is selected, re-pixelates
    /// it live (one undo step per slide, via armBlurCoalescing).
    func setBlurLevelCoalesced(_ level: CGFloat) {
        if blurCoalescingArmed {
            blurCoalescingArmed = false
            if selectedAnnotationTool == .blur { pushUndo() }   // one snapshot for the whole slide
        }
        currentBlurLevel = level
        if let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }),
           annotations[idx].tool == .blur {
            annotations[idx].blurLevel = level   // no pushUndo: already snapshotted at slide start
        }
        needsDisplay = true
    }

    /// Sets the default color for FUTURE strokes only — never recolors a committed selected annotation.
    /// Used on tool switches so changing tools doesn't silently rewrite an existing text's color.
    func setDefaultColor(_ color: NSColor) {
        currentColor = color
        if let field = activeTextField { field.textColor = color; editColor = color }
        needsDisplay = true
    }

    // MARK: - Actions

    private func pushUndo(_ snapshot: [Annotation]? = nil) {
        undoStack.append(snapshot ?? annotations)
        if undoStack.count > 50 { undoStack.removeFirst() }   // bound memory
        redoStack.removeAll()   // any new mutation invalidates the redo history
    }

    func undo() {
        // If text is being edited, cancel the edit first: the original stays in the array (hidden by
        // editingID) and reappears once editingID is cleared. The re-edited text is not lost.
        if activeTextField != nil {
            activeTextField?.removeFromSuperview(); activeTextField = nil; editingID = nil
            onTextEditingChanged?(false)
            needsDisplay = true
            return
        }
        // Restore the last snapshot — reverses ANY operation (add/move/edit/recolor/resize/delete),
        // not just the most-recently-added annotation.
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(annotations)   // so ⇧⌘Z can bring it back
        annotations = prev
        selectedID = nil
        onSelectionChange?()
        needsDisplay = true
    }

    /// Re-applies the last undone snapshot (⇧⌘Z). Cleared by any new mutation (see pushUndo).
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)   // direct append: pushUndo would wipe the redo history
        if undoStack.count > 50 { undoStack.removeFirst() }
        annotations = next
        selectedID = nil
        onSelectionChange?()
        needsDisplay = true
    }

    /// Deletes the currently selected annotation (Delete / Backspace), undoably.
    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51 || event.keyCode == 117   // Backspace / Forward-Delete
        if isDelete, activeTextField == nil, let id = selectedID,
           annotations.contains(where: { $0.id == id }) {
            pushUndo()
            annotations.removeAll { $0.id == id }
            selectedID = nil
            onSelectionChange?()
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    /// Flattens base + annotations into an NSImage at full pixel resolution (Retina).
    func flattened() -> NSImage {
        commitActiveText()
        let savedSelection = selectedID
        selectedID = nil   // don't rasterize the selection box
        defer { selectedID = savedSelection }

        let pxW = baseImage.representations.first?.pixelsWide ?? Int(bounds.width)
        let pxH = baseImage.representations.first?.pixelsHigh ?? Int(bounds.height)
        // Rasterize in the base image's OWN color space. Using a generic `.deviceRGB` bitmap rep would
        // strip a Display P3 (wide-gamut) profile and produce a washed-out PNG on capable displays; a
        // CGContext in `baseCG.colorSpace` preserves the colors the user actually saw.
        let colorSpace = baseCG?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        if pxW > 0, pxH > 0, bounds.width > 0, bounds.height > 0, let colorSpace,
           let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                               bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: CGFloat(pxW) / bounds.width, y: CGFloat(pxH) / bounds.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            baseImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            drawAnnotationLayers(forCanvas: false)
            NSGraphicsContext.restoreGraphicsState()
            if let outCG = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: outCG)
                rep.size = bounds.size
                let out = NSImage(size: bounds.size)
                out.addRepresentation(rep)
                return out
            }
        }

        // Fallback (couldn't create the pixel-resolution bitmap): rasterize at point size
        // BUT including the annotations. Never return the clean base: it would lose the user's work.
        let out = NSImage(size: bounds.size)
        out.lockFocus()
        baseImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        drawAnnotationLayers(forCanvas: false)
        out.unlockFocus()
        return out
    }
}
