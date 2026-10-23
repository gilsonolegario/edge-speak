import Testing

@testable import EdgeSpeak

/// 2026-10-18 (dono): trocar a voz ou pedir «Gerar leitura nova» com leitura
/// em curso refaz a leitura DA FRASE ATUAL, não do início — a regra mora em
/// `ReadingRestartPolicy`, pura; aqui a prova, sem controller nem áudio.
struct ReadingRestartTests {
    @Test func currentSentenceIsTheRestartPoint() {
        // Frase atual no meio da lista: o corte sai dela.
        #expect(ReadingRestartPolicy.offset(highlightIndex: 5, indices: [1, 3, 5, 7, 9]) == 2)
        #expect(ReadingRestartPolicy.offset(highlightIndex: 9, indices: [1, 3, 5, 7, 9]) == 4)
    }

    @Test func nothingReadYetStartsFromTheTop() {
        // Antes da primeira frase (highlightIndex -1), não há o que anular.
        #expect(ReadingRestartPolicy.offset(highlightIndex: -1, indices: [1, 3, 5]) == 0)
    }

    @Test func unknownSentenceFallsBackToTheTop() {
        // Índice fora da lista (ex.: lista recém-filtrada) → início, nunca
        // um ponto arbitrário; lista vazia também não estoura.
        #expect(ReadingRestartPolicy.offset(highlightIndex: 42, indices: [1, 3, 5]) == 0)
        #expect(ReadingRestartPolicy.offset(highlightIndex: 0, indices: []) == 0)
    }
}
