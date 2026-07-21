import AppKit

/// Shield-level window that CAN become key (unlike a plain borderless NSWindow, which by default
/// never receives keyboard events → Esc would not cancel). Required so keyboard cancellation works
/// while the window sits at the system shield level.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless full-screen window that shows the frozen capture (undimmed, ⌘⇧4-style) and lets
/// the user drag out a region. On release, it crops and returns an NSImage of the chosen area.
final class CaptureOverlayController {
    private var window: NSWindow?
    private let shot: DisplayShot
    private let onComplete: (NSImage?) -> Void
    /// Region mode (screen recording): instead of cropping the frozen bitmap, hand back the
    /// selection as TOP-LEFT-origin display points — SCStreamConfiguration.sourceRect's space.
    /// nil rect = cancelled. The frozen frame is still shown for picking; the recording that
    /// follows captures the live screen.
    private let onRegion: ((NSScreen, CGRect?) -> Void)?
    private var pendingRegion: CGRect?
    private var resolved = false               // avoids double-dismiss / firing onComplete twice
    private var escMonitor: Any?               // Esc backup while Klip is active (see present() for the limit)

    init(shot: DisplayShot, onComplete: @escaping (NSImage?) -> Void) {
        self.shot = shot
        self.onComplete = onComplete
        self.onRegion = nil
    }

    init(shot: DisplayShot, onRegion: @escaping (NSScreen, CGRect?) -> Void) {
        self.shot = shot
        self.onComplete = { _ in }
        self.onRegion = onRegion
    }

    func present() {
        let frame = shot.screen.frame
        let win = ShieldWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.hasShadow = false

        let view = CaptureOverlayView(shot: shot) { [weak self] rectInView in
            self?.finish(selectionInView: rectInView)
        } onCancel: { [weak self] in
            self?.dismiss(nil)
        }
        win.contentView = view
        win.setFrame(frame, display: false)
        // INSTANT, like ⌘⇧4. The overlay draws the frozen frame 1:1 and dims nothing, so it is
        // pixel-identical to the live screen — fading it in animates nothing the eye can see and
        // only delays the crosshair, which is the one thing that says "the tool is armed".
        win.alphaValue = 1
        // PAINT BEFORE SHOWING. Ordering a shield-level, full-screen, non-opaque window in first and
        // letting it draw afterwards puts an unpainted frame on screen — which is exactly the
        // "something pops up and then loads" flicker. Rendering into the backing store first makes
        // the window's very first visible frame the finished one, so it reads as instant, not as a
        // popup that resolves.
        view.display()
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKey()
        win.makeFirstResponder(view)
        self.window = win

        // Esc backup (keyCode 53) for when the contentView isn't first responder but Klip is still active.
        // It's a LOCAL monitor, so it can't fire if the overlay never became active at all — in that case a
        // single click (mouseUp with no drag → onCancel) is the way out, not Esc.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(nil); return nil }
            return event
        }
    }

    /// Converts the selection (points, bottom-left origin of the view) to bitmap pixels
    /// (top-left origin) and crops the CGImage.
    private func finish(selectionInView rect: NSRect) {
        guard !resolved else { return }
        guard rect.width >= 4, rect.height >= 4 else { dismiss(nil); return }
        if onRegion != nil {
            // Flip Y only: view coords are bottom-left points of this display, sourceRect wants
            // top-left points. No scale here — ScreenCaptureKit takes points and we set the
            // pixel dimensions separately.
            pendingRegion = CGRect(x: rect.minX, y: shot.screen.frame.height - rect.maxY,
                                   width: rect.width, height: rect.height)
            dismiss(nil)
            return
        }
        let scale = shot.scale
        let viewH = shot.screen.frame.height
        let imgBounds = CGRect(x: 0, y: 0, width: shot.cgImage.width, height: shot.cgImage.height)
        let px = CGRect(
            x: rect.minX * scale,
            y: (viewH - rect.maxY) * scale,        // flip Y: Cocoa (bottom) → CGImage (top)
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(imgBounds)         // clamp: a selection at the edge must not exceed the bitmap

        guard !px.isNull, px.width >= 1, px.height >= 1,
              let cropped = shot.cgImage.cropping(to: px) else { dismiss(nil); return }
        let image = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        dismiss(image)
    }

    private func dismiss(_ image: NSImage?) {
        guard !resolved else { return }
        resolved = true
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        let win = window
        window = nil
        // Always immediate — same reasoning as the appearance: an undimmed frozen frame looks
        // exactly like the live screen, so a fade-out is 0.12 s of nothing but lag.
        win?.orderOut(nil)
        if let onRegion { onRegion(shot.screen, pendingRegion) } else { onComplete(image) }
    }
}

/// View that draws the frozen capture, the selection, and the dimensions badge.
/// Visual target is the system's ⌘⇧4 marquee: the screen is NOT darkened, the selection is a
/// light translucent wash inside a hairline border, and the readouts are dark capsules.
private final class CaptureOverlayView: NSView {
    private let shot: DisplayShot
    private let onSelect: (NSRect) -> Void
    private let onCancel: () -> Void

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var lastDragPoint: NSPoint?         // current mouse position during the drag
    private var shiftHeld = false               // Shift = constrain selection to a square
    private var optionHeld = false              // Option = resize from the press point (center)
    private var spaceHeld = false               // Space = move the in-progress selection
    private let bgImage: NSImage
    /// Mouse position while roaming (before the drag): drives the x,y crosshair badge.
    private var hoverPoint: NSPoint?
    /// 1 → 0 white flash over the selection right after mouse-up, confirming the capture.
    private var flashAlpha: CGFloat = 0
    /// The hint introduces the modifiers, then gets out of the way. Undimmed, a block that never
    /// leaves reads as a floating button stuck on the user's screen.
    private var hintAlpha: CGFloat = 1
    private var hintTimer: Timer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(shot: DisplayShot, onSelect: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.shot = shot
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.bgImage = NSImage(cgImage: shot.cgImage,
                               size: NSSize(width: shot.screen.frame.width, height: shot.screen.frame.height))
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    /// Our own crosshair instead of `NSCursor.crosshair`. The system one is a thin BLACK cross with
    /// no outline: measured against backdrops it holds up on light content but collapses to ~9%
    /// contrast on a dark editor or photo — you lose the cursor exactly when you are trying to aim.
    /// A black outline around a white core stays ≥25% on white, light, mid-grey and near-black, and
    /// the extra size makes it readable without hunting. The centre gap keeps the target pixel clear.
    private static let crosshairCursor: NSCursor = {
        let size: CGFloat = 28, gap: CGFloat = 3.5
        let c = size / 2
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        func arms(width: CGFloat, color: NSColor) {
            color.setStroke()
            let p = NSBezierPath()
            p.lineWidth = width
            p.lineCapStyle = .butt
            p.move(to: NSPoint(x: 0, y: c));       p.line(to: NSPoint(x: c - gap, y: c))
            p.move(to: NSPoint(x: c + gap, y: c)); p.line(to: NSPoint(x: size, y: c))
            p.move(to: NSPoint(x: c, y: 0));       p.line(to: NSPoint(x: c, y: c - gap))
            p.move(to: NSPoint(x: c, y: c + gap)); p.line(to: NSPoint(x: c, y: size))
            p.stroke()
        }
        arms(width: 3.5, color: .black)   // outline first…
        arms(width: 1.5, color: .white)   // …then the core on top of it
        img.unlockFocus()
        // Symmetric image, so the hotspot is the centre in either coordinate convention.
        return NSCursor(image: img, hotSpot: NSPoint(x: c, y: c))
    }()

    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.crosshairCursor) }

    /// Our own mouse-moved area, tracked so we can replace ONLY it on relayout.
    private var mouseArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only OUR area. `trackingAreas.forEach(removeTrackingArea)` also destroys the
        // tracking area AppKit installs for `toolTip` (same bug that ate the Snap toolbar's help
        // text). The overlay has no tooltips today, so nothing is broken right now — but the
        // blanket sweep is what makes adding one later fail silently.
        if let a = mouseArea { removeTrackingArea(a); mouseArea = nil }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        mouseArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    /// Arms the hint's auto-fade. Called once the view is on screen so the dwell starts when the
    /// user can actually see it.
    deinit { hintTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, hintTimer == nil else { return }
        if reduceMotion { return }   // no timed motion: the hint just stays until the drag starts
        hintTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginHintFade() }
        }
    }

    private func beginHintFade() {
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hintAlpha -= 0.055
                if self.hintAlpha <= 0 {
                    self.hintAlpha = 0
                    self.hintTimer?.invalidate(); self.hintTimer = nil
                }
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background: the frozen capture, drawn 1:1. bgImage is built at `screen.frame.size` POINTS
        // from a bitmap captured at `points × backingScaleFactor` PIXELS (see ScreenCapturer), and
        // `bounds` is that same point size on a backing store of that same scale — so this is an
        // identity blit, no resampling. That exactness is load-bearing now that nothing is dimmed:
        // any scaling here would show up as a blurry "screen" the moment the overlay appears.
        bgImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        guard currentRect.width > 0, currentRect.height > 0 else {
            drawHint()               // no selection yet: explain what to do
            drawCursorCoordinates()  // …and show where the crosshair sits, in real pixels
            return
        }

        // NO outside dim. ⌘⇧4 never darkens the screen, and neither do we — the wash + border below
        // is the whole signal. (The old 18% black veil is what users read as "the screen went dark".)

        // Selection interior: a NEUTRAL GRAY veil. Measured, not guessed — white@0.14 (the first
        // attempt) renders 0.0% luminance difference over a white page and 1.2% over a light chat
        // background, i.e. invisible exactly where captures usually happen. Mid-gray at 0.25 reads
        // ~13% on white, ~12% on a light chat, ~11% on a dark editor. Its one weak spot is a
        // mid-gray backdrop (~1%), where the double-stroke border below carries the edge on its own.
        NSColor(white: 0.5, alpha: 0.25).setFill()
        currentRect.fill(using: .sourceOver)

        // Border: two ONE-DEVICE-PIXEL strokes — a dark hairline immediately outside, a white line
        // immediately inside — so the edge reads on white desktops and dark ones alike.
        // currentRect is already snapped to the device-pixel grid (see pixelSnapped), so insetting by
        // half a device pixel puts each stroke's centerline through the middle of one physical pixel
        // row: crisp, never straddling two. ponytail: no marching ants. Undimmed, an animated accent
        // dash reads as noise on top of live-looking content, and it cost a 30 Hz full-screen redraw.
        let px = 1 / max(shot.scale, 1)
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let outer = NSBezierPath(rect: currentRect.insetBy(dx: -px / 2, dy: -px / 2))
        outer.lineWidth = px
        outer.stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let inner = NSBezierPath(rect: currentRect.insetBy(dx: px / 2, dy: px / 2))
        inner.lineWidth = px
        inner.stroke()

        // Capture-confirm flash: a brief white pulse over the region right after mouse-up.
        if flashAlpha > 0 {
            NSColor.white.withAlphaComponent(0.28 * flashAlpha).setFill()
            currentRect.fill(using: .sourceOver)
        }

        drawDimensionBadge(for: currentRect)
    }

    /// Hint bar shown while the user hasn't dragged anything yet (so the overlay is self-explanatory).
    private func drawHint() {
        let text = L10n.t("capture.hint") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(hintAlpha)
        ]
        let size = text.size(withAttributes: attrs)
        let legend = legendSize
        let lineGap: CGFloat = 8
        let padX: CGFloat = 16, padY: CGFloat = 12
        let contentW = max(size.width, legend.width)
        let contentH = size.height + lineGap + legend.height
        // Bottom-anchored, not centered. With nothing dimmed the screen has to read as untouched
        // before the drag, and a dark block parked in the middle of the user's content is the one
        // thing left that doesn't. Down here it's a hint bar, out of the way of what you're aiming at.
        let pill = NSRect(x: bounds.midX - (contentW + padX * 2) / 2,
                          y: bounds.minY + 64,
                          width: contentW + padX * 2, height: contentH + padY * 2)
        guard hintAlpha > 0.01 else { return }
        NSColor.black.withAlphaComponent(0.7 * hintAlpha).setFill()
        // Two lines make this a block, not a chip: a full-capsule radius (right when the hint was one
        // line tall) would bow the sides out around the text. Rounded rect, concentric with nothing else.
        NSBezierPath(roundedRect: pill, xRadius: 16, yRadius: 16).fill()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.maxY - padY - size.height),
                  withAttributes: attrs)
        drawModifierLegend(at: NSPoint(x: pill.midX - legend.width / 2, y: pill.minY + padY))
    }

    // MARK: - Modifier legend

    private static let legendFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let legendKeyGap: CGFloat = 3     // key glyph → the symbol that says what it does
    private let legendItemGap: CGFloat = 14   // between the three pairs

    /// (key glyph, its measured width, the SF Symbol for what the key does). Deliberately wordless:
    /// ⇧ square / ⌥ from-center / ␣ move are the three modifiers this overlay understands, and glyphs
    /// say all of it without a sentence to translate per locale. Built once — the pill redraws on
    /// every pointer move before the drag starts.
    private lazy var legendPieces: [(key: NSString, width: CGFloat, image: NSImage?)] = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let items = [("⇧", "square"),
                     ("⌥", "dot.circle"),
                     ("␣", "arrow.up.and.down.and.arrow.left.and.right")]
        return items.map { pair in
            let key = pair.0 as NSString
            let image = NSImage(systemSymbolName: pair.1, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            // The palette config already bakes the white in; clearing the template flag keeps a
            // template repaint from putting the glyph back to black over the dark pill.
            image?.isTemplate = false
            return (key: key,
                    width: key.size(withAttributes: [.font: Self.legendFont]).width,
                    image: image)
        }
    }()

    private var legendSize: NSSize {
        let keyHeight = Self.legendFont.ascender - Self.legendFont.descender
        let height = max(keyHeight, legendPieces.compactMap { $0.image?.size.height }.max() ?? 0)
        var width: CGFloat = 0
        for (i, piece) in legendPieces.enumerated() {
            if i > 0 { width += legendItemGap }
            width += piece.width + legendKeyGap + (piece.image?.size.width ?? 0)
        }
        return NSSize(width: width, height: height)
    }

    private func drawModifierLegend(at origin: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.legendFont,
            .foregroundColor: NSColor.white
        ]
        let height = legendSize.height
        let keyHeight = Self.legendFont.ascender - Self.legendFont.descender
        var x = origin.x
        for (i, piece) in legendPieces.enumerated() {
            if i > 0 { x += legendItemGap }
            piece.key.draw(at: NSPoint(x: x, y: origin.y + (height - keyHeight) / 2), withAttributes: attrs)
            x += piece.width + legendKeyGap
            guard let img = piece.image else { continue }
            img.draw(in: NSRect(x: x, y: origin.y + (height - img.size.height) / 2,
                                width: img.size.width, height: img.size.height))
            x += img.size.width
        }
    }

    /// Small "x, y" pixel readout that follows the crosshair before any drag starts.
    private func drawCursorCoordinates() {
        guard let p = hoverPoint else { return }
        let label = "\(Int(p.x * shot.scale)), \(Int((bounds.height - p.y) * shot.scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 5
        var badge = NSRect(x: p.x + 14, y: p.y - textSize.height - 12,
                           width: textSize.width + pad * 2, height: textSize.height + pad)
        badge.origin.x = min(badge.origin.x, bounds.maxX - badge.width - 4)
        badge.origin.y = max(badge.origin.y, bounds.minY + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad / 2), withAttributes: attrs)
    }

    private func drawDimensionBadge(for rect: NSRect) {
        let wPx = Int(rect.width * shot.scale)
        let hPx = Int(rect.height * shot.scale)
        let label = "\(wPx) × \(hPx)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        var badge = NSRect(x: rect.minX, y: rect.maxY + 6,
                           width: textSize.width + pad * 2, height: textSize.height + pad)
        // If it doesn't fit above, place it inside/below.
        if badge.maxY > bounds.maxY { badge.origin.y = rect.minY - badge.height - 6 }
        if badge.minY < bounds.minY { badge.origin.y = rect.minY + 6 }
        badge.origin.x = max(bounds.minX, min(badge.origin.x, bounds.maxX - badge.width))

        // Dark translucent capsule + white monospaced digits, same recipe as the x,y readout.
        // Was a solid accent fill to match the accent marching ants; those are gone, and against an
        // undimmed screen a saturated chip shouted louder than the region it was measuring.
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad / 2), withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        hintTimer?.invalidate(); hintTimer = nil; hintAlpha = 0   // dragging: the hint's job is done
        startPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = startPoint
        shiftHeld = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        currentRect = .zero
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if spaceHeld, let last = lastDragPoint, var start = startPoint {
            // Space = move: translate the anchor by the mouse delta so the whole
            // selection slides instead of resizing (size — square or not — is preserved).
            start.x += p.x - last.x
            start.y += p.y - last.y
            startPoint = start
        }
        lastDragPoint = p
        shiftHeld = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        updateSelection()
    }

    /// Recomputes the selection from anchor + current mouse point, applying the Shift square and
    /// Option from-center constraints. Called from mouseDragged AND flagsChanged so pressing or
    /// releasing a modifier updates the rect without needing mouse movement.
    private func updateSelection() {
        guard let start = startPoint, let p = lastDragPoint else { return }
        var dx = p.x - start.x
        var dy = p.y - start.y
        if shiftHeld {
            // Shift = square: smaller extent wins, drag direction preserved.
            let side = min(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect: NSRect
        if optionHeld {
            // Option = the press point is the CENTER: mirror the drag to the opposite side, so the
            // selection grows both ways instead of anchoring a corner.
            rect = NSRect(x: start.x - abs(dx), y: start.y - abs(dy),
                          width: abs(dx) * 2, height: abs(dy) * 2)
        } else {
            rect = NSRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy),
                          width: abs(dx), height: abs(dy))
        }
        // Snap BEFORE clamping: `bounds` already sits on the pixel grid, so the intersection keeps
        // the alignment, while snapping afterwards could round a clamped edge back outside the screen.
        currentRect = pixelSnapped(rect)
        // Space-move and multi-monitor drags can push the rect past the screen: clamp it here so
        // finish() never sizes the NSImage from a rect larger than the pixels it actually crops.
        currentRect = currentRect.intersection(bounds)
        needsDisplay = true
    }

    /// Rounds the rect onto the display's device-pixel grid. Without this the badge reads
    /// `Int(width * scale)` (truncating) while finish() crops `.integral` (rounding outward), so a
    /// selection landing on a half-pixel would export one pixel wider than the badge promised.
    private func pixelSnapped(_ rect: NSRect) -> NSRect {
        let scale = shot.scale
        guard scale > 0 else { return rect }
        return NSRect(x: (rect.minX * scale).rounded() / scale,
                      y: (rect.minY * scale).rounded() / scale,
                      width: (rect.width * scale).rounded() / scale,
                      height: (rect.height * scale).rounded() / scale)
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        lastDragPoint = nil
        guard rect.width >= 4, rect.height >= 4 else { onCancel(); return }
        guard !reduceMotion else { onSelect(rect); return }
        // Confirm visually before handing off: a ~120ms white pulse over the captured region.
        flashAlpha = 1
        needsDisplay = true
        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = (CACurrentMediaTime() - start) / 0.12
                self.flashAlpha = max(0, 1 - CGFloat(progress))
                self.needsDisplay = true
                if progress >= 1 { timer.invalidate(); self.onSelect(rect) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    override func flagsChanged(with event: NSEvent) {
        shiftHeld = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        updateSelection()
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }               // Esc
        else if event.keyCode == 49 { spaceHeld = true }    // Space = move selection
        else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
        else { super.keyUp(with: event) }
    }

    /// Esc through the standard responder chain (in addition to keyDown and the safety-net monitor).
    override func cancelOperation(_ sender: Any?) { onCancel() }
}
