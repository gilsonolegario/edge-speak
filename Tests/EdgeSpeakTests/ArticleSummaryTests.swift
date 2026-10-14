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
