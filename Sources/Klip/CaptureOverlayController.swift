import AppKit

/// Shield-level window that CAN become key (unlike a plain borderless NSWindow, which by default
/// never receives keyboard events → Esc would not cancel). Required so keyboard cancellation works
/// while the window sits at the system shield level.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless full-screen window that shows the frozen, dimmed capture and lets
/// the user drag out a region. On release, it crops and returns an NSImage of the chosen area.
final class CaptureOverlayController {
    private var window: NSWindow?
    private let shot: DisplayShot
    private let onComplete: (NSImage?) -> Void
    private var resolved = false               // avoids double-dismiss / firing onComplete twice
    private var escMonitor: Any?               // Esc backup while Klip is active (see present() for the limit)

    init(shot: DisplayShot, onComplete: @escaping (NSImage?) -> Void) {
        self.shot = shot
        self.onComplete = onComplete
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
        win.setFrame(frame, display: true)
        // Ease the overlay in instead of snapping the frozen frame onto the screen.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        win.alphaValue = reduceMotion ? 1 : 0
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }
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
        // A capture should feel instant (the flash already confirmed it): close immediately.
        // A cancel eases out so the frozen frame doesn't just blink away.
        if image == nil, let win, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                win.animator().alphaValue = 0
            }, completionHandler: { win.orderOut(nil) })
        } else {
            win?.orderOut(nil)
        }
        onComplete(image)
    }
}

/// View that draws the frozen capture, the dimming, the selection, and the dimensions badge.
private final class CaptureOverlayView: NSView {
    private let shot: DisplayShot
    private let onSelect: (NSRect) -> Void
    private let onCancel: () -> Void

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var lastDragPoint: NSPoint?         // current mouse position during the drag
    private var shiftHeld = false               // Shift = constrain selection to a square
    private var spaceHeld = false               // Space = move the in-progress selection
    private let bgImage: NSImage
    /// Marching-ants phase: advanced by a timer while a selection exists (skipped under Reduce Motion).
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?
    /// Mouse position while roaming (before the drag): drives the x,y crosshair badge.
    private var hoverPoint: NSPoint?
    /// 1 → 0 white flash over the selection right after mouse-up, confirming the capture.
    private var flashAlpha: CGFloat = 0
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    /// The classic animated dashed border. Runs only while a selection exists.
    private func setAnts(running: Bool) {
        if running, antsTimer == nil, !reduceMotion {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.antsPhase += 0.6
                    self.needsDisplay = true
                }
            }
            RunLoop.main.add(t, forMode: .common)
            antsTimer = t
        } else if !running {
            antsTimer?.invalidate(); antsTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background: the frozen capture — kept fully legible (Shottr-style). Blacking the whole
        // screen out made every capture feel like a modal interruption; the crosshair + hint pill
        // already signal the mode.
        bgImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        guard currentRect.width > 0, currentRect.height > 0 else {
            drawHint()               // no selection yet: explain what to do
            drawCursorCoordinates()  // …and show where the crosshair sits, in real pixels
            return
        }

        // Once a drag starts, a SOFT outside dim makes the selection pop without hiding the screen.
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        // "Hole": repaint the selected area without dimming.
        bgImage.draw(in: currentRect, from: pixelSourceRect(for: currentRect), operation: .copy, fraction: 1)

        // Selection border: a solid hairline underneath + animated marching ants on top,
        // so the marquee reads on any background and feels alive (Shottr-style).
        let borderRect = currentRect.insetBy(dx: -0.5, dy: -0.5)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let base = NSBezierPath(rect: borderRect)
        base.lineWidth = 1.5
        base.stroke()
        NSColor.controlAccentColor.setStroke()
        let ants = NSBezierPath(rect: borderRect)
        ants.lineWidth = 1.5
        ants.setLineDash([6, 4], count: 2, phase: antsPhase)
        ants.stroke()

        // Capture-confirm flash: a brief white pulse over the region right after mouse-up.
        if flashAlpha > 0 {
            NSColor.white.withAlphaComponent(0.28 * flashAlpha).setFill()
            currentRect.fill(using: .sourceOver)
        }

        drawDimensionBadge(for: currentRect)
    }

    /// Source rect (in image points, bottom-left origin) corresponding to the view area.
    private func pixelSourceRect(for rect: NSRect) -> NSRect { rect }

    /// Centered hint shown while the user hasn't dragged anything yet (so the overlay is self-explanatory).
    private func drawHint() {
        let text = L10n.t("capture.hint")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 18, padY: CGFloat = 11
        let pill = NSRect(x: bounds.midX - (size.width + padX * 2) / 2,
                          y: bounds.midY - (size.height + padY * 2) / 2,
                          width: size.width + padX * 2, height: size.height + padY * 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attrs)
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
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad / 2), withAttributes: attrs)
    }

    private func drawDimensionBadge(for rect: NSRect) {
        let wPx = Int(rect.width * shot.scale)
        let hPx = Int(rect.height * shot.scale)
        let label = "\(wPx) × \(hPx)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
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

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad / 2), withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = startPoint
        shiftHeld = event.modifierFlags.contains(.shift)
        currentRect = .zero
        hoverPoint = nil
        setAnts(running: true)
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
        updateSelection()
    }

    /// Recomputes the selection from anchor + current mouse point, applying the
    /// Shift square constraint. Called from mouseDragged AND flagsChanged so
    /// pressing/releasing Shift updates the rect without needing mouse movement.
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
        currentRect = NSRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy),
                             width: abs(dx), height: abs(dy))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        lastDragPoint = nil
        setAnts(running: false)
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
