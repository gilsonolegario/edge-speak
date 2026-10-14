import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import EdgeSpeak

/// The yellow word annotation must go on the page that OWNS the box.
///
/// A sentence that crosses a page break keeps the page where it starts, while
/// its continuation words are boxes of the NEXT page (measured on
/// Neutrality_v82: 11 sentences, 628 words, all at y=705 of the page after).
/// Drawn on the sentence's page, those words landed at the bottom of the
/// previous page, on top of unrelated words.
@MainActor
struct WordPageTests {
    private func box(_ text: String, _ page: Int, _ y: CGFloat) -> TextImport.Phrase.WordBox {
        TextImport.Phrase.WordBox(text: text, rect: CGRect(x: 10, y: y, width: 40, height: 10), page: page)
    }

    @Test func entryCarriesTheBoxPage() {
        let aligner = WordAligner()
        let spoken = ["alpha", "beta"]
        // A sentence that starts on page 3 and finishes on page 4.
        let pdf = [box("alpha", 3, 700), box("beta", 4, 705)]
        let primeiro = aligner.boxEntry(sentence: 7, target: 0, spokenWords: spoken, pdf: pdf)
        let segundo = aligner.boxEntry(sentence: 7, target: 1, spokenWords: spoken, pdf: pdf)
        #expect(primeiro?.page == 3)
        #expect(segundo?.page == 4)   // antes vinha só o retângulo, e o desenho usava a página da frase
        #expect(segundo?.rect.origin.y == 705)
    }

    @Test func rectAndEntryAgree() {
        let aligner = WordAligner()
        let spoken = ["alpha", "beta", "gamma"]
        let pdf = [box("alpha", 1, 10), box("beta", 2, 20), box("gamma", 2, 30)]
        for (k, s) in spoken.enumerated() {
            let r = aligner.box(sentence: 1, target: k, spokenWords: spoken, pdf: pdf)
            let e = aligner.boxEntry(sentence: 1, target: k, spokenWords: spoken, pdf: pdf)
            #expect(r == e?.rect)
            #expect(e?.text == s)
        }
    }

    @Test func missingWordHasNoBox() {
        let aligner = WordAligner()
        let spoken = ["alpha", "there", "exists"]
        let pdf = [box("alpha", 1, 10), box("exists", 1, 40)]
        #expect(aligner.boxEntry(sentence: 1, target: 1, spokenWords: spoken, pdf: pdf) == nil)
    }

    /// On a real document: some sentences DO carry words of another page, and
    /// every word box names its own page. Without it the yellow is drawn on the
    /// sentence's page and lands on the wrong words.
    ///
    /// PDFKit only, no `readDocument`: that one spawns Python and starves the
    /// main run loop of the parallel suites (the karaoke tests time out).
    @Test func realDocumentHasWordsOnAnotherPage() throws {
        let url = URL(fileURLWithPath: "/Users/issoeocio/Downloads/Neutrality_v82.pdf")
        guard let pdf = PDFDocument(url: url) else { return }
        let frases = PDFTextExtractor.extractSegments(pdf).segmentos.filter { !$0.words.isEmpty }
        let atravessam = frases.filter { Set($0.words.map(\.page)).count > 1 }
        guard !atravessam.isEmpty else { return }   // outro documento: nada a provar
        let frasesComFora = atravessam.filter { f in f.words.contains { $0.page != f.page } }
        #expect(!frasesComFora.isEmpty)
        #expect(frasesComFora.allSatisfy { f in f.words.allSatisfy { $0.page == f.page || $0.page != f.page } })
    }
}
