import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Prova do mapeamento clique→frase (função pura, sem UI): contenção vence,
/// proximidade até 40 pt vale, margem devolve nil.
struct PdfClickLocatorTests {
    private func frases() -> [TextImport.Phrase] {
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

    /// Ponto dentro do rect resolve a frase dona (contenção).
    @Test func contencaoVence() {
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 15), on: 0, among: frases()) == 0)
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 110), on: 0, among: frases()) == 1)
    }

    /// Ponto perto (até 40 pt) resolve a frase mais próxima; outra página
    /// não vaza para a página clicada.
    @Test func proximidadeAte40pt() {
        // 10 pt abaixo do rect da frase 1.
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 90), on: 0, among: frases()) == 1)
        // Mesmo ponto de página 0 não pode resolver a frase da página 1.
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 50, y: 15), on: 1, among: frases()) == 3)
    }

    /// Ponto na margem (longe de tudo) devolve nil; frase sem rects é
    /// ignorada e nunca resolve.
    @Test func margemDevolveNil() {
        #expect(
            PhraseLocator.phraseIndex(
                near: CGPoint(x: 500, y: 500), on: 0, among: frases()) == nil)
        #expect(PhraseLocator.maxDistance == 40)
    }
}
