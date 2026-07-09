import AppKit

extension Notification.Name {
    /// Posted whenever Klip writes to the pasteboard, so zero-real-estate cues (menu-bar icon flash)
    /// can react no matter which path copied.
    static let klipDidCopy = Notification.Name("klipDidCopy")
}

/// Small transient "Copied ✓" confirmation (Shottr-style): a borderless non-activating panel that
/// fades in near the top-right of the active screen, shows a one-line preview, and fades out on its
/// own. Never takes focus; safe to call from any copy path.
@MainActor
enum ToastHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// Shows the toast. `detail` is a one-line preview (truncated); pass nil for a title-only toast.
    static func show(_ title: String, detail: String? = nil) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let titleField = NSTextField(labelWithString: "✓ " + title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor

        let stack = NSStackView(views: [titleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        if let detail, !detail.isEmpty {
            let one = detail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let detailField = NSTextField(labelWithString: String(one.prefix(64)) + (one.count > 64 ? "…" : ""))
            detailField.font = .systemFont(ofSize: 11)
            detailField.textColor = .secondaryLabelColor
            detailField.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(detailField)
        }

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        fx.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: fx.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -9),
        ])

        let size = fx.fittingSize
        let width = min(max(size.width, 160), 380)
        // Top-right of the screen the mouse is on (where the user is looking after a capture/copy).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: vis.maxX - width - 16, y: vis.maxY - size.height - 14,
                           width: width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true   // purely informative: clicks pass through
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil); if panel === p { panel = nil } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
