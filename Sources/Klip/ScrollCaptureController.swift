import AppKit
import ScreenCaptureKit

/// Scrolling-capture engine: the user scrolls the TARGET app themselves, Klip re-shoots the chosen
/// region after every scroll settles and stitches the frames into one tall image.
///
/// Manual-first on purpose (CleanShot shipped manual 4 years before auto-scroll): synthesizing
/// scroll events fights momentum, elastic bounce and per-app scroll speeds; watching the user's own
/// scrolls sidesteps all of it. The caller runs the region-selection overlay and hands over
/// `screen` + `region` (TOP-LEFT display-local points — SCStreamConfiguration.sourceRect's space,
/// exactly what CaptureOverlayController's region mode returns).
///
/// Ownership: keep the controller alive until `onFinished` fires (same contract as
/// CaptureOverlayController). `onFinished(nil)` = cancelled or failed; otherwise the stitched image
/// at full pixel resolution with the correct point size.
@MainActor
final class ScrollCaptureController: NSObject {

    // MARK: - Tuning

    /// Wait this long after the LAST scroll event before shooting: momentum frames stitch garbage,
    /// so a frame is only worth taking once the content has settled.
    private static let settleDelay: TimeInterval = 0.25
    /// Minimum rows two frames must share for an offset match to mean anything — below this the
    /// "overlap" is noise and the search would happily match anything.
    private static let minOverlapPx = 60
    /// A best offset smaller than this is the same content (sub-scroll jitter, elastic bounce):
    /// skip the frame instead of stacking a near-duplicate.
    private static let minScrollPx = 8
    /// Mean per-row luminance difference (0–255 scale) above which the best offset is a NO MATCH.
    // ponytail: empirical threshold — antialiasing keeps real matches under ~3, unrelated content
    // sits far above 10. Tune here if real pages misbehave; the failure mode is a visible seam,
    // never an abort.
    private static let matchThreshold: Float = 6.0
    /// Hard canvas cap. 16 000 px × a ~2 000 px-wide region × 4 B/px ≈ 128 MB — the ceiling that
    /// keeps a runaway capture from eating memory. On hitting it we STOP capturing and let Done
    /// save what exists (a too-long capture that can't be saved at all is the documented complaint).
    private static let maxCanvasHeightPx = 16_000
    /// Frame cap for the same reason (each append is a full-region draw + signature pass).
    private static let maxFrames = 120
    /// Horizontal downsample width for the per-row luminance signature. 64 samples per row is
    /// plenty to discriminate rows while keeping the O(H²) offset search cheap.
    private static let signatureWidth = 64
    /// Height of the visible seam drawn when a frame could not be matched (degraded output beats
    /// aborting — the spec is explicit).
    private static let seamHeightPx = 2

    // MARK: - State

    private let screen: NSScreen
    private let region: CGRect                     // top-left display-local points
    private let onFinished: (NSImage?) -> Void

    private var panel: NSPanel?
    private var statusField: NSTextField?
    private var scrollMonitors: [Any] = []         // global + local scroll-wheel monitors
    private var escMonitor: Any?
    private var debounceTimer: Timer?

    // Capture plumbing, resolved once in start() and reused for every frame.
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var isCapturing = false
    /// A scroll settled while a capture was still in flight: re-shoot as soon as it lands, so the
    /// final resting position is never missed.
    private var recapturePending = false

    // Stitching state. The canvas is a growing CGContext whose CONTENT occupies the top
    // `contentHeightPx` rows; `lastFrameTop` is where the most recent frame was placed (offsets
    // chain from frame to frame, not from the canvas bottom).
    private var canvas: CGContext?
    private var canvasCapacityPx = 0
    private var contentHeightPx = 0
    private var lastFrameTop = 0
    private var frameWidthPx = 0
    private var frameHeightPx = 0
    /// Row signature of the last APPENDED frame (not the last captured one): tiny scrolls skip
    /// frames without appending, and their offsets must keep accumulating against what is actually
    /// on the canvas.
    private var prevSignature: [Float] = []
    private var frameCount = 0
    private var capReached = false

    private var started = false
    private var finished = false

    init(screen: NSScreen, region: CGRect, onFinished: @escaping (NSImage?) -> Void) {
        self.screen = screen
        self.region = region
        self.onFinished = onFinished
    }

    /// Shows the control pill, starts watching scrolls, and takes frame 0 immediately (the view
    /// the user just framed IS the first slice — waiting for a scroll would lose the top).
    func start() {
        guard !started else { return }
        started = true
        guard region.width >= 4, region.height >= 4, ScreenCapturer.hasPermission() else {
            finish(nil); return
        }
        buildPanel()
        installMonitors()
        Task { @MainActor in
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !self.finished else { return }
                guard let display = content.displays.first(where: { $0.displayID == self.screen.displayID })
                else { self.finish(nil); return }
                // Exclude Klip's own windows so the control pill never appears in a frame — this is
                // also why the pill overlapping the region (fallback placement) can't corrupt output.
                let ownBundleID = Bundle.main.bundleIdentifier
                let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
                self.filter = SCContentFilter(display: display, excludingApplications: ownApps,
                                              exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = self.region
                let scale = self.screen.backingScaleFactor
                config.width  = Int((self.region.width  * scale).rounded())
                config.height = Int((self.region.height * scale).rounded())
                config.showsCursor = false
                config.scalesToFit = false
                self.config = config
                self.captureFrame()
            } catch {
                self.finish(nil)
            }
        }
    }

    // MARK: - Scroll watching

    private func installMonitors() {
        // Global covers the target app (Klip is NOT active while the user scrolls it); the local
        // twin covers the edge case where Klip itself is frontmost. Scroll/mouse global monitors
        // need no extra permission — only keyboard globals do.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.noteScroll() }
        }) { scrollMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.noteScroll() }
            return event
        }) { scrollMonitors.append(m) }

        // Esc = cancel. A LOCAL monitor: it only fires while Klip is active, so with the target app
        // in front the Cancel button is the way out (same documented limit as the capture overlay —
        // a global keyDown monitor would demand Input Monitoring permission for one key).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self?.cancelPressed() }
                return nil
            }
            return event
        }
    }

    /// Every scroll event — including each momentum frame — pushes the shot back: the capture
    /// happens `settleDelay` after the LAST one, i.e. once the content stops moving.
    private func noteScroll() {
        guard !finished, !capReached else { return }
        debounceTimer?.invalidate()
        let t = Timer(timeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureFrame() }
        }
        RunLoop.main.add(t, forMode: .common)
        debounceTimer = t
    }

    // MARK: - Frame capture

    private func captureFrame() {
        guard !finished, !capReached, let filter, let config else { return }
        if isCapturing { recapturePending = true; return }
        isCapturing = true
        Task { @MainActor in
            let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                 configuration: config)
            self.isCapturing = false
            guard !self.finished else { return }
            // A single failed shot is not fatal — the next scroll retries. Only setup failures end the flow.
            if let cg { self.ingest(cg) }
            if self.recapturePending { self.recapturePending = false; self.captureFrame() }
        }
    }

    /// Dedupe → offset match → append. All the stitching decisions live here.
    private func ingest(_ frame: CGImage) {
        guard !finished, !capReached else { return }
        guard let sig = rowSignature(of: frame) else { return }

        if prevSignature.isEmpty {                       // frame 0 anchors everything
            frameWidthPx = frame.width
            frameHeightPx = frame.height
            guard ensureCanvas(heightPx: frameHeightPx) else { finish(nil); return }
            draw(frame, atTop: 0)
            contentHeightPx = frameHeightPx
            lastFrameTop = 0
            prevSignature = sig
            frameCount = 1
            updateStatus()
            return
        }

        let match = bestOffset(prev: prevSignature, next: sig)
        let newTop: Int
        var seam = false
        if match.error <= Self.matchThreshold {
            // Offset 0 / tiny = the same content (an identical frame lands here too, with error ~0:
            // the row signature doubles as the cheap dedupe hash). Skip, keep prevSignature — the
            // next offset must still be measured against what's on the canvas.
            guard match.offset >= Self.minScrollPx else { return }
            newTop = lastFrameTop + match.offset
        } else {
            // NO MATCH (in-page animation, sticky elements, a scroll UP we don't search for):
            // append below with a visible seam instead of aborting.
            newTop = contentHeightPx + Self.seamHeightPx
            seam = true
        }

        guard newTop + frameHeightPx <= Self.maxCanvasHeightPx else { reachLimit(); return }
        guard ensureCanvas(heightPx: newTop + frameHeightPx) else { finish(nil); return }
        if seam { drawSeam(atTop: contentHeightPx) }
        draw(frame, atTop: newTop)     // whole frame: the overlap rows overwrite identical content
        contentHeightPx = newTop + frameHeightPx
        lastFrameTop = newTop
        prevSignature = sig
        frameCount += 1
        if frameCount >= Self.maxFrames { reachLimit() } else { updateStatus() }
    }

    // MARK: - Row signature + offset search

    /// Per-row luminance signature: the frame drawn into a `signatureWidth`-wide grayscale bitmap
    /// (Core Graphics does the luminance conversion AND the horizontal averaging in one pass), one
    /// Float mean per row, top-down — the same row order as CGImage cropping space.
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

    /// Finds the downward scroll offset that best aligns `next` under `prev`: for each candidate,
    /// `next`'s top rows are compared against `prev`'s rows shifted by the offset, and the mean
    /// absolute difference over the overlap wins. Ascending iteration + strict `<` prefers the
    /// SMALLEST offset on ties (flat pages match many offsets equally; the conservative one stacks
    /// the least garbage).
    // ponytail: plain O(H²) loop, ~2M float ops for a 2000 px region — swap in vDSP if profiling
    // ever shows this on the settle path.
    private func bestOffset(prev: [Float], next: [Float]) -> (offset: Int, error: Float) {
        let h = min(prev.count, next.count)
        let maxOffset = max(0, h - Self.minOverlapPx)
        var best = (offset: 0, error: Float.greatestFiniteMagnitude)
        for offset in 0...maxOffset {
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
    /// the TOP of the context, which after `makeImage()` is CGImage row 0 — so the final crop is
    /// simply the top `contentHeightPx` rows.
    private func ensureCanvas(heightPx needed: Int) -> Bool {
        if canvas != nil, needed <= canvasCapacityPx { return true }
        // `max(cap, needed)` lets a single frame TALLER than the cap through (8K portrait region):
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

    /// `top` is measured in pixels from the canvas TOP; CG contexts are bottom-up, hence the flip.
    private func draw(_ image: CGImage, atTop top: Int) {
        canvas?.draw(image, in: CGRect(x: 0, y: canvasCapacityPx - top - frameHeightPx,
                                       width: frameWidthPx, height: frameHeightPx))
    }

    private func drawSeam(atTop top: Int) {
        guard let canvas else { return }
        // Red on purpose: the seam marks "the stitcher gave up here" and must be findable, not
        // camouflaged into the page background.
        canvas.setFillColor(CGColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1))
        canvas.fill(CGRect(x: 0, y: canvasCapacityPx - top - Self.seamHeightPx,
                           width: frameWidthPx, height: Self.seamHeightPx))
    }

    // MARK: - Limits / status

    /// Height or frame cap hit: stop CAPTURING but keep the panel alive — Done still saves
    /// everything stitched so far (saving nothing at the cap is the documented failure).
    private func reachLimit() {
        capReached = true
        for m in scrollMonitors { NSEvent.removeMonitor(m) }
        scrollMonitors.removeAll()
        debounceTimer?.invalidate(); debounceTimer = nil
        statusField?.stringValue = L10n.t("scroll.maxReached")
    }

    private func updateStatus() {
        statusField?.stringValue = String(format: L10n.t("scroll.status"), frameCount, contentHeightPx)
    }

    // MARK: - Control pill

    private func buildPanel() {
        // Sized against the WIDEST realistic status ("888 captures · ≈ 88888 px") so the panel
        // never has to grow mid-capture: it's placed once, next to the region, and stays put.
        let status = NSTextField(labelWithString: String(format: L10n.t("scroll.status"), 888, 88_888))
        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(labelWithString: L10n.t("scroll.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let cancel = NSButton(title: L10n.t("common.cancel"), target: self,
                              action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        let done = NSButton(title: L10n.t("sel.done"), target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        // Return-key styling makes Done the prominent (accent-filled) button. The panel is never
        // key, so this is visual hierarchy, not an actual hotkey.
        done.keyEquivalent = "\r"

        let buttons = NSStackView(views: [cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [status, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: hint)

        // Apple's panel recipe (backdrop + sheen + rim), same as ToastHUD.
        let fx = GlassPanelView(frame: .zero, radius: 12)
        let contentBox = NSView()
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentBox.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor, constant: -10),
        ])
        fx.setContent(contentBox)

        let fit = contentBox.fittingSize
        let size = NSSize(width: max(fit.width, 220), height: fit.height)
        status.stringValue = "…"          // real count arrives with frame 0, a beat after start()

        // .nonactivatingPanel is the load-bearing choice: the user must keep scrolling the TARGET
        // app, so clicking Done/Cancel must never move focus to Klip.
        let p = NSPanel(contentRect: panelFrame(for: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        // NSPanel hides itself when the app deactivates BY DEFAULT — and Klip is inactive for this
        // whole flow. Without this line the pill vanishes the moment the user clicks the target app.
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p
        statusField = status
    }

    /// Below the region → above → beside (right, then left) → bottom-right of the screen. The pill
    /// must never cover the region; the last fallback (region ≈ whole screen) can't avoid it
    /// on-screen, but the content filter already keeps Klip out of the frames, so only the user's
    /// VIEW of the region is grazed — never the output.
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

    // MARK: - Finish

    @objc private func donePressed() {
        guard !finished else { return }
        guard let canvas, contentHeightPx > 0, let full = canvas.makeImage(),
              let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: frameWidthPx,
                                                     height: contentHeightPx))   // top rows = content
        else { finish(nil); return }
        // Full pixel resolution, point size = pixels / scale (the CaptureOverlayController rule):
        // wrong size here and the image pastes at 2× on Retina.
        let scale = screen.backingScaleFactor
        let image = NSImage(cgImage: cropped,
                            size: NSSize(width: CGFloat(cropped.width) / max(scale, 1),
                                         height: CGFloat(cropped.height) / max(scale, 1)))
        finish(image)
    }

    @objc private func cancelPressed() { finish(nil) }

    /// Single exit: idempotent teardown (monitors removed exactly once, timer dead, panel closed),
    /// then the callback — fired exactly once, nil for cancel/failure.
    private func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        for m in scrollMonitors { NSEvent.removeMonitor(m) }
        scrollMonitors.removeAll()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        debounceTimer?.invalidate(); debounceTimer = nil
        panel?.orderOut(nil)
        panel = nil
        statusField = nil
        canvas = nil
        prevSignature = []
        onFinished(image)
    }
}
