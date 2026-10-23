import Foundation
import Testing

@testable import EdgeSpeak

/// On-device summarizer: pure logic deterministic, model fail-closed.
struct ArticleSummaryTests {
    @Test func clippedShortPassesThrough() {
        #expect(ArticleSummary.clipped("Short passage.") == "Short passage.")
    }

    @Test func clippedLongCutsAtFullStop() {
        let pad = String(repeating: "a ", count: 1_400)
        let tail = String(repeating: "b ", count: 300)
        let text = pad + ". " + tail + "."
        let got = ArticleSummary.clipped(text)
        #expect(got.hasSuffix("."))
        #expect(got.count <= ArticleSummary.maxInputChars)
        #expect(!got.contains("b"))
    }

    /// Sentences with a unique, fixed-width tag per index (`sNNN` never appears
    /// inside another tag), so "contains" proves WHICH stretch was picked.
    private func tagged(_ count: Int) -> [String] {
        (0..<count).map { String(format: "s%03d ", $0) + String(repeating: "palavra ", count: 5) }
    }

    /// The window starts at the reading position, never at the document's head:
    /// with the reading halfway in, the opening sentences must not be there.
    /// Fails if the excerpt goes back to "first 3.000 characters of the file".
    @Test func excerptStartsAtReadingPositionNotDocumentStart() {
        let sentences = tagged(120)
        let got = ArticleSummary.excerpt(sentences: sentences, at: 80)
        #expect(!got.contains("s000"))
        #expect(!got.contains("s001"))
        #expect(!got.contains("s077"))   // just before the context window
        #expect(got.contains("s078"))    // 2 sentences of context before
        #expect(got.contains("s080"))    // the reading sentence itself
        #expect(got.contains("s081"))    // and it grows forward
        #expect(got.hasPrefix("s078"))
    }

    @Test func excerptKeepsBudgetAndTheCurrentSentence() {
        let sentences = tagged(120)
        let got = ArticleSummary.excerpt(sentences: sentences, at: 80, maxChars: 400)
        #expect(got.count <= 400)
        #expect(got.contains("s080"))
        #expect(got.hasPrefix("s078"))
    }

    /// Context yields when the budget is short: the current sentence always
    /// makes it in, even if the preceding ones would eat the whole window.
    @Test func excerptBudgetNeverDropsTheCurrentSentence() {
        let sentences = tagged(120)
        let got = ArticleSummary.excerpt(sentences: sentences, at: 80, maxChars: 51)
        #expect(!got.isEmpty)
        #expect(got.contains("s080"))
        #expect(!got.contains("s000"))
    }

    /// Before the first play there is no current sentence: the first one is the
    /// only anchor available.
    @Test func excerptAtZeroKeepsTheOpening() {
        let got = ArticleSummary.excerpt(sentences: tagged(10), at: 0)
        #expect(got.hasPrefix("s000"))
    }

    /// Out-of-range positions clamp to the list instead of returning nothing.
    @Test func excerptClampsPositionToTheEnd() {
        let got = ArticleSummary.excerpt(sentences: tagged(10), at: 999)
        #expect(got.contains("s009"))
        #expect(!got.contains("s000"))
    }

    @Test func excerptEmptyListIsEmpty() {
        #expect(ArticleSummary.excerpt(sentences: [], at: 3).isEmpty)
        #expect(ArticleSummary.excerpt(sentences: ["   ", ""], at: 0).isEmpty)
    }

    @Test func promptCarriesInstruction() {
        let got = ArticleSummary.prompt(for: "Neutrality thesis.")
        #expect(got.contains("three sentences"))
        #expect(got.contains("Neutrality thesis."))
    }

    #if canImport(FoundationModels)
    @Test func summarizeNeverThrowsAndStaysShort() async {
        if #available(macOS 26, *) {
            let got = await ArticleSummary.summarize(text: "Neutrality thesis. Second sentence here.")
            #expect(got == nil || !(got ?? "").isEmpty)
        }
    }

    @Test func summarizeEmptyIsNil() async {
        if #available(macOS 26, *) {
            #expect(await ArticleSummary.summarize(text: "   ") == nil)
        }
    }
    #endif
}
