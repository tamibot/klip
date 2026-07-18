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
    /// Outcome the toast reports. Drives the glyph, its tint, whether it bounces, and the VoiceOver
    /// announcement priority — a failure must not read like a confirmation.
    enum Style { case success, failure }

    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    private static var actionTarget: ClickTarget?   // NSControl.target is weak: retain it here
    private static var lastAnnouncedAt = Date.distantPast

    /// Bridges the action button's click to a closure (ToastHUD is an enum: it can't be a target itself).
    private final class ClickTarget: NSObject {
        let handler: () -> Void
        init(handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    /// Shows the toast. `detail` is a one-line preview (truncated); pass nil for a title-only toast.
    /// With `actionTitle` + `action` an inline button is added (Shottr-style): the panel then accepts
    /// clicks — still without ever taking focus — and stays on screen longer.
    static func show(_ title: String, detail: String? = nil, style: Style = .success,
                     actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        actionTarget = nil

        // Real SF Symbol glyph (not a text "✓"): the accent checkmark confirms, the orange warning
        // triangle reports a failure. Only the confirmation bounces — celebrating an error is wrong.
        let check = NSImageView()
        let symbol = style == .failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let glyphLabel = L10n.t(style == .failure ? "toast.a11y.failure" : "toast.a11y.success")
        check.image = NSImage(systemSymbolName: symbol, accessibilityDescription: glyphLabel)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        check.contentTintColor = style == .failure ? .systemOrange : .controlAccentColor
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
        var spokenDetail = ""
        if let detail, !detail.isEmpty {
            let one = detail.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            spokenDetail = String(one.prefix(64))
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

        // Apple's panel recipe (backdrop + ceiling tint + rim), shared with the main panel.
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

        let size = contentBox.fittingSize
        let width = min(max(size.width, 160), 380)
        // Top-right of the screen the mouse is on (where the user is looking after a capture/copy).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: vis.maxX - width - 16, y: vis.maxY - size.height - 14,
                           width: width, height: size.height)

        // Slide down from the screen edge + fade (banner-style); slide is dropped under Reduce Motion.
        let slide: CGFloat = Motion.reduced ? 0 : 8
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
        if style == .success, !Motion.reduced {
            check.addSymbolEffect(.bounce, options: .nonRepeating)
        }
        // The panel never takes focus, so VoiceOver never visits it: speak the outcome instead.
        // Failures interrupt whatever is being read — a silently-queued error is a missed error.
        announce(spokenDetail.isEmpty ? title : "\(title), \(spokenDetail)",
                 priority: style == .failure ? .high : .medium)

        Motion.run(Motion.appear) { _ in
            p.animator().alphaValue = 1
            p.animator().setFrame(frame, display: true)
        }
        let work = DispatchWorkItem { [weak p] in
            guard let p else { return }
            Motion.run(Motion.dismiss, { _ in
                p.animator().alphaValue = 0
                p.animator().setFrame(p.frame.offsetBy(dx: 0, dy: slide), display: true)
            }, completion: {
                MainActor.assumeIsolated {   // AppKit animation completions run on the main thread
                    p.orderOut(nil); if panel === p { panel = nil }
                }
            })
        }
        hideWork = work
        // With a button the toast lingers so the user has time to reach it. Under VoiceOver that
        // budget also has to cover the spoken announcement plus the trip to the button, so double it.
        let linger: TimeInterval = action == nil ? 1.8
            : (NSWorkspace.shared.isVoiceOverEnabled ? 8.0 : 4.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    /// Speaks an outcome through VoiceOver. Klip's confirmations are all zero-real-estate (toast,
    /// menu-bar icon flash, sound) — none of them reach the accessibility tree on their own.
    private static func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        guard !text.isEmpty else { return }
        lastAnnouncedAt = Date()
        // Announcements are posted against the app, not the toast panel: a non-activating panel is
        // never the accessibility focus, and VoiceOver drops announcements from an unfocused element.
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: priority.rawValue,
        ])
    }

    /// Speaks every pasteboard write made through Klip (mirrors SoundFX.activate's copy tick).
    /// Call once at startup.
    static func activateAnnouncements() {
        NotificationCenter.default.addObserver(forName: .klipDidCopy, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.isVoiceOverEnabled else { return }
                // Copy paths that also raise a toast post .klipDidCopy FIRST, so the check can't run
                // inline: defer a beat and drop this generic cue if the toast already said it better.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    MainActor.assumeIsolated {
                        guard Date().timeIntervalSince(lastAnnouncedAt) > 0.3 else { return }
                        announce(L10n.t("toast.copied"), priority: .medium)
                    }
                }
            }
        }
    }

    /// Immediate dismissal (button clicked). Leaves `actionTarget` alone — the click handler is still
    /// on the stack; the next `show` clears it.
    private static func dismissNow() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
