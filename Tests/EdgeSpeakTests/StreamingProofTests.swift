import Foundation
import Testing

@testable import EdgeSpeak

/// Prova headless dos dois defeitos (sem automação de UI):
/// entrega em ordem sob chegada fora de ordem, espera-sem-travar e words.
@MainActor
struct StreamingProofTests {
    /// As fatias terminam fora de ordem; a entrega precisa sair 0..N.
    @Test func entregaEmOrdem() {
        let total = 10
        let pub = EdgeTTS.OrderedPublisher(total: total)
        var ready = [Bool](repeating: false, count: total)
        var emitted: [Int] = []
        // Chegada fora de ordem: 3, 1, 0, 2, depois o resto embaralhado.
        for i in [3, 1, 0, 2, 5, 4, 9, 7, 6, 8] {
            ready[i] = true
            pub.emitReady({ ready[$0] }) { emitted.append($0) }
        }
        #expect(emitted == Array(0..<total))
    }

    /// Fatia corrompida esvaziando a fila com síntese em curso: espera
    /// (`isStarved`), não fim — e o `enqueue` seguinte retoma.
    @Test func fatiaRuimNaoTrava() {
        let player = StreamingPlayer()
        let ruim = URL(fileURLWithPath: "/inexistente/chunk-0000.mp3")
        player.start(urls: [ruim], chunkSegments: [[]])
        #expect(player.isStarved == true)
        #expect(player.isFinished == false)
    }

    /// `play()` sem `current` (fila em espera) retoma quando há áudio.
    @Test func playRetomaSemCurrent() {
        let player = StreamingPlayer()
        let ruim = URL(fileURLWithPath: "/inexistente/chunk-0000.mp3")
        player.start(urls: [ruim], chunkSegments: [[]])
        #expect(player.isStarved == true)
        player.play()  // antes: saía pelo `guard` sem fazer nada
        #expect(player.isStarved == true)  // sem áudio novo, segue em espera
        #expect(player.isFinished == false)
    }

    /// O caminho real (`mapSegments` sobre eventos do script) preserva words.
    @Test func wordsChegamAteAUi() {
        let script = [
            EdgeTTS.Segment(
                start: 0.0, duration: 0.5, text: "Hello world.",
                words: [
                    EdgeTTS.Segment.Word(start: 0.0, duration: 0.2, text: "Hello"),
                    EdgeTTS.Segment.Word(start: 0.2, duration: 0.3, text: "world"),
                ]),
            EdgeTTS.Segment(
                start: 0.5, duration: 0.4, text: "I am here.",
                words: [
                    EdgeTTS.Segment.Word(start: 0.5, duration: 0.1, text: "I"),
                    EdgeTTS.Segment.Word(start: 0.6, duration: 0.1, text: "am"),
                    EdgeTTS.Segment.Word(start: 0.7, duration: 0.2, text: "here"),
                ]),
        ]
        let phrases = [
            TextImport.Phrase(index: 0, text: "Hello world.", page: nil, rects: []),
            TextImport.Phrase(index: 1, text: "I am here.", page: nil, rects: []),
        ]
        let mapped = EdgeTTS.mapSegments(script, phrases)
        #expect(mapped.count == 2)
        #expect(mapped.allSatisfy { !$0.words.isEmpty })
        #expect(mapped.flatMap { $0.words }.count == 5)
        // Índices globais preservados (salto por frase durante o streaming).
        #expect(mapped.map { $0.index } == [0, 1])
    }
}
