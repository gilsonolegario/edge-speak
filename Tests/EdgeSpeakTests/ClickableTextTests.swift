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
