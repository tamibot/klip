import AppKit

/// Drawing tools for the snapshot editor (parity with Lightshot, extended toward Shottr).
enum SnapTool: String, CaseIterable {
    case select, pencil, line, arrow, rectangle, ellipse, marker, text, blur, spotlight, counter

    /// Our own SF Symbol (we don't use Lightshot's assets — they're Skillbrains' IP).
    var symbol: String {
        switch self {
        case .select:    return "cursorarrow"
        // "pencil" is a bare diagonal pencil body — at 15pt, next to "line.diagonal", both read as
        // one diagonal stroke (same collision already solved for the highlighter). "scribble.variable"
        // is a nib trailing a wavy stroke: it SHOWS freehand, which is exactly what the tool does,
        // and no straight-line reading survives next to it. (SF Symbols 3 — well under our macOS 14 floor.)
        case .pencil:    return "scribble.variable"
        case .line:      return "line.diagonal"         // one straight stroke: literally what it draws
        case .arrow:     return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .marker:    return "highlighter"
        case .text:      return "textformat"
        case .blur:      return "checkerboard.rectangle"   // reads as "pixelate" (a droplet read as nothing)                  // Shottr's blur metaphor; "mosaic" reads as a table
        case .spotlight: return "flashlight.on.fill"    // "camera.metering.spot" is cryptic
        case .counter:   return "1.circle"              // shows an actual number, like the badges it stamps
        }
    }

    /// L10n key stem. Every tool's keys are its raw value; `rectangle` alone was shortened to "rect".
    private var key: String { self == .rectangle ? "rect" : rawValue }

    /// One line saying what the tool DOES — the tool's name alone doesn't teach anything
    /// (especially "highlighter" vs "pencil"). Shown under the name in the toolbar tooltip.
    var hint: String { L10n.t("tool.hint.\(key)") }

    var tooltip: String { L10n.t("tool.\(key)") }
}

/// A drawable annotation. `points` holds the freehand stroke (pencil/marker); shapes use the
/// first and last point; text stores its string and its TOP-LEFT corner; a counter stores its center.
struct Annotation {
    var id = UUID()
    var tool: SnapTool
    var color: NSColor
    var lineWidth: CGFloat
    var points: [CGPoint]
    var text: String?
    var fontSize: CGFloat = 20   // only for .text
    var blurLevel: CGFloat = 12  // only for .blur: pixel-block divisor; higher = coarser blocks
    /// Only for .text. nil = point text (auto width: grows with what's typed, breaks only on Return).
    /// A value = area text: lines wrap to this width, and resizing the box re-flows them — the font
    /// size never follows the box (Figma "fixed width", Illustrator area type, Keynote, Canva).
    var boxWidth: CGFloat? = nil
    /// Only for .text: height the user gave the box. The text is never clipped — the box is at least
    /// as tall as its lines — so this only makes it TALLER than the content (Preview-style auto height).
    var boxMinHeight: CGFloat = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    var textFont: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }

    /// Normalized drag rectangle (valid whichever direction the user dragged).
    var dragRect: CGRect { rect(start, end) }

    /// Badge radius for .counter: a ~26pt badge at the default stroke, growing with thickness.
    var counterRadius: CGFloat { max(13, lineWidth * 3.25) }

    /// Attributes for text: ONE definition shared by the canvas draw, the flattened export, the
    /// measuring below and the in-place editor, so all four break lines in the same places.
    static func textAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: para]
    }

    /// Layout options shared by `measureText` and the draw. `.usesFontLeading` matches the line
    /// height NSLayoutManager gives the in-place NSTextView (it uses font leading by default).
    static let textDrawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// Size the text occupies when wrapped to `width` (nil = no wrap, only explicit line breaks).
    /// Rounded UP: a box a fraction of a point short truncates its last line intermittently.
    static func measureText(_ text: String, font: NSFont, width: CGFloat?) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: textAttributes(font: font, color: .black))
        let limit = CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let r = attributed.boundingRect(with: limit, options: textDrawingOptions)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: ceil(r.width), height: max(ceil(r.height), lineHeight))
    }

    /// Rectangle occupied by the text (for selection/hit-testing/moving/drawing). nil if not text.
    /// Anchored by its top-left corner, so a box grows DOWNWARD as lines are added.
    func textBounds() -> CGRect? {
        guard tool == .text, let text, !text.isEmpty else { return nil }
        let content = Self.measureText(text, font: textFont, width: boxWidth)
        let width = boxWidth ?? content.width
        let height = max(content.height, boxMinHeight)
        let topLeft = points.first ?? .zero
        return CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
    }

    /// Draws the annotation in the current context (view coordinates, not flipped).
    /// `base`/`canvasSize` feed the blur tool (it pixelates the base image); `number` is the
    /// counter's displayed ordinal — derived by the caller from array order, never stored, so
    /// deleting/undoing a counter renumbers the rest naturally on redraw.
    func draw(base: CGImage? = nil, canvasSize: CGSize = .zero, number: Int = 1) {
        color.set()
        switch tool {
        case .select:
            break   // never an annotation; the select tool only manipulates existing ones
        case .pencil:
            strokePath(points, width: lineWidth)
        case .marker:
            color.withAlphaComponent(0.35).set()
            strokePath(points, width: max(lineWidth * 4, 14), round: true)
        case .line:
            let p = NSBezierPath(); p.move(to: start); p.line(to: end)
            p.lineWidth = lineWidth; p.lineCapStyle = .round; p.stroke()
        case .arrow:
            drawArrow(from: start, to: end, width: lineWidth)
        case .rectangle:
            let r = NSBezierPath(rect: dragRect); r.lineWidth = lineWidth; r.stroke()
        case .ellipse:
            let e = NSBezierPath(ovalIn: dragRect); e.lineWidth = lineWidth; e.stroke()
        case .blur:
            drawPixelated(base: base, canvasSize: canvasSize)
        case .spotlight:
            break   // the dim layer is drawn once for ALL spotlights by the canvas/flatten pass
        case .counter:
            drawCounter(number: number)
        case .text:
            guard let text, !text.isEmpty, let box = textBounds() else { return }
            // Lines start at the TOP of the box; a box taller than its text keeps the space below.
            NSAttributedString(string: text, attributes: Self.textAttributes(font: textFont, color: color))
                .draw(with: box, options: Self.textDrawingOptions)
        }
    }

    /// Hit-test in canvas coordinates (used by the select tool). Slop margins make thin
    /// strokes and small shapes grabbable.
    func hitTest(_ p: CGPoint) -> Bool {
        switch tool {
        case .select:
            return false
        case .rectangle, .ellipse, .blur, .spotlight:
            return dragRect.insetBy(dx: -4, dy: -4).contains(p)
        case .line, .arrow:
            return distanceToSegment(p, start, end) < 8
        case .pencil, .marker:
            guard points.count > 1 else { return false }
            for i in 0..<(points.count - 1) where distanceToSegment(p, points[i], points[i + 1]) < 8 {
                return true
            }
            return false
        case .text:
            return textBounds()?.insetBy(dx: -6, dy: -6).contains(p) ?? false
        case .counter:
            return hypot(p.x - start.x, p.y - start.y) <= counterRadius + 2
        }
    }

    /// Box used to draw the dashed selection outline. nil if the annotation has no extent.
    func selectionBounds() -> CGRect? {
        switch tool {
        case .select:
            return nil
        case .text:
            return textBounds()
        case .rectangle, .ellipse, .blur, .spotlight:
            return dragRect
        case .counter:
            return CGRect(x: start.x - counterRadius, y: start.y - counterRadius,
                          width: counterRadius * 2, height: counterRadius * 2)
        case .line, .arrow, .pencil, .marker:
            guard let first = points.first else { return nil }
            var box = CGRect(origin: first, size: .zero)
            for pt in points.dropFirst() { box = box.union(CGRect(origin: pt, size: .zero)) }
            return box
        }
    }

    // MARK: - Tool renderers

    /// Blur/pixelate: crop the covered region from the base CGImage, downscale to ~1/blurLevel,
    /// and draw it back up with no interpolation. Purely derived from the base pixels, so the
    /// canvas and the flattened export render identical blocks.
    private func drawPixelated(base: CGImage?, canvasSize: CGSize) {
        guard let base, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let r = dragRect
        guard r.width >= 1, r.height >= 1 else { return }
        let sx = CGFloat(base.width) / canvasSize.width
        let sy = CGFloat(base.height) / canvasSize.height
        // CGImage cropping uses a top-left origin; the canvas is bottom-left → flip Y.
        let crop = CGRect(x: r.minX * sx,
                          y: (canvasSize.height - r.maxY) * sy,
                          width: r.width * sx,
                          height: r.height * sy).integral
        guard let cropped = base.cropping(to: crop) else { return }
        let tw = max(1, Int(crop.width / blurLevel)), th = max(1, Int(crop.height / blurLevel))
        // ponytail: re-pixelated on every draw; cache the tiny image per annotation if profiling
        // ever shows large blur rects lagging the canvas.
        guard let small = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .medium
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let tiny = small.makeImage(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(tiny, in: r)
        ctx.restoreGState()
    }

    /// Counter badge: filled circle in the annotation color with a bold white centered number.
    private func drawCounter(number: Int) {
        let radius = counterRadius
        let circle = CGRect(x: start.x - radius, y: start.y - radius,
                            width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        let label = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.1, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2),
                   withAttributes: attrs)
    }

    // MARK: - Geometry helpers

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func strokePath(_ pts: [CGPoint], width: CGFloat, round: Bool = false) {
        guard pts.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.lineCapStyle = round ? .square : .round   // marker: square cap (highlighter stroke)
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.stroke()
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, width: CGFloat) {
        // `a` = where you press, `b` = where you release → the tip points at `b`. A FILLED triangle head
        // makes it unmistakable which end is the point.
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(14, width * 4.5)
        // Stop the shaft at the base of the head so the line doesn't poke through the filled tip.
        let base = CGPoint(x: b.x - cos(angle) * head, y: b.y - sin(angle) * head)
        let shaft = NSBezierPath(); shaft.move(to: a); shaft.line(to: base)
        shaft.lineWidth = width; shaft.lineCapStyle = .round; shaft.stroke()
        let w1 = CGPoint(x: b.x + cos(angle + .pi - .pi / 7) * head, y: b.y + sin(angle + .pi - .pi / 7) * head)
        let w2 = CGPoint(x: b.x + cos(angle + .pi + .pi / 7) * head, y: b.y + sin(angle + .pi + .pi / 7) * head)
        let tri = NSBezierPath(); tri.move(to: b); tri.line(to: w1); tri.line(to: w2); tri.close()
        tri.fill()
    }
}
