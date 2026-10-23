import Foundation
import Testing

@testable import EdgeSpeak

/// The queue closing with nothing playing. Before the fix,
/// `markSynthesisComplete` only handled the held-back (pre-buffer) start; a
/// document whose buffer ran out BEFORE the synthesis was declared complete
/// left `isStarved` set forever — the player announced "waiting for buffer"
/// with the audio already over (one-slice documents, or a document whose last
/// slice exhausted the queue).
@MainActor
struct SynthesisCompleteStarveTests {

    /// Minimal WAV writer: the player only needs a decodable file.
    private func wav(in dir: URL, _ name: String, samples: Int = 8000) -> URL {
        let url = dir.appendingPathComponent(name)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(samples * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        try? data.write(to: url)
        return url
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-completa-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A corrupted slice empties the queue (`isStarved`), synthesis is declared
    /// complete, and nothing is playing or paused: the reading must CLOSE.
    /// It used to stay starved forever — the bar kept announcing "waiting for
    /// buffer" with no audio ever coming.
    @Test func completionClosesAStarvedEmptyQueue() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = StreamingPlayer()
        player.start(urls: [URL(fileURLWithPath: dir.appendingPathComponent("inexistente.mp3").path)],
                     durations: [1],
                     chunkSegments: [[EdgeTTS.Segment(start: 0, duration: 1, text: "zero",
                                                      index: 0, page: nil, rects: [])]])
        #expect(player.isStarved == true)
        #expect(player.isFinished == false)

        player.markSynthesisComplete()

        #expect(player.isStarved == false)
        #expect(player.isFinished == true)
    }

    /// Same closing, but the queue emptied while a slice was still PLAYING: the
    /// sound belongs to `current`, so the completion must NOT jump the gun —
    /// the reading finishes when that slice ends.
    @Test func completionDoesNotCutOffAudioStillPlaying() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = StreamingPlayer()
        let audio = wav(in: dir, "c0.wav")
        player.start(urls: [audio], durations: [1],
                     chunkSegments: [[EdgeTTS.Segment(start: 0, duration: 1, text: "zero",
                                                      index: 0, page: nil, rects: [])]])
        #expect(player.isPlaying == true)
        player.markSynthesisComplete()
        // Playing: the state is still "reading", not "finished".
        #expect(player.isFinished == false)
    }
}