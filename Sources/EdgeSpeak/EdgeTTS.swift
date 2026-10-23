import Foundation
import AVFoundation

/// Streaming synthesis engine: uses the `edge-tts` CLI per slice and delivers
/// each one as soon as it is ready. No UI — see INTERFACE.md section 1.
///
/// - SeeAlso: ``SpeechController``, ``StreamingPlayer``
enum EdgeTTS {
    /// Path of the edge-tts CLI (first existing; else "edge-tts" on PATH).
    static let edgeTTSPath: String = EdgeTTS.firstExisting([
        NSHomeDirectory() + "/.local/bin/edge-tts",
        "/opt/homebrew/bin/edge-tts",
        "/usr/local/bin/edge-tts",
    ]) ?? "edge-tts"

    static let ffmpegPath: String? = EdgeTTS.firstExisting([
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ])

    /// Python interpreter able to import `edge_tts`.
///
/// The search covers the two real installations that exist: the pipx venv (this
/// machine) and a loose venv at `~/.local/share/edge-tts-venv` (MacBook Pro). On the
/// MacBook only the venv has the package — the system `python3` gives
/// `ModuleNotFoundError`, so falling on it would make synthesis fail for no
/// apparent reason.
    static var pythonPath: String {
        let pronto = BundledEnv.readyPython()
        return BundledEnv.pickPython(
            support: pronto, supportValid: pronto != nil, legacy: legacyPython())
    }

    private static let legacyLock = NSLock()
    private static var legacyCache: String?
    private static var legacyCacheTime: Date?
    /// Cache TTL: re-check every 5 minutes in case the Python environment changes.
    private static let legacyCacheTTL: TimeInterval = 300

    private static func legacyPython() -> String {
        let cachedResult: String? = legacyLock.withLock {
            if let cached = legacyCache, let time = legacyCacheTime,
               Date().timeIntervalSince(time) < legacyCacheTTL,
               FileManager.default.isExecutableFile(atPath: cached) {
                return cached
            }
            return nil
        }
        if let cached = cachedResult { return cached }
        let found = firstPythonWithEdgeTTS()
        legacyLock.withLock {
            legacyCache = found
            legacyCacheTime = Date()
        }
        return found
    }

    /// Interpreter to synthesize now: prepares the bundled environment
    /// (with progress in the status) and only falls back to the legacy one in dev — if the
    /// preparation fails AND the legacy one does not import edge_tts, the preparation error
    /// (readable) is what the UI shows.
    static func pythonForSynthesis(locale: L.Language = .en, progress: @escaping (String) -> Void) throws -> String {
        if let pronto = BundledEnv.readyPython() { return pronto }
        do {
            return try BundledEnv.ensure(locale: locale, progress: progress)
        } catch {
            let legacy = legacyPython()
            if canImport(legacy, module: "edge_tts") { return legacy }
            throw error
        }
    }

    private static func canImport(_ python: String, module: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "import \(module)"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        // `waitUntilExit` only on a launched process: on a never-launched one
        // it raises NSInternalInconsistencyException.
        do {
            try probe.run()
        } catch {
            return false
        }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

private static func firstPythonWithEdgeTTS() -> String {
    let candidates = [
        NSHomeDirectory() + "/Library/Application Support/pipx/venvs/edge-tts/bin/python",
        NSHomeDirectory() + "/.local/share/edge-tts-venv/bin/python",
        "/opt/homebrew/opt/python@3.14/bin/python3.14",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3",
    ]
    for candidate in candidates
    where FileManager.default.isExecutableFile(atPath: candidate) {
        // Only accepts what actually imports `edge_tts`: an interpreter
        // that exists but lacks the package would produce a confusing failure.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: candidate)
        probe.arguments = ["-c", "import edge_tts"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        // `waitUntilExit` only on a launched process: on a never-launched one
        // it raises NSInternalInconsistencyException.
        do {
            try probe.run()
        } catch {
            continue
        }
        probe.waitUntilExit()
        if probe.terminationStatus == 0 { return candidate }
    }
    // None validated: returns the first existing one and lets the script's error
    // appear in the UI, which is more useful than a generic "not found".
    for candidate in candidates
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return "python3"
}

    /// Script that returns the audio and the sentence times.
    ///
    /// Looks inside the bundle (for the packaged app) and falls back to the repository
    /// path when run straight from the build, for development.
    static let synthTimingScript: String = {
        let name = "synth_timing.py"
        if let bundled = Bundle.main.url(forResource: "synth_timing", withExtension: "py") {
            return bundled.path
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EdgeSpeak
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Tools/\(name)").path
    }()

    /// Speech cadence, in percent: +0% is the natural pace, +30% speaks
    /// 30% faster. Comes from edge-tts's `--rate`.
///
/// Why in synthesis and not in the player: applying `AVAudioPlayer.rate` afterwards
/// changes the pitch (thin/strangled voice). By asking the service, the voice is
/// generated at the right cadence — and the highlight stays in sync by itself,
/// because the times are read from the audio already produced.
struct Rate: Equatable, Hashable, Sendable {
    let percent: Int

    static let normal = Rate(percent: 0)

    /// Steps presented in the UI, from slowest to fastest.
    ///
    /// Plano item 43 (capacidades item 15): the old list stopped at +50% (of 10
    /// in 10), leaving 1.75× out of reach for study-mode readers. The list is
    /// finer (0 ±10 in steps of 5 around the natural pace) and wider (-30%…
    /// 2×/+100%). Rates invalidate the per-rate cache by design — the cache
    /// key already includes the percent, so a new choice simply misses and
    /// resynthesizes.
    static let choices: [Rate] = [
        -30, -20, -15, -10, -5, 0, 5, 10, 15, 20, 25, 30,
        35, 40, 50, 60, 75, 100,
    ].map { Rate(percent: $0) }

    var label: String {
        percent == 0 ? "Normal" : (percent > 0 ? "+\(percent)%" : "\(percent)%")
    }

    /// The exact format the CLI expects (e.g. "+30%").
    var cliValue: String {
        percent >= 0 ? "+\(percent)%" : "\(percent)%"
    }
}

/// A read sentence, with the instant it starts inside the final MP3.
    struct Segment: Codable, Sendable, Identifiable {
        /// One word of the sentence, with times local to the slice (like the sentence).
        struct Word: Codable, Sendable {
            let start: Double
            let duration: Double
            let text: String
        }
        let start: Double
        let duration: Double
        let text: String
        /// Words of the sentence, in order (empty without word times).
        var words: [Word] = []
        /// Global index of the sentence in the active list (-1 when unknown).
        var index: Int = -1
        /// Source page (0-based; nil without PDF).
        var page: Int?
        /// Boxes of the source paragraph's lines ([] without PDF or without times).
        var rects: [CGRect] = []
        var id: Int { index >= 0 ? index : Int(start * 1000) }

        enum CodingKeys: String, CodingKey {
            case start, duration, text, words, index, page, rects
        }

        init(start: Double, duration: Double, text: String, words: [Word] = [],
             index: Int = -1, page: Int? = nil, rects: [CGRect] = []) {
            self.start = start
            self.duration = duration
            self.text = text
            self.words = words
            self.index = index
            self.page = page
            self.rects = rects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            duration = try c.decode(Double.self, forKey: .duration)
            text = try c.decode(String.self, forKey: .text)
            // Old JSON/cache has no `words`: becomes an empty list.
            words = (try? c.decode([Word].self, forKey: .words)) ?? []
            index = (try? c.decode(Int.self, forKey: .index)) ?? -1
            page = try? c.decode(Int.self, forKey: .page)
            rects = (try? c.decode([CGRect].self, forKey: .rects)) ?? []
        }
    }

    struct Result: Sendable {
        let audioURL: URL
        let segments: [Segment]
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Slices per sentence

    /// Measured: edge-tts produces ~35 characters per second (1760 chars ≈ 49 s).
    /// That is why the deadline scales with the slice size instead of being fixed — a
    /// short timeout killed legitimate synthesis and looked like a hang.
    static func timeout(forChars chars: Int) -> TimeInterval {
        // 10 chars/s is much more pessimistic than observed: there is slack for
        // bad network without leaving the UI stuck indefinitely.
        min(600, max(60, Double(chars) / 10))
    }

    /// How many slices to synthesize at once (max ~3).
    ///
    /// Above that the service throttles and the FIRST slice takes long — which
    /// defeats progressive reading. Low concurrency = fast audio.
    static let maxConcurrentChunks = 3

    /// Attempts per slice. The service fails sporadically under load; without
    /// retry, an isolated failure would drop the whole document's synthesis.
    static let maxAttemptsPerChunk = 3

    /// Groups whole sentences into slices of <= maxChars, with the FIRST one short,
    /// preferring to cut at a paragraph end — and NEVER after a phrase without
    /// terminal punctuation (a sentence split across pages comes as passages;
    /// cutting between them reads the sentence with a gap in the middle).
    /// A hard ceiling of 2x the cap still splits runaway text (no stall).
    ///
    /// A sentence is never cut in half: the script returns ~1 event per sentence and
    /// the pairing by order becomes the global index. First one short so the
    /// audio starts in ~1 s; the rest follow behind in index order. Cutting at a
    /// paragraph end puts the boundary breath (new prose + trimmed silence) at a
    /// natural pause, instead of mid-thought — without this the transition between slices stutters.
    ///
    /// Not the slicer of ONE runaway sentence (that is why the offline path has
    /// its own, `PiperTTS.speechPieces`, item 47): a phrase above the cap is
    /// returned UNCHANGED here (the loop only ever adds a phrase to a slice, it
    /// never splits one), and the hard ceiling of 2x lets a group past the cap —
    /// both deliberate for grouping whole sentences, neither of which bounds a
    /// single 30-thousand-character sentence.
    static func buildChunks(
        _ phrases: [TextImport.Phrase],
        maxChars: Int,
        firstChars: Int = 450,
        leadChunks: Int = 1
    ) -> [[TextImport.Phrase]] {
        /// A cut is only clean after terminal punctuation (trailing closers
        /// don't count as continuation).
        func endsCleanly(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]"))
            return t.last.map { ".!?…".contains($0) } ?? false
        }
        var out: [[TextImport.Phrase]] = []
        var current: [TextImport.Phrase] = []
        var count = 0
        var i = 0
        while i < phrases.count {
            let phrase = phrases[i]
            let size = phrase.text.count
            // Lead slices stay short: the player only starts after
            // `minStartChunks` slices arrive measured, so the gate fills in
            // ~2 s instead of waiting on a huge second slice. Default 1
            // preserves the historical single short head.
            let cap = out.count < leadChunks ? firstChars : maxChars
            let add = (current.isEmpty ? 0 : 1) + size
            if !current.isEmpty, count + add > cap {
                if let cut = current.lastIndex(where: { $0.paragraphEnd }),
                   cut < current.count - 1 {
                    // Returns the rest to the next slice and re-evaluates the current
                    // sentence against it; each retreat shrinks, so it terminates.
                    let rest = Array(current[(cut + 1)...])
                    current = Array(current[...cut])
                    out.append(current)
                    current = rest
                    count = rest.reduce(0) { $0 + $1.text.count }
                        + max(0, rest.count - 1)
                    continue
                }
                // Mid-sentence (page-split passages, runaway prose): carries on
                // to the next terminal punctuation, up to a hard 2x ceiling.
                if let last = current.last, !endsCleanly(last.text), count + add <= 2 * cap {
                    if !current.isEmpty { count += 1 }
                    current.append(phrase)
                    count += size
                    i += 1
                    continue
                }
                out.append(current)
                current = []
                count = 0
                continue
            }
            if !current.isEmpty { count += 1 }
            current.append(phrase)
            count += size
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Pairs the script's events with the slice's sentences, by order.
    ///
    /// The published text is the sentence's (active list); the script only brings
    /// the times. Extra events are ignored; sentences without an event inherit the end
    /// of the previous one — time is never invented, only index, page and boxes.
    /// With an EMPTY script every sentence comes out at `start: 0`; the slice's
    /// measured duration is spread over them later, by `distributeUntimed`.
    static func mapSegments(
        _ script: [Segment], _ phrases: [TextImport.Phrase]
    ) -> [Segment] {
        var out: [Segment] = []
        var lastEnd = 0.0
        for (i, phrase) in phrases.enumerated() {
            if i < script.count {
                let s = script[i]
                out.append(Segment(
                    start: s.start, duration: s.duration,
                    text: phrase.text, words: s.words,
                    index: phrase.index, page: phrase.page,
                    rects: phrase.rects))
                lastEnd = s.start + s.duration
            } else {
                out.append(Segment(
                    start: lastEnd, duration: 0,
                    text: phrase.text, index: phrase.index, page: phrase.page,
                    rects: phrase.rects))
            }
        }
        return out
    }

    /// Times for a slice whose timing script came back empty (or unreadable).
    ///
    /// The script is the only source of REAL times; without it `mapSegments`
    /// leaves every sentence at `start: 0`, and the binary search of
    /// `StreamingPlayer.updateHighlight` always lands on the LAST sentence of the
    /// slice — the highlight freezes there for the whole audio and a click plays
    /// from the start of the slice. Here the measured duration of the slice is
    /// divided among the sentences in proportion to their length: an ESTIMATE,
    /// said in the doc so nobody reads it as measurement, and only applied when
    /// NOT ONE sentence brought a usable time — a real script is never touched,
    /// and neither is a slice whose duration could not be measured (`over <= 0`).
    /// Internal (not private) so the suite covers the distribution directly.
    static func distributeUntimed(_ segments: [Segment], over total: Double) -> [Segment] {
        guard total > 0, !segments.isEmpty else { return segments }
        guard segments.allSatisfy({ $0.start <= 0 && $0.duration <= 0 }) else { return segments }
        // Weight by length, floor 1: a sentence never gets a zero-width window,
        // and the sum stays > 0 even with empty texts.
        let weights = segments.map { max(1, $0.text.count) }
        let weightSum = weights.reduce(0, +)
        var out: [Segment] = []
        var acc: Double = 0
        for (seg, weight) in zip(segments, weights) {
            let span = total * Double(weight) / Double(weightSum)
            out.append(Segment(
                start: acc, duration: span, text: seg.text, words: seg.words,
                index: seg.index, page: seg.page, rects: seg.rects))
            acc += span
        }
        return out
    }

/// Streams synthesis: delivers each slice as soon as it is ready.
    ///
    /// Why `AsyncStream` and not a callback: delivery must happen at the
    /// instant the task ends. With a fixed-window `TaskGroup`,
    /// the consumer only resumes when a group task returns — and the
    /// test showed slice 0 ready at 38 s being delivered only at 100 s,
    /// because the group waited for the others. The stream delivers at once.
    ///
    /// Slices are synthesized in parallel, but delivered IN ORDER:
    /// playback can only move forward, never backward.
    static func synthesizeStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        maxChars: Int,
        rate: Rate = .normal,
        readFootnotes: Bool = true,
        locale: L.Language = .en,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> AsyncThrowingStream<ChunkDelivery, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let final = try await runStreaming(
                        phrases: phrases, voice: voice, maxChars: maxChars, rate: rate,
                        readFootnotes: readFootnotes, locale: locale,
                        shouldCancel: shouldCancel, progress: progress,
                        onChunk: { continuation.yield($0) }
                    )
                    continuation.yield(.final(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Body of the streaming synthesis. Emits one `Result` per slice, in order, and at
    /// the end emits the final `Result` with the single MP3.
    private static func hasEnoughDiskSpace() -> Bool {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/")
        let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = vals?.volumeAvailableCapacityForImportantUsage ?? -1
        return free < 0 || free >= 200_000_000
    }

    private static func runStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        maxChars: Int,
        rate: Rate,
        readFootnotes: Bool,
        locale: L.Language,
        shouldCancel: @escaping () -> Bool,
        progress: @escaping (String) -> Void,
        onChunk: @escaping (ChunkDelivery) -> Void
    ) async throws -> Result {
        let groups = buildChunks(
            phrases, maxChars: maxChars, leadChunks: StreamingPlayer.minStartChunks)
        guard !groups.isEmpty else {
            throw makeError(key: "error.nothingToSynthesize")
        }
        if !Self.hasEnoughDiskSpace() {
            throw makeError(key: "error.insufficientDiskSpace")
        }
        try Task.checkCancellation()

        let fm = FileManager.default
        // Disk guard before writing hours of audio (item 48): the failure
        // belongs at the start, not in hour three with a generic message.
        guard DiskSpace.hasRoom(at: fm.temporaryDirectory, floor: DiskSpace.synthesisFloor) else {
            throw makeError(key: "error.diskFull", args: [DiskSpace.freeSpaceText(at: fm.temporaryDirectory)])
        }
        let dir = fm.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-\(UUID().uuidString)", isDirectory: true)
        let chunksDir = dir.appendingPathComponent("chunks", isDirectory: true)

        do {
            purgeStaleDirectories(keeping: dir)
            try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)

            let total = groups.count
            var chunkURLs = [URL?](repeating: nil, count: total)
            var chunkSegments = [[Segment]](repeating: [], count: total)
            var chunkDurations = [Double](repeating: 0, count: total)
            let done = Counter()
            // Serial publisher: slices may finish out of order, but
            // delivery must be in order. `nextToDeliver` marks up to where
            // it has already been emitted.
            let state = OrderedPublisher(total: total)

            try await withThrowingTaskGroup(of: (Int, URL, [Segment]).self) {
                group in
                var inFlight = 0
                for (i, groupPhrases) in groups.enumerated() {
                    // Fills the pipe from t=0. Before, the first slice went
                    // alone and the following ones only started when it
                    // finished — with the measured service variation (2 s to
                    // 30 s+ per slice), the queue emptied around ~30 s and the
                    // reading paused. Measured: 3 in parallel do not delay
                    // each other (first ready in ~1 s with the pipe full).
                    let limit = maxConcurrentChunks
                    while inFlight >= limit {
                        if let finished = try await group.next() {
                            chunkURLs[finished.0] = finished.1
                            chunkSegments[finished.0] = finished.2
                            inFlight -= 1
                            state.emitReady({ chunkURLs[$0] != nil }) { j in
                        onChunk(.chunk(index: j, url: chunkURLs[j]!, segments: chunkSegments[j]))
                    }
                        }
                    }
                    group.addTask {
                        try Task.checkCancellation()
                        // Adapted for speech (abbreviations, years, logic, and
                        // citations with the toggle on); the published one
                        // follows the original via `mapSegments`. Paragraph boundary
                        // becomes a line break (the TTS breath); `\n` does not match the
                        // script's `_SENT_END`, so the 1:1 sentence↔event holds.
                        var piece = ""
                        for (idx, ph) in groupPhrases.enumerated() {
                            if idx > 0 { piece += groupPhrases[idx - 1].paragraphEnd ? "\n" : " " }
                            piece += CitationSkip.speechText(ph.text, voice: voice, readFootnotes: readFootnotes, marker: ph.noteMarker)
                        }
                        let outURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.mp3", i))
                        let jsonURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.json", i))
                        let textURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.txt", i))
                        // Boundary with the script: one line per slice sentence,
                        // with the SAME speech text already sent (`speechText`, in
                        // sentence order). The script pairs 1:1 by order,
                        // without deriving sentences with its own regex.
                        let linesURL = chunksDir.appendingPathComponent(
                            String(format: "chunk-%04d.lines.txt", i))
                        let speechLines = groupPhrases.map {
                            CitationSkip.speechText($0.text, voice: voice, readFootnotes: readFootnotes, marker: $0.noteMarker)
                        }
                        // Why the Python script and not the CLI: the CLI only writes
                        // SRT per sentence; the script reads the SentenceBoundary
                        // events from the library and returns each one's time in JSON.
                        try piece.write(to: textURL, atomically: true, encoding: .utf8)
                        try speechLines.joined(separator: "\n")
                            .write(to: linesURL, atomically: true, encoding: .utf8)
                        // Retry: under load the service fails sporadically.
                        // Trying again avoids losing the document over a
                        // transient network failure.
                        var lastError = L.get("error.unknownError", locale: locale)
                        for attempt in 1...self.maxAttemptsPerChunk {
                            do {
                                try Task.checkCancellation()
                                let py = try Self.pythonForSynthesis(locale: locale, progress: progress)
                                try Task.checkCancellation()
                                try? FileManager.default.removeItem(at: outURL)
                                let (status, stderr) = try await self.run(
                                    py,
                                    [synthTimingScript,
                                     "--text-file", textURL.path,
                                     "--lines-file", linesURL.path,
                                     "--voice", voice,
                                     "--rate", rate.cliValue,
                                     "--out-mp3", outURL.path,
                                     "--out-json", jsonURL.path],
                                    timeout: self.timeout(forChars: piece.count)
                                )
                                guard status == 0 else {
                                    lastError = "status \(status): \(self.tail(stderr, max: 300))"
                                    throw self.makeError(detail: lastError)
                                }
                                guard let size = self.fileSize(outURL), size > 0 else {
                                    lastError = "no audio produced: \(self.tail(stderr, max: 300))"
                                    throw self.makeError(detail: lastError)
                                }
                                let leading = await self.trimSilence(outURL)
                                progress(L.get("progress.chunkFraction", locale: locale, args: done.increment(), total))
                                let (rawScript, reason) = self.loadSegments(jsonURL, locale: locale)
                                // Leading trim moves every sound earlier: shifts the
                                // sentence (and word) times by the removed lead.
                                let script = leading > 0 ? rawScript.map { seg in Segment(
                                    start: max(0, seg.start - leading), duration: seg.duration,
                                    text: seg.text,
                                    words: seg.words.map { w in Segment.Word(
                                        start: max(0, w.start - leading), duration: w.duration, text: w.text) },
                                    index: seg.index, page: seg.page, rects: seg.rects)
                                } : rawScript
                                if let reason {
                                    // Status warning: without timings the chunk still plays,
                                    // but highlight and click-jump collapse.
                                    progress(Self.warningWithoutTimings(
                                        slice: i + 1, reason: reason, locale: locale))
                                }
                                return (i, outURL, self.mapSegments(script, groupPhrases))
                            } catch {
                                lastError = self.tail(error.localizedDescription, max: 300)
                                // 403 is a service block, not instability:
                                // retrying the same call does not help, fail now.
                                if lastError.contains("403") { break }
                                if attempt < self.maxAttemptsPerChunk {
                                    // Short progressive wait: service failures
                                    // usually resolve in seconds.
                                    try? await Task.sleep(
                                        nanoseconds: UInt64(attempt) * 800_000_000)
                                }
                            }
                        }
                        throw self.makeError(
                            key: "error.chunkFailed",
                            args: [self.maxAttemptsPerChunk, i + 1, total, lastError])
                    }
                    inFlight += 1
                }
                while let finished = try await group.next() {
                    chunkURLs[finished.0] = finished.1
                    chunkSegments[finished.0] = finished.2
                    state.emitReady({ chunkURLs[$0] != nil }) { i in
                        onChunk(.chunk(index: i, url: chunkURLs[i]!, segments: chunkSegments[i]))
                    }
                }
            }
            if shouldCancel() { throw makeError(key: "common.synthesisCancelled") }

            let ordered = chunkURLs.compactMap { $0 }
            guard ordered.count == total else {
                throw makeError(key: "error.incompleteSynthesis", args: [ordered.count, total])
            }
            for url in ordered {
                let index = chunkURLs.firstIndex(of: url) ?? 0
                let measured = await duration(of: url)
                // Both probes (CoreMedia and AVAudioPlayer) came back zero: the
                // slice enters the account as 0 and every following sentence is
                // shifted with no other sign. The warning goes to the status
                // through the same channel as `warningWithoutTimings`; the
                // measurement itself is not replaced by an estimate.
                if measured <= 0 {
                    progress(Self.warningUnmeasuredDuration(slice: index + 1, locale: locale))
                }
                chunkDurations[index] = measured
            }
            let outURL = try await concat(ordered, into: dir.appendingPathComponent("EdgeSpeak.mp3"))
            var segments: [Segment] = []
            var offset: Double = 0
            for i in 0..<total {
                for seg in distributeUntimed(chunkSegments[i], over: chunkDurations[i]) {
                    // Words travel with the sentence: same offset.
                    let shifted = seg.words.map { w in Segment.Word(
                        start: w.start + offset, duration: w.duration, text: w.text) }
                    segments.append(Segment(
                        start: seg.start + offset, duration: seg.duration,
                        text: seg.text, words: shifted,
                        index: seg.index, page: seg.page,
                        rects: seg.rects))
                }
                offset += chunkDurations[i]
            }
            // From here on this directory is the current reading's: the
            // next purges (including of other voices/engines) preserve it.
            // `withLock` instead of lock/unlock: this runs inside an `async`
            // function and the raw pair is unavailable from asynchronous
            // contexts (an error in the Swift 6 language mode).
            keptLock.withLock { protectedDir = dir }
            return Result(audioURL: outURL, segments: segments)
        } catch {
            // Do NOT delete `dir` here: slices already delivered are still
            // referenced by the player's queue — erasing them made the
            // skip-chain consume the queue in silence and left `isStarved`
            // stuck forever. The orphan is collected by the next synthesis's
            // `purgeStaleDirectories` (this dir was never registered as the
            // protected current reading).
            throw error
        }
    }

    enum ChunkDelivery: Sendable {
        case chunk(index: Int, url: URL, segments: [Segment])
        case final(Result)
    }

    /// Publishes the slices in order, ignoring the ones that arrive out of sequence.
    ///
    /// Why a class with a lock: the emitter runs inside the group's
    /// consumer, and the index must be read and incremented without a race.
    /// Internal (not private) so the headless harness covers the order.
    final class OrderedPublisher: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private let total: Int

        init(total: Int) { self.total = total }

        /// Calls `body` for each index already ready, in order.
        func emitReady(_ isReady: (Int) -> Bool, _ body: (Int) -> Void) {
            let toEmit = lock.withLock { () -> [Int] in
                var out: [Int] = []
                while next < total, isReady(next) {
                    out.append(next)
                    next += 1
                }
                return out
            }
            for i in toEmit { body(i) }
        }
    }

    private static func concat(_ ordered: [URL], into outURL: URL) async throws -> URL {
        let fm = FileManager.default
        if let ffmpeg = ffmpegPath {
            let listURL = outURL.deletingLastPathComponent().appendingPathComponent("list.txt")
            let list = ordered.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
            try list.write(to: listURL, atomically: true, encoding: .utf8)
            let (status, stderr) = try await run(
                ffmpeg,
                ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", outURL.path])
            guard status == 0 else {
                throw makeError(key: "error.ffmpegFailed", args: [status, tail(stderr)])
            }
        } else {
            guard fm.createFile(atPath: outURL.path, contents: nil) else {
                throw makeError(key: "error.cannotCreateFile", args: [outURL.lastPathComponent])
            }
            let handle = try FileHandle(forWritingTo: outURL)
            defer { try? handle.close() }
            for url in ordered { try handle.write(contentsOf: Data(contentsOf: url)) }
        }
        guard let size = fileSize(outURL), size > 0 else {
            throw makeError(key: "error.concatEmpty")
        }
        return outURL
    }

    /// ffmpeg arguments to trim the LEADING silence of the slice. Factored
    /// pure for testing (the rule lives here, not spread in the caller).
    ///
    /// ONLY the lead is removed. A trailing `silenceremove=stop_periods=-1`
    /// clause used to sit here; it does NOT trim just the end — a negative
    /// `stop_periods` shortens EVERY silence period in the file, each
    /// inter-sentence pause included. Measured on 2026-10-17 with a synthetic
    /// slice (1 s tone + 0.9 s pause + 1 s tone, 24 kHz mono MP3, the same
    /// shape the service returns): original 2.900 s, current filter 2.170 s,
    /// and `silencedetect=noise=-40dB:d=0.5` finds no pause at all in the
    /// output — the 0.9 s interior pause was cut to ~0.27 s. The sentence and
    /// word times that `synth_timing.py` records still carry the ORIGINAL
    /// pauses, and `trimSilence` compensates only the lead, so the audio ran
    /// ahead of the highlight clock and the gap grew one pause per sentence.
    /// Removing only the lead keeps audio and metadata on the same timeline;
    /// the trailing breath stays as a natural pause (it is part of both the
    /// audio and the recorded times).
    static func silenceTrimArgs(input: URL, output: URL) -> [String] {
        ["-y", "-i", input.path,
         "-af", "silenceremove=start_periods=1:start_duration=0.15:start_threshold=-45dB",
         output.path]
    }

    /// Parses the leading silence from a `silencedetect` stderr: the end of
    /// the silence starting at 0, else 0. Pure for testing.
    static func parseLeadingSilence(_ stderr: String) -> TimeInterval {
        var currentStart: Double?
        for line in stderr.components(separatedBy: .newlines) {
            if line.contains("silence_start:") {
                currentStart = Double(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
            } else if line.contains("silence_end:"), currentStart == 0 {
                let tail = line.split(separator: "|").first ?? ""
                if let end = Double(tail.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                    return max(0, end)
                }
            }
        }
        return 0
    }

    /// Leading silence of the file, measured (fast pass, no rewrite).
    private static func leadingSilence(of url: URL) async -> TimeInterval {
        guard let ffmpeg = ffmpegPath else { return 0 }
        guard let (_, stderr) = try? await run(
            ffmpeg,
            ["-hide_banner", "-i", url.path,
             "-af", "silencedetect=noise=-45dB:d=0.15", "-f", "null", "-"],
            timeout: 60)
        else { return 0 }
        return parseLeadingSilence(stderr)
    }

    /// Trims the LEADING silence of the slice (when ffmpeg is available): without this
    /// each boundary carries the TTS breath and the untrimmed LEAD delays
    /// every highlight by its length (measured 0.19 s).
    /// Returns the leading seconds removed, so the caller shifts the sentence
    /// times by the same amount (only the lead moves; the interior pauses stay
    /// in the audio AND in the recorded times, so the timeline never drifts).
    /// The total duration is measured from the trimmed file. Swaps only when
    /// it truly shrinks (>2 KB), so it never swaps identical audio for a
    /// re-encode. Failure degrades silently: keeps the original (shift 0)
    /// and the synthesis proceeds.
    private static func trimSilence(_ url: URL) async -> TimeInterval {
        guard let ffmpeg = ffmpegPath else { return 0 }
        let leading = await leadingSilence(of: url)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("aparado-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let (status, _) = try? await run(
            ffmpeg, silenceTrimArgs(input: url, output: tmp),
            timeout: 120),
            status == 0,
            let antes = fileSize(url), let depois = fileSize(tmp),
            depois > 0, antes > depois + 2048
        else { return 0 }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
        return leading
    }

    /// Reads the sentence times written by synth_timing.py.
    ///
    /// Unreadable JSON does not fail the synthesis — the audio stays valid —, but
    /// it also cannot pass in silence: without times the highlight and the click
    /// jump of the slice collapse (`mapSegments` sets them all to 0). The warning
    /// goes back to the caller to show in the status; time is never invented.
    /// Internal (not private) so the suite can cover the degradation.
    static func loadSegments(
        _ jsonURL: URL, locale: L.Language
    ) -> (segments: [Segment], warning: String?) {
        guard let data = try? Data(contentsOf: jsonURL) else {
            return ([], L.get("error.segmentsFileUnreadable", locale: locale, args: jsonURL.lastPathComponent))
        }
        guard let parsed = try? JSONDecoder().decode(Timings.self, from: data)
        else {
            return ([], L.get("error.segmentsUnreadable", locale: locale, args: jsonURL.lastPathComponent))
        }
        return (parsed.segments, nil)
    }

    /// Timing-unavailable message shown in the status (pure, for tests).
    ///
    /// No "n/n" in the text: the UI parses `\d+/\d+` to feed the progress
    /// bar, and this warning is not progress — it would match and the bar
    /// would lie.
    static func warningWithoutTimings(slice: Int, reason: String, locale: L.Language) -> String {
        L.get("warn.noTimings", locale: locale, args: slice, reason)
    }

    /// Zero-duration message shown in the status (pure, for tests).
    ///
    /// Its own key, not `warn.noTimings`: there the problem is the sync of a
    /// slice that still measures, here the slice could not be measured at ALL —
    /// the account carries a 0 and the sentences after it are out of place. No
    /// "n/n" in the text either: the UI parses `\d+/\d+` to feed the progress
    /// bar, and this warning is not progress.
    static func warningUnmeasuredDuration(slice: Int, locale: L.Language) -> String {
        L.get("warn.durationUnmeasured", locale: locale, args: slice)
    }

    private struct Timings: Decodable {
        let segments: [Segment]
    }

    /// Real duration of the MP3, in seconds.
    ///
    /// Why read the file instead of summing the sentence times: there is silence
    /// at the end of each slice, and that silence must enter the account so
    /// the highlight of the following slices neither leads nor lags.
    ///
    /// Why a fallback instead of a warning: a 0 here does not stay in this
    /// slice — the caller accumulates it into the GLOBAL offset, so every
    /// sentence after the failed slice plays shifted with no visible sign.
    /// The choice is to measure by another real path (`AVAudioPlayer`, the
    /// same probe `StreamingPlayer` uses to play these very files) rather than
    /// announce a 0 the warning channel cannot localize (no catalog key for
    /// it), and both failures together (two independent parsers — CoreMedia
    /// and AudioToolbox — failing on the same file) means the file really is
    /// unreadable: only then does 0 go through, as before. Internal (not
    /// private) so the suite covers both paths.
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        var assetSeconds: Double?
        if let d = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(d)
            // Indefinite/invalid media reports NaN or 0: those are not measures,
            // the pure rule below decides instead.
            if seconds.isFinite, seconds > 0 { assetSeconds = seconds }
        }
        return chooseDuration(asset: assetSeconds, player: playerDuration(of: url))
    }

    /// Pure rule of the duration: the asset measure wins; only when it is
    /// absent/0/NaN/∞ does the player measure count; both failing is the only
    /// case where 0 goes through. Internal (not private) so the suite covers
    /// the DECISION directly — the inline form is only exercised by luck.
    static func chooseDuration(asset: Double?, player: Double?) -> Double {
        if let a = asset, a.isFinite, a > 0 { return a }
        if let p = player, p.isFinite, p > 0 { return p }
        return 0
    }

    /// Fallback probe with `AVAudioPlayer` (parses the header only, no
    /// playback), nil when the file cannot be measured. Internal (not
    /// private) so the suite exercises the fallback directly.
    static func playerDuration(of url: URL) -> Double? {
        guard let probe = try? AVAudioPlayer(contentsOf: url), probe.duration > 0 else { return nil }
        return probe.duration
    }

    /// Terminates any edge-tts left pending by a canceled synthesis.
    /// Without this, the user cancels but the child processes keep consuming CPU.
    ///
    /// Matches by the script under the app's path (bundle, support venv, dev
    /// repo, or temporary `EdgeSpeak-*`) — never by a bare "python"
    /// nor by the script's bare name, so as not to hit a user's manual
    /// run with the same name in another directory. The `Process`
    /// instances created in `run` are also stored and terminated directly.
    static func killRunningProcesses() {
        let tracked = runningLock.withLock { Array(runningSynth.values) }
        for proc in tracked {
            if proc.isRunning { proc.terminate() }
        }
        // Primary pattern: matches the production bundle path
        // (EdgeSpeak.app/Contents/Resources/synth_timing.py) and the dev repo path.
        // No loose fallback by bare script name: the old one reached manual
        // debugging of the same user (`python3 Tools/synth_timing.py` in the
        // Terminal) and killed it. What covers the cases the primary pattern
        // misses is the SECOND pattern below, which still demands EdgeSpeak
        // somewhere in the command line.
        //
        // Known limit of THIS pattern alone: the child's command line is
        // `python3 <script> --text-file <tmp>/EdgeSpeak-<uuid>/…`, so the
        // EdgeSpeak that the temp dir carries comes AFTER the script name —
        // a bundle renamed to something without "EdgeSpeak" would not match
        // here, and neither would the dev worktree when its path lacks the name.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "[Ee]dge[Ss]peak.*synth_timing\\.py"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        // Fallback in the OTHER order, for a renamed bundle and for the dev
        // worktree: the EdgeSpeak that appears after the script name is the temp
        // dir `EdgeSpeak-<uuid>` that carries the text files. Scoped to this user
        // and still requiring the EdgeSpeak context, so it does not eat someone's
        // own manual run of the script outside the app.
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p2.arguments = ["-u", String(getuid()), "-f", "synth_timing\\.py.*[Ee]dge[Ss]peak"]
        p2.standardOutput = FileHandle.nullDevice
        p2.standardError = FileHandle.nullDevice
        try? p2.run()
        p2.waitUntilExit()
    }

    /// Synthesis processes in progress (only those running `synth_timing.py`),
    /// so cancellation terminates them directly without relying only on pkill.
    private static let runningLock = NSLock()
    private static var runningSynth: [Int32: Process] = [:]

    /// Directory of the current reading (the one holding the `Result`'s MP3):
    /// `purgeStaleDirectories` never deletes it, else a later replay would hit
    /// the `restart`'s silent guard with `hasAudio` true and nothing plays.
    private static let keptLock = NSLock()
    private static var protectedDir: URL?

    /// Directory of the current OFFLINE reading (Piper), registered via
    /// `keepOfflineDirectory`: the online engine's purge also preserves it,
    /// otherwise it would delete WAVs still referenced by the reading in
    /// progress — the later replay would hit `restart`'s silent guard and
    /// nothing would play (M4).
    private static var protectedOfflineDir: URL?

    /// Registers the offline directory as the current reading (see M4).
    /// Internal so the suite covers the cross-engine protection.
    static func keepOfflineDirectory(_ url: URL) {
        keptLock.withLock { protectedOfflineDir = url }
    }

    /// Withdraws the offline reading's protection: the audio that used it died
    /// (new synthesis or discarded transcription) — without this, temp dirs of
    /// closed offline readings stayed out of every purge in this process.
    /// A future replay via cache validates the file and resynthesizes when gone.
    static func clearOfflineDirectory() {
        keptLock.lock()
        protectedOfflineDir = nil
        keptLock.unlock()
    }

    /// The directory protected as the current offline reading; nil when none.
    ///
    /// Internal along with `keepOfflineDirectory`/`clearOfflineDirectory`: the
    /// withdrawal after a failed offline run (item 53 of the robustness lane)
    /// is only observable through it, and the suite covers it without a live
    /// Piper.
    static var protectedOfflineDirectory: URL? {
        keptLock.withLock { protectedOfflineDir }
    }

    /// Counter of finished slices, safe for several queues.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        var value: Int {
            lock.withLock { current }
        }
        @discardableResult
        func increment() -> Int {
            lock.withLock {
                current += 1
                return current
            }
        }
    }

    // MARK: - Helpers

    /// Runs a blocking process; stderr goes to a file (no risk of
    /// pipe deadlock). Returns status and stderr content.
    private static func run(_ path: String, _ args: [String]) async throws -> (status: Int32, stderr: String) {
        try await run(path, args, timeout: timeout(forChars: 100_000))
    }

    /// Runs with a deadline: if the process does not finish in time, it is terminated.
    /// Without this, a network failure leaves edge-tts hanging and the UI in
    /// "Synthesizing…" indefinitely. The wait uses `Task.sleep` (never
    /// `Thread.sleep`): this `run` executes inside the task group, and sleeping
    /// on the cooperative thread would hold it for up to 600 s (B2).
    private static func run(
        _ path: String, _ args: [String], timeout: TimeInterval
    ) async throws -> (status: Int32, stderr: String) {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory
            .appendingPathComponent("edgespeak-stderr-\(UUID().uuidString).log")
        guard fm.createFile(atPath: errURL.path, contents: nil) else {
            throw makeError(key: "error.noStderrFile")
        }
        defer { try? fm.removeItem(at: errURL) }

        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            throw makeError(key: "error.cannotExecute", args: [path, error.localizedDescription])
        }
        // Only this app's syntheses enter the cancellation registry: the
        // first argument is the path of `synth_timing.py`.
        let isSynth = args.first?.hasSuffix("synth_timing.py") ?? false
        if isSynth {
            runningLock.withLock { runningSynth[process.processIdentifier] = process }
        }
        defer {
            if isSynth {
                // `removeValue` returns the removed value: discard it explicitly,
                // or `withLock` inherits `Process?` as its result type and the
                // call reads as an unused value.
                _ = runningLock.withLock { runningSynth.removeValue(forKey: process.processIdentifier) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            // Cancellable sleep: with `try?` a cancelled `Task.sleep` would return
            // at once and the loop would spin hot until the deadline; on catch, we
            // leave and the block below ends the process.
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
        }
        if process.isRunning {
            process.terminate()
            // Gives SIGTERM a moment; then forces.
            let hard = Date().addingTimeInterval(2)
            while process.isRunning && Date() < hard {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? errHandle.close()
            let partial = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw makeError(
                key: "error.processTimeout",
                args: [URL(fileURLWithPath: path).lastPathComponent,
                       Int(timeout), tail(partial, max: 400)])
        }
        process.waitUntilExit()
        try? errHandle.close()

        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, stderr)
    }

    /// Removes EdgeSpeak-* directories from earlier runs. The MP3 stays on disk
    /// because AVAudioPlayer needs it while playing, so the directories
    /// accumulate (each with dozens of MB) without this step.
    static func purgeStaleDirectories(keeping current: URL) {
        let fm = FileManager.default
        let (sheltered, offline): (URL?, URL?) = keptLock.withLock { (protectedDir, protectedOfflineDir) }
        let keepURLs = [current.standardizedFileURL, sheltered?.standardizedFileURL, offline?.standardizedFileURL]
            .compactMap { $0 }
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in items
        where url.lastPathComponent.hasPrefix("EdgeSpeak-")
            && !keepURLs.contains(url.standardizedFileURL) {
            try? fm.removeItem(at: url)
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private static func tail(_ text: String, max: Int = 2000) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return L.get("common.noStderrEdge") }
        return t.count <= max ? t : "…" + String(t.suffix(max))
    }

    /// Error with a catalog key: the message comes from `L` in the current language and
    /// the key+args go in `userInfo` so `failureKey` re-resolves on
    /// language switch.
    private static func makeError(key: String, args: [Any] = []) -> NSError {
        NSError(domain: "EdgeSpeak.EdgeTTS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.resolve(key, args: args),
                           "l10nKey": key, "l10nArgs": args])
    }

    /// Raw-detail error (attempt's stderr): only the text, no key —
    /// the attempt's `catch` turns it into `chunkFailed`'s `lastError`.
    private static func makeError(detail: String) -> NSError {
        NSError(domain: "EdgeSpeak.EdgeTTS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

/// Free-space guard before a long synthesis or a voice download (item 48 of the
/// robustness lane, 2026-10-17).
///
/// Without it, a disk that fills up mid-way fails HOURS later with a generic
/// "chunkFailed"/"joinEmpty" — the user sees a synthesis error, not a full
/// disk. The guard only refuses to START: an unavailable measurement (nil)
/// never blocks, so the reading does not become dependent on a resource macOS
/// may not report.
enum DiskSpace {
    /// Floor for the audio of one synthesis (per-chunk files plus the
    /// assembled one). Below this a long reading cannot finish anyway.
    static let synthesisFloor: Int64 = 512 * 1_024 * 1_024

    /// Floor for one voice download: the models are ~63 MB; the margin covers
    /// the `.part` and both files (`onnx` + `json`).
    static let downloadFloor: Int64 = 256 * 1_024 * 1_024

    /// Free bytes on the volume holding `url`; nil when macOS cannot answer
    /// (resource unavailable, volume gone).
    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            return nil
        }
        return capacity
    }

    /// Pure decision: unknown free space never blocks.
    static func allowsStart(available: Int64?, floor: Int64) -> Bool {
        guard let available else { return true }
        return available >= floor
    }

    /// The same rule against the live volume of `url`.
    static func hasRoom(at url: URL, floor: Int64) -> Bool {
        allowsStart(available: availableBytes(at: url), floor: floor)
    }

    /// Free space of `url` spelled for `error.diskFull` ("?" when unreadable:
    /// the message still names the problem instead of showing a fake zero).
    static func freeSpaceText(at url: URL) -> String {
        guard let available = availableBytes(at: url) else { return "?" }
        return humanSize(available)
    }

    /// Size for the message ("820 MB", "1.2 GB"): the number is what makes the
    /// error actionable. Locale-independent on purpose (technical detail).
    static func humanSize(_ bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
