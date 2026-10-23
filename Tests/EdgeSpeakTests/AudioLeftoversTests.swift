import Foundation
import Testing

@testable import EdgeSpeak

/// Lane "sobras de áudio" (plan items 14 and 17).
///
/// Item 14: a slice whose timing script came back empty entered with every
/// sentence at `start: 0` — the highlight rested on the slice's LAST sentence
/// for the whole audio — and a slice whose duration no probe could measure
/// entered the offset account as 0 without a word in the status. Item 17: the
/// volume was the only preference outside `AppSetting` and went back to 100% on
/// every launch.
///
/// Pure rules plus the controller funnel: no network, no audio files.
struct AudioLeftoversTests {
    // MARK: - Item 14: times of a slice without a script

    /// One slice per call, all sentences without times (what `mapSegments`
    /// produces over an empty script).
    private func untimed(_ texts: [String]) -> [EdgeTTS.Segment] {
        texts.enumerated().map { EdgeTTS.Segment(start: 0, duration: 0, text: $1, index: $0) }
    }

    /// The measured duration is split in proportion to the text: 8 and 2
    /// letters over 10 s give 8 s and 2 s — the highlight moves sentence by
    /// sentence instead of freezing on the last one.
    @Test func untimedSliceSplitsDurationInProportionToText() {
        let out = EdgeTTS.distributeUntimed(untimed(["aaabbbbb", "cc"]), over: 10)
        #expect(out[0].start == 0)
        #expect(abs(out[0].duration - 8) < 1e-9)
        #expect(abs(out[1].start - 8) < 1e-9)
        #expect(abs(out[1].duration - 2) < 1e-9)
    }

    /// Starts grow, sentences never overlap and the slice is covered end to
    /// end: the distribution is a timeline, not four sentences at the same
    /// instant.
    @Test func untimedSliceCoversTheWholeSlice() {
        let out = EdgeTTS.distributeUntimed(untimed(["a", "bb", "ccc", "dddd"]), over: 4)
        let starts = out.map(\.start)
        for i in 1..<starts.count {
            #expect(starts[i] > starts[i - 1], "frase \(i) começa onde a anterior começou")
        }
        let end = out[out.count - 1].start + out[out.count - 1].duration
        #expect(abs(end - 4) < 1e-9, "a fatia não foi coberta até o fim: \(end)")
        #expect(out.allSatisfy { $0.index >= 0 } , "índice global perdido na distribuição")
    }

    /// A real script is never rewritten: one usable time is enough to leave the
    /// whole slice as it came (the last sentences keep piling on the last known
    /// instant, as before).
    @Test func realTimingsAreNeverRewritten() {
        let timed = [
            EdgeTTS.Segment(start: 0.5, duration: 1, text: "aaaa", index: 0),
            EdgeTTS.Segment(start: 1.5, duration: 0.4, text: "aa", index: 1),
        ]
        #expect(EdgeTTS.distributeUntimed(timed, over: 9).map(\.start) == [0.5, 1.5])

        let partial = [
            EdgeTTS.Segment(start: 0, duration: 1.2, text: "aaaa", index: 0),
            EdgeTTS.Segment(start: 1.2, duration: 0, text: "aa", index: 1),
        ]
        #expect(EdgeTTS.distributeUntimed(partial, over: 5).map(\.duration) == [1.2, 0])
    }

    /// With no measured duration there is nothing to distribute and no
    /// division by zero: the slice stays as it was.
    @Test func withoutMeasuredDurationNothingMoves() {
        #expect(EdgeTTS.distributeUntimed(untimed(["aa", "bb"]), over: 0).map(\.duration) == [0, 0])
        #expect(EdgeTTS.distributeUntimed(untimed(["aa", "bb"]), over: -1).map(\.start) == [0, 0])
        #expect(EdgeTTS.distributeUntimed([], over: 3).isEmpty)
    }

    /// The zero-duration warning names the slice in both languages and cannot
    /// be read as progress: the bar parses `\d+/\d+` and would lie.
    @Test func unmeasuredDurationWarningIsNotProgress() {
        let pt = EdgeTTS.warningUnmeasuredDuration(slice: 4, locale: .pt)
        let en = EdgeTTS.warningUnmeasuredDuration(slice: 4, locale: .en)
        #expect(pt.contains("4"))
        #expect(en.contains("4"))
        #expect(pt != en)
        #expect(SpeechController.parseProgress(pt) == nil)
        #expect(SpeechController.parseProgress(en) == nil)
    }

    /// The rule is welded to the playback map: a slice whose script was empty
    /// and whose duration arrived measured must highlight the FIRST sentence at
    /// the start of the slice. Before, every `start` stayed at 0, the binary
    /// search always landed on the last one and the highlight spent the whole
    /// slice there.
    @MainActor
    @Test func startOfUntimedSliceHighlightsTheFirstSentence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-sem-tempos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c0.wav")
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let samples = 8000
        data.append(contentsOf: "RIFF".utf8); u32(36 + UInt32(samples * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        try data.write(to: url)

        let player = StreamingPlayer()
        player.start(
            urls: [url], durations: [1.0], chunkSegments: [untimed(["frase um.", "frase dois."])],
            minStart: 1)
        #expect(player.isPlaying)
        #expect(player.currentSegmentIndex == 0, "destacou a frase \(player.currentSegmentIndex)")
        #expect(player.currentSegmentText == "frase um.")
        // Targets for the click-jump: no longer all at the slice's zero.
        #expect(player.chunkStarts == [0])
    }

    /// Drena o RunLoop.main para o sink `.receive(on: RunLoop.main)` entregar.
    @MainActor
    private func drena() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    /// Ephemeral suite plus its name: the name is what erases it at the end
    /// (`description` of a `UserDefaults` is not the suite).
    private func ephemeralDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "audio-leftovers-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// The slice out of the measurement account reaches the status — the only
    /// sign a shifted track gets. Message matched against both languages: the
    /// controller resolves in the language of the machine running the suite.
    @MainActor
    @Test func unmeasuredSliceReachesTheStatus() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controle = SpeechController(defaults: defaults)
        #expect(controle.status.isEmpty)

        controle.streamer.noteUnmeasuredDuration(slice: 2)
        drena()
        let esperado = [
            L.get("warn.durationUnmeasured", locale: .pt, args: 3),
            L.get("warn.durationUnmeasured", locale: .en, args: 3),
        ]
        #expect(esperado.contains(controle.status), "status: \(controle.status)")

        // Ticks with no new slice: the warning stays, it is not overwritten.
        controle.streamer.volume = 0.4
        drena()
        #expect(esperado.contains(controle.status))

        // Another slice: the warning follows it.
        controle.streamer.noteUnmeasuredDuration(slice: 5)
        drena()
        #expect(controle.status.contains("6"), "status: \(controle.status)")
    }

    // MARK: - Item 17: volume persisted

    /// Key, default and clamping, straight against an ephemeral suite: absent
    /// key means the default, an explicit 0 is a real choice, out of range
    /// falls back instead of silencing the reading.
    @Test func volumeRoundTripLivesUnderItsOwnKey() {
        #expect(AppSetting.volumeKey == "readingVolume")
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppSetting.loadVolume(defaults: defaults) == AppSetting.volumeDefault)

        AppSetting.saveVolume(0.35, defaults: defaults)
        #expect(abs(AppSetting.loadVolume(defaults: defaults) - 0.35) < 1e-9)

        AppSetting.saveVolume(0, defaults: defaults)
        #expect(AppSetting.loadVolume(defaults: defaults) == 0)

        AppSetting.saveVolume(2, defaults: defaults)
        #expect(AppSetting.loadVolume(defaults: defaults) == 1)

        defaults.set(7.5, forKey: AppSetting.volumeKey)
        #expect(AppSetting.loadVolume(defaults: defaults) == AppSetting.volumeDefault)
    }

    /// Creation syncs both ends of the bar (the published value and the
    /// streamer, which is what each following slice reads) and every change is
    /// written back to the preferences.
    @MainActor
    @Test func controllerOpensAtStoredVolumeAndPersistsChanges() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.3, forKey: AppSetting.volumeKey)

        let controle = SpeechController(defaults: defaults)
        #expect(abs(controle.volume - 0.3) < 1e-6, "volume da barra: \(controle.volume)")
        #expect(abs(controle.streamer.volume - 0.3) < 1e-6, "volume do streamer: \(controle.streamer.volume)")

        controle.volume = 0.75
        let stored = (defaults.object(forKey: AppSetting.volumeKey) as? NSNumber)?.doubleValue ?? -1
        #expect(abs(stored - 0.75) < 1e-6, "gravado: \(stored)")
    }
}
