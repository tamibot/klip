import AppKit

/// Editor canvas: draws the base capture and the annotations on top. Handles live drawing,
/// in-place text (a temporary NSTextField — supports accents), universal select/move/delete of
/// any annotation (.select tool), blur/spotlight/counter rendering, and for text: re-editing
/// and resizing. Flattens everything to a full-resolution image.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
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
    /// Grab anchor and latest pointer position of a move. The move is applied as a TOTAL offset from
    /// the anchor against `preMoveSnapshot` (not as a per-event delta), which is what lets Shift
    /// axis-lock mid-drag — and un-lock again — without the discarded axis drifting away.
    private var moveAnchor = CGPoint.zero
    private var lastMovePoint = CGPoint.zero
    private var movedDuringDrag = false
    /// Live modifier state, mirroring CaptureOverlayView: ⇧ constrains, ⌥ grows from the press point.
    /// Held here (not read per-event) so `flagsChanged` can re-derive the draft with no mouse movement.
    private var shiftHeld = false
    private var optionHeld = false
    /// Anchor + latest pointer position of the shape draft, for the same re-derivation.
    private var draftAnchor: CGPoint?
    private var lastDraftPoint: CGPoint?
    /// Full-state undo snapshots: add / move / edit / recolor / resize / delete are all reversible.
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var preMoveSnapshot: [Annotation]?
    /// Live resize, sharing `preMoveSnapshot` with the move path: a resize is re-derived from the
    /// grab snapshot on every event (never accumulated), which is what lets ⇧/⌥ be pressed and
    /// released mid-drag, and what keeps ONE completed resize equal to ONE undo step.
    private var resizingID: UUID?
    private var resizeKind: HandleKind?
    /// Press point → the handle's true geometry point. The selection box is padded outward, so
    /// resizing straight against the pointer would snap the edge by that padding the instant it's grabbed.
    private var resizeGrabOffset = CGPoint.zero
    private var lastResizePoint = CGPoint.zero
    private var resizedDuringDrag = false
    /// Fired when in-place text editing starts (true) / ends (false), so the editor can disable its
    /// ⌘C/⌘Z/⌘S/⌘±/⌘0 key equivalents while the user types into the field (otherwise they hijack
    /// editing). Esc is not among them: it belongs to the field editor while typing, and to the
    /// responder chain (cancelOperation) otherwise.
    var onTextEditingChanged: ((Bool) -> Void)?
    /// Last rung of the Esc ladder (see `cancelOperation`): nothing left on the canvas to dismiss, so
    /// the editor takes over and runs its discard confirmation.
    var onEscape: (() -> Void)?

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

    // MARK: - Cursor

    /// Cursor the active tool claims over the whole canvas. `.select` returns nil on purpose: it has
    /// no single cursor — the hover tracking below drives arrow / open hand / closed hand instead, and
    /// a cursor rect would fight it by re-asserting itself every time the pointer re-enters.
    private var toolCursor: NSCursor? {
        switch currentTool {
        case .select: return nil
        case .text:   return .iBeam
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .blur, .spotlight, .counter:
            return .crosshair
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // While Space is held the whole canvas is a pan surface. Claiming it as a cursor RECT (rather
        // than just calling .set()) is what keeps the hand there: the tool's own rect would otherwise
        // re-assert the crosshair on the next pointer move.
        if spaceHeld {
            addCursorRect(bounds, cursor: panAnchor == nil ? .openHand : .closedHand)
            return
        }
        if let cursor = toolCursor { addCursorRect(bounds, cursor: cursor) }
    }

    /// Hover tracking for `.select`, owned by us so `updateTrackingAreas` can replace ONLY this one.
    /// Removing every area would also destroy the ones AppKit installs for other purposes (the same
    /// trap that once killed the toolbar tooltips).
    private var selectHoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = selectHoverArea { removeTrackingArea(a); selectHoverArea = nil }
        guard currentTool == .select else { return }   // only .select needs per-position feedback
        // .inVisibleRect keeps the area correct as the scroll view pans/zooms under us.
        let a = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        selectHoverArea = a
    }

    /// The cursor rects and the hover tracking are both keyed on `currentTool`, and nothing about the
    /// view's geometry changes when the tool does — so neither refreshes on its own. The editor calls
    /// this (plus `invalidateCursorRects`) from its tool-change choke point.
    func toolDidChange() {
        updateTrackingAreas()
        needsDisplay = true   // the resize handles are drawn for .select only, so they come and go with the tool
        // A tool switched by its letter shortcut leaves the pointer parked, so nothing re-enters the
        // cursor rect: apply the new cursor now if the pointer is already over the canvas.
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(p) else { return }
        if currentTool == .select { updateSelectCursor(at: p) } else { toolCursor?.set() }
    }

    /// Open hand over something grabbable, closed hand while dragging it — the standard macOS
    /// affordance for "this moves". Plain arrow over empty canvas. Resize cursors take precedence:
    /// the handles sit on top of the annotation, so the hand would otherwise mask them.
    private func updateSelectCursor(at point: CGPoint) {
        // resizeKind first: mid-drag the geometry travels under the pointer, and re-hit-testing
        // would drop the cursor the moment the handle slid out from beneath it.
        if let kind = resizeKind ?? handleHitTest(point)?.kind {
            Self.resizeCursor(for: kind).set()
            return
        }
        if movingID != nil { NSCursor.closedHand.set(); return }
        let hit = annotations.contains(where: { $0.hitTest(point) })
        (hit ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !spaceHeld else { return }   // the pan cursor rect owns the pointer while Space is down
        guard currentTool == .select else { return }
        updateSelectCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if currentTool == .select, !spaceHeld { NSCursor.arrow.set() }
    }

    // MARK: - Space-hold hand pan

    /// Space means "move the thing you're framing" in the capture overlay; it means the same here,
    /// panning the zoomed canvas under the pointer. Only ever armed when there IS something off-screen
    /// to pan to, and never while the in-place text field is up — the field editor owns Space then,
    /// and typing a space must never grab the canvas instead.
    private var spaceHeld = false
    private var panAnchor: NSPoint?   // window-space pointer position, re-anchored on every drag event

    private var canPan: Bool {
        guard let scroll = enclosingScrollView else { return false }
        let visible = scroll.documentVisibleRect
        return visible.width < bounds.width - 0.5 || visible.height < bounds.height - 0.5
    }

    private func setSpaceHeld(_ held: Bool) {
        guard spaceHeld != held else { return }
        spaceHeld = held
        window?.invalidateCursorRects(for: self)
        if held {
            NSCursor.openHand.set()
        } else {
            panAnchor = nil
            restoreToolCursor()
        }
    }

    /// Puts the tool's own cursor back after a pan (cursor rects only re-run when the pointer moves).
    private func restoreToolCursor() {
        if currentTool == .select {
            guard let window else { NSCursor.arrow.set(); return }
            updateSelectCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            toolCursor?.set()
        }
    }

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
              let box = selectionBox(for: ann) else { return }
        // Same two-stroke dialect as the capture overlay's marquee: a white hairline underneath
        // carries the accent dash over dark screenshots, where a bare accent stroke disappears.
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let base = NSBezierPath(rect: box)
        base.lineWidth = 1.5
        base.stroke()
        NSColor.controlAccentColor.setStroke()
        let dash = NSBezierPath(rect: box)
        dash.lineWidth = 1.5
        dash.setLineDash([4, 3], count: 2, phase: 0)
        dash.stroke()
        // Handles only under .select: that is the one tool whose hit-testing and hover cursors can
        // act on them, and an affordance you can see but not grab is worse than none.
        guard currentTool == .select else { return }
        for handle in selectionHandles(for: ann) {
            let r = CGRect(x: handle.point.x - Self.handleSize / 2,
                           y: handle.point.y - Self.handleSize / 2,
                           width: Self.handleSize, height: Self.handleSize)
            let path = NSBezierPath(rect: r)
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: - Resize handles

    /// A grab point of the selection. `box` names which edges of the selection box the handle owns
    /// (−1 / 0 / +1 per axis), so one rescale routine covers corners and edge midpoints alike;
    /// `endpoint` names an index into a line's or arrow's two points.
    private enum HandleKind: Equatable {
        case box(x: Int, y: Int)
        case endpoint(Int)
    }

    private struct Handle {
        let kind: HandleKind
        /// Where the square is drawn and hit-tested — on the PADDED selection box.
        let point: CGPoint
        /// The point it actually moves, on the annotation's own bounds (see `resizeGrabOffset`).
        let geometry: CGPoint
    }

    private static let handleSize: CGFloat = 6
    private static let handleHitSlop: CGFloat = 3
    /// Gap between an annotation and its selection box.
    private static let selectionPadding: CGFloat = 4
    /// Below this the edge-midpoint handles are dropped: on a small box they crowd the corners and
    /// blanket the body, leaving no bare pixels to grab the annotation by and move it.
    private static let minEdgeHandleExtent: CGFloat = 24

    private func selectionBox(for ann: Annotation) -> CGRect? {
        ann.selectionBounds()?.insetBy(dx: -Self.selectionPadding, dy: -Self.selectionPadding)
    }

    private static func boxPoint(_ r: CGRect, _ xe: Int, _ ye: Int) -> CGPoint {
        CGPoint(x: xe < 0 ? r.minX : xe > 0 ? r.maxX : r.midX,
                y: ye < 0 ? r.minY : ye > 0 ? r.maxY : r.midY)
    }

    /// Grab points of a selected annotation. Corners come FIRST so that on a small box — where the
    /// hit slop makes them overlap the edge handles — a corner still wins the grab.
    /// Freehand strokes and counters have no handles: a pencil stroke has no two defining points to
    /// rescale, and a counter's size is its stroke width, which the toolbar already owns.
    private func selectionHandles(for ann: Annotation) -> [Handle] {
        switch ann.tool {
        case .line, .arrow:
            guard ann.points.count > 1 else { return [] }
            return [Handle(kind: .endpoint(0), point: ann.start, geometry: ann.start),
                    Handle(kind: .endpoint(ann.points.count - 1), point: ann.end, geometry: ann.end)]
        case .rectangle, .ellipse, .blur, .spotlight, .text:
            guard let geom = ann.selectionBounds(), let box = selectionBox(for: ann) else { return [] }
            var out: [Handle] = []
            for (xe, ye) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] {
                out.append(Handle(kind: .box(x: xe, y: ye),
                                  point: Self.boxPoint(box, xe, ye), geometry: Self.boxPoint(geom, xe, ye)))
            }
            guard ann.tool != .text else { return out }   // text scales by font size: corners only
            for (xe, ye) in [(0, -1), (1, 0), (0, 1), (-1, 0)] {
                if xe != 0, geom.height < Self.minEdgeHandleExtent { continue }
                if ye != 0, geom.width < Self.minEdgeHandleExtent { continue }
                out.append(Handle(kind: .box(x: xe, y: ye),
                                  point: Self.boxPoint(box, xe, ye), geometry: Self.boxPoint(geom, xe, ye)))
            }
            return out
        case .select, .pencil, .marker, .counter:
            return []
        }
    }

    private func handleHitTest(_ p: CGPoint) -> Handle? {
        guard currentTool == .select, activeTextField == nil, let id = selectedID,
              let ann = annotations.first(where: { $0.id == id }) else { return nil }
        let reach = Self.handleSize / 2 + Self.handleHitSlop
        return selectionHandles(for: ann).first {
            abs(p.x - $0.point.x) <= reach && abs(p.y - $0.point.y) <= reach
        }
    }

    private func beginResize(_ handle: Handle, at p: CGPoint) {
        guard let id = selectedID else { return }
        resizingID = id
        resizeKind = handle.kind
        resizeGrabOffset = CGPoint(x: handle.geometry.x - p.x, y: handle.geometry.y - p.y)
        lastResizePoint = p
        resizedDuringDrag = false
        preMoveSnapshot = annotations   // one snapshot per gesture, pushed on mouseUp only if it moved
        Self.resizeCursor(for: handle.kind).set()
    }

    /// Re-derives the resized annotation from the grab snapshot — from `mouseDragged` and from
    /// `flagsChanged`, exactly like `updateMove`, so ⇧/⌥ take effect with no pointer movement.
    private func updateResize() {
        guard let resizingID, let kind = resizeKind,
              let idx = annotations.firstIndex(where: { $0.id == resizingID }),
              let base = preMoveSnapshot?.first(where: { $0.id == resizingID }) else { return }
        let p = CGPoint(x: lastResizePoint.x + resizeGrabOffset.x,
                        y: lastResizePoint.y + resizeGrabOffset.y)
        var updated = base
        switch kind {
        case .endpoint(let i):
            resizeEndpoint(&updated, index: i, to: p)
        case .box(let xe, let ye):
            if base.tool == .text { resizeText(&updated, x: xe, y: ye, to: p) }
            else { resizeBox(&updated, x: xe, y: ye, to: p) }
        }
        if updated.points != base.points || updated.fontSize != base.fontSize { resizedDuringDrag = true }
        annotations[idx] = updated
        Self.resizeCursor(for: kind).set()   // cursor rects can re-assert if the pointer leaves mid-drag
        needsDisplay = true
    }

    /// Rescales a rect-family annotation by moving the grabbed edge(s). Rectangle, ellipse, blur and
    /// spotlight all render from the NORMALIZED `dragRect`, so rebuilding the defining pair as the
    /// new rect's opposite corners loses nothing — including when the drag flips the shape inside out.
    private func resizeBox(_ ann: inout Annotation, x xe: Int, y ye: Int, to p: CGPoint) {
        guard let base = ann.selectionBounds() else { return }
        // ⌥ = the shape grows from its own center, mirroring the press-point-is-the-center dialect
        // `updateDraft` uses while the shape is being drawn.
        // An edge handle owns ONE axis: the other's anchor is never read, since only the free axis
        // is rebuilt below.
        let anchorX = optionHeld ? base.midX : (xe > 0 ? base.minX : base.maxX)
        let anchorY = optionHeld ? base.midY : (ye > 0 ? base.minY : base.maxY)
        var dx = p.x - anchorX
        var dy = p.y - anchorY
        if shiftHeld, xe != 0, ye != 0 {
            // ⇧ = square, the same "smaller extent wins" rule as when the shape was drawn.
            let side = min(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        var r = base
        if xe != 0 {
            r.origin.x = optionHeld ? anchorX - abs(dx) : min(anchorX, anchorX + dx)
            r.size.width = optionHeld ? abs(dx) * 2 : abs(dx)
        }
        if ye != 0 {
            r.origin.y = optionHeld ? anchorY - abs(dy) : min(anchorY, anchorY + dy)
            r.size.height = optionHeld ? abs(dy) * 2 : abs(dy)
        }
        ann.points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    /// Moves one endpoint of a line/arrow. ⇧ snaps the direction to 45° (never to a square: for these
    /// two the ANGLE is the point); ⌥ mirrors around the midpoint, so the segment grows from center.
    private func resizeEndpoint(_ ann: inout Annotation, index: Int, to p: CGPoint) {
        guard ann.points.count > 1, ann.points.indices.contains(index) else { return }
        let otherIndex = index == 0 ? ann.points.count - 1 : 0
        let other = ann.points[otherIndex]
        let held = ann.points[index]
        let anchor = optionHeld ? CGPoint(x: (held.x + other.x) / 2, y: (held.y + other.y) / 2) : other
        var dx = p.x - anchor.x
        var dy = p.y - anchor.y
        if shiftHeld {
            let step = CGFloat.pi / 4
            let length = hypot(dx, dy)
            let angle = (atan2(dy, dx) / step).rounded() * step
            dx = cos(angle) * length
            dy = sin(angle) * length
        }
        var pts = ann.points
        pts[index] = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        if optionHeld { pts[otherIndex] = CGPoint(x: anchor.x - dx, y: anchor.y - dy) }
        ann.points = pts
    }

    /// Text has no box to stretch — its extent IS its font size, so a corner drag maps the distance
    /// from the held corner onto the size (uniform by construction, which is why ⇧ has nothing to
    /// constrain here). The origin is then re-derived so the anchor corner stays exactly where it was.
    private func resizeText(_ ann: inout Annotation, x xe: Int, y ye: Int, to p: CGPoint) {
        guard let base = ann.textBounds(), base.width > 0.5, base.height > 0.5 else { return }
        // Fraction of the box the anchor sits at: the opposite corner, or (⌥) the center.
        let fx: CGFloat = optionHeld ? 0.5 : (xe > 0 ? 0 : 1)
        let fy: CGFloat = optionHeld ? 0.5 : (ye > 0 ? 0 : 1)
        let anchor = CGPoint(x: base.minX + base.width * fx, y: base.minY + base.height * fy)
        let grabbed = Self.boxPoint(base, xe, ye)
        let reach = hypot(grabbed.x - anchor.x, grabbed.y - anchor.y)
        guard reach > 0.5 else { return }
        let scale = hypot(p.x - anchor.x, p.y - anchor.y) / reach
        ann.fontSize = max(10, min(120, ann.fontSize * scale))   // same clamp as setFontSize
        guard let grown = ann.textBounds() else { return }
        ann.points = [CGPoint(x: anchor.x - grown.width * fx, y: anchor.y - grown.height * fy)]
    }

    /// Standard macOS resize feedback. AppKit ships only the straight up/down and left/right cursors
    /// below macOS 15 — the diagonal ones arrive with `frameResize(position:directions:)` — so older
    /// systems get the crosshair rather than a cursor pointing along the wrong axis.
    private static func resizeCursor(for kind: HandleKind) -> NSCursor {
        guard case .box(let xe, let ye) = kind else { return .crosshair }   // endpoint: place a point
        if xe == 0 { return .resizeUpDown }
        if ye == 0 { return .resizeLeftRight }
        guard #available(macOS 15.0, *) else { return .crosshair }
        let position: NSCursor.FrameResizePosition = ye > 0
            ? (xe > 0 ? .topRight : .topLeft)
            : (xe > 0 ? .bottomRight : .bottomLeft)
        return .frameResize(position: position, directions: .all)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        shiftHeld = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        nudgeCoalescingArmed = true   // any mouse work ends the current arrow-key burst

        if spaceHeld, canPan {
            panAnchor = event.locationInWindow
            window?.invalidateCursorRects(for: self)
            NSCursor.closedHand.set()
            return
        }

        // Handles before bodies: they straddle the annotation's own outline, so a body hit-test
        // running first would swallow every grab and turn a resize into a move.
        if let handle = handleHitTest(p) {
            beginResize(handle, at: p)
            return
        }

        if currentTool == .select {
            // Universal select & move: hit-test ALL annotations, topmost first. Never creates
            // a draft — this tool only selects, drags, and (via ⌫) deletes existing annotations.
            commitActiveText()
            if let ann = annotations.last(where: { $0.hitTest(p) }) {
                selectedID = ann.id
                movingID = ann.id
                moveAnchor = p
                lastMovePoint = p
                preMoveSnapshot = annotations   // snapshot in case the drag moves it (undoable)
                movedDuringDrag = false
            } else {
                selectedID = nil
            }
            updateSelectCursor(at: p)
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
                    moveAnchor = p
                    lastMovePoint = p
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
        draftAnchor = p
        lastDraftPoint = p
        draft = Annotation(tool: currentTool, color: currentColor,
                           lineWidth: currentLineWidth, points: [p], text: nil,
                           blurLevel: currentBlurLevel)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        shiftHeld = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)

        if let anchor = panAnchor, let scroll = enclosingScrollView {
            // Hand pan: the image follows the pointer, so the viewport travels the other way. The
            // anchor is re-set every event because the document slides under a pointer whose WINDOW
            // position hasn't changed — an absolute delta would compound.
            let now = event.locationInWindow
            let magnification = max(scroll.magnification, 0.0001)
            var origin = scroll.documentVisibleRect.origin
            origin.x -= (now.x - anchor.x) / magnification
            origin.y -= (now.y - anchor.y) / magnification
            panAnchor = now
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            NSCursor.closedHand.set()
            return
        }

        if resizingID != nil {
            lastResizePoint = p
            updateResize()
            return
        }

        // Move the grabbed annotation (works for single-point text/counters and multi-point strokes).
        if movingID != nil {
            lastMovePoint = p
            updateMove()
            return
        }

        guard var d = draft else { return }
        if d.tool == .pencil || d.tool == .marker {
            d.points.append(p)   // freehand: every sample is the stroke, no constraint to apply
            draft = d
            needsDisplay = true
        } else {
            lastDraftPoint = p
            updateDraft()
        }
    }

    /// Re-derives the moved annotation from the grab snapshot — from `mouseDragged` and from
    /// `flagsChanged`, so Shift starts and stops axis-locking without waiting for the pointer.
    private func updateMove() {
        guard let movingID, let idx = annotations.firstIndex(where: { $0.id == movingID }),
              let base = preMoveSnapshot?.first(where: { $0.id == movingID })?.points else { return }
        var dx = lastMovePoint.x - moveAnchor.x
        var dy = lastMovePoint.y - moveAnchor.y
        if shiftHeld {
            // Shift = constrain, same as everywhere else: here that means locking to the axis the
            // drag is committed to, so a nudge sideways can't tilt a carefully placed annotation.
            if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        }
        if dx != 0 || dy != 0 { movedDuringDrag = true }
        annotations[idx].points = base.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        // Cursor rects can re-assert mid-drag if the pointer crosses out of the canvas; keep the
        // closed hand pinned for as long as the grab lasts.
        if currentTool == .select { NSCursor.closedHand.set() }
        needsDisplay = true
    }

    /// Re-derives the two-point draft from anchor + pointer, applying the modifiers. Ported from
    /// CaptureOverlayView.updateSelection so the editor and the capture overlay constrain identically.
    private func updateDraft() {
        guard var d = draft, let anchor = draftAnchor, let p = lastDraftPoint,
              d.tool != .pencil, d.tool != .marker else { return }
        // No drag yet: don't promote the 1-point draft to a pair. flagsChanged also lands here, so
        // tapping ⇧/⌥ on a press with no movement would otherwise satisfy mouseUp's `points.count > 1`
        // and commit a zero-extent annotation (plus an undo step) for what was just a click.
        guard d.points.count > 1 || p != anchor else { return }
        var dx = p.x - anchor.x
        var dy = p.y - anchor.y
        switch d.tool {
        case .line, .arrow:
            if shiftHeld {
                // Shift = snap the direction to the nearest 45°, keeping the drag's length along it
                // (a square constraint would break the one case where the ANGLE is the point).
                let step = CGFloat.pi / 4
                let length = hypot(dx, dy)
                let angle = (atan2(dy, dx) / step).rounded() * step
                dx = cos(angle) * length
                dy = sin(angle) * length
            }
        default:
            if shiftHeld {
                // Shift = square: smaller extent wins, drag direction preserved.
                let side = min(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side
                dy = dy < 0 ? -side : side
            }
        }
        if optionHeld {
            // Option = the press point is the CENTER: mirror the drag to the opposite side.
            d.points = [CGPoint(x: anchor.x - dx, y: anchor.y - dy),
                        CGPoint(x: anchor.x + dx, y: anchor.y + dy)]
        } else {
            d.points = [anchor, CGPoint(x: anchor.x + dx, y: anchor.y + dy)]
        }
        draft = d
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        shiftHeld = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        if resizingID != nil { updateResize() }
        else if movingID != nil { updateMove() }
        else { updateDraft() }
        super.flagsChanged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if panAnchor != nil {
            panAnchor = nil
            window?.invalidateCursorRects(for: self)
            if spaceHeld { NSCursor.openHand.set() } else { restoreToolCursor() }
            return
        }
        draftAnchor = nil
        lastDraftPoint = nil
        if resizingID != nil {
            if resizedDuringDrag, let snap = preMoveSnapshot { pushUndo(snap) }   // ONE undo per completed resize
            resizingID = nil; resizeKind = nil; preMoveSnapshot = nil; resizedDuringDrag = false
            updateSelectCursor(at: convert(event.locationInWindow, from: nil))
            return
        }
        if movingID != nil {
            if movedDuringDrag, let snap = preMoveSnapshot { pushUndo(snap) }   // ONE undo per completed drag
            movingID = nil; preMoveSnapshot = nil; movedDuringDrag = false
            if currentTool == .select {   // grab released: closed hand → open hand / arrow
                updateSelectCursor(at: convert(event.locationInWindow, from: nil))
            }
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
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)   // adapts to dark mode
        field.font = font
        field.textColor = color
        field.focusRingType = .default   // the active field carries the accent focus ring (active = accent)
        field.placeholderString = L10n.t("editor.text.placeholder")
        field.stringValue = existing?.text ?? ""
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        // Return fires the action; but Esc (abortEditing), click-away and focus loss end editing WITHOUT
        // firing it — and only commitActiveText re-enables the toolbar's key equivalents. Route every
        // end-of-editing through the delegate so ⌘C/⌘S/⌘Z + the tool keys can't get stranded off.
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
        editFontSize = fontSize
        editColor = color
        onTextEditingChanged?(true)   // let the toolbar release its ⌘ shortcuts while typing
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) { commitActiveText() }

    /// Fires on EVERY end-of-editing — Return, Esc-abort, click-away, focus loss. commitActiveText is
    /// idempotent (it nils activeTextField first, so the Return path's action + this both land safely),
    /// so this is the single choke point that guarantees the toolbar key equivalents get restored.
    /// On Esc, abortEditing has already reverted the field to its original value, so committing it is a
    /// clean cancel: empty for a new text (adds nothing), the original for a re-edit (keeps it).
    func controlTextDidEndEditing(_ obj: Notification) { commitActiveText() }

    /// True while the in-place field holds real (non-whitespace) uncommitted text — the editor's
    /// close path treats it as unsaved work (trimmed, matching commitActiveText's semantics).
    var hasPendingText: Bool {
        guard let field = activeTextField else { return false }
        return !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commitActiveText() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = field.frame
        let font = field.font ?? NSFont.systemFont(ofSize: editFontSize, weight: .semibold)
        let id = editingID
        activeTextField = nil
        editingID = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)   // removing the field editor dropped keyboard focus
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
            // One snapshot for the whole slide, if anything is actually going to change.
            if selectedAnnotationTool == .blur || annotations.contains(where: { $0.tool == .blur }) {
                pushUndo()
            }
        }
        currentBlurLevel = level
        if let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }),
           annotations[idx].tool == .blur {
            annotations[idx].blurLevel = level   // a blur is selected → tune just that one
        } else {
            // Nothing selected: the slider reads as "how blurred things are", so re-render every
            // blur already on the canvas — otherwise the strength you pick only affects the NEXT
            // one you draw, and the control looks broken.
            for i in annotations.indices where annotations[i].tool == .blur {
                annotations[i].blurLevel = level
            }
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
            window?.makeFirstResponder(self)   // removing the field editor dropped keyboard focus
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

    /// Arrow-key nudges arrive as a burst — key repeat while held, or a run of quick taps. Snapshot
    /// ONCE at the head of the burst and translate in place afterwards: the arm-once shape of
    /// armColorCoalescing, with the gap between key events standing in for the mouse-up that ends a
    /// drag (and any mouse-down re-arming it, so a nudge never folds into someone else's snapshot).
    private var nudgeCoalescingArmed = true
    private var lastNudgeTime: TimeInterval = 0
    private static let nudgeBurstGap: TimeInterval = 0.6

    /// Unit nudge for the four arrow keys, in canvas coordinates (the view is not flipped, so Up is +y).
    private static func nudgeDelta(for keyCode: UInt16) -> CGPoint? {
        switch keyCode {
        case 123: return CGPoint(x: -1, y: 0)
        case 124: return CGPoint(x: 1, y: 0)
        case 125: return CGPoint(x: 0, y: -1)
        case 126: return CGPoint(x: 0, y: 1)
        default:  return nil
        }
    }

    /// Deletes the currently selected annotation (Delete / Backspace) and nudges it with the arrow
    /// keys, both undoably; Space arms the hand pan; Esc walks the layered ladder in cancelOperation.
    override func keyDown(with event: NSEvent) {
        // Esc: AppKit only routes cancelOperation through the text input system, which a plain NSView
        // never invokes — so call the ladder directly, exactly as CaptureOverlayView does.
        if event.keyCode == 53 { cancelOperation(nil); return }

        if event.keyCode == 49 {   // Space = hold to pan the zoomed canvas
            guard activeTextField == nil, canPan else { super.keyDown(with: event); return }
            setSpaceHeld(true)
            return                 // swallow the repeats too: Space must not also page-scroll
        }

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

        if let unit = Self.nudgeDelta(for: event.keyCode), activeTextField == nil,
           let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            if event.timestamp - lastNudgeTime > Self.nudgeBurstGap { nudgeCoalescingArmed = true }
            if nudgeCoalescingArmed {
                nudgeCoalescingArmed = false
                pushUndo()   // one snapshot for the whole burst
            }
            lastNudgeTime = event.timestamp
            annotations[idx].points = annotations[idx].points.map {
                CGPoint(x: $0.x + unit.x * step, y: $0.y + unit.y * step)
            }
            needsDisplay = true
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld { setSpaceHeld(false); return }
        super.keyUp(with: event)
    }

    /// No keyUp ever arrives if focus leaves mid-hold (the text field taking over): drop the pan so the
    /// hand cursor can't strand itself over the canvas.
    override func resignFirstResponder() -> Bool {
        setSpaceHeld(false)
        return super.resignFirstResponder()
    }

    /// The other half of that: ⌘-Tab away mid-hold and the Space keyUp goes to the app that took over,
    /// while WE keep first responder (a window doesn't resign its responder just for stopping being key)
    /// — so resignFirstResponder above never runs and the pan would stay armed on return.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResignedKey(_ note: Notification) { setSpaceHeld(false) }

    /// Layered Esc, mirroring the panel's: dismiss the most transient thing first and only reach the
    /// editor's discard confirmation once the canvas itself has nothing left to close. Esc is no
    /// longer the Close button's key equivalent precisely so the earlier rungs get their turn.
    override func cancelOperation(_ sender: Any?) {
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            NSColorPanel.shared.orderOut(nil)
            return
        }
        if selectedID != nil {
            selectedID = nil
            onSelectionChange?()
            needsDisplay = true
            return
        }
        onEscape?()
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
