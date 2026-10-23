import Foundation
import Testing

@testable import EdgeSpeak

/// Audit finding M1 regression: jumping to a sentence in ANOTHER slice with
/// the queue drained (`isStarved`, synthesis in course) started the audio in
/// `playChunk` and then the `else` of `gotoChunk` rewrote
/// `isPlaying=false; isPaused=true`. The following `play()` became a no-op
/// (`player.isPlaying` already true) and the UI showed "paused" with sound —
/// the streamer is the source of state truth (SpeechController), so the declared
/// state must match the playing audio.
@MainActor
struct StreamingPlayerStarvedSeekTests {
    @Test func starvedJumpStaysPlaying() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-starved-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let samples = 2000 // 0,25 s de silêncio, 8 kHz mono 16 bits
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(samples * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(samples * 2))
            data.append(Data(count: samples * 2))
            try? data.write(to: url)
            return url
        }
        let player = StreamingPlayer()
        // Durações explícitas: dispensa as sondas em fundo e isola o cenário.
        player.start(
            urls: [wav("c0.wav"), wav("c1.wav")],
            durations: [0.25, 0.25],
            chunkSegments: [
                [EdgeTTS.Segment(start: 0, duration: 0.25, text: "zero", index: 0, page: nil, rects: [])],
                [EdgeTTS.Segment(start: 0, duration: 0.25, text: "one", index: 5, page: nil, rects: [])],
            ]
        )
        // Espera as duas fatias terminarem sem novo enqueue: fila esvaziada
        // com síntese em curso (`isStarved`, `isFinished == false`). O run
        // loop da main precisa girar para o delegate do AVAudioPlayer
        // entregar o fim de cada fatia.
        let deadline = Date().addingTimeInterval(10)
        while !player.isStarved, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(player.isStarved == true)
        #expect(player.isFinished == false)

        // Clique na frase da fatia 0 (outra fatia: `nextIndex` já passou das duas).
        #expect(player.jumpToSegment(0) == true)
        #expect(player.currentChunkIndex == 0)
        #expect(player.isStarved == false)
        // O áudio recomeçou no `playChunk`; o estado declarado tem de dizer
        // "tocando", não "pausado". Com o defeito: isPlaying == false e
        // isPaused == true, e o `play()` de `jumpToSegment` não corrigia.
        #expect(player.isPlaying == true)
        #expect(player.isPaused == false)
    }
}
