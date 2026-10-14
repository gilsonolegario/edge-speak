import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Proof of the click→sentence mapping (pure function, no UI): containment wins,
/// proximity up to 40 pt counts, margin returns nil.
struct PdfClickLocatorTests {
    private func sentences() -> [TextImport.Phrase] {
        [
            TextImport.Phrase(
                index: 0, text: "Primeira.", page: 0,
                rects: [CGRect(x: 10, y: 10, width: 100, height: 20)]),
            TextImport.Phrase(
                index: 1, text: "Segunda.", page: 0,
                rects: [CGRect(x: 10, y: 100, width: 100, height: 20)]),
            TextImport.Phrase(index: 2, text: "Sem caixas.", page: 0, rects: []),
            TextImport.Phrase(
                index: 3, text: "Outra página.", page: 1,
                rects: [CGRect(x: 10, y: 10, width: 100, height: 20)]),
        ]
    }

    /// A point inside the rect resolves the owning sentence (containment).
    @Test func containmentWins() {
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 15), on: 0, among: sentences()) == 0)
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 110), on: 0, among: sentences()) == 1)
    }

    /// A nearby point (up to 40 pt) resolves the closest sentence; another page
    /// does not leak into the clicked page.
    @Test func proximityUpTo40pt() {
        // 10 pt below the rect of sentence 1.
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 90), on: 0, among: sentences()) == 1)
        // The same point on page 0 must not resolve a page 1 sentence.
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 15), on: 1, among: sentences()) == 3)
    }

    /// A point in the margin (far from everything) returns nil; a sentence without rects is
    /// ignored and never resolves.
    @Test func marginReturnsNil() {
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 500, y: 500), on: 0, among: sentences()) == nil)
        #expect(PhraseLocator.maxDistance == 40)
    }
}
