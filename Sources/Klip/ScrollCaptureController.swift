import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Why a scrolling capture ended without an image (`onFinished(nil, failure)`).
/// nil failure + nil image = the user cancelled — the caller should stay SILENT (no error toast).
enum ScrollCaptureFailure {
    /// Synthetic scrolling needs Accessibility, same privilege as auto-paste. The caller should
    /// prompt via `Paster.ensureAccessibilityPermission(prompt: true)` and explain.
    case needsAccessibility
    /// Setup or capture broke (no screen-recording permission, display vanished, nothing stitched).
    case failed
}

/// Fully automatic scrolling capture: Klip scrolls the target app ITSELF — synthetic scroll-wheel
/// events at the region's center — re-shoots the region after each step settles, and stitches the
/// frames into one tall image. It finishes ON ITS OWN when the content stops moving (end of page)
/// or a cap is hit; the user only ever needs the pill's Cancel (or the caller-wired hotkeys).
///
/// Stitching uses KNOWN-DELTA matching: we posted the scroll, so the expected pixel offset is
/// known, and the search runs only in a narrow window around it. That kills the false matches a
/// full-range search produced on repetitive content — and no seam is ever drawn: an unmatchable
/// frame ends the capture with what exists instead of appending garbage.
///
/// `region` is TOP-LEFT display-local points (SCStreamConfiguration.sourceRect's space, exactly
/// what CaptureOverlayController's region mode returns). Ownership: keep the controller alive
/// until `onFinished` fires — it fires exactly once, on the main actor.
@MainActor
final class ScrollCaptureController: NSObject {

    // MARK: - Tuning

    /// Scroll step as a fraction of the region height: 60% keeps a 40% overlap for matching.
    private static let stepFraction: CGFloat = 0.6
    /// One step is posted as several small wheel events a few ms apart — some apps clamp a single
    /// giant delta, and chunks ride the same smooth-scroll path a real trackpad flick does.
    private static let chunksPerStep = 3
    private static let chunkGapNs: UInt64 = 8_000_000
    /// Wait after posting a step before shooting: covers the target app's smooth-scroll animation
    /// and elastic bounce. Frames taken mid-animation stitch garbage.
    // ponytail: fixed 450 ms — an adaptive "wait until two consecutive shots match" loop is the
    // upgrade if slow-animating apps (heavy web pages) misalign in practice.
    private static let settleDelay: TimeInterval = 0.45
    /// Half-width of the offset search window around the expected (posted) delta, in pixels.
    /// Wide enough for scroll-speed wobble; partial last steps near the page bottom stay OUT of
    /// it on purpose — the single full-range retry catches those.
    private static let searchWindowPx = 120
    /// Minimum rows two frames must share for an offset match to mean anything.
    private static let minOverlapPx = 60
    /// A matched offset below this means the content didn't actually move — end of page.
    private static let minScrollPx = 8
    /// Mean per-row luminance difference (0–255 scale) above which a candidate offset is no match.
    // ponytail: empirical — antialiased real matches sit under ~3, unrelated content far above 10.
    private static let matchThreshold: Float = 6.0
    /// Two signatures within this per-row epsilon are the same frame (end-of-page detector).
    private static let identicalEps: Float = 0.5
    /// Manual fallback cadence: how often we re-shoot while the USER scrolls, and how many
    /// consecutive unchanged shots mean "they have stopped".
    private static let manualPollDelay: Double = 0.45
    private static let manualIdleTicks = 9        // ≈4 s of stillness
    /// Hard canvas cap (~128 MB at a 2 000 px-wide region). Hitting it AUTO-FINISHES with what
    /// exists — a capture that can't be saved at all is the documented failure to avoid.
    private static let maxCanvasHeightPx = 16_000
    private static let maxFrames = 120
    /// Horizontal downsample width of the per-row luminance signature.
    private static let signatureWidth = 64
    /// eventSourceUserData tag on every synthetic scroll, so any Klip scroll monitor (none today)
    /// can tell our events from the user's. "KLIP" in ASCII.
    private static let syntheticScrollTag: Int64 = 0x4B4C_4950

    // MARK: - State

    private let screen: NSScreen
    private let region: CGRect                     // top-left display-local points
    private let onFinished: (NSImage?, ScrollCaptureFailure?) -> Void

    private var panel: NSPanel?
    private var statusField: NSTextField?
    private var loopTask: Task<Void, Never>?

    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?

    // Stitching state: the canvas content occupies the top `contentHeightPx` rows; offsets chain
    // from the last appended frame's placement, not from the canvas bottom.
    private var canvas: CGContext?
    private var canvasCapacityPx = 0
    private var contentHeightPx = 0
    private var lastFrameTop = 0
    private var frameWidthPx = 0
    private var frameHeightPx = 0
    private var prevSignature: [Float] = []
    private var frameCount = 0
    /// True once auto-scroll proved impossible and the user is driving instead.
    private var manualMode = false

    private var started = false
    private var finished = false

    /// True from start() until the callback fired — the caller's re-entry / toggle check
    /// (⌥⇧S while active = finishNow()).
    var isActive: Bool { started && !finished }

    init(screen: NSScreen, region: CGRect, onFinished: @escaping (NSImage?, ScrollCaptureFailure?) -> Void) {
        self.screen = screen
        self.region = region
        self.onFinished = onFinished
    }

    /// Kicks off the automatic loop. All failure paths (permissions included) report through
    /// `onFinished` asynchronously — never re-entrantly from inside this call.
    func start() {
        guard !started else { return }
        started = true
        loopTask = Task { @MainActor in await self.run() }
    }

    /// User abort (pill button, caller-wired Esc): tears down and reports the SILENT nil/nil.
    func cancel() { finish(nil, nil) }

    /// Flattens what exists right now and finishes (caller-wired ⌥⇧S-again). With nothing stitched
    /// yet it reports `.failed` so the caller can say so.
    func finishNow() {
        guard isActive else { return }
        guard let canvas, contentHeightPx > 0, let full = canvas.makeImage(),
              let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: frameWidthPx,
                                                     height: contentHeightPx))   // top rows = content
        else { finish(nil, .failed); return }
        // Full pixel resolution, point size = pixels / scale (the CaptureOverlayController rule) —
        // wrong size here and the image pastes at 2× on Retina.
        let scale = max(screen.backingScaleFactor, 1)
        finish(NSImage(cgImage: cropped,
                       size: NSSize(width: CGFloat(cropped.width) / scale,
                                    height: CGFloat(cropped.height) / scale)), nil)
    }

    // MARK: - The loop

    private func run() async {
        guard region.width >= 4, region.height >= 4, ScreenCapturer.hasPermission() else {
            finish(nil, .failed); return
        }
        // DELIBERATELY NOT GATED on Paster.hasAccessibilityPermission. That flag is bound to the
        // app's code signature, so a rebuilt/re-signed Klip reads false even while System Settings
        // still lists it as enabled — refusing up front turned a working setup into a hard error.
        // Instead: attempt the scroll, and judge by whether the CONTENT ACTUALLY MOVED. The flag is
        // only consulted afterwards, to explain a failure we really observed.
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !finished else { return }
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID })
            else { finish(nil, .failed); return }
            // Exclude Klip's own windows so the pill never appears in a frame — which is also why
            // the pill's fallback placement over the region can't corrupt output.
            let ownBundleID = Bundle.main.bundleIdentifier
            let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            filter = SCContentFilter(display: display, excludingApplications: ownApps,
                                     exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = region
            let scale = screen.backingScaleFactor
            cfg.width  = Int((region.width  * scale).rounded())
            cfg.height = Int((region.height * scale).rounded())
            cfg.showsCursor = false
            cfg.scalesToFit = false
            config = cfg
        } catch { finish(nil, .failed); return }

        buildPanel()
        warpCursorToRegionCenter()
        guard let first = await capture(), ingest(first) == .appended else {
            finish(nil, .failed); return
        }

        var movedAtLeastOnce = false
        while !finished {
            guard frameCount < Self.maxFrames, contentHeightPx < Self.maxCanvasHeightPx else { break }
            await postScrollStep()
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard !finished else { return }
            guard let frame = await capture() else { break }   // a dead shot ends with what we have
            if ingest(frame) == .endOfPage { break }
            movedAtLeastOnce = true
        }
        // Nothing EVER moved and we are not trusted for Accessibility: our synthetic scrolls went
        // nowhere (CGEvent.post fails SILENTLY when untrusted). Rather than throw the session away,
        // fall back to letting the USER scroll — the stitcher does not care who moved the content.
        // This is what keeps scrolling capture usable on a Mac whose Accessibility entry has gone
        // stale against a rebuilt binary, which is a state the user cannot even see.
        if !movedAtLeastOnce, !Paster.hasAccessibilityPermission {
            await runManualFallback()
            return
        }
        finishNow()   // the headline: end of page / cap reached → the image arrives on its own
    }

    /// Manual mode: Klip stops driving and just watches. Keeps shooting the region while the user
    /// scrolls it themselves, stitching every frame that actually moved, and finishes on its own
    /// once the content has been still for a few seconds (or via Cancel / ⌥⇧S, as always).
    private func runManualFallback() async {
        manualMode = true
        updateStatus()
        var idleTicks = 0
        while !finished {
            guard frameCount < Self.maxFrames, contentHeightPx < Self.maxCanvasHeightPx else { break }
            try? await Task.sleep(nanoseconds: UInt64(Self.manualPollDelay * 1_000_000_000))
            guard !finished else { return }
            guard let frame = await capture() else { break }
            if ingest(frame) == .appended {
                idleTicks = 0
            } else {
                idleTicks += 1
                // Still for long enough that the user is done scrolling — wrap up on our own.
                if idleTicks >= Self.manualIdleTicks { break }
            }
        }
        finishNow()
    }

    private func capture() async -> CGImage? {
        guard let filter, let config else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Synthetic scrolling

    /// Region center in GLOBAL top-left (CG) coordinates: CGDisplayBounds is already that space,
    /// and `region` is display-local top-left — a plain offset, no Y flip anywhere.
    private var regionCenterGlobal: CGPoint {
        let b = CGDisplayBounds(screen.displayID)
        return CGPoint(x: b.origin.x + region.midX, y: b.origin.y + region.midY)
    }

    /// Scroll routing follows the CURSOR on macOS, not the event's location field — warp it into
    /// the region once so the app under the region receives our wheel events.
    private func warpCursorToRegionCenter() {
        _ = CGWarpMouseCursorPosition(regionCenterGlobal)
        // Warping detaches the cursor from mouse deltas until re-associated; leave the mouse usable.
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Points per wheel chunk; one step = `chunksPerStep` of these. Pixel-unit wheel events move
    /// content 1 POINT per unit, so the expected image offset is the posted points × scale.
    private var chunkPoints: Int32 {
        Int32(max(1, Int(region.height * Self.stepFraction) / Self.chunksPerStep))
    }

    private var expectedOffsetPx: Int {
        Int((CGFloat(Int(chunkPoints) * Self.chunksPerStep) * screen.backingScaleFactor).rounded())
    }

    private func postScrollStep() async {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let center = regionCenterGlobal
        for _ in 0..<Self.chunksPerStep {
            // Negative wheel1 = scroll DOWN (view content further down), pixel (continuous) units.
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                                  wheel1: -chunkPoints, wheel2: 0, wheel3: 0) else { continue }
            e.location = center
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticScrollTag)
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: Self.chunkGapNs)
        }
    }

    // MARK: - Stitching

    private enum StitchOutcome { case appended, endOfPage }

    /// Frame 0 anchors; every later frame is matched at its KNOWN delta first, one full-range
    /// retry after, and otherwise ends the capture. Never a seam: unmatched = done, not degraded.
    private func ingest(_ frame: CGImage) -> StitchOutcome {
        guard !finished, let sig = rowSignature(of: frame) else { return .endOfPage }

        if prevSignature.isEmpty {
            frameWidthPx = frame.width
            frameHeightPx = frame.height
            guard ensureCanvas(heightPx: frameHeightPx) else { return .endOfPage }
            draw(frame, atTop: 0)
            contentHeightPx = frameHeightPx
            lastFrameTop = 0
            prevSignature = sig
            frameCount = 1
            updateStatus()
            return .appended
        }

        // Identical frame = the scroll moved nothing = END OF PAGE. This is the auto-finish
        // trigger; the row signature doubles as the cheap digest.
        if sig.count == prevSignature.count,
           zip(sig, prevSignature).allSatisfy({ abs($0 - $1) < Self.identicalEps }) {
            return .endOfPage
        }

        let expected = expectedOffsetPx
        var match = bestOffset(prev: prevSignature, next: sig,
                               window: (expected - Self.searchWindowPx)...(expected + Self.searchWindowPx))
        if match.error > Self.matchThreshold {
            // Partial last step near the page bottom, or the user scrolled too: one full retry.
            match = bestOffset(prev: prevSignature, next: sig, window: nil)
        }
        // Still nothing acceptable, or the content barely moved (blinking caret at the bottom):
        // finish with what exists. minScrollPx applies to BOTH searches — an accepted near-zero
        // offset would stack a duplicate.
        guard match.error <= Self.matchThreshold, match.offset >= Self.minScrollPx else {
            return .endOfPage
        }

        let newTop = lastFrameTop + match.offset
        guard newTop + frameHeightPx <= Self.maxCanvasHeightPx,
              ensureCanvas(heightPx: newTop + frameHeightPx) else { return .endOfPage }
        draw(frame, atTop: newTop)     // whole frame: overlap rows overwrite identical content
        contentHeightPx = newTop + frameHeightPx
        lastFrameTop = newTop
        prevSignature = sig
        frameCount += 1
        updateStatus()
        return .appended
    }

    /// Per-row luminance signature: the frame drawn into a `signatureWidth`-wide grayscale bitmap
    /// (Core Graphics does luminance conversion AND horizontal averaging in one pass), one Float
    /// mean per row, top-down — the same row order as CGImage cropping space.
    private func rowSignature(of image: CGImage) -> [Float]? {
        let w = Self.signatureWidth
        let h = image.height
        guard h > 0, image.width > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low    // averaging is all a signature needs
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sig = [Float](repeating: 0, count: h)
        for y in 0..<h {
            var sum = 0
            let row = y * w                    // bitmap row 0 = image TOP row
            for x in 0..<w { sum += Int(buf[row + x]) }
            sig[y] = Float(sum) / Float(w)
        }
        return sig
    }

    /// Best downward offset aligning `next` under `prev`: mean absolute row difference over the
    /// overlap, lowest wins; ascending iteration + strict `<` prefers the smallest offset on ties.
    /// `window` restricts the search (known-delta pass); nil = full range (the retry).
    // ponytail: plain O(H·W) loop — the windowed pass is ~240 offsets, the full retry is rare.
    // Swap in vDSP if profiling ever shows this on the loop's critical path.
    private func bestOffset(prev: [Float], next: [Float],
                            window: ClosedRange<Int>?) -> (offset: Int, error: Float) {
        let h = min(prev.count, next.count)
        let maxOffset = max(0, h - Self.minOverlapPx)
        let lo = max(0, window?.lowerBound ?? 0)
        let hi = min(maxOffset, window?.upperBound ?? maxOffset)
        var best = (offset: 0, error: Float.greatestFiniteMagnitude)
        guard lo <= hi else { return best }
        for offset in lo...hi {
            let overlap = h - offset
            var sum: Float = 0
            for y in 0..<overlap { sum += abs(next[y] - prev[y + offset]) }
            let err = sum / Float(overlap)
            if err < best.error { best = (offset, err) }
        }
        return best
    }

    // MARK: - Canvas

    /// Grows the canvas (doubling, capped) so appends stay amortized-cheap. Content always sits at
    /// the TOP of the context, which after `makeImage()` is CGImage row 0 — the final crop is
    /// simply the top `contentHeightPx` rows.
    private func ensureCanvas(heightPx needed: Int) -> Bool {
        if canvas != nil, needed <= canvasCapacityPx { return true }
        // `max(cap, needed)` lets a single frame taller than the cap through (8K portrait region):
        // frame 0 must always fit or there is nothing to save at all.
        let ceiling = max(Self.maxCanvasHeightPx, needed)
        let capacity = canvas == nil
            ? min(max(needed, frameHeightPx * 4), ceiling)
            : min(max(canvasCapacityPx * 2, needed), ceiling)
        guard let ctx = CGContext(data: nil, width: frameWidthPx, height: capacity,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        if let old = canvas, let snapshot = old.makeImage() {
            // Keep existing content at the TOP of the taller context (CG y grows upward).
            ctx.draw(snapshot, in: CGRect(x: 0, y: capacity - canvasCapacityPx,
                                          width: frameWidthPx, height: canvasCapacityPx))
        }
        canvas = ctx
        canvasCapacityPx = capacity
        return true
    }

    /// `top` is measured from the canvas TOP; CG contexts are bottom-up, hence the flip.
    private func draw(_ image: CGImage, atTop top: Int) {
        canvas?.draw(image, in: CGRect(x: 0, y: canvasCapacityPx - top - frameHeightPx,
                                       width: frameWidthPx, height: frameHeightPx))
    }

    // MARK: - Progress pill

    private func updateStatus() {
        // Manual mode has to SAY so — otherwise the user waits for a scroll that will never come.
        statusField?.stringValue = manualMode
            ? String(format: L10n.t("scroll.status.manual"), frameCount)
            : String(format: L10n.t("scroll.status"), frameCount, contentHeightPx)
    }

    /// Passive progress + one Cancel. ToastHUD's exact action-button recipe — the shipped,
    /// known-clickable combination of nonactivating borderless panel + plain target/action button.
    private func buildPanel() {
        // Sized against the widest realistic status so the pill never grows mid-capture.
        let status = NSTextField(labelWithString: String(format: L10n.t("scroll.status"), 888, 88_888))
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail

        let cancel = NSButton(title: L10n.t("common.cancel"), target: self,
                              action: #selector(cancelPressed))
        cancel.isBordered = false
        cancel.controlSize = .small
        // Inline text action reads as an accent link (design language): borderless, accent, semibold.
        cancel.attributedTitle = NSAttributedString(string: L10n.t("common.cancel"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ])

        let stack = NSStackView(views: [status, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        // Apple's panel recipe (backdrop + sheen + rim), same as ToastHUD.
        let fx = GlassPanelView(frame: .zero, radius: 12)
        let contentBox = NSView()
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentBox.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor, constant: -9),
        ])
        fx.setContent(contentBox)

        let fit = contentBox.fittingSize
        let size = NSSize(width: max(fit.width, 200), height: fit.height)
        status.stringValue = "…"          // real numbers arrive with frame 0, a beat later

        // .nonactivatingPanel is load-bearing: the capture scrolls the TARGET app, so a click on
        // Cancel must never pull focus to Klip.
        let p = NSPanel(contentRect: panelFrame(for: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = false           // the Cancel button must take the click
        p.becomesKeyOnlyIfNeeded = true
        // NSPanel hides itself when the app deactivates BY DEFAULT — and Klip is inactive for this
        // whole flow. Without this the pill vanishes the moment the target app is frontmost.
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p
        statusField = status
    }

    /// Below the region → above → beside (right, then left) → bottom-right of the screen. The last
    /// fallback (region ≈ whole screen) can overlap the region visually, but never the OUTPUT —
    /// the content filter already excludes Klip's windows from every frame.
    private func panelFrame(for size: NSSize) -> NSRect {
        let sf = screen.frame
        let vis = screen.visibleFrame
        let margin: CGFloat = 8, gap: CGFloat = 12
        // Region (top-left display-local points) → global Cocoa bottom-left coordinates.
        let regionCocoa = NSRect(x: sf.minX + region.minX, y: sf.maxY - region.maxY,
                                 width: region.width, height: region.height)
        let clampedX = max(vis.minX + margin, min(regionCocoa.minX, vis.maxX - size.width - margin))
        let sideY = max(vis.minY + margin,
                        min(regionCocoa.midY - size.height / 2, vis.maxY - size.height - margin))
        let candidates = [
            NSRect(x: clampedX, y: regionCocoa.minY - gap - size.height,
                   width: size.width, height: size.height),                              // below
            NSRect(x: clampedX, y: regionCocoa.maxY + gap,
                   width: size.width, height: size.height),                              // above
            NSRect(x: regionCocoa.maxX + gap, y: sideY,
                   width: size.width, height: size.height),                              // right
            NSRect(x: regionCocoa.minX - gap - size.width, y: sideY,
                   width: size.width, height: size.height),                              // left
        ]
        for c in candidates where vis.contains(c) && !c.intersects(regionCocoa) { return c }
        return NSRect(x: vis.maxX - size.width - 16, y: vis.minY + 16,
                      width: size.width, height: size.height)
    }

    @objc private func cancelPressed() { cancel() }

    // MARK: - Finish

    /// Single exit: idempotent teardown (loop cancelled, panel closed, buffers dropped), then the
    /// callback — exactly once. (nil, nil) = silent cancel.
    private func finish(_ image: NSImage?, _ failure: ScrollCaptureFailure?) {
        guard !finished else { return }
        finished = true
        loopTask?.cancel(); loopTask = nil
        panel?.orderOut(nil)
        panel = nil
        statusField = nil
        canvas = nil
        prevSignature = []
        onFinished(image, failure)
    }
}
