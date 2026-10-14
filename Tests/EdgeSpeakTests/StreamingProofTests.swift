import Foundation
import Testing

@testable import EdgeSpeak

/// Headless proof of the two defects (no UI automation):
/// in-order delivery under out-of-order arrival, wait-without-stalling, and words.
@MainActor
struct StreamingProofTests {
    /// Jump by sentence with durations not yet measured (streaming): goes STRAIGHT
    /// to the sentence's slice, without clamping at the end of the measured audio. Before, the global
    /// time computed with zeroed offsets fell into slice 0 — the click read
    /// ANOTHER part (the defect the owner saw when clicking far away in the PDF).
    @Test func jumpByPhraseWithoutDurations() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-prova-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ nome: String) -> URL {
            let url = dir.appendingPathComponent(nome)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let amostras = 8000 // let samples = 8000 // 1 s of silence, 8 kHz mono 16-bit
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
            data.append(Data(count: amostras * 2))
            try? data.write(to: url)
            return url
        }
        let player = StreamingPlayer()
        // No durations (nil): zeroed offsets, as in streaming before the
        // probes — that is exactly the defect's condition.
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

    /// Track and ±15 s with durations not yet measured (streaming): no slice
    /// skipping. With zeroed offsets, `seek(to:)` lookup stopped at the LAST
    /// slice with the same start and skipped the earlier slices' audio — the variant on the
    /// click track that read another part. Now it goes back to the first with the same
    /// start (honest point: end of the measured passage, skipping nothing). With
    /// known durations the starts are strict and nothing changes.
    @Test func trackWithoutDurationsDoesNotSkipSlice() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-prova-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ nome: String) -> URL {
            let url = dir.appendingPathComponent(nome)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let amostras = 8000 // let samples = 8000 // 1 s of silence, 8 kHz mono 16-bit
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
            data.append(Data(count: amostras * 2))
            try? data.write(to: url)
            return url
        }
        let player = StreamingPlayer()
        // No durations (nil): only the 1st slice measures on play; the others stay
        // zeroed until the background probes — with no suspension point yet,
        // they are still zeroed, which is the defect's condition.
        player.start(urls: [wav("t0.wav")], durations: nil, chunkSegments: [[
            EdgeTTS.Segment(start: 0, duration: 1, text: "zero", index: 0, page: nil, rects: []),
        ]])
        player.enqueue(urls: [wav("t1.wav"), wav("t2.wav")], durations: nil, chunkSegments: [[
            EdgeTTS.Segment(start: 0, duration: 1, text: "um", index: 1, page: nil, rects: []),
        ], [
            EdgeTTS.Segment(start: 0, duration: 1, text: "dois", index: 2, page: nil, rects: []),
        ]])
        // Going to the end of the measured (that is where +15 s clamps): lands on the 1st un-
        // measured slice, without jumping to the last. Before, it landed on slice 2.
        player.seek(to: player.knownDuration)
        #expect(player.currentChunkIndex == 1)
        #expect(player.currentSegmentIndex == 1)
        #expect(player.isFinished == false)
        // Track at zero stays on the 1st slice, with consistent state.
        player.seek(to: 0)
        #expect(player.currentChunkIndex == 0)
        #expect(player.isFinished == false)
    }

    /// The slices finish out of order; delivery must come out 0..N.
    @Test func deliversInOrder() {
        let total = 10
        let pub = EdgeTTS.OrderedPublisher(total: total)
        var ready = [Bool](repeating: false, count: total)
        var emitted: [Int] = []
        // Out-of-order arrival: 3, 1, 0, 2, then the rest shuffled.
        for i in [3, 1, 0, 2, 5, 4, 9, 7, 6, 8] {
            ready[i] = true
            pub.emitReady({ ready[$0] }) { emitted.append($0) }
        }
        #expect(emitted == Array(0..<total))
    }

    /// A corrupted slice emptying the queue with synthesis in progress: it waits
    /// (`isStarved`), not end — and the next `enqueue` resumes.
    @Test func badSliceDoesNotStall() {
        let player = StreamingPlayer()
        let bad = URL(fileURLWithPath: "/inexistente/chunk-0000.mp3")
        player.start(urls: [bad], chunkSegments: [[]])
        #expect(player.isStarved == true)
        #expect(player.isFinished == false)
    }

    /// `play()` without `current` (queue starved) resumes when there is audio.
    @Test func playResumesWithoutCurrent() {
        let player = StreamingPlayer()
        let bad = URL(fileURLWithPath: "/inexistente/chunk-0000.mp3")
        player.start(urls: [bad], chunkSegments: [[]])
        #expect(player.isStarved == true)
        player.play()  // before: it returned through the `guard` doing nothing
        #expect(player.isStarved == true)  // with no new audio, stays starved
        #expect(player.isFinished == false)
    }

    /// The real path (`mapSegments` over script events) preserves words.
    @Test func wordsReachUI() {
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
        // Global indices preserved (jump by sentence during streaming).
        #expect(mapped.map { $0.index } == [0, 1])
    }

    /// Pre-buffering (owner choice): one slice holds the first sound and the
    /// third releases it — wait longer at the start, then never stall.
    @Test func startHoldsFirstSoundUntilBuffered() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-prebuf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ nome: String) -> URL {
            let url = dir.appendingPathComponent(nome)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let amostras = 8000
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
            data.append(Data(count: amostras * 2))
            try? data.write(to: url)
            return url
        }
        func segs(_ text: String, _ index: Int) -> [EdgeTTS.Segment] {
            [EdgeTTS.Segment(start: 0, duration: 1, text: text, index: index, page: nil, rects: [])]
        }
        let player = StreamingPlayer()
        player.start(urls: [wav("c0.wav")], durations: [1], chunkSegments: [segs("zero", 0)],
                     minStart: StreamingPlayer.minStartChunks)
        #expect(player.isBuffering == true)
        #expect(player.isPlaying == false)
        player.enqueue(urls: [wav("c1.wav")], durations: [1], chunkSegments: [segs("one", 1)])
        #expect(player.isBuffering == true)
        #expect(player.isPlaying == false)
        player.enqueue(urls: [wav("c2.wav")], durations: [1], chunkSegments: [segs("two", 2)])
        #expect(player.isBuffering == false)
        #expect(player.isPlaying == true)
        #expect(player.currentChunkIndex == 0)
    }

    /// A finished synthesis releases the held start with a single slice.
    @Test func finishedSynthesisReleasesHeldStart() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-prebuf2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ nome: String) -> URL {
            let url = dir.appendingPathComponent(nome)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let amostras = 8000
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
            data.append(Data(count: amostras * 2))
            try? data.write(to: url)
            return url
        }
        let player = StreamingPlayer()
        player.start(urls: [wav("c0.wav")], durations: [1],
                     chunkSegments: [[EdgeTTS.Segment(start: 0, duration: 1, text: "zero", index: 0, page: nil, rects: [])]],
                     minStart: StreamingPlayer.minStartChunks)
        #expect(player.isBuffering == true)
        player.markSynthesisComplete()
        #expect(player.isBuffering == false)
        #expect(player.isPlaying == true)
    }
}
