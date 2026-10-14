import AppKit
import Testing

@testable import EdgeSpeak

/// Dictionary entry range: selection wins, else the word under the click.
struct ClickableTextTests {
    @Test func selectionWins() {
        let text = "hello world" as NSString
        let got = ClickReportingTextView.lookupRange(
            in: text, selection: NSRange(location: 6, length: 5), click: 1)
        #expect(got == NSRange(location: 6, length: 5))
    }

    @Test func clickInsideWordFindsIt() {
        let text = "hello world" as NSString
        let got = ClickReportingTextView.lookupRange(
            in: text, selection: NSRange(location: 0, length: 0), click: 8)
        #expect(got == NSRange(location: 6, length: 5))
    }

    @Test func clickOutsideIsNil() {
        let text = "hi" as NSString
        #expect(ClickReportingTextView.lookupRange(
            in: text, selection: NSRange(location: 0, length: 0), click: 99) == nil)
    }
}

/// Incremental highlight: only changed background runs repaint (never a
/// skipped new highlight — the click regression), full swap otherwise.
@MainActor
struct ClickablePaintTests {
    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(attributedString: NSAttributedString(string: text))
    }

    private func desired(_ text: String, bg: NSRange) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text)
        s.addAttribute(.backgroundColor, value: NSColor.systemYellow, range: bg)
        return s
    }

    @Test func changedRunsRepaint() {
        let storage = storage("scientists study genes")
        ClickableTextView.paintHighlight(
            storage: storage, desired: desired("scientists study genes", bg: NSRange(location: 0, length: 10)),
            pointSize: 13)
        #expect(ClickableTextView.bgRuns(storage) == ClickableTextView.bgRuns(desired("scientists study genes", bg: NSRange(location: 0, length: 10))))
    }

    @Test func clickMovesRuns() {
        let text = "scientists study genes"
        let storage = storage(text)
        ClickableTextView.paintHighlight(
            storage: storage, desired: desired(text, bg: NSRange(location: 11, length: 5)),
            pointSize: 13)
        // Click on the first word: runs must change (never skipped as equal).
        let first = desired(text, bg: NSRange(location: 0, length: 10))
        #expect(ClickableTextView.bgRuns(storage) != ClickableTextView.bgRuns(first))
        ClickableTextView.paintHighlight(storage: storage, desired: first, pointSize: 13)
        #expect(ClickableTextView.bgRuns(storage) == ClickableTextView.bgRuns(first))
    }

    @Test func oldRunRestoresBaseStyle() {
        let text = "scientists study genes"
        let storage = storage(text)
        ClickableTextView.paintHighlight(
            storage: storage, desired: desired(text, bg: NSRange(location: 0, length: 10)),
            pointSize: 13)
        ClickableTextView.paintHighlight(storage: storage, desired: NSAttributedString(string: text), pointSize: 13)
        #expect(ClickableTextView.bgRuns(storage).isEmpty)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 13)
    }
}
