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

/// Direct-drive word location: UTF-16 offsets of the spoken word in the full
/// text, nil on miss (caller keeps the last highlight).
@MainActor
struct LocateWordTests {
    private let full = "scientists study genes and alleles"
    private var entry: Range<String.Index> { full.startIndex..<full.endIndex }

    @Test func hitsSecondWord() {
        let got = ClickableTextView.locateWord(
            full: full, entry: entry, segWords: ["scientists", "study", "genes"], target: 1)
        let want = (full as NSString).range(of: "study")
        #expect(got?.low == want.location && got?.high == want.location + want.length)
    }

    @Test func missKeepsNil() {
        #expect(ClickableTextView.locateWord(
            full: full, entry: entry, segWords: ["scientists", "1998"], target: 1) == nil)
    }

    @Test func beyondEndIsNil() {
        #expect(ClickableTextView.locateWord(
            full: full, entry: entry, segWords: ["scientists"], target: 5) == nil)
    }

    /// Citation with year + page, PT voice spelling the year out: the
    /// expansion fragments (`mil`, `e`, `de`) must miss cleanly instead of
    /// matching inside later words and dragging the cursor — the panel
    /// yellow jumped while the audio flowed on.
    @Test func citationYearExpansionDoesNotDragCursor() {
        let text = "como viu Carnap 1950 segue a tese"
        let range = text.startIndex..<text.endIndex
        let spoken = ["como", "viu", "Carnap", "mil", "novecentos", "e", "cinquenta", "segue", "a", "tese"]
        // The expansion itself has no box: caller keeps the last highlight.
        #expect(ClickableTextView.locateWord(
            full: text, entry: range, segWords: spoken, target: 5) == nil)
        // The word after the expansion still lands on its own occurrence.
        let got = ClickableTextView.locateWord(
            full: text, entry: range, segWords: spoken, target: 7)
        let want = (text as NSString).range(of: "segue")
        #expect(got?.low == want.location && got?.high == want.location + want.length)
    }
}
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

/// Rebinding on document switch: the second `bind` replaces the word-locating
/// closure. Before, the guard kept the first document's text and the panel
/// yellow drifted from the 2nd sentence on.
@MainActor
struct CoordinatorBindTests {
    @Test func secondBindReplacesContext() {
        let controller = SpeechController()
        let view = ClickReportingTextView()
        let coordinator = ClickableTextView.Coordinator()
        let doc1 = "doc one text"
        let doc2 = "doc two text"
        coordinator.bind(
            controller: controller, textView: view,
            context: { (doc1, doc1.startIndex..<doc1.endIndex) }, pointSize: 13)
        #expect(coordinator.context?()?.full == doc1)
        coordinator.bind(
            controller: controller, textView: view,
            context: { (doc2, doc2.startIndex..<doc2.endIndex) }, pointSize: 15)
        #expect(coordinator.context?()?.full == doc2)
        #expect(coordinator.pointSize == 15)
    }
}
