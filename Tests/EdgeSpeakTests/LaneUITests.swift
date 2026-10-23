import Foundation
import PDFKit
import Testing
import NaturalLanguage

@testable import EdgeSpeak

/// Lane UI/HIG 2026-10-17: as políticas puras dos itens 26, 29, 30, 36, 40,
/// 42, 43, 57b/S1 e o feedback do cache (item 28). Nada de app aqui — a UI
/// nativa (menu bar, hover, janela de Ajustes) fica para a verificação ao
/// vivo da integração.
struct LaneUITests {
    // MARK: - Item 43: presets de ritmo mais finos e amplos

    @Test func rateChoicesAreMonotonicAndReachTwoTimes() {
        let percents = EdgeTTS.Rate.choices.map(\.percent)
        #expect(percents == percents.sorted())
        #expect(percents.contains(-30))
        #expect(percents.contains(0))
        #expect(percents.contains(75))  // 1,75× (o teto antes era 1,5×)
        #expect(percents.contains(100)) // 2×
        // Sem duplicatas (o Picker nos Ajustes daria itens iguais).
        #expect(Set(percents).count == percents.count)
        // O normal continua sendo exatamente 0%.
        #expect(EdgeTTS.Rate.normal == EdgeTTS.Rate(percent: 0))
        #expect(EdgeTTS.Rate(percent: 75).cliValue == "+75%")
    }

    // MARK: - Item 26: título da janela/cabeçalho decodificado

    @Test func documentTitleDecodesPercentEscapes() {
        let raw = URL(fileURLWithPath: "/Users/uso/Docs/A Contingência.pdf")
            .absoluteString
        #expect(DocumentTitle.name(fromDocumentID: raw) == "A Contingência.pdf")
        #expect(DocumentTitle.name(fromDocumentID: "file:///tmp/Prova.pdf") == "Prova.pdf")
        // Sem documento: título do app, nunca vazio.
        #expect(DocumentTitle.name(fromDocumentID: nil) == "EdgeSpeak")
        #expect(DocumentTitle.name(fromDocumentID: "") == "EdgeSpeak")
    }

    // MARK: - Item 30: reserva compartilhada da barra flutuante

    @Test func floatingBarReserveStaysLargerThanGap() {
        // Os números continuam os do plano (74/14): a quebra de layout
        // esperada "barra cobre a última linha" é o que o item 30 trava.
        #expect(PlayerBarMetrics.reserve == 74)
        #expect(PlayerBarMetrics.gap == 14)
        #expect(PlayerBarMetrics.reserve > PlayerBarMetrics.gap)
    }

    // MARK: - Item 36: documentos recentes

    @Test func recentListDedupesFrontAndCaps() {
        let base = ["file:///a.pdf", "file:///b.pdf", "file:///c.pdf"]
        // Novo vai para a frente, sem duplicar.
        #expect(RecentDocumentsPolicy.list(base, adding: "file:///b.pdf")
            == ["file:///b.pdf", "file:///a.pdf", "file:///c.pdf"])
        #expect(RecentDocumentsPolicy.list(base, adding: "file:///d.pdf").first
            == "file:///d.pdf")
        // Entrada vazia ou inválida: lista intacta.
        #expect(RecentDocumentsPolicy.list(base, adding: "  ") == base)
        #expect(RecentDocumentsPolicy.list(base, adding: "%%") == base)
        // O limite corta o mais velho.
        var long: [String] = []
        for i in 0..<20 { long.append("file:///\(i).txt") }
        #expect(RecentDocumentsPolicy.list(long, adding: "file:///x.pdf").count
            == RecentDocumentsPolicy.limit)
        #expect(RecentDocumentsPolicy.list(long, adding: "file:///x.pdf").last
            == "file:///6.txt") // limite 8 → 7 antigos: 0…6
    }

    @Test func recentRecordPersistsIntoInjectableDefaults() {
        let ephemeral = UserDefaults(suiteName: #function)!
        defer { ephemeral.removePersistentDomain(forName: #function) }

        let docA = URL(fileURLWithPath: "/t/a.pdf")
        RecentDocumentsPolicy.record(docA, defaults: ephemeral)
        let docB = URL(fileURLWithPath: "/t/b.pdf")
        RecentDocumentsPolicy.record(docB, defaults: ephemeral)

        let urls = RecentDocumentsPolicy.urls(defaults: ephemeral)
        #expect(urls.map(\.lastPathComponent) == ["b.pdf", "a.pdf"])
        // A chave é a mesma que a cena (@AppStorage) lê.
        #expect(ephemeral.string(forKey: RecentDocumentsPolicy.defaultsKey) != nil)
        // JSON maciado → lista vazia (nunca crash de menu).
        ephemeral.set("não é json", forKey: RecentDocumentsPolicy.defaultsKey)
        #expect(RecentDocumentsPolicy.urls(defaults: ephemeral).isEmpty)
    }

    // MARK: - Item 40: filtro do painel e avanço do Find

    @Test func searchPolicyKeepsEverythingWithoutQueryAndIgnoresCase() {
        func phrase(_ text: String) -> TextImport.Phrase {
            TextImport.Phrase(index: 0, text: text, page: nil, rects: [], noteNumber: nil)
        }
        let list = [phrase("A casa amarela"), phrase("Sect. 2 já bateu"), phrase("ACLARO")]

        #expect(SearchPolicy.filter(list, by: "") == list)
        #expect(SearchPolicy.filter(list, by: "   ") == list)
        // Case-insensitive e acento-indiferente ("aclaro" pega "ACLARO").
        #expect(SearchPolicy.filter(list, by: "aclaro").map(\.text) == ["ACLARO"])
        #expect(SearchPolicy.filter(list, by: "casa").map(\.text) == ["A casa amarela"])
        #expect(SearchPolicy.filter(list, by: "xyz").isEmpty)
    }

    @Test func findAdvanceCyclesThroughMatches() {
        #expect(FindPolicy.next(shown: -1, count: 3) == 0)
        #expect(FindPolicy.next(shown: 0, count: 3) == 1)
        #expect(FindPolicy.next(shown: 2, count: 3) == 0)
        // Sem resultados: cursor segue em 0 (o PDF não mostra nada).
        #expect(FindPolicy.next(shown: 0, count: 0) == 0)
        #expect(FindPolicy.next(shown: 5, count: 0) == 0)
    }

    // MARK: - Item 42: ir para página e índice

    @Test func pageJumpSanitizesOneBasedInput() {
        // "12" em documento de 300 páginas → índice 11 (0-based).
        #expect(PageJump.sanitize("12", pageCount: 300) == 11)
        #expect(PageJump.sanitize("  5 ", pageCount: 300) == 4)
        #expect(PageJump.sanitize("1", pageCount: 300) == 0)
        #expect(PageJump.sanitize("300", pageCount: 300) == 299)
        // Fora da faixa, sem número ou documento vazio → nil (status avisa).
        #expect(PageJump.sanitize("301", pageCount: 300) == nil)
        #expect(PageJump.sanitize("0", pageCount: 300) == nil)
        #expect(PageJump.sanitize("abc", pageCount: 300) == nil)
        #expect(PageJump.sanitize("", pageCount: 300) == nil)
        #expect(PageJump.sanitize("1", pageCount: 0) == nil)
    }

    @Test func outlineListingWalksChildrenWithoutDestination() {
        // PDF sem outline → lista vazia (a linha de navegação nem aparece).
        let plain = PDFDocument()
        #expect(OutlineListing.entries(in: plain).isEmpty)

        // Outline com dois filhos e um neto sem destino: títulos saem em
        // ordem de leitura (DFS) e a página é nil (nada para navegar).
        let doc = PDFDocument()
        let root = PDFOutline()
        let first = PDFOutline()
        first.label = "Capítulo 1"
        let second = PDFOutline()
        second.label = "Capítulo 2"
        let nested = PDFOutline()
        nested.label = "Seção 2.1"
        second.insertChild(nested, at: 0)
        first.insertChild(PDFOutline(), at: 0) // sem rótulo: some da lista
        // Ordem que o PDFKit exige: raiz presa ao documento ANTES dos filhos.
        // Inserir e depois atribuir outlineRoot deixa a árvore órfã e
        // childAtIndex: aborta (NSException) — por isso a atribuição vem
        // primeiro aqui.
        doc.outlineRoot = root
        root.insertChild(first, at: 0)
        root.insertChild(second, at: 1)

        let entries = OutlineListing.entries(in: doc)
        // DFS em ordem de leitura: C1 → C2 (o unlabeled some) → o neto.
        #expect(entries.map(\.title) == ["Capítulo 1", "Capítulo 2", "Seção 2.1"])
        #expect(entries.allSatisfy { $0.page == nil })
        #expect(entries.map(\.id).count == Set(entries.map(\.id)).count)
    }

    // MARK: - Item 26 (revisão): subtítulo da janela no lugar do cabeçalho

    @Test func windowSubtitleKeepsReadingOrderAndDropsEmpties() {
        #expect(DocumentHeaderInfo.subtitle(
            pageText: "Page 1", voiceText: "Antonio (Brazil, masculine)",
            highlight: nil) == "Page 1 • Antonio (Brazil, masculine)")
        // Modo destacar ligado: o aviso entra no FIM, sem quebrar a ordem.
        #expect(DocumentHeaderInfo.subtitle(
            pageText: "Page 1", voiceText: "Voz", highlight: "Destacar")
            == "Page 1 • Voz • Destacar")
        // Parte vazia some (nunca um "•" solto).
        #expect(DocumentHeaderInfo.subtitle(
            pageText: "", voiceText: "Voz", highlight: nil) == "Voz")
        #expect(DocumentHeaderInfo.subtitle(
            pageText: "", voiceText: "", highlight: nil) == "")
        #expect(DocumentHeaderInfo.subtitle(
            pageText: "", voiceText: "", highlight: "Destacar") == "Destacar")
    }

    // MARK: - Item 28: formatação do feedback do cache

    @Test func cacheFeedbackUsesTheControllerRuler() {
        #expect(CacheFeedback.freedText(0) == "1 KB")
        #expect(CacheFeedback.freedText(2_048) == "2 KB")
        #expect(CacheFeedback.freedText(1_048_576) == "1 MB")
        #expect(CacheFeedback.freedText(3_485_701) == "3 MB")
    }

    // MARK: - Item 57b (S1): decisão do aviso de idioma

    @Test func languageNoticeOnlyFiresWhenSomethingToSay() {
        let name = LanguageNotice.languageName(for: .german, locale: .pt)
        #expect(name == "alemão")
        #expect(LanguageNotice.languageName(for: .portuguese, locale: .en) == "Portuguese")
        // Idioma sem chave no catálogo: o identificador cru (honesto).
        #expect(LanguageNotice.languageName(
            for: NLLanguage(rawValue: "sw")) == "sw")

        // Sem detecção → nada.
        #expect(LanguageNotice.decide(
            suggestion: nil, currentVoice: "qualquer",
            languageNameFor: { _ in "x" }) == nil)

        let german = DocumentLanguage.Suggestion(language: .german, voice: nil)
        // Idioma sem voz no app → recado honesto, sempre.
        #expect(LanguageNotice.decide(
            suggestion: german, currentVoice: "pt-BR-FranciscaNeural",
            languageNameFor: { _ in "alemão" })
            == .noVoice(languageName: "alemão"))

        let english = DocumentLanguage.Suggestion(language: .english, voice: "offline-lessac-enus")
        // Voz compatível é OUTRA → oferecer a troca.
        #expect(LanguageNotice.decide(
            suggestion: english, currentVoice: "pt-BR-FranciscaNeural",
            languageNameFor: { _ in "inglês" })
            == .compatible(languageName: "inglês", voice: "offline-lessac-enus"))
        // Voz compatível JÁ é a escolhida → silêncio.
        #expect(LanguageNotice.decide(
            suggestion: english, currentVoice: "offline-lessac-enus",
            languageNameFor: { _ in "inglês" }) == nil)
    }
}
