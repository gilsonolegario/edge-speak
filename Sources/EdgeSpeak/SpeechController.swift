import Foundation
import AppKit
import AVFoundation
import Combine

/// Sendable box to carry progress messages from the background thread to the main.
private final class StatusRelay: @unchecked Sendable {
    weak var controller: SpeechController?
}

/// Plano item 18 (a11y): o que cada status TERMINAL pede ao VoiceOver, e o
/// que é falha (banner persistentе — item 18). Puro e testável: a classificação
/// vive aqui, o efeito (post de anúncio) é a fina camada abaixo. progresso
/// (msg crua, sem chave) nunca anuncia — senão cada tick de fatia viraria
/// fala em cima de fala.
enum AccessibilityAnnouncements {
    /// Plano item 18: o macOS não tem `.announcement` nomeado no enum —
    /// a via pública é a notificação raw `AXAnnouncementRequested`
    /// (AXNotificationConstants.h:315), com a mensagem em `AXAnnouncementKey`
    /// (:327) e prioridade em `AXPriorityKey` (:323, alta = 90).
    private static let announcementNotification =
        NSAccessibility.Notification(rawValue: "AXAnnouncementRequested")
    private static let messageKey =
        NSAccessibility.NotificationUserInfoKey(rawValue: "AXAnnouncementKey")
    private static let priorityKey =
        NSAccessibility.NotificationUserInfoKey(rawValue: "AXPriorityKey")

    /// Terminal kinds: loaded (content entered), finished (reading ended),
    /// cancelled (stop/cancel), failure (synthesis/import failure).
    enum Kind {
        case loaded
        case finished
        case cancelled
        case failure
    }

    /// Classifies by catalog key. The set is the TERMINAL one of the plan
    /// item 18: loaded, error, finished, cancelled — anything else (progress,
    /// playing warnings, rate) is pre-tick and returns nil.
    static func kind(of statusKey: String?) -> Kind? {
        guard let key = statusKey else { return nil }
        switch key {
        case "status.fileLoaded", "status.textPasted":
            return .loaded
        case "status.finished":
            return .finished
        case "status.stopped", "common.synthesisCancelled", "status.importCancelled":
            return .cancelled
        // Failures — including those resolved by `failureKey` (errors carried
        // by the engines via `l10nKey`) and those written directly by the UI.
        case "status.onlineBlocked", "status.openFailed", "status.synthesisStalled",
             "status.exportFailed", "pdf.exportFailed", "summary.failed":
            return .failure
        default:
            return key.hasPrefix("error.") || key.hasPrefix("status.failure.") ? .failure : nil
        }
    }

    /// Whether the current message is a failure: the banner does not dismiss
    /// itself while the failure is current (plan item 18). Progress clears
    /// (`reportProgress`) and any new message re-classifies in `storeStatus`.
    static func isFailure(_ statusKey: String?) -> Bool {
        kind(of: statusKey) == .failure
    }

    /// Effective layer: posts the announcement to the system with the text
    /// ALREADY resolved (`status`). Without VoiceOver active, posting is a
    /// no-op of the OS — the cost falls on terminal events only.
    @MainActor
    static func post(_ message: String, kind: Kind) {
        let element: AnyObject = NSApp.mainWindow ?? NSApp
        // Falha importa: prioridade alta (90) antes das notícias correntes.
        let priority: Int = kind == .failure ? 90 : 50
        NSAccessibility.post(
            element: element,
            notification: announcementNotification,
            userInfo: [Self.messageKey: message, Self.priorityKey: priority])
    }

    /// Plan item 23: after opening a PDF / changing the content, the window
    /// was narrated before the new area existed — VoiceOver landed on element
    /// without speaks. `.layoutChanged` replays the new content.
    @MainActor
    static func postLayoutChanged() {
        guard let window = NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .layoutChanged,
            userInfo: [:])
    }
}

/// Plan item 41: the times of the reading exported BESIDE the audio file.
///
/// The exported MP3/WAV went out alone: on another player there was no
/// follow-along and no jump by sentence. The `Segment` list the app already
/// keeps for the highlight (`SpeechController.segments`) is what describes
/// that audio — `start`/`duration` are instants inside the FINAL file (the
/// single-file path shifts each slice by its accumulated offset, and the
/// cache stores that same list, so a cache replay exports the same times),
/// and `words[].start` travels with the sentence, hence also global here.
///
/// Serialization is pure (strings in, strings out, no I/O and no main actor)
/// so the suite pins it byte by byte; the writing to disk is one call at the
/// end of `writeBeside`.
enum SubtitleExporter {
    /// The three carriers written next to the audio, in this order.
    enum Format: String, CaseIterable {
        case srt
        case vtt
        case json

        var pathExtension: String { rawValue }
    }

    /// Sidecar path derived from the exported audio: `leitura.mp3` →
    /// `leitura.srt`. Same directory, same stem, only the extension changes.
    static func sidecarURL(for audio: URL, format: Format) -> URL {
        audio.deletingPathExtension().appendingPathExtension(format.pathExtension)
    }

    /// Renders the segment list in one of the three formats.
    static func serialize(_ segments: [EdgeTTS.Segment], as format: Format) -> String {
        switch format {
        case .srt: return srt(segments)
        case .vtt: return vtt(segments)
        case .json: return json(segments)
        }
    }

    /// Writes the three carriers beside `audio`; returns whether there was
    /// anything to write (an empty list means the reading has no times yet —
    /// then no file is created, and the audio goes out alone as before).
    @discardableResult
    static func writeBeside(_ segments: [EdgeTTS.Segment], audio: URL) throws -> Bool {
        guard !segments.isEmpty else { return false }
        for format in Format.allCases {
            try serialize(segments, as: format)
                .write(
                    to: sidecarURL(for: audio, format: format),
                    atomically: true,
                    encoding: .utf8)
        }
        return true
    }

    // MARK: - Formats

    /// SubRip: `1`, the range with a comma in the milliseconds, the text, and
    /// a blank line between cues.
    static func srt(_ segments: [EdgeTTS.Segment]) -> String {
        let cues = ordered(segments).enumerated().map { (i, segment) in
            """
            \(i + 1)
            \(timecode(segment.start, decimalComma: true)) --> \(timecode(end(of: segment), decimalComma: true))
            \(cueText(segment.text))
            """
        }
        return cues.isEmpty ? "" : cues.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT: the `WEBVTT` header (then a blank line), then the cues WITHOUT
    /// a number (VTT does not need one) and with a dot in the milliseconds.
    static func vtt(_ segments: [EdgeTTS.Segment]) -> String {
        let cues = ordered(segments).map { segment in
            """
            \(timecode(segment.start, decimalComma: false)) --> \(timecode(end(of: segment), decimalComma: false))
            \(cueText(segment.text))
            """
        }
        guard !cues.isEmpty else { return "WEBVTT\n" }
        return "WEBVTT\n\n" + cues.joined(separator: "\n\n") + "\n"
    }

    /// JSON: an array of cues in reading order, keys sorted alphabetically by
    /// `JSONEncoder` and identical bytes for identical input (the suite asserts
    /// it). `words` comes from the timing script and is ABSENT when the engine
    /// brought none (Piper) — an empty array would suggest times that do not
    /// exist.
    static func json(_ segments: [EdgeTTS.Segment]) -> String {
        let cues: [JSONCue] = ordered(segments).map { segment in
            JSONCue(
                start: segment.start,
                duration: segment.duration,
                text: segment.text,
                index: segment.index >= 0 ? segment.index : nil,
                page: segment.page,
                words: segment.words.isEmpty
                    ? nil
                    : segment.words.map {
                        JSONCue.JSONWord(start: $0.start, duration: $0.duration, text: $0.text)
                    })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard !cues.isEmpty else { return "[]\n" }
        guard let data = try? encoder.encode(cues),
              let text = String(data: data, encoding: .utf8) else { return "[]\n" }
        return text + "\n"
    }

    /// Sorted by start instant, with the global index as tiebreak: a subtitle
    /// file out of order makes players drop cues, and the untimed slices all
    /// start at zero, where the index is the only order that means anything.
    private static func ordered(_ segments: [EdgeTTS.Segment]) -> [EdgeTTS.Segment] {
        segments.sorted {
            $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start
        }
    }

    private static func end(of segment: EdgeTTS.Segment) -> Double {
        segment.start + max(0, segment.duration)
    }

    /// `00:00:00,000` (SRT) or `00:00:00.000` (VTT), from whole milliseconds —
    /// accumulating seconds and formatting the fraction is what produces the
    /// `00:00:03,519999` some generators write. Negative times clamp to zero.
    static func timecode(_ seconds: Double, decimalComma: Bool) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        let milliseconds = total % 1000
        let whole = total / 1000
        let stamp = String(
            format: "%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
        return stamp + (decimalComma ? "," : ".") + String(format: "%03d", milliseconds)
    }

    /// One cue holds ONE line: a newline inside the payload would open a blank
    /// line and the rest of the sentence would become a cue of its own.
    private static func cueText(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private struct JSONCue: Codable {
        struct JSONWord: Codable {
            let start: Double
            let duration: Double
            let text: String
        }
        let start: Double
        let duration: Double
        let text: String
        let index: Int?
        let page: Int?
        let words: [JSONWord]?
    }
}

/// Orchestrates text-to-speech playback: synthesis, streaming, seeking, and
/// highlight tracking. All state mutations happen on the main actor.
///
/// - SeeAlso: ``StreamingPlayer``, ``EdgeTTS``
@MainActor
final class SpeechController: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var status: String = ""
    /// Key+args of the current status in the `L` catalog, to re-resolve the text
    /// on language switch. Nil when the status is a raw engine message
    /// (progress, outside the catalog) — then there is nothing to re-resolve.
    private var statusKey: String?
    private var statusArgs: [String] = []
    /// Plano item 18: the current message is a FAILURE — the banner does NOT
    /// dismiss itself while the failure is on screen (before, it went away in
    /// 4 s and the blind user was left without a trace). Reads via the pure
    /// policy `AccessibilityAnnouncements.isFailure`; progress and success
    /// messages reclassify in `storeStatus`.
    @Published private(set) var statusIsFailure: Bool = false
    /// Current interface language, read from the persisted default (the UI
    /// writes via `@AppStorage`; here there is no `@AppStorage`, so it reads
    /// `UserDefaults`).
    private var currentLanguage: L.Language {
        L.Language(
            rawValue: UserDefaults.standard.string(forKey: AppSetting.languageKey)
                ?? AppSetting.languageDefault) ?? .en
    }
    @Published var isPlaying: Bool = false
    @Published var isPaused: Bool = false
    @Published private(set) var hasAudio: Bool = false

    /// Streaming playback: each slice plays as soon as it arrives.
    let streamer = StreamingPlayer()

    /// Slices synthesized so far and the predicted total, for the progress bar.
    @Published private(set) var completedChunks: Int = 0
    @Published private(set) var totalChunks: Int = 0
    private var audioURL: URL?
    /// Sentences read, with their start instant, for the highlight and the click.
    @Published private(set) var segments: [EdgeTTS.Segment] = []

    /// O(1) lookup of a segment by its global index.
    func segment(forIndex index: Int) -> EdgeTTS.Segment? {
        segments.first(where: { $0.index == index })
    }
    /// Active sentence list (for the UI to click by index).
    @Published private(set) var phrases: [TextImport.Phrase] = []
    /// Key (text+voice+cadence) of the current reading; the audio lives on disk.
    private var currentKey: String?
    /// Voice of the current reading (to export with the right extension and credit).
    @Published private(set) var voiceInUse: String = ""
    /// Identity of the open document (file URL), written by the UI.
    /// This is what anchors the saved position: pause/stop stores `elapsed` under
    /// (document+voice); finishing or discarding the transcription clears it.
    var documentIDForPosition: String?
    /// Task of the ongoing synthesis, so it can be canceled.
    private var synthTask: Task<Void, Never>?
    /// Watchdog task: cancels the synthesis if no slice arrives for too long
    /// (stuck synthesis — network hang without timeout). Canceled on cancel,
    /// discard, or completion.
    private var synthWatchdog: Task<Void, Never>?
    /// Last moment a synthesis slice was delivered (or synthesis started).
    /// The watchdog compares against this to detect a stall.
    private var lastSynthProgress: Date = .now
    /// Synthesis generation: each new `play` increments it; `cancelSynthesis`
    /// invalidates. The task stores its birth generation and only writes
    /// (streamer, segments, status, isBusy) if it is still the current one.
    private var synthGeneration = 0
    /// Key (text+voice+cadence) of the in-flight synthesis, for `play`'s
    /// no-op on a repeated call while waiting for the first slice (when `currentKey`
    /// is still the previous reading's).
    private var synthKeyInFlight: String?
    /// Clicked sentence with no audio yet (nothing synthesized or synthesis in
    /// progress): each arriving slice tries the jump again, until it succeeds. This is what
    /// makes the PDF/text click "play from there" even before the first slice.
    private var pendingJumpIndex: Int?

    /// Sentence being read, mirrored from the streamer so the UI updates.
    ///
    /// Why mirror: `currentSegmentText` lives in the `StreamingPlayer`, and the
    /// `objectWillChange` `sink` only republishes the controller when
    /// `isPlaying`/`isPaused`/`status` change — the highlight (text and PDF)
    /// would stay still on the first sentence. Here every new sentence republishes.
    /// This is what moves the UI (clickable text + per-page PDF).
    @Published private(set) var highlightText: String?
    @Published private(set) var highlightIndex: Int = -1
    @Published private(set) var highlightPage: Int?
    /// Word being read (index within the active sentence), mirrored from the streamer.
    @Published private(set) var highlightWordIndex: Int = -1
    /// Output volume, 0…1. Mirrors the streamer for the IINA-style bar and
    /// persists on every change: it was the only preference that went back to
    /// 100% on each launch. Goes through `AppSetting` so the key and the
    /// clamped range live in one place.
    @Published var volume: Float {
        didSet {
            streamer.volume = volume
            AppSetting.saveVolume(Double(volume), defaults: defaults)
        }
    }
    /// Link to the streamer, so playback state never diverges.
    ///
    /// Why it exists: `isPlaying`/`isPaused` live in BOTH objects and, before
    /// this link, were only copied in a few places. When the `StreamingPlayer`
    /// finished a slice by itself (end of queue), the controller kept
    /// `isPlaying = true` — the UI showed "Playing…" and the Pause/Stop buttons
    /// active with no sound. Here the streamer is the source of truth.
    private var streamCancellable: AnyCancellable?
    private var highlightCancellables: Set<AnyCancellable> = []

    /// Sink of the system Now Playing entry; injectable so tests can record
    /// what would have been published without touching the shared center.
    private let nowPlayingSink: NowPlayingSink
    /// Last snapshot sent to the sink, and whether the sink was ever
    /// touched: a controller that never published and has nothing to publish
    /// must not write into the system center (hundreds of tests construct
    /// one idle).
    private var lastNowPlaying: NowPlaying.Snapshot?
    private var nowPlayingTouched = false

    /// Preferences store, injectable so the suite covers the volume round-trip
    /// against an ephemeral suite instead of the real preferences.
    private let defaults: UserDefaults

    init(nowPlayingSink: NowPlayingSink = SystemNowPlayingSink(),
         defaults: UserDefaults = .standard) {
        self.nowPlayingSink = nowPlayingSink
        self.defaults = defaults
        // Volume comes back where the user left it, in both ends at once: the
        // published value (the bar) and the streamer (each following slice).
        // Assigned before the sinks below; `didSet` does not run in `init`, so
        // opening the app writes nothing to the preferences.
        let savedVolume = Float(AppSetting.loadVolume(defaults: defaults))
        volume = savedVolume
        streamer.volume = savedVolume
        streamCancellable = streamer.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.mirrorStreamerState()
            }
        streamer.$currentSegmentText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if self.highlightText != text { self.highlightText = text }
            }
            .store(in: &highlightCancellables)
        streamer.$currentSegmentIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                self?.highlightIndex = index
            }
            .store(in: &highlightCancellables)
        streamer.$currentSegmentPage
            .receive(on: RunLoop.main)
            .sink { [weak self] page in
                self?.highlightPage = page
            }
            .store(in: &highlightCancellables)
        streamer.$currentWordIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                if self?.highlightWordIndex != index { self?.highlightWordIndex = index }
            }
            .store(in: &highlightCancellables)
        // End of queue with synthesis closed: the reading is over — there is
        // nothing to resume, so the position is forgotten (reopening starts from scratch).
        streamer.$isFinished
            .receive(on: RunLoop.main)
            .sink { [weak self] done in
                guard let self, done else { return }
                self.clearSavedPositionOnFinish()
            }
            .store(in: &highlightCancellables)
    }

    /// Effective streamer state on a mirror tick (comparable, to know
    /// whether there was a real change since the previous tick).
    private struct MirroredState: Equatable {
        var playing: Bool
        var paused: Bool
        var finished: Bool
        var starved: Bool
        /// Slice the probes could not measure. Part of the state so the warning
        /// is published the moment the count appears — and only then.
        var unmeasured: Int?
    }
    /// Last effective state seen by the mirror; without change, republishes nothing.
    private var lastMirroredState: MirroredState?

    private func mirrorStreamerState() {
        let playing = streamer.isPlaying
        let paused = streamer.isPaused
        if isPlaying != playing { isPlaying = playing }
        if isPaused != paused { isPaused = paused }
        let state = MirroredState(
            playing: playing, paused: paused,
            finished: streamer.isFinished, starved: streamer.isStarved,
            unmeasured: streamer.unmeasuredSlice)
        defer { lastMirroredState = state }
        // Republish ONLY when the effective state changes: the mirror runs at ~10 Hz
        // via `objectWillChange` and, before this guard, called `show` on
        // every tick — overwriting transient messages within ~100 ms
        // (e.g. "cache cleared" published by `clearCache`; finding B1).
        guard lastMirroredState != state else { return }
        // State changed → the Now Playing entry follows (this is the single
        // funnel where the streamer's playing/paused reach the controller).
        publishNowPlaying()
        // A slice out of the measurement account shifts every following sentence,
        // and no other sign exists: it is said here, before the playing/paused
        // switch, so "Playing…" does not erase it. Only on a NEW slice — the
        // warning stays on screen until a real state change.
        if let slice = streamer.unmeasuredSlice, slice != lastMirroredState?.unmeasured {
            show("warn.durationUnmeasured", slice + 1)
            return
        }
        // Wait with an empty queue: say it is generating, not "playing" —
        // silence with a playing status looked like a hang.
        if streamer.isStarved, isBusy {
            show("status.generatingNext")
            return
        }
        // The status starts describing what is actually happening. Without this,
        // "Playing…" survived the end of the audio.
        if !isBusy {
            switch (playing, paused, state.finished) {
            case (true, _, _): show("status.playing")
            case (_, true, _): show("status.paused")
            case (false, false, true): show("status.finished")
            default: break
            }
        }
    }
    /// Honest failure message: Microsoft's 403 (global block of the
    /// old endpoint since 2026-10-10, verified) is not instability —
    /// retrying does not help, and the user needs to know the way out
    /// is the offline voice.
    nonisolated static func failureMessage(for error: Error, locale: L.Language = .en) -> String {
        let (key, args) = failureKey(for: error)
        return L.resolve(key, locale: locale, args: args)
    }

    /// Failure key+args, stored so a language switch re-resolves the message.
    /// Errors thrown by the engines carry their catalog key in `userInfo`.
    nonisolated static func failureKey(for error: Error) -> (String, [Any]) {
        let ns = error as NSError
        if let key = ns.userInfo["l10nKey"] as? String {
            return (key, ns.userInfo["l10nArgs"] as? [Any] ?? [])
        }
        let detail = error.localizedDescription
        if detail.contains("403") {
            return ("status.onlineBlocked", [])
        }
        return ("error.synthesisFailed", [detail])
    }

    /// Flags a cancellation requested by the user (read by the background queues).
    /// One instance per generation: a new `play` creates another instead of zeroing
    /// the old one, so an old task stuck in a blocking `run` keeps
    /// reading `isCancelled == true` and does not enqueue again.
    private var cancelFlag = CancelFlag()

    /// Cross-thread readable cancellation state.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
        }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        func reset() { lock.lock(); flag = false; lock.unlock() }
    }

    /// Decision taken by `play` for a given reading request. Extracted as a
    /// pure enum so the (fragile) ordering of the checks is explicit and
    /// testable without spinning up the controller or any audio.
    enum PlayDecision {
        case resumePaused              // paused, same reading → resume
        case resumePausedSynthesizing  // paused mid-synthesis, same reading in flight
        case noOpPlaying               // playing, same reading, synthesis in flight
        case noOpInFlight              // synthesis in flight of the same reading
        case cancelAndRestart          // synthesis in flight of a DIFFERENT reading
        case replayCached              // same reading already synthesized → replay
        case playFromDiskCache          // cache hit on disk
        case synthesize                // start a new synthesis
    }

    /// Pure decision function for `play`. All inputs are values; no side
    /// effects. The order mirrors the original if-chain and must not change
    /// without updating the comments in `play`.
    nonisolated static func decidePlay(
        isPaused: Bool, isPlaying: Bool, isBusy: Bool,
        sameInput: Bool, hasAudio: Bool, hasAudioURL: Bool,
        inflightKey: String?, key: String,
        cacheHit: Bool
    ) -> PlayDecision {
        if isPaused, sameInput { return .resumePaused }
        if isPaused, isBusy, inflightKey == key { return .resumePausedSynthesizing }
        if isPlaying, sameInput, isBusy { return .noOpPlaying }
        if isBusy, inflightKey == key { return .noOpInFlight }
        // The run in flight is the semantic reference, not `sameInput`: the
        // currentKey is that of the last COMPLETED reading, so `isBusy && sameInput`
        // (new press for the already-finished text, with ANOTHER run synthesizing)
        // leaked and reached `replayCached` — the obsolete slice would call
        // `streamer.start` and hijack the replay in the middle.
        if isBusy, inflightKey != key { return .cancelAndRestart }
        if sameInput, hasAudio, hasAudioURL { return .replayCached }
        if !sameInput, cacheHit { return .playFromDiskCache }
        return .synthesize
    }

    /// Reads the active sentence list (already filtered or integral, the UI chooses).
    /// - `readFootnotes`: with `false`, note markers become pauses and bodies
    /// stay out of the list (ContentView filters); it enters the cache key,
    /// because the audio is different.
    func play(phrases list: [TextImport.Phrase], voice: String, rate: EdgeTTS.Rate = .normal, readFootnotes: Bool = true) {
        let trimmed = list.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmed.isEmpty else {
            show("status.noText")
            return
        }
        // Paragraph boundary joins with `\n` (a breath in speech; invalidates the
        // old cache ONCE, which is what we want — each sentence's text does not change).
        var fullText = ""
        for (idx, ph) in trimmed.enumerated() {
            if idx > 0 { fullText += trimmed[idx - 1].paragraphEnd ? "\n" : " " }
            fullText += ph.text
        }
        let key = DiskCache.key(text: fullText, voice: voice, rate: rate, readFootnotes: readFootnotes)
        let sameInput = currentKey == key
        // Cache lookup is read-only: done up front so the decision function
        // stays pure. The actual application happens in the .playFromDiskCache
        // branch below.
        let cacheHit = DiskCache.lookup(key: key)

        // Single decision point: the ordering lives in `decidePlay` and must
        // not be reordered (see the comments there and in the enum).
        let decision = Self.decidePlay(
            isPaused: streamer.isPaused, isPlaying: streamer.isPlaying,
            isBusy: isBusy, sameInput: sameInput, hasAudio: hasAudio,
            hasAudioURL: audioURL != nil, inflightKey: synthKeyInFlight,
            key: key, cacheHit: cacheHit != nil)

        switch decision {
        case .resumePaused:
            streamer.resume()
            isPlaying = true
            isPaused = false
            show("status.playing")
            return

        case .resumePausedSynthesizing:
            streamer.resume()
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            if streamer.isPlaying {
                show("status.playingWhileSynthesizing")
            } else {
                show("status.generatingNext")
            }
            return

        case .noOpPlaying, .noOpInFlight:
            return

        case .cancelAndRestart:
            cancelSynthesis()

        case .replayCached:
            // Validate the cached audio before replaying: a corrupted file
            // would play silence or fail. If invalid, discard and resynthesize.
            if let audioURL, (try? AVAudioPlayer(contentsOf: audioURL)) != nil {
                streamer.restart(audioURL: audioURL, segments: segments)
                voiceInUse = voice
                isPlaying = true
                isPaused = false
                hasAudio = true
                show("status.playing")
                return
            } else {
                hasAudio = false
                self.audioURL = nil
            }

        case .playFromDiskCache:
            if let hit = cacheHit {
                // Validate the cached audio before replaying.
                if (try? AVAudioPlayer(contentsOf: hit.audioURL)) != nil {
                    currentKey = key
                    voiceInUse = voice
                    phrases = trimmed
                    audioURL = hit.audioURL
                    segments = hit.segments
                    completedChunks = 0
                    totalChunks = 0
                    streamer.restart(audioURL: hit.audioURL, segments: hit.segments)
                    hasAudio = true
                    isPlaying = true
                    isPaused = false
                    show("status.playingFromCache")
                    return
                } else {
                    // Corrupted cache entry: remove and resynthesize.
                    DiskCache.remove(key: key)
                }
            }

        case .synthesize:
            break
        }
        streamer.stop()
        PiperTTS.stopActiveSession()
        // The next synthesis is a different reading: the offline dir that was
        // protected goes out of the purge (replay of the closed one goes back
        // to the cache validation).
        EdgeTTS.clearOfflineDirectory()
        voiceInUse = voice
        isBusy = true
        isPlaying = false
        isPaused = false
        // Why the relay: the flow is asynchronous and runs off the main thread; the relay
        // brings progress back to the main without extending the controller's lifetime.
        let relay = StatusRelay()
        relay.controller = self
        // Honest notice before starting. Measured in Portuguese (26k chars,
        // 27 slices): 1391 chars/s and first slice audible at 4.3 s. 700 is used
        // as the estimate — bad network falls below the measured, and promising
        // the ideal number makes the real wait look like a hang.
        let estimate = max(1, Int(Double(fullText.count) / 700.0))
        if fullText.count > 4000 {
            if estimate >= 60 {
                show("status.longTextEstimate", fullText.count, estimate / 60)
            } else {
                show("status.synthesizingCount", fullText.count, estimate)
            }
        } else {
            show("status.synthesizing")
        }
        cancelFlag = CancelFlag()
        synthGeneration += 1
        let gen = synthGeneration
        let flag = cancelFlag
        synthKeyInFlight = key
        lastSynthProgress = Date()
        startSynthWatchdog(generation: gen)
        let locale = currentLanguage
        synthTask = Task {
            // Offline voice (local Piper) or online (edge-tts): the same flow —
            // the first slice plays in seconds and the single audio comes at the end.
            // Offline warns about the download on first use (network only on demand).
            let stream: AsyncThrowingStream<EdgeTTS.ChunkDelivery, Error>
            if PiperTTS.isOfflineVoice(voice) {
                stream = PiperTTS.synthesizeStreaming(
                    phrases: trimmed,
                    voice: voice,
                    rate: rate,
                    readFootnotes: readFootnotes,
                    locale: locale,
                    shouldCancel: { flag.isCancelled },
                    progress: { message in
                        Task { @MainActor in
                            guard gen == relay.controller?.synthGeneration else { return }
                            relay.controller?.reportProgress(message)
                            if let parsed = Self.parseProgress(message) {
                                relay.controller?.completedChunks = parsed.done
                                relay.controller?.totalChunks = parsed.total
                            }
                        }
                    }
                )
            } else {
                stream = EdgeTTS.synthesizeStreaming(
                    phrases: trimmed,
                    voice: voice,
                    maxChars: 1800,
                    rate: rate,
                    readFootnotes: readFootnotes,
                    locale: locale,
                    shouldCancel: { flag.isCancelled },
                    progress: { message in
                        Task { @MainActor in
                            guard gen == relay.controller?.synthGeneration else { return }
                            relay.controller?.reportProgress(message)
                            // "Synthesizing i/n…" → real progress bar.
                            if let parsed = Self.parseProgress(message) {
                                relay.controller?.completedChunks = parsed.done
                                relay.controller?.totalChunks = parsed.total
                            }
                        }
                    }
                )
            }

            var allSegments: [EdgeTTS.Segment] = []
            var started = false
            var finalResult: EdgeTTS.Result?

            do {
                for try await event in stream {
                    if Task.isCancelled || flag.isCancelled { break }
                    // An old generation does not write: check on the main before the effect.
                    let stale = await MainActor.run { gen != self.synthGeneration }
                    if stale { break }
                    switch event {
                    case .chunk(_, let url, let chunkSegments):
                        // Segments already carry global index + page from the
                        // first slice: jump-by-sentence does not wait for the end.
                        allSegments.append(contentsOf: chunkSegments)
                        if !started {
                            started = true
                            let wrote = await MainActor.run { () -> Bool in
                                guard gen == self.synthGeneration, !flag.isCancelled else { return false }
                                self.streamer.start(
                                    urls: [url],
                                    chunkSegments: [chunkSegments],
                                    minStart: StreamingPlayer.minStartChunks)
                                self.phrases = trimmed
                                self.segments = allSegments
                                self.hasAudio = true
                                self.isPlaying = true
                                self.isPaused = false
                                self.show(self.streamer.isBuffering ? "status.buffering" : "status.playingWhileSynthesizing")
                                self.lastSynthProgress = Date()
                                self.retryPendingJump()
                                return true
                            }
                            if !wrote { break }
                        } else {
                            let wrote = await MainActor.run { () -> Bool in
                                guard gen == self.synthGeneration, !flag.isCancelled else { return false }
                                self.streamer.enqueue(
                                    urls: [url], chunkSegments: [chunkSegments])
                                self.segments = allSegments
                                // Only promise "Playing…" with sound coming out: before,
                                // this line erased the "Generating the next
                                // audio…" mirror and the empty queue's
                                // silence looked like a hang instead of a wait.
                                if self.streamer.isPlaying {
                                    self.show("status.playingWhileSynthesizing")
                                } else if self.streamer.isBuffering {
                                    self.show("status.buffering")
                                } else if self.streamer.isStarved {
                                    self.show("status.generatingNext")
                                }
                                self.lastSynthProgress = Date()
                                self.retryPendingJump()
                                return true
                            }
                            if !wrote { break }
                        }
                    case .final(let result):
                        finalResult = result
                    }
                }
            } catch {
                if !flag.isCancelled && !Task.isCancelled {
                    await MainActor.run {
                        guard gen == self.synthGeneration else { return }
                        self.isBusy = false
                        self.synthKeyInFlight = nil
                        self.synthWatchdog?.cancel()
                        self.synthWatchdog = nil
                        // A pending jump dies with the synthesis: without this, an
                        // earlier click would fire by itself in a future reading.
                        self.pendingJumpIndex = nil
                        let (errorKey, failureArgs) = SpeechController.failureKey(for: error)
                        self.storeStatus(key: errorKey, args: failureArgs)
                    }
                }
                return
            }

            guard !flag.isCancelled, !Task.isCancelled else { return }
            let staleFinal = await MainActor.run { gen != self.synthGeneration }
            guard !staleFinal else { return }
            if let finalResult {
                await MainActor.run {
                    guard gen == self.synthGeneration, !flag.isCancelled else { return }
                    self.currentKey = key
                    self.audioURL = finalResult.audioURL
                    self.segments = finalResult.segments
                    self.isBusy = false
                    self.synthKeyInFlight = nil
                    self.synthWatchdog?.cancel()
                    self.synthWatchdog = nil
                    self.streamer.markSynthesisComplete()
                    // Synthesis closed and jump still pending: the index does not
                    // exist in the list — clear it, so as not to fire in a
                    // future reading with another list.
                    self.pendingJumpIndex = nil
                    // Disk store: the next identical opening plays without network.
                    // Disk store off the main thread: copying the final MP3/WAV here
                    // froze the UI at the end of synthesis (found in the audit).
                    //
                    // Offline, the final WAV already lives in the protected
                    // temporary directory of this reading; copying it to the
                    // cache kept a THIRD copy of the same audio on disk (audit
                    // item 10: partials + final + cache). The cache is an
                    // optimization and the offline engine runs locally, so the
                    // copy is skipped for offline voices.
                    if !PiperTTS.isOfflineVoice(voice) {
                        let cacheKey = key
                        let audioCache = finalResult.audioURL
                        let segmentosCache = finalResult.segments
                        Task.detached(priority: .utility) {
                            DiskCache.store(
                                key: cacheKey, audioURL: audioCache,
                                segments: segmentosCache)
                        }
                    }
                    if self.streamer.isQueueExhausted {
                        self.isPlaying = false
                        self.isPaused = false
                        self.show("status.finished")
                    } else if self.streamer.isPaused {
                        // Do not overwrite the pause with "Playing…".
                        self.isPlaying = false
                        self.isPaused = true
                        self.show("status.paused")
                    } else if self.streamer.isPlaying {
                        self.isPlaying = true
                        self.show("status.playing")
                    }
                }
            }
        }
    }

    /// There is a transcription to discard: ready audio, synthesis in progress or current
    /// key. This is what enables the "Generate new reading" menu item.
    var hasTranscription: Bool { hasAudio || isBusy || currentKey != nil }

    /// Discards the current transcription to force a new synthesis on the next play.
    ///
    /// Why it exists: `play` reuses audio when the key does not change
    /// (`sameInput`, with pause resume and cache replay). Without clearing
    /// `currentKey`/`hasAudio`/segments here, switching the text mode and
    /// pressing play would resume the old reading instead of the new.
    func discardTranscription() {
        synthWatchdog?.cancel()
        synthWatchdog = nil
        let oldKey = currentKey
        let inflight = synthKeyInFlight
        if isBusy { cancelSynthesis() }
        streamer.stop()
        PiperTTS.stopActiveSession()
        EdgeTTS.clearOfflineDirectory()
        // The discarded reading's per-sentence WAVs go with it: nothing will
        // open them again (the queue died in `stop`, and the next Play
        // synthesizes anew) — item 49 of the robustness lane.
        PiperTTS.releasePhraseWavs()
        // New list, old position is void: without this, the next play
        // would resume a point of the discarded reading.
        if let doc = documentIDForPosition, !voiceInUse.isEmpty {
            ReadingPositionStore.clear(documentID: doc, voice: voiceInUse)
        }
        hasAudio = false
        audioURL = nil
        segments = []
        phrases = []
        currentKey = nil
        synthKeyInFlight = nil
        pendingJumpIndex = nil
        completedChunks = 0
        totalChunks = 0
        voiceInUse = ""
        highlightText = nil
        highlightIndex = -1
        highlightPage = nil
        highlightWordIndex = -1
        isPlaying = false
        isPaused = false
        // Discarded document: nothing to control — the entry is removed even
        // if the streamer's async mirror has not run yet.
        publishNowPlaying()
        if let oldKey { DiskCache.remove(key: oldKey) }
        if let inflight, inflight != oldKey { DiskCache.remove(key: inflight) }
        show("status.transcriptionDiscarded")
    }

    /// Cancels the ongoing synthesis (does not affect audio already playing).
    func cancelSynthesis() {
        synthWatchdog?.cancel()
        synthWatchdog = nil
        guard isBusy else { return }
        // Invalidates the generation: the old task, even stuck in a blocking
        // `run`, fails every `gen == synthGeneration` check and
        // stops without writing to the streamer, the status or `isBusy`.
        synthGeneration += 1
        cancelFlag.cancel()
        synthTask?.cancel()
        synthTask = nil
        synthKeyInFlight = nil
        pendingJumpIndex = nil
        isBusy = false
        show("common.synthesisCancelled")
        // Leftover edge-tts processes are terminated by the timeout/group;
        // forcing termination here avoids waiting for the remaining slices.
        EdgeTTS.killRunningProcesses()
        // The Piper child dies with the reading: no leftover process.
        PiperTTS.killRunningProcesses()
    }

    /// Watchdog: cancels the synthesis if no slice arrives for 5 minutes
    /// (stuck synthesis — network hang without timeout, observed in BACKLOG).
    /// Checks every 30 seconds. Only acts if the generation is still current.
    private func startSynthWatchdog(generation gen: Int) {
        synthWatchdog?.cancel()
        synthWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
                guard let self else { return }
                let stale = await MainActor.run { gen != self.synthGeneration }
                if stale { return }
                let elapsed = await MainActor.run { () -> TimeInterval in
                    guard self.isBusy else { return 0 }
                    return Date().timeIntervalSince(self.lastSynthProgress)
                }
                if elapsed > 300 { // 5 min → cancel
                    await MainActor.run {
                        guard gen == self.synthGeneration, self.isBusy else { return }
                        self.cancelSynthesis()
                        self.show("status.synthesisStalled")
                    }
                    return
                } else if elapsed > 30, elapsed < 60 { // 30-60s → warn (only once per stall)
                    await MainActor.run {
                        guard gen == self.synthGeneration, self.isBusy else { return }
                        // Warn once per stall: compare the stored KEY, not the
                        // resolved text — the old check looked for the Portuguese
                        // substring "demorando" and, in English, warned again on
                        // every 30 s check.
                        if self.statusKey != "status.synthesisSlow" {
                            self.show("status.synthesisSlow")
                        }
                    }
                }
            }
        }
    }

    /// Time already played and known duration, for the navigation bar.
    ///
    /// The time is the PLAYED position (`currentTime` of the current slice
    /// + its offset), read from `AVAudioPlayer` on every access — not the
    /// ~10 Hz karaoke snapshot, which lags and freezes on slice change. With
    /// the queue drained or the reading finished, the measured audio end applies.
    var elapsed: TimeInterval { streamer.currentGlobalTime }
    var knownDuration: TimeInterval { streamer.knownDuration }

    /// Writes (or clears) the system Now Playing entry from the live state.
    ///
    /// This is what makes macOS deliver the media keys here (see
    /// `AppDelegate.setupRemoteCommands`): the OS routes them to the app that
    /// owns the Now Playing state. Publishing while idle would leave a ghost
    /// entry stealing the keys from whatever the user is actually listening
    /// to, so `NowPlaying.info` returns nil whenever the reading is neither
    /// playing nor paused — and a nil clears the entry.
    ///
    /// Elapsed/duration are the real measured values; the system advances the
    /// clock between updates using the published rate (1.0 playing, 0.0
    /// paused), so a snapshot is only re-sent when the state or the position
    /// actually changed.
    ///
    /// Internal (not private) so the tests drive the lifecycle through the
    /// very entry point the app uses.
    func publishNowPlaying() {
        let snapshot = NowPlaying.Snapshot(
            isPlaying: isPlaying,
            isPaused: isPaused,
            elapsed: elapsed,
            duration: knownDuration,
            title: documentTitleForNowPlaying,
            artist: voiceInUse)
        guard snapshot != lastNowPlaying else { return }
        lastNowPlaying = snapshot
        // Never touched and nothing to say: do not write into the shared
        // center at all (tests build idle controllers by the dozen).
        guard snapshot.isPlaying || snapshot.isPaused || nowPlayingTouched else { return }
        nowPlayingTouched = true
        nowPlayingSink.apply(
            info: NowPlaying.info(for: snapshot),
            state: NowPlaying.playbackState(snapshot))
    }

    /// Track title in Now Playing: the document's file name; nil in text-only
    /// mode (the entry then shows without a title, not with a fake one).
    private var documentTitleForNowPlaying: String? {
        guard let doc = documentIDForPosition, !doc.isEmpty else { return nil }
        return URL(fileURLWithPath: doc).lastPathComponent
    }

    /// Seeks to an instant. This is what makes the bar draggable.
    func seek(to time: TimeInterval) {
        streamer.seek(to: time)
        // Position-only change: the mirror sees no state change, so the
        // Now Playing clock would keep counting from the old point.
        publishNowPlaying()
    }

    func skip(_ seconds: TimeInterval) {
        guard canSkip else { return }
        let target = min(max(0, elapsed + seconds), knownDuration)
        streamer.seek(to: target)
        publishNowPlaying()
    }

    /// There is audio to move within: `skip` acts, and the ±15 s buttons and the
    /// ⌥←/⌥→ shortcut follow this same rule.
    ///
    /// Deliberately NOT `!isBusy`: synthesis lasts minutes on a long text, and
    /// gating the skip on it left both the buttons and the shortcut dead for the
    /// whole reading — the ±15 s unreachable exactly while it was wanted. The
    /// seek already clamps to the audio that exists, so skipping during
    /// synthesis is safe.
    var canSkip: Bool { hasAudio && knownDuration > 0 }

    /// Jumps to the start of the sentence with global index `index`.
    ///
    /// Works DURING streaming: the player indexes by global index
    /// from the first slice.
    func seek(toSegmentAt index: Int) {
        if streamer.seek(toSegment: index) {
            publishNowPlaying()
        } else {
            show("status.waitForSynthesisToJump")
        }
    }

    /// Moves the reading one sentence back/forward from the one being read.
    ///
    /// Why it exists: stepping by sentence was reachable only with the pointer
    /// (clicking the panel or the PDF). For keyboard-only and VoiceOver use there
    /// was no way to walk the document.
    ///
    /// Goes through `jumpToSegment`, the SAME call the click path uses — so it
    /// inherits the pending-jump behaviour (when the target sentence has not been
    /// synthesized yet it is remembered and honoured on arrival) instead of
    /// growing a second way to jump that could drift from the first.
    func stepSentence(by delta: Int) {
        let ordered = segments.map(\.index)
        guard !ordered.isEmpty else { return }
        let target: Int
        if highlightIndex < 0 {
            target = delta > 0 ? ordered[0] : ordered[ordered.count - 1]
        } else if let at = ordered.firstIndex(of: highlightIndex) {
            let next = at + delta
            guard next >= 0, next < ordered.count else { return }
            target = ordered[next]
        } else {
            target = ordered[0]
        }
        _ = jumpToSegment(target)
    }

    /// Click on text/PDF: jumps the reading to the corresponding sentence.
    ///
    /// When the sentence has no audio yet (nothing synthesized or synthesis
    /// in progress), the index is stored as pending instead of ignored: each
    /// arriving slice tries the jump (`retryPendingJump`), so the click becomes
    /// "play from there" as soon as the passage exists. Returns false while
    /// the audio has not arrived.
    @discardableResult
    func jumpToSegment(_ index: Int) -> Bool {
        guard index >= 0 else { return false }
        if streamer.jumpToSegment(index) {
            pendingJumpIndex = nil
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            show("status.playing")
            return true
        } else {
            pendingJumpIndex = index
            show("status.generatingPassage")
            return false
        }
    }

    /// Tries the pending jump against the audio that has arrived; clears it when
    /// it succeeds. Called on every slice (start and continuation).
    @discardableResult
    private func retryPendingJump() -> Bool {
        guard let pending = pendingJumpIndex else { return false }
        if streamer.jumpToSegment(pending) {
            pendingJumpIndex = nil
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            show("status.playing")
            return true
        }
        return false
    }

    func pause() {
        guard streamer.isPlaying else { return }
        streamer.pause()
        isPlaying = false
        isPaused = true
        // The clock stays alive on pause: stores where to resume.
        savePositionNow()
        // Rate 0.0 with the real elapsed: the entry stays (the keys must
        // still reach here to resume) but the system stops counting.
        publishNowPlaying()
        show("status.paused")
    }

    func resume() {
        guard streamer.isPaused else { return }
        streamer.resume()
        isPlaying = streamer.isPlaying
        isPaused = streamer.isPaused
        publishNowPlaying()
        show("status.playing")
    }

    func stopPlayback() {
        pendingJumpIndex = nil
        // `stop` zeroes the clock: capture before, so the resume knows from where.
        // Played position (not the karaoke snapshot): the same as the track.
        let position = elapsed
        let doc = documentIDForPosition
        let voice = voiceInUse
        streamer.stop()
        // With synthesis in progress, the session continues (cancellation ends it);
        // stopping without synthesis leaves no leftover process.
        if !isBusy {
            PiperTTS.stopActiveSession()
            // The chunk queue died with the `stop`: the per-sentence WAVs of
            // the offline reading are consumed, and a later Play replays the
            // assembled `EdgeSpeak.wav` (`replayCached` → `restart`). Releasing
            // them here is what stops partials + assembled + cache from being
            // three copies of the same audio (item 49 of the robustness lane).
            PiperTTS.releasePhraseWavs()
        }
        isPlaying = false
        isPaused = false
        // Nothing is being read anymore: the entry goes away, so the keys
        // stop pointing at a silent app.
        publishNowPlaying()
        if let doc, !voice.isEmpty {
            ReadingPositionStore.save(documentID: doc, voice: voice, position: position)
        }
        show("status.stopped")
    }

    /// Stores the current position under (document+voice), for the resume.
    /// With no document (text-only mode) or no voice in use, there is nothing to anchor.
    private func savePositionNow() {
        guard let doc = documentIDForPosition, !voiceInUse.isEmpty else { return }
        ReadingPositionStore.save(documentID: doc, voice: voiceInUse, position: elapsed)
    }

    /// Reading finished: forgets the position (reopening starts from scratch).
    private func clearSavedPositionOnFinish() {
        guard let doc = documentIDForPosition, !voiceInUse.isEmpty else { return }
        ReadingPositionStore.clear(documentID: doc, voice: voiceInUse)
    }

    /// Extracts "i/n" from the progress message to feed the bar.
    ///
    /// Why parse text and not pass a counter: the engine already produces the
    /// message readable to the user; avoid duplicating that state here.
    nonisolated static func parseProgress(_ message: String) -> (done: Int, total: Int)? {
        guard let range = message.range(of: #"(\d+)/(\d+)"#, options: .regularExpression)
        else { return nil }
        let parts = message[range].split(separator: "/")
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0
        else { return nil }
        return (done, total)
    }

    /// Exposes the status to the UI (e.g. file import result).
    ///
    /// Raw message, no key: the language switch does not re-resolve it. Whoever has
    /// a catalog key should use `setStatusKey`.
    func setStatus(_ message: String) {
        reportProgress(message)
    }

    /// Stores the key+args and shows the text already resolved in the requested
    /// language (default: the current one). This is what the UI calls for catalog messages.
    func setStatusKey(_ key: String, args: [Any] = [], locale: L.Language? = nil) {
        storeStatus(key: key, args: args, locale: locale ?? currentLanguage)
    }

    /// Re-resolves the stored status in the new language; with no stored key
    /// (raw engine progress), it keeps the message as is.
    func refreshLocale(_ locale: L.Language) {
        guard let key = statusKey else { return }
        status = L.resolve(key, locale: locale, args: statusArgs)
    }

    /// Stores the key+args and resolves in the current language (short internal form).
    private func show(_ key: String, _ args: Any...) {
        storeStatus(key: key, args: args, locale: currentLanguage)
    }

    /// Core of the guard: key+args stay so the language switch can re-resolve.


    static func isFailureKey(_ key: String) -> Bool {
        key.hasPrefix("error.") || key == "status.onlineBlocked"
    }

    private func storeStatus(key: String, args: [Any], locale: L.Language? = nil) {
        statusKey = key
        statusArgs = args.map { String(describing: $0) }
        status = L.resolve(key, locale: locale ?? currentLanguage, args: args)
        statusIsFailure = Self.isFailureKey(key)
        DiagStatus.record(status)
        // Plano item 18: a falha marca o banner (permanente enquanto dura) e
        // os terminais viram anúncio VEZ ÚNICA — carregado/erro/concluído/
        // cancelado. Progresso (`reportProgress`) nunca passa aqui por chave.
        let kind = AccessibilityAnnouncements.kind(of: key)
        statusIsFailure = AccessibilityAnnouncements.isFailure(key)
        if let kind { AccessibilityAnnouncements.post(status, kind: kind) }
    }

    /// Live engine progress (raw text, outside the catalog): clears the
    /// stored key so the language switch does not overwrite the current message.
    ///
    /// Why it feeds the watchdog clock: the report arrives while the
    /// synthesis is alive but has not delivered a slice yet — first use of an
    /// offline voice downloads ~63 MB (progress on screen the whole time), and
    /// `pip install` can run for minutes. Without this beat, the watchdog
    /// (5 min of "no progress") killed a download visibly in progress.
    func reportProgress(_ message: String) {
        lastSynthProgress = Date()
        statusKey = nil
        statusArgs = []
        status = message
        DiagStatus.record(message)
        // Plano item 18: progresso cru NÃO é falha — uma falha anterior deixa
        // de segurar o banner quando o trabalho recomeça (a síntese anda).
        statusIsFailure = false
    }

    /// Clears the disk cache preserving the current reading (Advanced tab
    /// button, via the `.edgeSpeakClearCache` notification).
    func clearCache() {
        let current = currentKey
        Task.detached(priority: .utility) {
            let freed = DiskCache.clearAll(preserving: current)
            let text = freed >= 1_048_576
                ? "\(freed / 1_048_576) MB" : "\(max(1, freed / 1_024)) KB"
            await MainActor.run { self.show("status.cacheCleared", text) }
        }
    }

    func exportMP3() {
        guard let audioURL else {
            show("status.noAudioToExport")
            return
        }
        // Offline generates WAV (concatenated PCM); online, MP3. The final file
        // is already together — here it is only saved with the right extension.
        let isWav = audioURL.pathExtension.lowercased() == "wav"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isWav
            ? L.get("export.defaultWav", locale: currentLanguage)
            : L.get("export.defaultMp3", locale: currentLanguage)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Captured now: the copy leaves the main thread and by then `audioURL`
        // may belong to another reading.
        let source = audioURL
        // The same reason holds for the times: they describe THIS audio, and a
        // later reading would make `segments` another list (item 41).
        let times = segments
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { return }
            // The copy used to run synchronously on the `@MainActor`: seconds
            // to minutes for a book, freezing the window — the same freeze the
            // cache copy already documented. Detached, only the report comes
            // back (item 45 of the robustness lane, 2026-10-17).
            Task.detached(priority: .utility) {
                do {
                    let fm = FileManager.default
                    do {
                        if fm.fileExists(atPath: destination.path) {
                            try fm.removeItem(at: destination)
                        }
                        try fm.copyItem(at: source, to: destination)
                        // The timings travel WITH the audio, not behind a menu
                        // item: an MP3 on another machine had no way to follow
                        // the sentence. Same basename, `.srt` beside it — the
                        // format players already load as a sidecar.
                        let timed = SubtitleSRT.write(segments: times, beside: destination)
                        await MainActor.run {
                            if let timed {
                                self.show("status.audioSavedWithTimes",
                                          [destination.lastPathComponent, timed.lastPathComponent])
                            } else {
                                self.show("status.audioSaved", destination.lastPathComponent)
                            }
                        }
                    } catch {
                        await MainActor.run { self.show("status.exportFailed", error.localizedDescription) }
                    }
                    try fm.copyItem(at: source, to: destination)
                } catch {
                    await MainActor.run {
                        self.show("status.exportFailed", error.localizedDescription)
                    }
                    return
                }
                // Item 41: the audio goes out WITH its times beside it — same
                // directory, same name, `.srt`/`.vtt`/`.json`. No times yet
                // (empty list): the audio goes out alone, as before.
                do {
                    let wroteTimes = try SubtitleExporter.writeBeside(times, audio: destination)
                    await MainActor.run {
                        self.show(
                            wroteTimes ? "status.audioWithTimes" : "status.audioSaved",
                            destination.lastPathComponent)
                    }
                } catch {
                    // The audio IS saved; saying "export failed" would be a lie.
                    await MainActor.run {
                        self.show(
                            "status.audioTimesFailed",
                            destination.lastPathComponent, error.localizedDescription)
                    }
                }
            }
        }
    }
}

/// Writes the reading's sentences as SRT next to the exported audio.
///
/// Why SRT and not JSON: the symptom of the missing timings was hearing the
/// export elsewhere with no way to follow the sentence, which is exactly what a
/// sidecar subtitle fixes. JSON remains what `Segment` already encodes to —
/// it is not what any player reads.
///
/// Times are GLOBAL in the final file (`Segment.start`), so the cues line up
/// with the exported audio and not with an individual slice.
enum SubtitleSRT {
    /// Returns the written file, or nil when there was nothing to write (no
    /// segments) — the audio export then reports the audio alone, as before.
    static func write(segments: [EdgeTTS.Segment], beside destination: URL) -> URL? {
        let usable = segments.filter { $0.duration > 0 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return nil }
        let text = render(usable)
        let stem = destination.deletingPathExtension()
        var target = stem.appendingPathExtension("srt")
        // Two exports in the same second must not overwrite each other's cues.
        if FileManager.default.fileExists(atPath: target.path), let data = text.data(using: .utf8) {
            target = stem.appendingPathExtension("-\(Int(Date().timeIntervalSince1970)).srt")
            try? data.write(to: target)
        } else {
            try? text.write(to: target, atomically: true, encoding: .utf8)
        }
        return target
    }

    /// SRT body: numbered cues, `HH:MM:SS,mmm --> …`, then the sentence.
    /// Static and pure so it can be checked without touching the disk.
    static func render(_ segments: [EdgeTTS.Segment]) -> String {
        var out = ""
        for (n, seg) in segments.enumerated() {
            let end = seg.start + max(seg.duration, 0.001)
            out += "\(n + 1)\n"
            out += "\(timestamp(seg.start)) --> \(timestamp(end))\n"
            out += seg.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return out
    }

    /// SRT wants `HH:MM:SS,mmm` with a comma, not the dot of a timestamp.
    ///
    /// Decomposed by multiplication, never by `rounded()` minus the value: that
    /// subtraction rounds twice and hands out negative milliseconds
    /// (`00:00:03,-500`), which players reject.
    private static func timestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let millis = totalMs % 1000
        let totalSeconds = totalMs / 1000
        return String(format: "%02d:%02d:%02d,%03d",
                      totalSeconds / 3600, (totalSeconds / 60) % 60,
                      totalSeconds % 60, millis)
    }
}
