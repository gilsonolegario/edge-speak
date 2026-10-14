import Foundation
import Testing

@testable import EdgeSpeak

/// Trilho honesto: o valor que a barra lê (`SpeechController.elapsed`) segue
/// a posição TOCADA (`currentTime` da fatia corrente + deslocamento), sem o
/// atraso do retrato a ~10 Hz do karaokê. Sem áudio real na suíte: WAVs de
/// silêncio tocam de verdade no `AVAudioPlayer` headless, com o runloop
/// girando — o relógio de parede ancora a prova.
@MainActor
struct TrilhoHonestoTests {
    private func wav(_ nome: String, segundos: Int, dir: URL) -> URL {
        let url = dir.appendingPathComponent(nome)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let amostras = 8000 * segundos
        data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
        data.append(Data(count: amostras * 2))
        try? data.write(to: url)
        return url
    }

    private func dirTemporario() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-trilho-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Durante o play, o trilho acompanha o áudio: cada amostra bate com a
    /// posição tocada (tolerância de um tique do karaokê) e o total avança
    /// com o relógio de parede. Antes, o retrato a ~10 Hz deixava o trilho
    /// até ~130 ms preso — inclusive parado na fatia antiga após a troca.
    @Test func trilhoSeguePosicaoTocada() {
        let dir = dirTemporario()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controle = SpeechController()
        controle.streamer.start(
            urls: [wav("h0.wav", segundos: 2, dir: dir)],
            durations: [2.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 2, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        var primeira: TimeInterval?
        var ultima: TimeInterval = 0
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let trilho = controle.elapsed
            let tocada = controle.streamer.currentGlobalTime
            // O trilho é a posição tocada, não um retrato atrasado.
            #expect(abs(trilho - tocada) < 0.02)
            if primeira == nil { primeira = trilho }
            ultima = trilho
        }
        // E anda com o áudio (0,4 s de parede renderam avanço real).
        #expect(ultima - (primeira ?? 0) >= 0.2)
        #expect(controle.streamer.isPlaying == true)
    }

    /// Leitura terminada: o trilho marca o fim do áudio medido, sem congelar
    /// no último retrato do karaokê (que parava alguns ms antes do fim).
    @Test func trilhoNoFimQuandoAcaba() {
        let dir = dirTemporario()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controle = SpeechController()
        controle.streamer.start(
            urls: [wav("f0.wav", segundos: 1, dir: dir)],
            durations: [1.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 1, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        controle.streamer.markSynthesisComplete()
        let prazo = Date().addingTimeInterval(10)
        while !controle.streamer.isFinished, Date() < prazo {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(controle.streamer.isFinished == true)
        #expect(controle.elapsed == controle.knownDuration)
    }
}
