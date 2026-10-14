import Foundation
import Testing

@testable import EdgeSpeak

/// Honest track: the value the bar reads (`SpeechController.elapsed`) follows
/// the PLAYED position (`currentTime` of the current slice + offset), without
/// the karaoke's ~10 Hz snapshot lag. No real audio in the suite: silence WAVs
/// really play in the headless `AVAudioPlayer`, with the runloop spinning —
/// the wall clock anchors the proof.
@MainActor
struct HonestTrackTests {
    private func wav(_ name: String, seconds: Int, dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let samples = 8000 * seconds
        data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(samples * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        try? data.write(to: url)
        return url
    }

    private func temporaryDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-track-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// During play, the track follows the audio: each sample matches the
    /// played position (one karaoke tick of tolerance) and the total advances
    /// with the wall clock. Before, the ~10 Hz snapshot left the track up to
    /// ~130 ms stuck — including stopped on the old slice after the switch.
    @Test func trackFollowsPlayedPosition() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = SpeechController()
        controller.streamer.start(
            urls: [wav("h0.wav", seconds: 2, dir: dir)],
            durations: [2.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 2, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        var first: TimeInterval?
        var last: TimeInterval = 0
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let track = controller.elapsed
            let played = controller.streamer.currentGlobalTime
            // The track is the played position, not a stale snapshot.
            #expect(abs(track - played) < 0.02)
            if first == nil { first = track }
            last = track
        }
        // And it moves with the audio (0.4 s of wall clock rendered real advance).
        #expect(last - (first ?? 0) >= 0.2)
        #expect(controller.streamer.isPlaying == true)
    }

    /// Finished reading: the track marks the measured audio end, without freezing
    /// on the karaoke's last snapshot (which stopped a few ms before the end).
    @Test func trackAtEndWhenFinished() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = SpeechController()
        controller.streamer.start(
            urls: [wav("f0.wav", seconds: 1, dir: dir)],
            durations: [1.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 1, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        controller.streamer.markSynthesisComplete()
        let deadline = Date().addingTimeInterval(10)
        while !controller.streamer.isFinished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(controller.streamer.isFinished == true)
        #expect(controller.elapsed == controller.knownDuration)
    }
}
