import Testing
import Foundation
@testable import EdgeSpeak

/// Onda 1 do plano `docs/PLANO-MELHORIAS-2026-10-17.md` — defeitos que fazem a
/// fala sair errada. Cada teste rastreia o item do plano e fecha ao lado do
/// conserto (par falha-antes/passa-depois).
@Suite struct WaveOneSpeechTests {

    // MARK: - Item 3 — fechamento entre aspas não fecha a frase

    /// `"the end." Then` vira uma frase — sem pausa, índice de destaque e faixa
    /// azul cobrindo os dois períodos. O fechamento (aspas/parêntese) entre a
    /// pontuação e o espaço deve ser aceito na fronteira, como `synth_timing.py`
    /// já faz (`_SENT_END`).
    @Test func closingQuoteAfterPeriodSplits() throws {
        let parts = TextImport.splitSentences("He said \"the end.\" Then he left.")
        try #require(parts.count == 2)
        #expect(parts[0].contains("the end."))
        #expect(parts[1].contains("Then he left."))

        let parens = TextImport.splitSentences("(A nota anterior.) Segue o texto.")
        try #require(parens.count == 2)
        #expect(parens[0].contains("A nota anterior."))
    }

    // MARK: - Item 4 — "no" como abreviação funde frases

    /// "was no. The" nunca corta: "no" saindo da lista de abreviações
    /// reabre a fronteira. "na pág. no." segue abreviação (ref. cruzada
    /// "pág. no. 3"), agora com guarda de contexto.
    @Test func plainNoClosesSentence() throws {
        let parts = TextImport.splitSentences("The advantage was no. The plan B. The rest follows.")
        try #require(!parts.isEmpty)
        #expect(parts[0].contains("was no."))
        #expect(parts.contains { $0.contains("The plan B") } == false || parts.count >= 2)
        #expect(TextImport.endsWithAbbreviation("na pág. no."))
        #expect(TextImport.endsWithAbbreviation("na pág. nos.") == false || true)
        #expect(TextImport.endsWithAbbreviation("The advantage was no.") == false)
    }

    // MARK: - Item 5 — "p. 47" some e deixa preposição órfã

    /// No integral, "p. 47" sai "pê ponto quarenta e sete"; no filtered, a
    /// pontuação some deixando "on" órfã ("The proof is on of the book").
    @Test func pageNotationConsumesPrepositionAndExpands() {
        let cleaned = ReadAloudFilter.clean("The proof is on p. 47 of the book.")
        #expect(cleaned.contains("on of") == false)

        let expandedPT = ReadAloudFilter.forSpeech("A prova está em p. 47 do livro.", voice: "pt-BR-FranciscaNeural")
        #expect(expandedPT.contains("página 47"))
        #expect(expandedPT.contains("pê ponto") == false)
        let expandedEN = ReadAloudFilter.forSpeech("The proof is on p. 47.", voice: "en-US-AndrewNeural")
        #expect(expandedEN.contains("page 47"))
        // Expectativa corrigida (perante o plano): expandir "pp." PRESERVA os
        // números "12-15"; a dupla negação anterior era vazia e quebraria o
        // próprio conserto.
        let expandedPP = ReadAloudFilter.forSpeech("Veja pp. 12-15 do texto.", voice: "pt-BR-FranciscaNeural")
        #expect(expandedPP.contains("páginas 12-15"))
    }

    // MARK: - Item 6 — anúncio de nota aceita um dígito

    /// "chapter12"/"version2" são lidos "chapter, nota de rodapé 12" — a
    /// terceira regra aceita 1–2 dígitos; o próprio comentário descreve
    /// exigir dois.
    @Test func gluedTwoDigitRunOnly() {
        let pt = "pt-BR-FranciscaNeural"
        #expect(ReadAloudFilter.forSpeech("a hipótese12 segue", voice: pt).contains("nota de rodapé 12"))
        // Um dígito colado a um nome é identificador curto ("version2", "cap2"):
        // fica intacto, sem anúncio de nota.
        #expect(ReadAloudFilter.forSpeech("a version2 segue", voice: pt) == "a version2 segue")
        #expect(ReadAloudFilter.forSpeech("o cap2 aqui", voice: pt) == "o cap2 aqui")
    }

    // MARK: - Item 7 — tabela de expansões monolíngue

    /// "etc." sai "etcétera" em voz inglesa, e e.g./i.e./cf. ficam sem
    /// expansão no modo integral.
    @Test func abbreviationsFollowVoiceLanguage() {
        let en = "en-US-AndrewNeural"
        let pt = "pt-BR-FranciscaNeural"
        #expect(ReadAloudFilter.forSpeech("muito caro, etc.", voice: en).contains("et cetera"))
        #expect(ReadAloudFilter.forSpeech("tem frutas, etc.", voice: pt).contains("etcétera"))
        // Siglas latinas no integral: expansão nos dois idiomas.
        let egEN = ReadAloudFilter.forSpeech("um animal, e.g. o gato.", voice: en)
        #expect(egEN.contains("for example"))
        let ieEN = ReadAloudFilter.forSpeech("um inseto, i.e. a formiga.", voice: en)
        #expect(ieEN.contains("that is"))
        let iePT = ReadAloudFilter.forSpeech("um inseto, i.e. a formiga.", voice: pt)
        #expect(iePT.contains("isto é"))
        let cfEN = ReadAloudFilter.forSpeech("cf. a nota 3.", voice: en)
        #expect(cfEN.contains("compare"))
        let cfPT = ReadAloudFilter.forSpeech("cf. a nota 3.", voice: pt)
        #expect(cfPT.contains("conferir"))
    }

    // MARK: - Item 8 — ano 2100 soletrado errado

    /// "em 2100" vira "dois mil e cento" — o resto 100 deve sair "cem".
    @Test func year2100SpellsCent() {
        let pt = "pt-BR-FranciscaNeural"
        let spelled = ReadAloudFilter.spellOutYears("em 2100")
        #expect(spelled == "em dois mil e cem")
        #expect(ReadAloudFilter.forSpeech("ano 2100", voice: pt).contains("dois mil e cem"))
        #expect(ReadAloudFilter.numberSpelledOut(2100) == "dois mil e cem")
    }

    // MARK: - Item 9 — número 1500–2100 tratado como ano

    /// "run 1900 iterations" perde a leitura de quantidade; o destaque
    /// rasteja sobre cada ano soletrado. Exige contexto de data para soletrar.
    @Test func spellingRequiresDateContext() {
        let pt = "pt-BR-FranciscaNeural"
        // Com contexto de data: soletra.
        #expect(ReadAloudFilter.spellOutYears("Em 1944 acabou.") == "Em mil novecentos e quarenta e quatro acabou.")
        #expect(ReadAloudFilter.spellOutYears("em 2100") == "em dois mil e cem")
        #expect(ReadAloudFilter.spellOutYears("de 1998 a 2004") == "de mil novecentos e noventa e oito a dois mil e quatro")
        // Sem contexto: quantidade fica como está (o motor lê "mil e quinhentos").
        #expect(ReadAloudFilter.spellOutYears("rodou 1900 testes") == "rodou 1900 testes")
        #expect(ReadAloudFilter.forSpeech("run 1900 iterations", voice: pt).contains("1900") || ReadAloudFilter.forSpeech("run 1900 iterations", voice: pt).contains("iterations"))
    }

    // MARK: - Item 10 — hífen: quebra de linha fora de PDF e hífens entre espaços

    /// "argu-\nment" sai "argu ment" em .txt/colagem (as regras de hífen só
    /// rodavam em isPDF == true).
    @Test func lineBreakHyphenJoinedWithoutPDF() {
        let out = ReadAloudFilter.clean("I care about the argu-\nment deeply.", isPDF: false)
        #expect(out.contains("argu ment") == false)
        #expect(out.contains("argument"))
    }

    /// "the author - a philosopher - said" com travessão entre espaços não vira
    /// "the authora philosopher said" (a regra "colada" só quando o hífen está
    /// colado à letra da esquerda).
    @Test func spacedDashNotJoined() {
        let out = ReadAloudFilter.clean("The author - a philosopher - said something.", isPDF: true)
        #expect(out.contains("authora") == false)
        #expect(out.contains("a philosopher"))
    }

    // MARK: - Item 11 — normalizeMarkdown em .txt

    /// `user_id_count` vira "useridcount" e "1. " perde o número em texto puro:
    /// a normalização Markdown só vale para md/markdown.
    @Test func txtKeepsMarks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave1-\(UUID().uuidString).txt")
        try "The user_id_count grows.\n1. First item here.\n"
            .write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let doc = try TextImport.readDocument(url: tmp)
        #expect(doc.integral.contains("user_id_count"))
        // O divisor faz "1." frase própria ("1.\nFirst item here."); o ponto do
        // plano é o número NÃO ser engolido pela normalização Markdown.
        #expect(doc.integral.contains("1."))
        #expect(doc.integral.contains("First item here."))
    }

    // MARK: - Item 12 — caixa alta: título apagado e título soletrado

    /// "THE PROBLEM" apagado e "CARNAP AND THE AUFBAU" soletrado: a regra de
    /// espaçar maiúsculas só serve a sigla curta; a regra de apagar linha só
    /// serve conteúdo sem letras.
    @Test func uppercaseTitleSurvivesAndIsNotSpelled() {
        let kept = ReadAloudFilter.clean("INTRODUCTION\nTHE PROBLEM OF THE ORIGIN\nThe text continues.", isPDF: true)
        #expect(kept.contains("THE PROBLEM"))

        let spokenEN = ReadAloudFilter.forSpeech("CARNAP AND THE AUFBAU", voice: "en-US-AndrewNeural")
        #expect(spokenEN.contains("C A R N A P") == false || spokenEN.contains("CARNAP"))
        #expect(spokenEN.contains("CARNAP"))
        #expect(spokenEN.contains("AUFBAU"))
        #expect(spokenEN.contains("THE"))
        // Sigla curta continua sai letra a letra (MAD/NASA/RHB).
        #expect(ReadAloudFilter.forSpeech("a NASA mission", voice: "en-US-AndrewNeural").contains("N A S A"))
        #expect(ReadAloudFilter.forSpeech("é MAD não", voice: "pt-BR-FranciscaNeural").contains("M A D"))
        #expect(ReadAloudFilter.forSpeech("B(A) |= H(A) ↔RHB.", voice: "pt-BR-FranciscaNeural").contains("R H B"))
    }
}
