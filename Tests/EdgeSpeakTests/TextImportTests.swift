import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Hífen de fim de linha e virada de página no casamento frase→caixa.
///
/// Motivo (pesquisa em docs/pesquisas/pymupdf-pesquisa.md): o extrator junta
/// "empir-" + "icism" numa palavra só com a união das caixas, e a frase nunca
/// leva caixas de duas páginas. Sem isto, a hifenizada caía no parágrafo
/// inteiro e a virada desenhava na página errada — o defeito que o dono viu.
struct TextImportTests {
    private func caixa(_ x: CGFloat, _ y: CGFloat, pagina: Int? = nil) -> TextImport.Phrase.WordBox {
        TextImport.Phrase.WordBox(
            text: "", rect: CGRect(x: x, y: y, width: 8, height: 10), page: pagina)
    }

    private func palavra(_ texto: String, _ x: CGFloat, _ y: CGFloat, pagina: Int? = nil) -> TextImport.Phrase.WordBox {
        TextImport.Phrase.WordBox(
            text: texto, rect: CGRect(x: x, y: y, width: 8, height: 10), page: pagina)
    }

    private func seg(
        _ texto: String, pagina: Int?, caixas: [CGRect], palavras: [TextImport.Phrase.WordBox]
    ) -> (text: String, page: Int?, rects: [CGRect], words: [TextImport.Phrase.WordBox]) {
        (text: texto, page: pagina, rects: caixas, words: palavras)
    }

    /// Texto junto ("procurar", como vem do filtro) casa com a caixa junta
    /// do extrator: uma frase, sem cair no parágrafo.
    @Test func hifenJuntoCasa() {
        let junta = palavra("procurar", 0, 0, pagina: 0)
        let frases = TextImport.makePhrases(from: [
            seg("procurar aqui", pagina: 0, caixas: [],
                palavras: [junta, palavra("aqui", 60, 0, pagina: 0)]),
        ])
        #expect(frases.count == 1)
        #expect(frases[0].rects.count == 1)
    }

    /// Texto cru ("procu-", "rar", como vem no modo integral) casa com a
    /// caixa junta: o token sem o hífen mais o próximo, colados.
    @Test func hifenCruCasaComCaixaJunta() {
        let junta = palavra("procurar", 0, 0, pagina: 0)
        let frases = TextImport.makePhrases(from: [
            seg("procu- rar aqui", pagina: 0, caixas: [],
                palavras: [junta, palavra("aqui", 60, 0, pagina: 0)]),
        ])
        #expect(frases.count == 1)
        #expect(frases[0].rects.count == 1)
    }

    /// "state-of-the-art" no meio da linha não junta nada: cada token casa
    /// com a sua caixa e nada se corrompe.
    @Test func hifenNoMeioNaoJunta() {
        let palavras = [
            palavra("state-", 0, 0, pagina: 0), palavra("of", 30, 0, pagina: 0),
            palavra("the", 50, 0, pagina: 0), palavra("art", 70, 0, pagina: 0),
        ]
        let frases = TextImport.makePhrases(from: [
            seg("state- of the art", pagina: 0, caixas: [], palavras: palavras),
        ])
        #expect(frases.count == 1)
        #expect(frases[0].rects.count == 1) // mesma linha: união
    }

    /// Frase atravessando a página parte em duas, cada parte na sua página
    /// com suas caixas, índices em sequência e fim só na última.
    @Test func viradaDePaginaParteEmDuas() {
        let palavras = [
            palavra("primeira", 0, 100, pagina: 0), palavra("metade", 60, 100, pagina: 0),
            palavra("segunda", 0, 20, pagina: 1), palavra("parte", 60, 20, pagina: 1),
        ]
        let frases = TextImport.makePhrases(from: [
            seg("primeira metade segunda parte", pagina: 0, caixas: [], palavras: palavras),
        ])
        #expect(frases.count == 2)
        #expect(frases.map(\.index) == [0, 1])
        #expect(frases[0].page == 0)
        #expect(frases[1].page == 1)
        #expect(frases[0].paragraphEnd == false)
        #expect(frases[1].paragraphEnd == true)
        // Cada parte leva só palavras da sua página (o clique localiza).
        #expect(frases[0].words.allSatisfy { $0.page == 0 })
        #expect(frases[1].words.allSatisfy { $0.page == 1 })
    }

    /// Sem virada, uma frase só na página do segmento.
    @Test func semViradaUmaFrase() {
        let frases = TextImport.makePhrases(from: [
            seg("uma frase simples", pagina: 2, caixas: [],
                palavras: [palavra("uma", 0, 0, pagina: 2)]),
        ])
        #expect(frases.count == 1)
        #expect(frases[0].page == 2)
    }

    /// Sem caixa casada, cai nas caixas do segmento (reserva preservada).
    @Test func semCaixaCaiNoSegmento() {
        let reserva = CGRect(x: 0, y: 0, width: 100, height: 50)
        let frases = TextImport.makePhrases(from: [
            seg("texto sem caixa", pagina: 0, caixas: [reserva], palavras: []),
        ])
        #expect(frases.count == 1)
        #expect(frases[0].rects == [reserva])
    }

    /// Ligadura "ﬁ" casa com "fi" (NFKC antes de comparar).
    @Test func ligaduraCasa() {
        var cursor = 0
        let casados = TextImport.boxesForSentence(
            "filosofia", words: [palavra("ﬁlosoﬁa", 0, 0, pagina: 0)], cursor: &cursor)
        #expect(casados.count == 1)
    }
}