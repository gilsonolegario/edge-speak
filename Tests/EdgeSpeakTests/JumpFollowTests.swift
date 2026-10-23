import Foundation
import Testing

@testable import EdgeSpeak

/// Jump (click/drag) must not leave the reading with audio running and the
/// highlight frozen: the karaoke timer is what moves the sentence, the word and
/// the clock snapshot. These tests fail when the timer is not reinstalled on the
/// seek state machine, because `play()` cannot do it — the player is already
/// playing at that point, so its `guard !player.isPlaying` returns early.
/// `.serialized`: these tests drive a real `AVAudioPlayer` and read the main run
/// loop (the karaoke tick is a `Timer` there). Run in parallel with the rest of
/// the suite, the clock starved and the poll ran out — the flake reproduced only
/// in the full run.
@MainActor
@Suite(.serialized)
struct JumpFollowTests {
    /// 200 sentences of 0.5 s each, as silence in a valid 8 kHz mono WAV (100 s).
    ///
    /// The slice is deliberately far longer than any poll below: the suite runs in
    /// parallel with the rest of the process (and with whatever else the machine
    /// is doing), so the slice must never END while the test waits — with a short
    /// one the audio could reach the end of the queue before the karaoke tick
    /// fired, and the check would be measuring the wrong thing.
    private func fixture() -> (player: StreamingPlayer, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-follow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("c0.wav")
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let amostras = 800_000  // 100 s
        data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
        data.append(Data(count: amostras * 2))
        try? data.write(to: url)
        let player = StreamingPlayer()
        player.start(urls: [url], durations: [100.0], chunkSegments: [(0..<200).map { i in
            EdgeTTS.Segment(start: Double(i) * 0.5, duration: 0.5,
                            text: "frase \(i)", index: i, page: nil, rects: [])
        }])
        return (player, dir)
    }

    /// Highest highlight index seen while polling, instead of a fixed sleep: the
    /// karaoke tick lands at 100 ms, so the instant a sentence is crossed depends
    /// on where the ticks fall — and under load they fall seconds late.
    ///
    /// The MAXIMUM is what makes this honest. A "did it move?" condition also
    /// passes for the wrong reason: when the audio reaches the end of the slice,
    /// the delegate clears the highlight (-1), which is a move without the tick
    /// ever having run. Measured — the test passed against the unfixed code that
    /// way.
    /// Generous budget: the tick is a main-run-loop `Timer`, and with the app
    /// synthesizing in parallel the loop can be busy for seconds. A dead tick
    /// never recovers, so a long budget only costs time in the failing case.
    private func maxIndexSeen(limit: Int = 120, _ read: () -> Int) async -> Int {
        var best = read()
        for _ in 0..<limit {
            if best >= 2 { return best }
            try? await Task.sleep(nanoseconds: 100_000_000)
            best = max(best, read())
        }
        return best
    }

    /// Paused reading + click inside the SAME slice: the audio resumes from the
    /// clicked sentence, so the highlight must leave it. Before the fix the jump
    /// played without the karaoke timer and the highlight stayed on the clicked
    /// sentence for the rest of the slice (measured: stuck on 0 while the audio
    /// went from 0.4 s to 0.8 s).
    @Test func clickWhilePausedKeepsHighlightMoving() async throws {
        let (player, dir) = fixture()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        player.pause()
        #expect(player.isPaused == true)
        #expect(player.jumpToSegment(1) == true)
        #expect(player.isPlaying == true)
        // Positioned on the clicked sentence at once: the jump used the intended
        // offset, not a `currentTime` read stale from before `play()`.
        #expect(player.currentSegmentIndex == 1)
        // It must REACH the next sentence, not merely stop being the clicked one.
        #expect(await maxIndexSeen { player.currentSegmentIndex } >= 2)
    }

    /// Same jump, on the snapshot clock: `elapsed` is published by the karaoke
    /// tick, so a frozen tick also freezes the bar and the resume position. The
    /// live `currentGlobalTime` is read from the player itself, hence it would
    /// move even with a dead tick — the snapshot is the one under test.
    @Test func clickWhilePausedKeepsSnapshotClockMoving() async throws {
        let (player, dir) = fixture()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        player.pause()
        #expect(player.jumpToSegment(1) == true)
        let before = player.elapsed
        // 500 ms, not 300: after a seek the audio clock trails ~100 ms before it
        // catches up, so the tick publishes ~0.39 s of audio in the first 300 ms.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(player.elapsed > before + 0.25)
    }

    /// Dragging the bar while paused goes through the same state machine
    /// (`seek(to:)` → `gotoChunk`), so the tick must live there too.
    @Test func seekWhilePausedKeepsSnapshotClockMoving() async throws {
        let (player, dir) = fixture()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        player.pause()
        player.seek(to: 0.5)
        #expect(player.currentSegmentIndex == 1)
        let before = player.elapsed
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(player.elapsed > before + 0.25)
    }

    /// The pre-buffer hold must not fire on top of a jump made while it waits:
    /// the release restarted the slice from zero and the sentence the user had
    /// just chosen was heard twice. `elapsed` cannot see it (a stale snapshot
    /// until the next tick), so the assertion is on the position actually read
    /// from the player — and on the highlight, which the replay pulled back to
    /// the first sentence.
    @Test func clickDuringBufferDoesNotReplaySlice() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-replay-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func wav(_ nome: String) -> URL {
            let url = dir.appendingPathComponent(nome)
            var data = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let amostras = 8000  // 1 s
            data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
            data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
            data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
            data.append(Data(count: amostras * 2))
            try? data.write(to: url)
            return url
        }
        let player = StreamingPlayer()
        player.start(urls: [wav("c0.wav")], durations: [1], chunkSegments: [[
            EdgeTTS.Segment(start: 0.0, duration: 0.4, text: "zero", index: 0, page: nil, rects: []),
            EdgeTTS.Segment(start: 0.4, duration: 0.6, text: "one", index: 1, page: nil, rects: []),
        ]], minStart: StreamingPlayer.minStartChunks)
        #expect(player.isBuffering == true)
        #expect(player.jumpToSegment(1) == true)
        #expect(abs(player.currentGlobalTime - 0.4) < 0.05)
        // Slices arriving now used to release the hold over the jump.
        player.enqueue(urls: [wav("c1.wav")], durations: [1], chunkSegments: [[
            EdgeTTS.Segment(start: 0.0, duration: 1.0, text: "two", index: 2, page: nil, rects: []),
        ]])
        player.enqueue(urls: [wav("c2.wav")], durations: [1], chunkSegments: [[
            EdgeTTS.Segment(start: 0.0, duration: 1.0, text: "three", index: 3, page: nil, rects: []),
        ]])
        #expect(player.isBuffering == false)
        #expect(player.currentChunkIndex == 0)
        // Still on the clicked sentence, not rewound to the start of the slice.
        #expect(abs(player.currentGlobalTime - 0.4) < 0.1)
        #expect(player.currentSegmentIndex == 1)
        player.stop()
    }

    /// A year/number arrives as ONE timed word lasting over a second ("1950"
    /// ≈ 1.4 s, spoken "mil novecentos e cinquenta"). The creep used to fire
    /// 0.9 s into it, jumping the yellow ahead, and the next tick snapped it
    /// back — the word flickered on citations. The published word must never
    /// move backward inside a sentence.
    @Test func longWordDoesNotFlickerBack() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-nudge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c0.wav")
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let amostras = 800_000  // 100 s: the slice must never end mid-test
        data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(amostras * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(amostras * 2))
        data.append(Data(count: amostras * 2))
        try? data.write(to: url)
        let player = StreamingPlayer()
        player.start(urls: [url], durations: [100.0], chunkSegments: [[
            EdgeTTS.Segment(start: 0.0, duration: 3.0, text: "Carta 1950, página 12.",
                words: [
                    EdgeTTS.Segment.Word(start: 0.0, duration: 0.3, text: "Carta"),
                    EdgeTTS.Segment.Word(start: 0.3, duration: 2.0, text: "1950"),
                    EdgeTTS.Segment.Word(start: 2.3, duration: 0.4, text: "página"),
                    EdgeTTS.Segment.Word(start: 2.7, duration: 0.3, text: "12"),
                ], index: 0, page: nil, rects: []),
        ]])
        // Sample the published word until just before "página" genuinely
        // starts (2.3 s): any 2 there is the false creep, and any drop
        // afterwards is the snap-back.
        var seen: [Int] = []
        var timerRan = false
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if player.isHighlightTimerRunning { timerRan = true }
            guard player.elapsed < 2.0 else { break }
            seen.append(player.currentWordIndex)
        }
        #expect(timerRan == true)
        #expect(seen.contains(1))  // ticks ran inside the long word
        #expect(seen.max() == 1)   // never crept early onto "página"
        #expect(seen == seen.sorted())  // never moved backward
        player.stop()
    }
}
