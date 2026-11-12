import AppKit
import Testing
@testable import Klip

/// Area text: a text annotation with a `boxWidth` wraps to it, and changing the box re-flows the
/// lines — the font size never follows the box. Point text (`boxWidth == nil`) keeps growing
/// sideways and only breaks on Return.
@Suite("Area text")
struct AreaTextTests {

    private func text(_ s: String, width: CGFloat?, minHeight: CGFloat = 0,
                      topLeft: CGPoint = CGPoint(x: 10, y: 300)) -> Annotation {
        var a = Annotation(tool: .text, color: .red, lineWidth: 3, points: [topLeft], text: s, fontSize: 20)
        a.boxWidth = width
        a.boxMinHeight = minHeight
        return a
    }

    private let sentence = "Revisa el reporte de ventas antes de mandarlo al cliente por WhatsApp"

    @Test("point text stays on one line and its box is as wide as the text")
    func pointTextOneLine() throws {
        let a = text(sentence, width: nil)
        let box = try #require(a.textBounds())
        let lineHeight = Annotation.measureText("A", font: a.textFont, width: nil).height
        #expect(box.height == lineHeight)
        #expect(box.width > 300)
    }

    @Test("area text wraps to its width, and a narrower box means more lines at the same font size")
    func narrowerBoxMoreLines() throws {
        let wide = try #require(text(sentence, width: 400).textBounds())
        let narrow = try #require(text(sentence, width: 150).textBounds())
        #expect(wide.width == 400)
        #expect(narrow.width == 150)
        #expect(narrow.height > wide.height)
        #expect(text(sentence, width: 150).fontSize == 20)
    }

    @Test("the box is anchored by its top-left corner, so it grows downward")
    func anchoredTopLeft() throws {
        let one = try #require(text("hola", width: 200).textBounds())
        let many = try #require(text(sentence, width: 120).textBounds())
        #expect(one.maxY == 300 && many.maxY == 300)
        #expect(one.minX == 10 && many.minX == 10)
        #expect(many.minY < one.minY)
    }

    @Test("a taller box keeps its height, a shorter one never clips the text")
    func minHeightNeverClips() throws {
        let content = try #require(text(sentence, width: 150).textBounds()).height
        let tall = try #require(text(sentence, width: 150, minHeight: content + 80).textBounds())
        #expect(tall.height == content + 80)
        let short = try #require(text(sentence, width: 150, minHeight: 5).textBounds())
        #expect(short.height == content)
    }

    @Test("Return breaks the line in point text too")
    func explicitLineBreaks() throws {
        let one = try #require(text("uno", width: nil).textBounds())
        let three = try #require(text("uno\ndos\ntres", width: nil).textBounds())
        #expect(three.height > one.height * 2.5)
    }

    @Test("a word wider than the box is broken, not drawn past the box")
    func longWordWraps() throws {
        let box = try #require(text("Supercalifragilisticoespialidoso", width: 60).textBounds())
        #expect(box.width == 60)
        #expect(box.height > Annotation.measureText("A", font: NSFont.systemFont(ofSize: 20, weight: .semibold), width: nil).height)
    }

    /// The export path: draw into a bitmap with the canvas' own (non-flipped) coordinates and check
    /// the ink lands at the TOP of a box taller than its text — `draw(with:)` in a non-flipped
    /// context is the one place this could silently invert.
    @Test("drawn text starts at the top of its box")
    func drawsFromTop() throws {
        let size = 200
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        // Box from y=20 to y=180 (non-flipped: 180 is the top); one short line of text.
        text("Hola", width: 150, minHeight: 160, topLeft: CGPoint(x: 20, y: 180))
            .draw(base: nil, canvasSize: CGSize(width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        // NSBitmapImageRep rows run top-down: row 0 is the top of the image (y = 200).
        func inkInRows(_ rows: Range<Int>) -> Bool {
            for y in rows { for x in 20..<170 {
                if let c = rep.colorAt(x: x, y: y), c.redComponent > 0.5, c.greenComponent < 0.5 { return true }
            } }
            return false
        }
        #expect(inkInRows(20..<60))        // just under the box's top edge (y 180…140)
        #expect(!inkInRows(120..<180))     // bottom of the box (y 80…20) stays empty
    }
}
