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
    private static var actionTarget: ClickTarget?   // NSControl.target is weak: retain it here

    /// Bridges the action button's click to a closure (ToastHUD is an enum: it can't be a target itself).
    private final class ClickTarget: NSObject {
        let handler: () -> Void
        init(handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    /// Shows the toast. `detail` is a one-line preview (truncated); pass nil for a title-only toast.
    /// With `actionTitle` + `action` an inline button is added (Shottr-style): the panel then accepts
    /// clicks — still without ever taking focus — and stays on screen longer.
    static func show(_ title: String, detail: String? = nil,
                     actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        actionTarget = nil

        // Real SF Symbol checkmark (bounced on appear) instead of a text "✓" glyph.
        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        check.contentTintColor = .controlAccentColor   // brand accent on the confirm glyph
        check.symbolConfiguration = .preferringHierarchical()
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        let titleRow = NSStackView(views: [check, titleField])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6

        let stack = NSStackView(views: [titleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if let detail, !detail.isEmpty {
            let one = detail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let detailField = NSTextField(labelWithString: String(one.prefix(64)) + (one.count > 64 ? "…" : ""))
            detailField.font = .systemFont(ofSize: 11)
            detailField.textColor = .secondaryLabelColor
            detailField.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(detailField)
        }
        if let actionTitle, let action {
            let target = ClickTarget { dismissNow(); action() }
            actionTarget = target
            // Inline text action reads as an accent link (design language): borderless, accent, semibold.
            let button = NSButton(title: actionTitle, target: target, action: #selector(ClickTarget.fire))
            button.isBordered = false
            button.controlSize = .small
            button.attributedTitle = NSAttributedString(string: actionTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
            ])
            stack.addArrangedSubview(button)
        }

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12   // matches the main HUD panel (PanelController)
        fx.layer?.cornerCurve = .continuous
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

        // Slide down from the screen edge + fade (banner-style); slide is dropped under Reduce Motion.
        let slide: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 8
        let p = NSPanel(contentRect: frame.offsetBy(dx: 0, dy: slide), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        // Purely informative toasts let clicks pass through; with an action button the panel must
        // accept the click (the .nonactivatingPanel style keeps it from ever stealing focus).
        p.ignoresMouseEvents = (action == nil)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check.addSymbolEffect(.bounce, options: .nonRepeating)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(frame, display: true)
        }
        let work = DispatchWorkItem { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 0
                p.animator().setFrame(p.frame.offsetBy(dx: 0, dy: slide), display: true)
            }, completionHandler: {
                MainActor.assumeIsolated {   // AppKit animation completions run on the main thread
                    p.orderOut(nil); if panel === p { panel = nil }
                }
            })
        }
        hideWork = work
        // With a button the toast lingers so the user has time to reach it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 1.8 : 4.0), execute: work)
    }

    /// Immediate dismissal (button clicked). Leaves `actionTarget` alone — the click handler is still
    /// on the stack; the next `show` clears it.
    private static func dismissNow() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
