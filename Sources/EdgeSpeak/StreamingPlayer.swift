import Foundation
import AVFoundation

/// Plays the audio slices in sequence, without waiting for the whole document.
///
/// Why this exists: with a 300-page PDF, full synthesis takes
/// dozens of minutes. Playing each slice as it arrives, the reading
/// starts in seconds. Slices arrive in index order, so it suffices to
/// chain `AVAudioPlayer`s: at the end of one, trigger the next.
///
/// Sentences are indexed by GLOBAL INDEX from the first slice (each
/// segment already carries `index` + `page`): jumping to a sentence works DURING
/// streaming. This is the ONLY emitter of the highlight (`currentSegmentText`,
/// `currentSegmentIndex`, `currentSegmentPage`).
@MainActor
final class StreamingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isFinished = false

    /// Queue emptied before synthesis finished: not end, it is a wait.
    ///
    /// Without this, slices arriving later would never play again — the
    /// reading "paused" by itself at the end of the first slice (~30 s), with the
    /// following ones already ready on disk. With the flag, `enqueue` resumes.
    @Published private(set) var isStarved = false

    /// Time already played, in seconds, summing the previous slices.
    @Published private(set) var elapsed: TimeInterval = 0

    /// Total duration of the audio that has arrived. Grows while synthesis proceeds,
    /// so the bar reflects what exists so far.
    @Published private(set) var knownDuration: TimeInterval = 0

    /// Sentence being read (text, global index, page), for the highlight.
    @Published private(set) var currentSegmentText: String?
    @Published private(set) var currentSegmentIndex: Int = -1
    @Published private(set) var currentSegmentPage: Int?
    /// Word being read, as an index WITHIN the current sentence (-1 with no word).
    @Published private(set) var currentWordIndex: Int = -1

    /// Output volume, 0…1, applied to the current and following players.
    ///
    /// Exists so the IINA-style bar can control volume without touching the
    /// system volume. `AVAudioPlayer` already has `volume`; here the value is only
    /// stored and reapplied on each slice.
    @Published var volume: Float = 1.0 {
        didSet { current?.volume = volume }
    }

    private var queue: [URL] = []
    /// Sentence times of each slice, index-aligned with `queue`.
    ///
    /// The times are local to the slice (each audio restarts at zero); the global
    /// position is `chunkOffsets[i] + seg.start`. Each segment's `index` is
    /// global from the start, hence jump-by-sentence does not wait for the MP3.
    private var chunkSegments: [[EdgeTTS.Segment]] = []
    private var current: AVAudioPlayer?
    private var highlightTimer: Timer?
    private var pausedAt: TimeInterval = 0
    private var synthesisComplete = false
    private var nextIndex = 0
    /// Duration of each slice already played or queued, in order. This is what
    /// allows converting "global position" ↔ "which slice and how far into it".
    private var chunkDurations: [TimeInterval] = []
    private var chunkOffsets: [TimeInterval] = []
    /// Generation of the playback session: `stop()` increments it; the delegate only
    /// acts when the current generation is still the one of the player that ended.
    private var playbackGeneration = 0
    private var currentGeneration = -1
    /// URLs with duration measurement in progress (background task). Avoids measuring the
    /// same slice twice; `stop()` clears, and the generation invalidates the rest.
    private var pendingProbes: Set<URL> = []
    /// Slices buffered before the first sound (owner choice: wait longer at
    /// the start, then never stall). `start` with fewer slices holds them and
    /// `enqueue` releases at the threshold; a finished synthesis releases at once.
    static let minStartChunks = 3
    @Published private(set) var isBuffering = false
    private var startPending = false

    /// Buffered enough to start: the first slices are in AND their durations
    /// measured. With zeroed durations the sentence→time map is approximate
    /// until the probes land, and the highlight lags from the second sentence
    /// on — so the pre-buffer waits for the map, not just the audio.
    private var startReady: Bool {
        guard queue.count >= Self.minStartChunks else { return false }
        return queue.indices.prefix(Self.minStartChunks).allSatisfy { chunkDurations[$0] > 0 }
    }

    /// Restores a click-jump offset after a (re)start from zero: without this,
    /// a jump made while buffered replays the slice from its first sentence.
    private func restorePausedOffset() {
        guard isPaused, pausedAt > 0, let duration = current?.duration, duration > 0 else { return }
        current?.currentTime = min(pausedAt, duration)
    }

    /// Index of the slice being played (for the UI to show progress).
    var currentChunkIndex: Int { nextIndex }

    /// Start of each slice in global time, for the UI and for tests.
    var chunkStarts: [TimeInterval] { chunkOffsets }

    var isQueueExhausted: Bool { nextIndex >= queue.count }

    /// Whether the karaoke/highlight tick is live. `pause()` invalidates it and
    /// only `playChunk`/`gotoChunk`(resume branch) reinstall it — this accessor
    /// lets the tests prove the reinstall instead of inferring it from a frozen
    /// word.
    var isHighlightTimerRunning: Bool { highlightTimer?.isValid == true }

    /// Starts playback with the first slice.
    ///
    /// The durations arrive READY from the synthesizer (background task, off the
    /// main thread); here nothing measures nor decodes. Without durations, per-slice
    /// background measurement is triggered (off the main thread); `playChunk` remains as
    /// backstop, via the playback's own player.
    func start(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments segments: [[EdgeTTS.Segment]], minStart: Int = 1) {
        stop()
        guard let first = urls.first else { return }
        queue = urls
        chunkSegments = segments
        chunkDurations = Self.resolvedDurations(durations, count: urls.count)
        recomputeOffsets()
        nextIndex = 0
        isFinished = false
        synthesisComplete = false
        if urls.count < minStart {
            // Pre-buffering: hold the first sound until enough slices are in
            // (or the synthesis finishes); `enqueue` releases at the threshold.
            startPending = true
            isBuffering = true
            probeMissingDurations(startingAt: 0)
            return
        }
        playChunk(first)
        probeMissingDurations(startingAt: 0)
    }

    /// Queues the slices that finished synthesizing.
    ///
    /// Same as `start`: the duration comes ready from the background task; without it,
    /// it measures in the background (off the main thread) and the known total grows on slice
    /// arrival, not at playback start. The bar uses the total known
    /// so far, with no main-thread I/O per slice.
    func enqueue(urls: [URL], durations: [TimeInterval]? = nil, chunkSegments segments: [[EdgeTTS.Segment]]) {
        guard !urls.isEmpty else { return }
        let base = queue.count
        queue.append(contentsOf: urls)
        chunkSegments.append(contentsOf: segments)
        chunkDurations.append(contentsOf: Self.resolvedDurations(durations, count: urls.count))
        recomputeOffsets()
        // Pre-buffered start releases when the map is ready (slices +
        // measured durations). A click-jump during the buffer keeps its
        // offset: releasing from zero would replay the slice's first
        // sentence (heard twice).
        releasePrebufferIfReady()
        // Audio arrived with the queue emptied: resumes where it stopped.
        if isStarved, nextIndex < queue.count {
            playChunk(queue[nextIndex])
        }
        probeMissingDurations(startingAt: base)
    }

    /// Normalizes the durations coming from the background task: uses the ready
    /// ones when the size matches; else, zeros (background measurement fills
    /// in on arrival, and `playChunk` completes on play, with no main-thread I/O).
    private static func resolvedDurations(_ durations: [TimeInterval]?, count: Int) -> [TimeInterval] {
        if let durations, durations.count == count { return durations }
        return [TimeInterval](repeating: 0, count: count)
    }

    /// Measures in the background the slices without duration, without touching the main thread.
    ///
    /// Each probe writes ONLY to its own index, and only if it stays zeroed
    /// and with the same URL — hence the slice order never changes and the
    /// `restart` (own probe, another session) is not disturbed. A slice with
    /// producer duration or a probe in progress is not re-measured.
    private func probeMissingDurations(startingAt base: Int) {
        let generation = playbackGeneration
        for index in base..<queue.count {
            guard index < chunkDurations.count, chunkDurations[index] == 0 else { continue }
            let url = queue[index]
            guard !pendingProbes.contains(url) else { continue }
            pendingProbes.insert(url)
            Task.detached(priority: .utility) {
                let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
                await MainActor.run {
                    self.finishProbe(url: url, index: index, duration: duration, generation: generation)
                }
            }
        }
    }

    /// Receives the duration measured in the background (already on the main thread). Ignores when the session
    /// died (`stop`/`restart` swapped the generation), when the index left the
    /// queue or changed URL, or when the duration already arrived by another path.
    private func finishProbe(url: URL, index: Int, duration: TimeInterval, generation: Int) {
        guard generation == playbackGeneration else { return }
        guard pendingProbes.contains(url) else { return }
        pendingProbes.remove(url)
        guard index < queue.count, index < chunkDurations.count else { return }
        guard queue[index] == url, chunkDurations[index] == 0 else { return }
        guard duration > 0 else { return }
        chunkDurations[index] = duration
        recomputeOffsets()
        // The probe is what completes the map the pre-buffer waits for: the
        // slice arrives before its duration (measured in the background), so
        // the release check in `enqueue` always saw a zeroed duration. Without
        // this call the held start waited for the NEXT slice — or, in a short
        // document, for the whole synthesis to close (the reading opened with
        // seconds of silence and no highlight).
        releasePrebufferIfReady()
    }

    private func recomputeOffsets() {
        chunkOffsets = []
        var acc: TimeInterval = 0
        for d in chunkDurations {
            chunkOffsets.append(acc)
            acc += d
        }
        knownDuration = acc
    }

    /// Current global position: the playing slice's offset plus the time
    /// within it, read from `AVAudioPlayer` AT ACCESS TIME.
    ///
    /// Why read at access time instead of storing: the published `elapsed`
    /// is a ~10 Hz snapshot (karaoke tick) and freezes on slice change — the
    /// track stayed up to ~130 ms stuck on the old value while the audio had
    /// moved on. This read follows the actually-played position, so it is
    /// what feeds the track (via `SpeechController.elapsed`). Known limit:
    /// with not-yet-measured durations the offsets are approximate until the
    /// probes arrive — only the map, not the clock.
    var currentGlobalTime: TimeInterval {
        guard nextIndex < chunkOffsets.count else {
            return knownDuration
        }
        return chunkOffsets[nextIndex] + (current?.currentTime ?? 0)
    }

    /// Seeks to a global instant. Serves both dragging the bar and
    /// the ±15 s (which clamps the target to the known and calls here).
    ///
    /// It is only possible to go up to where audio exists; asking time beyond the measured
    /// leaves the player at the start of the still-unmeasured passage — the FIRST
    /// slice without duration —, skipping nothing. With known durations the
    /// starts are strict and the backwards move never triggers.
    func seek(to globalTime: TimeInterval) {
        guard !queue.isEmpty, !chunkOffsets.isEmpty else { return }
        let target = min(max(0, globalTime), knownDuration)
        var index = 0
        // Binary search of the slice start: it is the one containing the requested instant.
        var low = 0
        var high = chunkOffsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if chunkOffsets[mid] <= target { index = mid; low = mid + 1 } else { high = mid - 1 }
        }
        // Back to the first slice with the same start: without measured duration the
        // offsets repeat, and stopping at the last repeated one would skip the audio of the
        // earlier ones — the click-track variant that read another part.
        while index > 0, chunkOffsets[index - 1] == chunkOffsets[index] {
            index -= 1
        }
        guard index < queue.count else { return }
        gotoChunk(index, within: target - chunkOffsets[index])
    }

    /// Plays slice `chunk` from `within` (local time). It is the common
    /// end of `seek(to:)` (global time, for the bar) and of
    /// `seek(toSegment:)` (sentence, for the click): both use the same
    /// state machine.
    private func gotoChunk(_ chunk: Int, within: TimeInterval) {
        guard chunk < queue.count else { return }
        // `isFinished` counts as "play": dragging backwards after the
        // audio ended must resume playing, not stay still.
        // `isStarved` too: an emptied queue with synthesis in progress is a wait,
        // not a pause — without this, the `else` below re-wrote "paused" right after
        // `playChunk` started the target slice's audio, and the following `play()`
        // became a no-op (`player.isPlaying` already true): the UI lied.
        let wasPlaying = isPlaying || isPaused || isFinished || isStarved

        if chunk != nextIndex || current == nil {
            current?.stop()
            current = nil
            nextIndex = chunk
            playChunk(queue[chunk])
        }
        if isPaused {
            current?.stop()
        }
        // A jump positions real audio: the pre-buffer hold is spent. Without
        // this, the release in `enqueue`/`markSynthesisComplete` fires on top
        // of a jump made during buffering and replays the first sentence.
        startPending = false
        isBuffering = false
        let targetTime = min(within, current?.duration ?? within)
        current?.currentTime = targetTime
        elapsed = (chunk < chunkOffsets.count ? chunkOffsets[chunk] : knownDuration)
            + targetTime
        isFinished = false
        if wasPlaying, current != nil {
            current?.play()
            isPlaying = true
            isPaused = false
            installHighlightTimer()
        } else {
            isPlaying = false
            isPaused = current != nil
            pausedAt = targetTime
        }
        updateHighlight(at: targetTime)
    }

    /// Jumps to the start of the sentence with global index `index`, going STRAIGHT to the
    /// slice that contains it — without going through global time.
    ///
    /// Why straight: in streaming the durations arrive late (background
    /// probe) and `knownDuration`/offsets stay wrong until measured. The old
    /// path converted sentence→global time with zeroed offsets and `seek(to:)`
    /// clamped at the end of the measured audio or fell into the wrong slice: the click read
    /// ANOTHER part. Here the slice is the one containing the sentence and the point is
    /// `seg.start` (LOCAL time, always right); the highlight uses the same
    /// local times. The displayed clock (`elapsed`) stays approximate until
    /// the probes arrive — only it. Returns false when the sentence has no
    /// audio yet.
    @discardableResult
    func seek(toSegment index: Int) -> Bool {
        for (chunk, segs) in chunkSegments.enumerated() {
            guard chunk < queue.count else { continue }
            if let seg = segs.first(where: { $0.index == index }) {
                gotoChunk(chunk, within: seg.start)
                return true
            }
        }
        return false
    }

    @discardableResult
    func jumpToSegment(_ index: Int) -> Bool {
        guard seek(toSegment: index) else { return false }
        play()
        return true
    }

    func pause() {
        guard let player = current, player.isPlaying else { return }
        pausedAt = player.currentTime
        player.pause()
        highlightTimer?.invalidate()
        highlightTimer = nil
        isPlaying = false
        isPaused = true
    }

    func resume() {
        guard let player = current, isPaused else { return }
        player.currentTime = pausedAt
        player.play()
        isPlaying = true
        isPaused = false
        installHighlightTimer()
    }

    func stop() {
        playbackGeneration += 1
        currentGeneration = -1
        pendingProbes = []
        current?.stop()
        current = nil
        highlightTimer?.invalidate()
        highlightTimer = nil
        queue = []
        chunkSegments = []
        chunkDurations = []
        chunkOffsets = []
        nextIndex = 0
        elapsed = 0
        knownDuration = 0
        synthesisComplete = false
        isPlaying = false
        isPaused = false
        isFinished = false
        isStarved = false
        startPending = false
        isBuffering = false
        currentSegmentText = nil
        currentSegmentIndex = -1
        currentSegmentPage = nil
        currentWordIndex = -1
    }

    /// Restarts the reading from the fully synthesized MP3 (or from cache).
    ///
    /// Here the times ARE already global (the file is the concatenated one), hence the
    /// whole list works as a "single slice" with zero offset.
    func restart(audioURL: URL, segments allSegments: [EdgeTTS.Segment]) {
        stop()
        guard let probe = try? AVAudioPlayer(contentsOf: audioURL) else { return }
        queue = [audioURL]
        chunkSegments = [allSegments]
        chunkDurations = [probe.duration]
        recomputeOffsets()
        nextIndex = 0
        synthesisComplete = true
        playChunk(audioURL)
    }

    func play() {
        // Queue starved (`isStarved`): without `current`, the `guard`
        // below returned doing nothing and the reading never resumed via the button.
        if current == nil, nextIndex < queue.count {
            playChunk(queue[nextIndex])
            return
        }
        guard let player = current, !player.isPlaying else { return }
        player.play()
        isPlaying = true
        isPaused = false
        isFinished = false
        installHighlightTimer()
    }

    /// Releases the held start as soon as the map is ready (enough slices AND
    /// their durations measured). Called by `enqueue`, by `finishProbe` — the
    /// probe is usually what completes the map, and forgetting it here held the
    /// first sound until the NEXT slice arrived (or the whole synthesis closed):
    /// the opening seconds ran with no audio and no highlight.
    private func releasePrebufferIfReady() {
        guard startPending, startReady else { return }
        startPending = false
        isBuffering = false
        if nextIndex < queue.count {
            playChunk(queue[nextIndex])
            restorePausedOffset()
        }
    }

    /// Closes the queue: when the last slice ends, the reading is over.
    /// A held-back start releases at once with whatever is buffered.
    func markSynthesisComplete() {
        synthesisComplete = true
        if startPending {
            startPending = false
            isBuffering = false
            if nextIndex < queue.count {
                playChunk(queue[nextIndex])
                restorePausedOffset()
            }
            else { handleExhausted() }
        }
    }

    private func playChunk(_ url: URL) {
        guard nextIndex < queue.count else {
            handleExhausted()
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = volume
            player.prepareToPlay()
            // Completes the duration when the background task did not deliver it: reads
            // from the playback's OWN player, with no extra I/O nor instance.
            if nextIndex < chunkDurations.count, chunkDurations[nextIndex] == 0 {
                chunkDurations[nextIndex] = player.duration
                recomputeOffsets()
            }
            player.play()
            current = player
            currentGeneration = playbackGeneration
            isPlaying = true
            isPaused = false
            isFinished = false
            isStarved = false
            installHighlightTimer()
            // Positions the highlight at once, without waiting the first 10 Hz
            // tick: the sound and the highlight start together.
            updateHighlight(at: player.currentTime)
        } catch {
            // A corrupted slice cannot drop the whole reading: skip
            // to the NEXT in the queue. Before, it repeated the SAME url (`playChunk(url)`)
            // and burned `nextIndex` until emptying without marking `isStarved` —
            // a permanent hang with the following slices already ready on disk.
            nextIndex += 1
            if nextIndex < queue.count {
                playChunk(queue[nextIndex])
            } else {
                handleExhausted()
            }
        }
    }

    /// Queue emptied: end only when synthesis finished; else, wait
    /// (`isStarved`) for `enqueue` to resume when the next slice arrives.
    private func handleExhausted() {
        isFinished = synthesisComplete
        isPlaying = false
        isStarved = !synthesisComplete
        current = nil
    }

    private func installHighlightTimer() {
        highlightTimer?.invalidate()
        guard !chunkSegments.isEmpty else { return }
        // 10 Hz suffices: the shortest word lasts ~300 ms, and every tick
        // rebuilds the highlight — 20 Hz with long text saturated the main thread.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.current else { return }
                self.updateHighlight(at: player.currentTime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    /// Nudge state: when the timed word stalls while its sentence continues
    /// (timings exhausted by expansions like years), the yellow would freeze
    /// and jump — it creeps instead, one word per ~0.9 s, never past the last
    /// timed word. Reset on every real change; every nudge is probe-marked.
    private var nudgeWord = -1
    private var nudgeSince = 0.0
    private var nudgeSeg = -1
    private var nudgedNow = false
    private func updateHighlight(at seconds: Double) {
        elapsed = nextIndex < chunkOffsets.count
            ? chunkOffsets[nextIndex] + seconds
            : knownDuration
        guard nextIndex < chunkSegments.count else { return }
        let local = chunkSegments[nextIndex]
        guard !local.isEmpty else {
            currentSegmentText = nil
            currentSegmentIndex = -1
            currentSegmentPage = nil
            currentWordIndex = -1
            return
        }
        var low = 0
        var high = local.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if local[mid].start <= seconds { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        if found >= 0 {
            // Only republishes when it CHANGES: without this guard, the 4 published
            // ones below emitted on every tick and the view rebuilt the text
            // entirely (45k letters) 10x/s — the main thread saturated and the highlight
            // looked stuck.
            let seg = local[found]
            var word = wordIndex(in: seg.words, at: seconds)
            // Timed word stalled while the sentence continues: creep forward
            // instead of freezing (expansions exhaust the timed words).
            nudgedNow = false
            if word == nudgeWord, seg.index == nudgeSeg, word >= 0, word + 1 < seg.words.count,
               seconds - nudgeSince >= 0.9 {
                word += 1
                nudgeWord = word
                nudgeSince = seconds
                nudgedNow = true
            } else if word != nudgeWord || seg.index != nudgeSeg {
                nudgeSeg = seg.index
                nudgeWord = word
                nudgeSince = seconds
            }
            if seg.text != currentSegmentText { currentSegmentText = seg.text }
            if seg.index != currentSegmentIndex { currentSegmentIndex = seg.index }
            if seg.page != currentSegmentPage { currentSegmentPage = seg.page }
            if word != currentWordIndex { currentWordIndex = word }
        } else {
            currentSegmentText = nil
            currentSegmentIndex = -1
            currentSegmentPage = nil
            currentWordIndex = -1
        }
    }

    /// Index of the word being read within the sentence, by binary search at the
    /// local instant. -1 when there is no word (empty list or before the 1st).
    private func wordIndex(in words: [EdgeTTS.Segment.Word], at seconds: Double) -> Int {
        guard !words.isEmpty else { return -1 }
        var low = 0
        var high = words.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= seconds { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Late delegate (e.g. fired after a `stop()`): only the
        // current session's player counts; the rest is ignored, without touching the queue.
        guard player === current, currentGeneration == playbackGeneration else { return }
        nextIndex += 1
        guard nextIndex < queue.count else {
            current = nil
            handleExhausted()
            currentSegmentText = nil
            currentSegmentIndex = -1
            currentSegmentPage = nil
            currentWordIndex = -1
            return
        }
        playChunk(queue[nextIndex])
    }
}
