import Foundation
import Testing
import MediaPlayer

@testable import EdgeSpeak

/// Now Playing entry: the media keys only reach the app that owns the system
/// Now Playing state, so `SpeechController.publishNowPlaying()` writes the
/// REAL reading state (and clears it when nothing is read — a ghost entry
/// would steal the keys from whatever the user is actually listening to).
/// Headless: a recording sink replaces `MPNowPlayingInfoCenter`; the playing
/// states come from silence WAVs (same recipe as `HonestTrackTests`).

/// Recording sink: what would have been published, without the system.
/// File-scope (not nested in the `@MainActor` suite): it must satisfy the
/// nonisolated `NowPlayingSink` protocol without an isolation mismatch.
private final class RecordingSink: NowPlayingSink, @unchecked Sendable {
    private(set) var infos: [[String: Any]?] = []
    private(set) var states: [MPNowPlayingPlaybackState] = []
    func apply(info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        infos.append(info)
        states.append(state)
    }
    var lastInfo: [String: Any]? { infos.last ?? nil }
    var lastState: MPNowPlayingPlaybackState? { states.last }
}

@MainActor
struct LaneNowPlayingTests {
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
            .appendingPathComponent("EdgeSpeak-nowplaying-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Drena o RunLoop.main para o sink `.receive(on: RunLoop.main)` entregar.
    private func drena() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Pure mapping

    /// Playing snapshot: the real elapsed/duration go out, rate 1.0.
    @Test func mapeamentoTocandoCarregaTempoERaxaoReais() throws {
        let snapshot = NowPlaying.Snapshot(
            isPlaying: true, isPaused: false,
            elapsed: 12.5, duration: 90, title: "doc.pdf", artist: "pt-BR-Francisca")
        let info = try #require(NowPlaying.info(for: snapshot))
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 12.5)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 90)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(info[MPMediaItemPropertyTitle] as? String == "doc.pdf")
        #expect(info[MPMediaItemPropertyArtist] as? String == "pt-BR-Francisca")
        #expect(NowPlaying.playbackState(snapshot) == .playing)
    }

    /// Paused snapshot: same position, rate 0.0 — the system must STOP counting.
    @Test func mapeamentoPausadoTemRaxaoZero() throws {
        let snapshot = NowPlaying.Snapshot(
            isPlaying: false, isPaused: true,
            elapsed: 12.5, duration: 90, title: nil, artist: "")
        let info = try #require(NowPlaying.info(for: snapshot))
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
        #expect(NowPlaying.playbackState(snapshot) == .paused)
    }

    /// Nothing being read → nil: there is no entry to keep (and no ghost).
    @Test func mapeamentoOciosoENil() {
        let snapshot = NowPlaying.Snapshot(
            isPlaying: false, isPaused: false,
            elapsed: 0, duration: 0, title: nil, artist: "")
        #expect(NowPlaying.info(for: snapshot) == nil)
        #expect(NowPlaying.playbackState(snapshot) == .stopped)
    }

    /// Unknown duration is omitted, not published as a zero-length track.
    @Test func mapeamentoSemDuracaoConhecidaOmiteAChave() throws {
        let snapshot = NowPlaying.Snapshot(
            isPlaying: true, isPaused: false,
            elapsed: 3, duration: 0, title: nil, artist: "")
        let info = try #require(NowPlaying.info(for: snapshot))
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
    }

    // MARK: - Controller lifecycle (the very entry point the app uses)

    /// Idle controller never touches the sink: an entry published at launch
    /// would steal the media keys from the app the user is actually hearing.
    @Test func controladorOciosoNuncaPublica() {
        let sink = RecordingSink()
        let controller = SpeechController(nowPlayingSink: sink)
        controller.publishNowPlaying()
        drena()
        #expect(sink.infos.isEmpty)
        #expect(sink.states.isEmpty)
    }

    /// Play → pause → stop through the controller: the entry appears with the
    /// real measured time, freezes on pause (rate 0.0), and is CLEARED on
    /// stop — never left as a ghost pointing at a silent app.
    @Test func cicloTocarPausarPararPublicaENaoDeixaFantasma() throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RecordingSink()
        let controller = SpeechController(nowPlayingSink: sink)
        controller.streamer.start(
            urls: [wav("n0.wav", seconds: 3, dir: dir)],
            durations: [3.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 3, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        drena()
        // Playing: the entry exists, with the rate that lets the clock advance.
        #expect(controller.isPlaying == true)
        let tocando = try #require(sink.lastInfo)
        #expect(tocando[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(sink.lastState == .playing)

        // Pause: same position, but the system must stop counting.
        controller.pause()
        drena()
        let pausado = try #require(sink.lastInfo)
        #expect(pausado[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
        #expect(sink.lastState == .paused)

        // Stop: nothing is being read — the entry is removed.
        controller.stopPlayback()
        drena()
        #expect(sink.lastInfo == nil)
        #expect(sink.lastState == .stopped)
    }

    /// Finish: the audio ends by itself → the entry clears without any UI call.
    @Test func fimDaLeituraApagaAEntrada() throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RecordingSink()
        let controller = SpeechController(nowPlayingSink: sink)
        controller.streamer.start(
            urls: [wav("n1.wav", seconds: 1, dir: dir)],
            durations: [1.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 1, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        controller.streamer.markSynthesisComplete()
        drena()
        #expect(sink.lastInfo != nil)

        let deadline = Date().addingTimeInterval(10)
        while !controller.streamer.isFinished, Date() < deadline { drena() }
        #expect(controller.streamer.isFinished == true)
        #expect(sink.lastInfo == nil)
        #expect(sink.lastState == .stopped)
    }

    /// Discard: the document goes away — the entry is removed even before the
    /// streamer's async mirror gets to run.
    @Test func descartarTranscricaoApagaAEntrada() throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RecordingSink()
        let controller = SpeechController(nowPlayingSink: sink)
        controller.documentIDForPosition = dir.appendingPathComponent("doc.pdf").path
        controller.streamer.start(
            urls: [wav("n2.wav", seconds: 3, dir: dir)],
            durations: [3.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 3, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        drena()
        let comDocumento = try #require(sink.lastInfo)
        #expect(comDocumento[MPMediaItemPropertyTitle] as? String == "doc.pdf")

        controller.discardTranscription()
        drena()
        #expect(sink.lastInfo == nil)
        #expect(sink.lastState == .stopped)
    }

    /// Seek while playing: the entry is re-sent with the new position (the
    /// system only extrapolates from the last published elapsed + rate).
    @Test func seekRepublicaONovoTempo() throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RecordingSink()
        let controller = SpeechController(nowPlayingSink: sink)
        controller.streamer.start(
            urls: [wav("n3.wav", seconds: 3, dir: dir)],
            durations: [3.0],
            chunkSegments: [[
                EdgeTTS.Segment(start: 0, duration: 3, text: "zero", words: [], index: 0, page: nil, rects: []),
            ]])
        drena()
        let infoAntes = try #require(sink.lastInfo)
        let antes = infoAntes[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval

        controller.seek(to: 2.0)
        drena()
        let infoDepois = try #require(sink.lastInfo)
        let depois = infoDepois[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval
        // The published clock moved to the seek target (not extrapolated from
        // the old point); while playing it may advance a few ticks further.
        #expect(depois ?? 0 >= 2.0)
        #expect((depois ?? 0) > (antes ?? 0))
    }
}
