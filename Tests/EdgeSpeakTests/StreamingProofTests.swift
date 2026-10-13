import Foundation
import Testing

@testable import EdgeSpeak

/// Prova headless dos dois defeitos (sem automação de UI):
/// entrega em ordem sob chegada fora de ordem, espera-sem-travar e words.
@MainActor
struct StreamingProofTests {
    /// Salto por frase com durações ainda não medidas (streaming): vai DIRETO
    /// à fatia da frase, sem grampear no fim do áudio medido. Antes, o tempo
    /// global calculado com offsets zerados caía na fatia 0 — o clique lia
    /// OUTRA parte (defeito que o dono viu ao clicar longe no PDF).
    @Test func saltoPorFraseSemDuracoes() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-prova-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ nome: String) -> URL {
            let url = dir.appendingPathComponent(nome)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let amostras = 8000 // 1 s de silêncio, 8 kHz mono 16 bits
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
            data.append(Data(count: amostras * 2))
            try? data.write(to: url)
            return url
        }
        let player = StreamingPlayer()
        // Sem durações (nil): offsets zerados, como no streaming antes das
        // sondas — é exatamente a condição do defeito.
        player.start(urls: [wav("c0.wav")], durations: nil, chunkSegments: [[
            EdgeTTS.Segment(start: 0, duration: 1, text: "zero", index: 0, page: nil, rects: []),
        ]])
        player.enqueue(urls: [wav("c1.wav")], durations: nil, chunkSegments: [[
            EdgeTTS.Segment(start: 0, duration: 1, text: "cinco", index: 5, page: nil, rects: []),
        ]])
        #expect(player.seek(toSegment: 5) == true)
        #expect(player.currentChunkIndex == 1)
        #expect(player.currentSegmentIndex == 5)
    }

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
