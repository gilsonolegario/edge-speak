import CoreGraphics
import Foundation
import Testing

@testable import EdgeSpeak

/// Fatiamento da síntese: fronteira em fim de parágrafo e aparo de silêncio.
///
/// Motivação do dono: a transição entre fatias picava — o corte caía no meio
/// do pensamento e cada fatia carregava o respiro final do TTS.
struct EdgeTTSChunkTests {
    private func frase(_ i: Int, tamanho: Int, fim: Bool = false) -> TextImport.Phrase {
        TextImport.Phrase(
            index: i, text: String(repeating: "x", count: tamanho),
            page: nil, rects: [], paragraphEnd: fim)
    }

    /// Com estouro no meio do parágrafo seguinte, o corte recua ao fim de
    /// parágrafo anterior em vez de partir o pensamento.
    @Test func fatiaCortaEmFimDeParagrafo() {
        let lista = [
            frase(0, tamanho: 100), frase(1, tamanho: 100, fim: true),
            frase(2, tamanho: 100), frase(3, tamanho: 100),
        ]
        let fatias = EdgeTTS.buildChunks(lista, maxChars: 350, firstChars: 350)
        #expect(fatias.map { $0.map(\.index) } == [[0, 1], [2, 3]])
    }

    /// Primeira fatia curta preservada (áudio entra rápido).
    @Test func primeiraFatiaCurta() {
        let lista = [frase(0, tamanho: 200), frase(1, tamanho: 200), frase(2, tamanho: 200)]
        let fatias = EdgeTTS.buildChunks(lista, maxChars: 1800)
        #expect(fatias.count == 2)
        #expect(fatias[0].map(\.index) == [0, 1])
    }

    /// Parágrafo maior que a fatia ainda parte (sem travar, sem perder frase).
    @Test func paragrafoGiganteAindaParte() {
        let lista = [frase(0, tamanho: 2000, fim: true), frase(1, tamanho: 100)]
        let fatias = EdgeTTS.buildChunks(lista, maxChars: 350, firstChars: 350)
        #expect(fatias.map { $0.map(\.index) } == [[0], [1]])
    }

    /// O aparo pede ao ffmpeg exatamente o silêncio do fim.
    @Test func aparoPedeSilencioDoFim() {
        let args = EdgeTTS.silenceTrimArgs(
            input: URL(fileURLWithPath: "/a.mp3"),
            output: URL(fileURLWithPath: "/b.mp3"))
        #expect(args.contains("/a.mp3"))
        #expect(args.contains("/b.mp3"))
        #expect(args.joined(separator: " ").contains("silenceremove=stop_periods=-1"))
    }

    /// JSON de tempos ilegível: áudio segue (segmentos vazios), mas o aviso
    /// volta — nunca sincronia zerada em silêncio.
    @Test func temposIlegiveisAvisamEmVezDeZerar() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(UUID().uuidString).json")
        try Data("{não é json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (segments, motivo) = EdgeTTS.loadSegments(url)
        #expect(segments.isEmpty)
        #expect(motivo?.isEmpty == false)
    }

    /// O aviso de sincronia não casa o "i/n" da barra de progresso: ele não
    /// é progresso, e a barra não pode inventar um andamento.
    @Test func avisoSemTemposNaoMenteABarra() {
        let aviso = EdgeTTS.avisoSemTempos(
            fatia: 3, motivo: "tempos ilegíveis em chunk-0003.json")
        #expect(SpeechController.parseProgress(aviso) == nil)
    }
}
