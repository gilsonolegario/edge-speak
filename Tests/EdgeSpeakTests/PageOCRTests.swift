import AppKit
import Testing

@testable import EdgeSpeak

/// OCR fallback: pure gate deterministic, Vision proven on rendered text.
struct PageOCRTests {
    @Test func shortPageNeedsOCR() {
        #expect(PageOCR.needsOCR(pageText: "   ") == true)
        #expect(PageOCR.needsOCR(pageText: "EBSCO") == true)
    }

    @Test func prosePageSkipsOCR() {
        #expect(PageOCR.needsOCR(pageText: String(repeating: "word ", count: 20)) == false)
    }

    @Test func renderedTextRecognizes() throws {
        let text = "Hello OCR 123"
        let font = NSFont.systemFont(ofSize: 64)
        let size = text.size(withAttributes: [.font: font])
        let image = NSImage(size: NSSize(width: size.width + 40, height: size.height + 40))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: image.size))
        text.draw(at: NSPoint(x: 20, y: 20), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            Issue.record("could not rasterize fixture")
            return
        }
        let got = try PageOCR.recognize(cg, languages: ["en"])
        #expect(got.contains("Hello"))
        #expect(got.contains("123"))
    }
}
