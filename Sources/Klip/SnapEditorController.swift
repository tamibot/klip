import AppKit

/// Ventana del editor de capturas: toolbar de herramientas + lienzo. Al copiar/guardar entrega
/// la imagen anotada; al cerrar sin guardar entrega nil.
final class SnapEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let canvas: AnnotationCanvasView
    private let onFinish: (NSImage?) -> Void
    private var toolButtons: [SnapTool: NSButton] = [:]
    private var finished = false

    init(image: NSImage, onFinish: @escaping (NSImage?) -> Void) {
        self.canvas = AnnotationCanvasView(image: image)
        self.onFinish = onFinish
        super.init()
    }

    func present() {
        let imgSize = canvas.bounds.size
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minBarWidth: CGFloat = 780   // ancho mínimo para que la toolbar no se encime
        let maxW = screen.width * 0.9, maxH = screen.height * 0.85 - 52
        let scale = min(1, min(maxW / imgSize.width, maxH / imgSize.height))
        let contentW = max(minBarWidth, imgSize.width * scale)
        let contentH = imgSize.height * scale + 52   // 52 = barra de herramientas

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Anotar captura — Klip"
        win.minSize = NSSize(width: minBarWidth, height: 240)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))

        // Lienzo dentro de un scroll view (por si la captura es grande).
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH - 52))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        scroll.backgroundColor = .underPageBackgroundColor
        content.addSubview(scroll)

        let toolbar = buildToolbar(width: contentW)
        toolbar.frame = NSRect(x: 0, y: contentH - 52, width: contentW, height: 52)
        toolbar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(toolbar)

        win.contentView = content
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(canvas)
        selectTool(.arrow)
        self.window = win
    }

    // MARK: - Toolbar

    private func buildToolbar(width: CGFloat) -> NSView {
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        let size: CGFloat = 30

        // Grupo izquierdo: herramientas + color + grosor + deshacer.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 4
        leading.alignment = .centerY
        leading.translatesAutoresizingMaskIntoConstraints = false

        for tool in SnapTool.allCases {
            let b = NSButton()
            b.bezelStyle = .texturedRounded
            b.setButtonType(.toggle)
            b.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.tooltip)
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = tool.tooltip
            b.target = self
            b.action = #selector(toolTapped(_:))
            b.tag = SnapTool.allCases.firstIndex(of: tool) ?? 0
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: size).isActive = true
            b.heightAnchor.constraint(equalToConstant: size).isActive = true
            toolButtons[tool] = b
            leading.addArrangedSubview(b)
        }

        let well = NSColorWell()
        well.color = .systemRed
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: size).isActive = true
        leading.addArrangedSubview(well)

        let widths = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne,
                                        target: self, action: #selector(widthChanged(_:)))
        widths.selectedSegment = 1
        leading.addArrangedSubview(widths)

        let undo = makeActionButton(symbol: "arrow.uturn.backward", tip: "Deshacer (⌘Z)", action: #selector(undoTapped))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = [.command]
        undo.translatesAutoresizingMaskIntoConstraints = false
        undo.widthAnchor.constraint(equalToConstant: size).isActive = true
        leading.addArrangedSubview(undo)

        // Grupo derecho: copiar + guardar + cerrar.
        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.alignment = .centerY
        trailing.translatesAutoresizingMaskIntoConstraints = false

        let copy = makeTextButton(title: "Copiar", tip: "Copiar (⌘C)", action: #selector(copyTapped))
        copy.keyEquivalent = "c"; copy.keyEquivalentModifierMask = [.command]
        let save = makeTextButton(title: "Guardar", tip: "Guardar (⌘S)", action: #selector(saveTapped))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        let close = makeActionButton(symbol: "xmark", tip: "Cerrar (Esc)", action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"   // Esc
        close.translatesAutoresizingMaskIntoConstraints = false
        close.widthAnchor.constraint(equalToConstant: size).isActive = true
        trailing.addArrangedSubview(copy)
        trailing.addArrangedSubview(save)
        trailing.addArrangedSubview(close)

        bar.addSubview(leading)
        bar.addSubview(trailing)
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -16)
        ])
        return bar
    }

    private func makeActionButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.toolTip = tip
        return b
    }

    private func makeTextButton(title: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        b.keyEquivalent = ""
        return b
    }

    // MARK: - Acciones de toolbar

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = SnapTool.allCases[sender.tag]
        selectTool(tool)
    }

    private func selectTool(_ tool: SnapTool) {
        canvas.currentTool = tool
        for (t, b) in toolButtons { b.state = (t == tool) ? .on : .off }
    }

    @objc private func colorChanged(_ sender: NSColorWell) { canvas.currentColor = sender.color }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        canvas.currentLineWidth = [2.0, 3.0, 6.0][max(0, min(2, sender.selectedSegment))]
    }

    @objc private func undoTapped() { canvas.undo() }

    @objc private func copyTapped() {
        let image = canvas.flattened()
        finish(with: image)
    }

    @objc private func saveTapped() {
        let image = canvas.flattened()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Captura Klip.png"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
            self?.finish(with: image)
        }
    }

    @objc private func closeTapped() { finish(with: nil) }

    private func finish(with image: NSImage?) {
        guard !finished else { return }
        finished = true
        window?.orderOut(nil)
        window = nil
        onFinish(image)
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onFinish(nil)
    }
}
