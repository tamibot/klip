import AppKit

/// Floating frame around the region being recorded + a small control pill (red dot, elapsed time,
/// Stop). Answers "is it recording? WHERE?" at a glance — the red menu-bar icon alone wasn't
/// enough. Both windows belong to Klip, and the recorder's content filter excludes Klip's own
/// windows, so neither ever appears in the footage.
@MainActor
final class RecordingIndicator {
    private var borderWindow: NSWindow?
    private var pillPanel: NSPanel?
    private var timer: Timer?
    private var startedAt = Date()
    private var elapsedLabel: NSTextField?
    private var onStop: (() -> Void)?

    /// Frame only, no pill — for flows that draw their own controls (scrolling capture shows its
    /// own progress pill, so a second one would be redundant).
    func showFrame(screen: NSScreen, region: CGRect, color: NSColor = .controlAccentColor) {
        hide()
        installBorder(screen: screen, region: region, color: color)
    }

    /// `region` in TOP-LEFT display-local points (the recorder's coordinate space).
    func show(screen: NSScreen, region: CGRect, onStop: @escaping () -> Void) {
        hide()
        self.onStop = onStop
        startedAt = Date()

        let frame = installBorder(screen: screen, region: region, color: .systemRed)

        // Control pill below the region (above when there's no room), never overlapping it.
        let pillSize = NSSize(width: 148, height: 34)
        var px = frame.midX - pillSize.width / 2
        px = max(screen.visibleFrame.minX + 8, min(px, screen.visibleFrame.maxX - pillSize.width - 8))
        var py = frame.minY - pillSize.height - 8
        if py < screen.visibleFrame.minY + 8 { py = min(frame.maxY + 8, screen.visibleFrame.maxY - pillSize.height - 8) }

        let pill = NSPanel(contentRect: NSRect(x: px, y: py, width: pillSize.width, height: pillSize.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pill.isOpaque = false
        pill.backgroundColor = .clear
        pill.hasShadow = true
        pill.level = .floating
        pill.becomesKeyOnlyIfNeeded = true
        pill.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let glass = GlassPanelView(frame: NSRect(origin: .zero, size: pillSize), radius: 17)
        let content = NSView(frame: NSRect(origin: .zero, size: pillSize))

        let dot = NSView(frame: NSRect(x: 12, y: 13, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        // Slow breathing pulse — "live", not alarming. Removed with the layer on hide().
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0; pulse.toValue = 0.35
        pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            dot.layer?.add(pulse, forKey: "pulse")
        }
        content.addSubview(dot)

        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 26, y: 9, width: 44, height: 16)
        content.addSubview(label)
        elapsedLabel = label

        let stop = NSButton(title: L10n.t("rec.screen.stop"), target: self, action: #selector(stopTapped))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.font = .systemFont(ofSize: 11, weight: .semibold)
        stop.sizeToFit()
        stop.frame = NSRect(x: pillSize.width - stop.frame.width - 10,
                            y: (pillSize.height - stop.frame.height) / 2,
                            width: stop.frame.width, height: stop.frame.height)
        content.addSubview(stop)

        glass.setContent(content)
        pill.contentView = glass
        pill.orderFrontRegardless()
        pillPanel = pill

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let label = self.elapsedLabel else { return }
                let s = Int(Date().timeIntervalSince(self.startedAt).rounded())
                label.stringValue = String(format: "%d:%02d", s / 60, s % 60)
            }
        }
    }

    /// Convert to global Cocoa (bottom-left) and put the stroke OUTSIDE the marked area, so the
    /// frame marks the region without sitting on its edge pixels. Returns the (inset) frame.
    @discardableResult
    private func installBorder(screen: NSScreen, region: CGRect, color: NSColor) -> NSRect {
        let frame = NSRect(x: screen.frame.minX + region.minX,
                           y: screen.frame.maxY - region.maxY,
                           width: region.width, height: region.height)
            .insetBy(dx: -3, dy: -3)
        let border = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.level = .floating
        border.ignoresMouseEvents = true   // pure decoration: clicks go to the app underneath
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = BorderView(frame: NSRect(origin: .zero, size: frame.size), color: color)
        border.orderFrontRegardless()
        borderWindow = border
        return frame
    }

    @objc private func stopTapped() { onStop?() }

    func hide() {
        timer?.invalidate(); timer = nil
        elapsedLabel = nil
        borderWindow?.orderOut(nil); borderWindow = nil
        pillPanel?.orderOut(nil); pillPanel = nil
        onStop = nil
    }

    /// 3pt red rounded stroke with a white hairline just outside it, so the frame stays visible
    /// over both dark and light content.
    private final class BorderView: NSView {
        private let color: NSColor
        init(frame: NSRect, color: NSColor) {
            self.color = color
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(roundedRect: inner, xRadius: 5, yRadius: 5)
            path.lineWidth = 3
            color.setStroke()
            path.stroke()
            let halo = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            halo.lineWidth = 0.5
            NSColor.white.withAlphaComponent(0.55).setStroke()
            halo.stroke()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
