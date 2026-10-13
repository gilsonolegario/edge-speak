import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Alinhamento entre as palavras faladas e as palavras do PDF.
///
/// O caso que motivou tudo: no artigo de teste, "R= ∃uT (u,o), C= R →T (t,o)."
/// vira na voz "R equals there exists u such that T of u o, C equals R implies
/// T of t o" — 6 palavras faladas para 3 caixas no PDF. A busca palavra a
/// palavra fazia as expansões ("and", "such", "there") roubarem a caixa de
/// uma palavra de prosa logo adiante: o amarelo pulava de lado a lado. Aqui a
/// palavra de expansão fica SEM caixa, que é a única resposta honesta.
@MainActor
struct WordAlignerTests {
    private func pdf(_ textos: [String]) -> [WordAligner.Caixa] {
        textos.enumerated().map { i, t in
            TextImport.Phrase.WordBox(
                text: t, rect: CGRect(x: CGFloat(i) * 10, y: 0, width: 8, height: 10))
        }
    }

    /// O caso do artigo: as expansões não levam caixa nenhuma, e as palavras
    /// reais ficam na caixa certa.
    @Test func expansoesNaoRoubanCaixa() {
        let aligner = WordAligner()
        // Falado: "R equals there exists u such that T of u o" (11 palavras).
        // PDF: "R= ∃uT (u,o)" → tokens do extrator.
        let faladas = ["R", "equals", "there", "exists", "u", "such", "that", "T", "of", "u", "o"]
        let caixas = pdf(["R=", "∃uT", "(u,o)"])
        let mapa = aligner.alinha(faladas: faladas, pdf: caixas)
        // A palavra "R" (mesma nas duas pontas) fica na primeira caixa.
        #expect(mapa[0] == 0)
        // Nenhuma expansão ("equals", "there", "such"…) pode casar com caixa:
        // se casassem, estariam roubando a caixa de prosa adiante.
        for i in 1..<faladas.count {
            #expect(mapa[i] == nil, "palavra \(faladas[i]) não devia ter caixa")
        }
    }

    /// Repetida com vizinhas diferentes: cada fala vai para a sua ocorrência.
    @Test func repetidaComVizinhasDiferentes() {
        let aligner = WordAligner()
        let faladas = ["the", "role", "the", "test"]
        let caixas = pdf(["the", "role", "the", "test"])
        let mapa = aligner.alinha(faladas: faladas, pdf: caixas)
        #expect(mapa == [0, 1, 2, 3])
    }

    /// "the" a cada poucas palavras (o texto do artigo é cheio disso) não
    /// desloca o resto da frase.
    @Test func theRepetidoNaoDesloca() {
        let aligner = WordAligner()
        let faladas = ["the", "theory", "of", "the", "theory", "is", "the", "gap"]
        let caixas = pdf(["the", "theory", "of", "the", "theory", "is", "the", "gap"])
        let mapa = aligner.alinha(faladas: faladas, pdf: caixas)
        #expect(mapa == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    /// A palavra falada que existe no PDF casa mesmo com caixa a menos: a
    /// sequência é menor que a do PDF (símbolo que a voz não fala).
    @Test func pdfComSimboloNaoFalado() {
        let aligner = WordAligner()
        // Falado: "R equals R" (o "=" é expansão da voz, não do PDF).
        let faladas = ["R", "equals", "R"]
        let caixas = pdf(["R", "=", "R"])
        let mapa = aligner.alinha(faladas: faladas, pdf: caixas)
        #expect(mapa[0] == 0)
        #expect(mapa[1] == nil)
        #expect(mapa[2] == 2)
    }

    /// Caso real do artigo (Neutrality_v80, p. 5): a frase "Avery's title … the
    /// laboratory." é lida contra as palavras do PARÁGRAFO inteiro (80 tokens
    /// reais do extrator), e a frase seguinte contém "the laboratory" de novo.
    /// Pular o meio ou pular o fim custa o mesmo, e o backtrace a partir do
    /// fim prefere a ocorrência TARDIA: o 2º "the" ia para a caixa 63 em vez
    /// da 52, e o amarelo pulava para a frase seguinte. As faladas passam pelo
    /// `forSpeech` como no app.
    @Test func theRepetidoNoArtigoFicaNaPropriaFrase() {
        let aligner = WordAligner()
        let frase = "Avery’s title named a role and left the identity of its occupant to the laboratory."
        let faladas = ReadAloudFilter.forSpeech(frase, voice: "en-US")
            .split(separator: " ").map(String.init)
        #expect(faladas.count == 15)
        let caixas = pdf([
            "The", "two", "uses", "of", "Carnap", "assign", "different", "work", "to", "a",
            "choice.", "The", "reconstruction", "fixes", "an", "inter-", "pretation", "under", "which", "realization",
            "suffices", "for", "theoretical", "truth.", "The", "realist", "frame", "makes", "a", "general",
            "existential", "commitment", "part", "of", "engaging", "in", "an", "explanatory", "practice.", "Avery’s",
            "title", "named", "a", "role", "and", "left", "the", "identity", "of", "its",
            "occupant", "to", "the", "laboratory.", "Whether", "either", "device", "leaves", "questions", "of",
            "that", "kind", "where", "the", "laboratory", "found", "them", "depends", "on", "how",
            "theoretical", "terms", "are", "understood,", "and", "Carnap", "himself", "marked", "the", "difference.",
        ])
        let mapa = aligner.alinha(faladas: faladas, pdf: caixas)
        for i in 0..<13 {
            #expect(mapa[i] == 39 + i, "palavra \(faladas[i]) devia estar na caixa \(39 + i)")
        }
        #expect(mapa[13] == 52)
        #expect(mapa[14] == 53)
    }

    /// Espelho do caso do artigo: a frase seguinte ("… where the laboratory
    /// found them …") casa o "the laboratory" na SUA ocorrência (63–64), não
    /// na anterior (52–53). Trava o outro lado: o contexto não pode empurrar
    /// tudo para a primeira ocorrência.
    @Test func fraseSeguinteCasaNaPropriaOcorrencia() {
        let aligner = WordAligner()
        let frase = "Whether either device leaves questions of that kind where the laboratory found them depends on how theoretical terms are understood, and Carnap himself marked the difference."
        let faladas = ReadAloudFilter.forSpeech(frase, voice: "en-US")
            .split(separator: " ").map(String.init)
        #expect(faladas.count == 26)
        let caixas = pdf([
            "The", "two", "uses", "of", "Carnap", "assign", "different", "work", "to", "a",
            "choice.", "The", "reconstruction", "fixes", "an", "inter-", "pretation", "under", "which", "realization",
            "suffices", "for", "theoretical", "truth.", "The", "realist", "frame", "makes", "a", "general",
            "existential", "commitment", "part", "of", "engaging", "in", "an", "explanatory", "practice.", "Avery’s",
            "title", "named", "a", "role", "and", "left", "the", "identity", "of", "its",
            "occupant", "to", "the", "laboratory.", "Whether", "either", "device", "leaves", "questions", "of",
            "that", "kind", "where", "the", "laboratory", "found", "them", "depends", "on", "how",
            "theoretical", "terms", "are", "understood,", "and", "Carnap", "himself", "marked", "the", "difference.",
        ])
        let mapa = aligner.alinha(faladas: faladas, pdf: caixas)
        #expect(mapa == Array(54..<80).map { Optional($0) })
    }

    /// Expansão antes de repetidas: a palavra que não existe no PDF continua
    /// sem caixa mesmo com o bônus de contexto (só o par igual ganha bônus).
    @Test func expansaoAntesDeRepetidaNaoRoubaCaixa() {
        let aligner = WordAligner()
        let mapa = aligner.alinha(
            faladas: ["oh", "the", "role", "the", "test"],
            pdf: pdf(["the", "role", "the", "test"]))
        #expect(mapa == [nil, 0, 1, 2, 3])
    }

    /// A caixa da palavra alvo sai do mapa; sem correspondência, nil (nunca
    /// uma caixa vizinha inventada).
    @Test func caixaDoAlvo() {
        let aligner = WordAligner()
        let caixas = pdf(["a", "b", "c"])
        let mapa = aligner.alinha(faladas: ["a", "b", "c"], pdf: caixas)
        #expect(aligner.caixa(alinhado: mapa, alvo: 1, pdf: caixas)?.origin.x == CGFloat(10))
        // Alvo inexistente (índice além da lista) não quebra.
        #expect(aligner.caixa(alinhado: mapa, alvo: 9, pdf: caixas) == nil)
    }

    /// Repetir o pedido (como a cada tique do destaque) devolve a MESMA caixa.
    @Test func repetirTiqueNaoMudaACaixa() {
        let aligner = WordAligner()
        let faladas = ["the", "role", "the", "test"]
        let caixas = pdf(["the", "role", "the", "test"])
        let primeira = aligner.caixa(frase: 1, alvo: 2, faladas: faladas, pdf: caixas)
        for _ in 0..<20 {
            #expect(aligner.caixa(frase: 1, alvo: 2, faladas: faladas, pdf: caixas) == primeira)
        }
    }

    /// Trocar de frase recalcula o alinhamento.
    @Test func trocaDeFraseRecalcula() {
        let aligner = WordAligner()
        let faladas = ["a", "b"]
        let caixas = pdf(["a", "b"])
        #expect(aligner.caixa(frase: 1, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(0))
        #expect(aligner.caixa(frase: 2, alvo: 0, faladas: faladas, pdf: caixas)?.origin.x == CGFloat(0))
    }

    /// A comparação ignora pontuação, caixa e hífen.
    @Test func normalizacao() {
        #expect(WordAligner.normalizada("Carnap’s") == "carnaps")
        #expect(WordAligner.normalizada("well-known") == "wellknown")
        #expect(WordAligner.normalizada("(") == "")
        #expect(WordAligner.normalizada("1944") == "1944")
    }
}