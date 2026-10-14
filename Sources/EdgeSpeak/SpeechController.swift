import Foundation
import AppKit
import Combine

/// Sendable box to carry progress messages from the background thread to the main.
private final class StatusRelay: @unchecked Sendable {
    weak var controller: SpeechController?
}

@MainActor
final class SpeechController: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var status: String = ""
    /// Key+args of the current status in the `L` catalog, to re-resolve the text
    /// on language switch. Nil when the status is a raw engine message
    /// (progress, outside the catalog) — then there is nothing to re-resolve.
    private var statusKey: String?
    private var statusArgs: [String] = []
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
    /// Output volume, 0…1. Mirrors the streamer for the IINA-style bar.
    @Published var volume: Float = 1.0 {
        didSet { streamer.volume = volume }
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

    init() {
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
            finished: streamer.isFinished, starved: streamer.isStarved)
        defer { lastMirroredState = state }
        // Republish ONLY when the effective state changes: the mirror runs at ~10 Hz
        // via `objectWillChange` and, before this guard, called `show` on
        // every tick — overwriting transient messages within ~100 ms
        // (e.g. "cache cleared" published by `clearCache`; finding B1).
        guard lastMirroredState != state else { return }
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
        // Only resumes if it is the SAME list, voice and cadence. Without this check,
        // loading another file during the pause and pressing Play would play the
        // previous reading, which was not expected.
        if streamer.isPaused, sameInput {
            streamer.resume()
            isPlaying = true
            isPaused = false
            show("status.playing")
            return
        }
        // Paused with the SAME reading's synthesis still in progress (the first
        // slice has not arrived or the queue emptied): resumes what exists and the rest
        // engages on arrival. Before, it fell into the in-flight synthesis no-op and Play
        // looked dead (found in the audit).
        if streamer.isPaused, isBusy, let inflight = synthKeyInFlight, inflight == key {
            streamer.resume()
            isPlaying = streamer.isPlaying
            isPaused = streamer.isPaused
            if streamer.isPlaying {
                show("status.playingWhileSynthesizing")
            } else {
                show("status.generatingNext")
            }
            return
        }
        if streamer.isPlaying, sameInput, isBusy { return }
        // Synthesis in progress of the SAME reading (first slice not yet arrived,
        // `currentKey` is still the old one): do not start a second synthesis.
        if isBusy, let inflight = synthKeyInFlight, inflight == key { return }
        if isBusy, !sameInput {
            cancelSynthesis()
        }
        // Replay of already-synthesized audio: avoids redoing the slow part (network).
        if sameInput, hasAudio, let audioURL {
            streamer.restart(audioURL: audioURL, segments: segments)
            voiceInUse = voice
            isPlaying = true
            isPaused = false
            hasAudio = true
            show("status.playing")
            return
        }
        // Disk cache: reopening the same PDF/voice/cadence plays without network.
        if !sameInput, let hit = DiskCache.lookup(key: key) {
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
        }
        streamer.stop()
        PiperTTS.stopActiveSession()
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
                    self.streamer.markSynthesisComplete()
                    // Synthesis closed and jump still pending: the index does not
                    // exist in the list — clear it, so as not to fire in a
                    // future reading with another list.
                    self.pendingJumpIndex = nil
                    // Disk store: the next identical opening plays without network.
                    // Disk store off the main thread: copying the final MP3/WAV here
                    // froze the UI at the end of synthesis (found in the audit).
                    let cacheKey = key
                    let audioCache = finalResult.audioURL
                    let segmentosCache = finalResult.segments
                    Task.detached(priority: .utility) {
                        DiskCache.store(
                            key: cacheKey, audioURL: audioCache,
                            segments: segmentosCache)
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
        let oldKey = currentKey
        let inflight = synthKeyInFlight
        if isBusy { cancelSynthesis() }
        streamer.stop()
        PiperTTS.stopActiveSession()
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
        if let oldKey { DiskCache.remove(key: oldKey) }
        if let inflight, inflight != oldKey { DiskCache.remove(key: inflight) }
        show("status.transcriptionDiscarded")
    }

    /// Cancels the ongoing synthesis (does not affect audio already playing).
    func cancelSynthesis() {
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

    /// Time already played and known duration, for the navigation bar.
    ///
    /// The time is the PLAYED position (`currentTime` of the current slice
    /// + its offset), read from `AVAudioPlayer` on every access — not the
    /// ~10 Hz karaoke snapshot, which lags and freezes on slice change. With
    /// the queue drained or the reading finished, the measured audio end applies.
    var elapsed: TimeInterval { streamer.currentGlobalTime }
    var knownDuration: TimeInterval { streamer.knownDuration }

    /// Seeks to an instant. This is what makes the bar draggable.
    func seek(to time: TimeInterval) { streamer.seek(to: time) }

    func skip(_ seconds: TimeInterval) {
        guard controllerHasAudio else { return }
        let target = min(max(0, elapsed + seconds), knownDuration)
        streamer.seek(to: target)
    }

    private var controllerHasAudio: Bool { hasAudio && knownDuration > 0 }

    /// Jumps to the start of the sentence with global index `index`.
    ///
    /// Works DURING streaming: the player indexes by global index
    /// from the first slice.
    func seek(toSegmentAt index: Int) {
        if !streamer.seek(toSegment: index) {
            show("status.waitForSynthesisToJump")
        }
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
        show("status.paused")
    }

    func resume() {
        guard streamer.isPaused else { return }
        streamer.resume()
        isPlaying = streamer.isPlaying
        isPaused = streamer.isPaused
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
        if !isBusy { PiperTTS.stopActiveSession() }
        isPlaying = false
        isPaused = false
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
    private func storeStatus(key: String, args: [Any], locale: L.Language? = nil) {
        statusKey = key
        statusArgs = args.map { String(describing: $0) }
        status = L.resolve(key, locale: locale ?? currentLanguage, args: args)
        DiagStatus.record(status)
    }

    /// Live engine progress (raw text, outside the catalog): clears the
    /// stored key so the language switch does not overwrite the current message.
    func reportProgress(_ message: String) {
        statusKey = nil
        statusArgs = []
        status = message
        DiagStatus.record(message)
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

    func exportMP3() {        guard let audioURL else {
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
        panel.begin { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard response == .OK, let destination = panel.url else { return }
                do {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.copyItem(at: audioURL, to: destination)
                    self.show("status.audioSaved", destination.lastPathComponent)
                } catch {
                    self.show("status.exportFailed", error.localizedDescription)
                }
            }
        }
    }
}
