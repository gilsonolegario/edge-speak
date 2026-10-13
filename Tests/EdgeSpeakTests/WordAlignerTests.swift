import CoreGraphics
import Testing

@testable import EdgeSpeak

/// O casamento da palavra falada com a caixa do PDF: uma passada só para
/// frente, estável ao longo da leitura da frase.
///
/// Motivo dos testes: o defeito que o dono viu era o amarelo pular entre
/// ocorrências de palavras idêntimas. A versão anterior recalculava o
/// casamento do zero a cada tique (10 Hz), e uma palavra sem caixa no meio da
/// frase fazia as seguintes casarem com posições erradas.
@MainActor
struct WordAlignerTests {
    private func fala(_ textos: [String]) -> [EdgeTTS.Segment.Word] {
        textos.enumerated().map { i, t in
            EdgeTTS.Segment.Word(start: Double(i), duration: 0.3, text: t)
        }
    }

    private func pdf(_ textos: [String]) -> [WordAligner.Caixa] {
        textos.enumerated().map { i, t in
            TextImport.Phrase.WordBox(
                text: t, rect: CGRect(x: Double(i) * 10, y: 0, width: 8, height: 10))
        }
    }

    /// A vizinha desambigua: com uma cópia a mais da mesma palavra no PDF, o
    /// par com a seguinte escolhe a ocorrência certa. Sem a vizinha, a busca
    /// pela palavra sozinha pegaria a primeira cópia e tudo depois dela
    /// ficaria deslocado.
    @Test func vizinhaDesambiguaRepetida() {
        let aligner = WordAligner()
        let faladas = fala(["a", "b", "a", "c"])
        let caixas = pdf(["a", "a", "b", "c"])
        // "a" seguida de "b" é a segunda cópia (índice 1), não a primeira.
        #expect(aligner.caixa(frase: 5, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(10))
        #expect(aligner.caixa(frase: 5, alvo: 1, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(20))
    }

    /// Repetida com vizinhas diferentes: cada fala vai para a sua ocorrência.
    @Test func repetidaComVizinhasDiferentes() {
        let aligner = WordAligner()
        let faladas = fala(["the", "role", "the", "test"])
        let caixas = pdf(["the", "role", "the", "test"])
        #expect(aligner.caixa(frase: 6, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(0))
        #expect(aligner.caixa(frase: 6, alvo: 1, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(10))
        #expect(aligner.caixa(frase: 6, alvo: 2, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(20))
        #expect(aligner.caixa(frase: 6, alvo: 3, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(30))
    }

    /// Palavras repetidas: cada ocorrência fala vai para a ocorrência certa,
    /// na ordem — nunca para a primeira.
    @Test func repetidasSeguemOrdem() {
        let aligner = WordAligner()
        let faladas = fala(["the", "cat", "the", "sat"])
        let caixas = pdf(["the", "cat", "the", "sat"])
        for (alvo, esperadoX) in [(0, CGFloat(0)), (1, CGFloat(10)), (2, CGFloat(20)), (3, CGFloat(30))] {
            let r = aligner.caixa(frase: 7, alvo: alvo, faladas: faladas, pdf: caixas)
            #expect(r?.origin.x == esperadoX, "alvo \(alvo)")
        }
    }

    /// O defeito reportado: ao voltar a perguntar (como a cada tique), a
    /// resposta é a MESMA caixa — o cursor não recomeça.
    @Test func repetirTiqueNaoMudaACaixa() {
        let aligner = WordAligner()
        let faladas = fala(["the", "cat", "the", "sat"])
        let caixas = pdf(["the", "cat", "the", "sat"])
        let primeira = aligner.caixa(frase: 7, alvo: 2, faladas: faladas, pdf: caixas)
        for _ in 0..<20 {
            let repetido = aligner.caixa(frase: 7, alvo: 2, faladas: faladas, pdf: caixas)
            #expect(repetido == primeira)
        }
    }

    /// Palavra falada sem caixa (símbolo, palavra que o PDF não tranca) não
    /// pode deslocar as seguintes: "the" falado sem caixa não come a
    /// ocorrência do "the" que existe no PDF.
    @Test func palavraSemCaixaNaoDesloca() {
        let aligner = WordAligner()
        let faladas = fala(["the", "⟨símbolo⟩", "the", "sat"])
        let caixas = pdf(["the", "the", "sat"])
        #expect(aligner.caixa(frase: 1, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(0))
        #expect(aligner.caixa(frase: 1, alvo: 1, faladas: faladas, pdf: caixas) == nil)
        #expect(aligner.caixa(frase: 1, alvo: 2, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(10))
        #expect(aligner.caixa(frase: 1, alvo: 3, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(20))
    }

    /// Pular de uma palavra para outra (o tique pode pular duas) continua
    /// casando na ordem.
    @Test func puloDeIndices() {
        let aligner = WordAligner()
        let faladas = fala(["a", "b", "c", "d"])
        let caixas = pdf(["a", "b", "c", "d"])
        #expect(aligner.caixa(frase: 2, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(0))
        #expect(aligner.caixa(frase: 2, alvo: 3, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(30))
    }

    /// Trocar de frase reinicia: as caixas são de outra frase.
    @Test func trocaDeFraseReinicia() {
        let aligner = WordAligner()
        let faladas = fala(["the", "cat"])
        #expect(aligner.caixa(frase: 1, alvo: 0, faladas: faladas, pdf: pdf(["the", "cat"]))?.origin.x == CGFloat(0))
        // Frase 2 com a mesma palavra: volta ao começo das caixas novas.
        #expect(aligner.caixa(frase: 2, alvo: 0, faladas: faladas, pdf: pdf(["the", "cat"]))?.origin.x == CGFloat(0))
    }

    /// Índice de palavra andando para trás (salto no áudio) reinicia o cursor.
    @Test func indiceParaTrasReinicia() {
        let aligner = WordAligner()
        let faladas = fala(["a", "b", "c"])
        let caixas = pdf(["a", "b", "c"])
        #expect(aligner.caixa(frase: 3, alvo: 2, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(20))
        #expect(aligner.caixa(frase: 3, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(0))
    }

    /// Sem caixa casada, nil — nunca uma caixa vizinha.
    @Test func semCaixaDevolveNil() {
        let aligner = WordAligner()
        let r = aligner.caixa(
            frase: 1, alvo: 0,
            faladas: fala(["zzz"]), pdf: pdf(["aaa"]))
        #expect(r == nil)
    }

    /// A comparação ignora pontuação, caixa e hífen.
    @Test func normalizacao() {
        #expect(WordAligner.normalizada("Carnap’s") == "carnaps")
        #expect(WordAligner.normalizada("well-known") == "wellknown")
        #expect(WordAligner.normalizada("(") == "")
        #expect(WordAligner.normalizada("1944") == "1944")
    }
}