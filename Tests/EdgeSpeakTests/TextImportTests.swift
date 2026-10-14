import CoreGraphics
import Testing

@testable import EdgeSpeak

/// End-of-line hyphen and page break in sentence→box matching.
///
/// Reason (research in docs/pesquisas/pymupdf-pesquisa.md): the extractor joins
/// "empir-" + "icism" into a single word only by unioning the boxes, and the sentence never
/// carries boxes from two pages. Without this, the hyphenated word fell into the whole
/// paragraph and the page break drew on the wrong page — the defect the owner saw.
struct TextImportTests {
    private func box(_ x: CGFloat, _ y: CGFloat, page: Int? = nil) -> TextImport.Phrase.WordBox {
        TextImport.Phrase.WordBox(
            text: "", rect: CGRect(x: x, y: y, width: 8, height: 10), page: page)
    }

    private func palavra(_ text: String, _ x: CGFloat, _ y: CGFloat, page: Int? = nil) -> TextImport.Phrase.WordBox {
        TextImport.Phrase.WordBox(
            text: text, rect: CGRect(x: x, y: y, width: 8, height: 10), page: page)
    }

    private func seg(
        _ text: String, page: Int?, wordBoxes: [CGRect], palavras: [TextImport.Phrase.WordBox]
    ) -> (text: String, page: Int?, rects: [CGRect], words: [TextImport.Phrase.WordBox]) {
        (text: text, page: page, rects: wordBoxes, words: palavras)
    }

    /// Glued text ("procurar", as it comes from the filter) matches the glued box
    /// from the extractor: one sentence, without falling into the paragraph.
    @Test func adjacentHyphenMatches() {
        let junta = palavra("procurar", 0, 0, page: 0)
        let sentences = TextImport.makePhrases(from: [
            seg("procurar aqui", page: 0, wordBoxes: [],
                palavras: [junta, palavra("aqui", 60, 0, page: 0)]),
        ])
        #expect(sentences.count == 1)
        #expect(sentences[0].rects.count == 1)
    }

    /// Raw text ("procu-", "rar", as it comes in integral mode) matches the
    /// glued box: the token without the hyphen plus the next one, joined.
    @Test func rawHyphenMatchesWithTightBox() {
        let junta = palavra("procurar", 0, 0, page: 0)
        let sentences = TextImport.makePhrases(from: [
            seg("procu- rar aqui", page: 0, wordBoxes: [],
                palavras: [junta, palavra("aqui", 60, 0, page: 0)]),
        ])
        #expect(sentences.count == 1)
        #expect(sentences[0].rects.count == 1)
    }

    /// "state-of-the-art" mid-line joins nothing: each token matches
    /// its own box and nothing is corrupted.
    @Test func midHyphenDoesNotJoin() {
        let palavras = [
            palavra("state-", 0, 0, page: 0), palavra("of", 30, 0, page: 0),
            palavra("the", 50, 0, page: 0), palavra("art", 70, 0, page: 0),
        ]
        let sentences = TextImport.makePhrases(from: [
            seg("state- of the art", page: 0, wordBoxes: [], palavras: palavras),
        ])
        #expect(sentences.count == 1)
        #expect(sentences[0].rects.count == 1) // #expect(sentences[0].rects.count == 1) // same line: union
    }

    /// A sentence crossing the page splits in two, each part on its own page
    /// with its own boxes, sequential indices and end only on the last.
    @Test func pageBreakSplitsInTwo() {
        let palavras = [
            palavra("primeira", 0, 100, page: 0), palavra("metade", 60, 100, page: 0),
            palavra("segunda", 0, 20, page: 1), palavra("parte", 60, 20, page: 1),
        ]
        let sentences = TextImport.makePhrases(from: [
            seg("primeira metade segunda parte", page: 0, wordBoxes: [], palavras: palavras),
        ])
        #expect(sentences.count == 2)
        #expect(sentences.map(\.index) == [0, 1])
        #expect(sentences[0].page == 0)
        #expect(sentences[1].page == 1)
        #expect(sentences[0].paragraphEnd == false)
        #expect(sentences[1].paragraphEnd == true)
        // Each part carries only words from its own page (the click locates).
        #expect(sentences[0].words.allSatisfy { $0.page == 0 })
        #expect(sentences[1].words.allSatisfy { $0.page == 1 })
    }

    /// No page break, one sentence on the segment's page.
    @Test func noBreakOnePhrase() {
        let sentences = TextImport.makePhrases(from: [
            seg("uma frase simples", page: 2, wordBoxes: [],
                palavras: [palavra("uma", 0, 0, page: 2)]),
        ])
        #expect(sentences.count == 1)
        #expect(sentences[0].page == 2)
    }

    /// With no matched box, it falls back to the segment's boxes (fallback preserved).
    @Test func noBoxFallsToSegment() {
        let reserva = CGRect(x: 0, y: 0, width: 100, height: 50)
        let sentences = TextImport.makePhrases(from: [
            seg("texto sem caixa", page: 0, wordBoxes: [reserva], palavras: []),
        ])
        #expect(sentences.count == 1)
        #expect(sentences[0].rects == [reserva])
    }

    /// Ligature "ﬁ" matches "fi" (NFKC before comparing).
    @Test func ligatureMatches() {
        var cursor = 0
        let matched = TextImport.boxesForSentence(
            "filosofia", words: [palavra("ﬁlosoﬁa", 0, 0, page: 0)], cursor: &cursor)
        #expect(matched.count == 1)
    }
}