import Foundation

/// Offline synthesis with Piper (local neural voice, no network during reading).
///
/// The app launches `Tools/piper_synth.py` as a child process (the voice loads ONCE)
/// and kills it on stop/switch — no installed daemon. On first
/// use it creates its own venv and downloads the voice on demand, with a UI notice.
enum PiperTTS {
    /// Offline voices exposed in the selector's "Offline" section.
    static let faberPtBR = "offline-faber-ptbr"
    static let lessacEnUS = "offline-lessac-enus"
    static let edressonPtBR = "offline-edresson-ptbr"
    static let caduPtBR = "offline-cadu-ptbr"
    static let jeffPtBR = "offline-jeff-ptbr"

    static let offlineVoices = [faberPtBR, edressonPtBR, caduPtBR, jeffPtBR, lessacEnUS]

    static func label(for voice: String, locale: L.Language) -> String {
        let key = "voice.\(voice)"
        let resolved = L.resolve(key, locale: locale)
        return resolved == key ? voice : resolved
    }

    static func isOfflineVoice(_ voice: String) -> Bool {
        offlineVoices.contains(voice)
    }

    // MARK: - Paths (models/venv outside the repo, in Application Support)

    /// Base folder: `~/Library/Application Support/EdgeSpeak`.
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
    }

    static var venvDir: URL { supportDir.appendingPathComponent("piper-venv", isDirectory: true) }
    /// Offline voice interpreter: the support venv (bundled) when
    /// ready, else the legacy venv in Application Support (dev machines).
    static var venvPython: URL {
        if let pronto = BundledEnv.readyPython() {
            return URL(fileURLWithPath: pronto)
        }
        return venvDir.appendingPathComponent("bin/python", isDirectory: false)
    }
    static var voicesDir: URL { supportDir.appendingPathComponent("voices", isDirectory: true) }

    /// Persistent script: inside the bundle (packaged app) or in the repo (dev).
    static let synthScript: String = {
        let name = "piper_synth"
        if let bundled = Bundle.main.url(forResource: "piper_synth", withExtension: "py") {
            return bundled.path
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/\(name).py").path
    }()

    // MARK: - Voices and wheel

    private static let hfBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main/"

    private static func voiceFiles(for voice: String) -> (file: String, remote: String)? {
        guard let file = voiceFileBase(for: voice) else { return nil }
        return (file, hfBase + voiceRemotePath(for: voice)!)
    }

    /// Model base name (.onnx/.onnx.json), without extension. Pure (testable).
    static func voiceFileBase(for voice: String) -> String? {
        switch voice {
        case faberPtBR: "pt_BR-faber-medium"
        case lessacEnUS: "en_US-lessac-medium"
        case edressonPtBR: "pt_BR-edresson-low"
        case caduPtBR: "pt_BR-cadu-medium"
        case jeffPtBR: "pt_BR-jeff-medium"
        default: nil
        }
    }

    private static func voiceRemotePath(for voice: String) -> String? {
        switch voice {
        case faberPtBR: "pt/pt_BR/faber/medium/pt_BR-faber-medium"
        case lessacEnUS: "en/en_US/lessac/medium/en_US-lessac-medium"
        case edressonPtBR: "pt/pt_BR/edresson/low/pt_BR-edresson-low"
        case caduPtBR: "pt/pt_BR/cadu/medium/pt_BR-cadu-medium"
        case jeffPtBR: "pt/pt_BR/jeff/medium/pt_BR-jeff-medium"
        default: nil
        }
    }

    /// Voices bundled in the app (`Resources/voices`; dev fallback in
    /// `Build/staging/voices`), or nil.
    static var bundledVoicesDir: URL? {
        if let url = Bundle.main.url(forResource: "voices", withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for base in ["Build/staging", "Resources"] {
            let url = root.appendingPathComponent(base).appendingPathComponent("voices")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Choice of the .onnx: support, then bundle, else the support path
    /// (download target). Essentially pure (testable with fake URLs).
    static func pickOnnx(support: URL, supportExists: Bool, bundle: URL?, bundleExists: Bool) -> URL {
        if supportExists { return support }
        if bundleExists, let bundle { return bundle }
        return support
    }

    /// Local path of the .onnx (nil for an unknown voice).
    static func onnxPath(for voice: String) -> String? {
        guard let file = voiceFileBase(for: voice) else { return nil }
        let fm = FileManager.default
        let support = voicesDir.appendingPathComponent(file + ".onnx")
        let supportJson = voicesDir.appendingPathComponent(file + ".onnx.json")
        var bundle: URL?
        var bundleOk = false
        if let dir = bundledVoicesDir {
            let b = dir.appendingPathComponent(file + ".onnx")
            let bj = dir.appendingPathComponent(file + ".onnx.json")
            bundle = b
            bundleOk = fm.fileExists(atPath: b.path) && fm.fileExists(atPath: bj.path)
        }
        return pickOnnx(
            support: support,
            supportExists: cachedVoiceValid(onnx: support, json: supportJson),
            bundle: bundle, bundleExists: bundleOk).path
    }

    /// Piper wheel per architecture (`uname -m`).
    static var wheelURL: String {
        var arch = "arm64"
        var sysinfo = utsname()
        uname(&sysinfo)
        let m = withUnsafeBytes(of: &sysinfo.machine) { bytes -> String in
            let c = bytes.bindMemory(to: CChar.self)
            return String(cString: c.baseAddress!)
        }
        if m.contains("x86_64") { arch = "x86_64" }
        let tag = arch == "arm64" ? "macosx_11_0_arm64" : "macosx_10_9_x86_64"
        return "https://github.com/OHF-Voice/piper1-gpl/releases/download/v1.8.0/piper_tts-1.8.0-cp39-abi3-\(tag).whl"
    }

    /// Sanity floors for the downloaded voice (planning hypothesis: the
    /// .onnx is around ~63 MB and the .onnx.json, a few KB; the floors only reject
    /// gross truncations and change if the catalog changes voice).
    static let onnxMinBytes: Int64 = 1_000_000
    static let jsonMinBytes: Int64 = 512

    /// Pure download rule: received covers the minimum and, when the server
    /// reported a size, covers the expected. Testable without network.
    static func downloadComplete(received: Int64, expected: Int64, minBytes: Int64) -> Bool {
        guard received >= minBytes, received > 0 else { return false }
        if expected > 0 { return received >= expected }
        return true
    }

    static func cachedVoiceSizesValid(onnxSize: Int?, jsonSize: Int?) -> Bool {
        guard let o = onnxSize, let j = jsonSize else { return false }
        return Int64(o) >= onnxMinBytes && Int64(j) >= jsonMinBytes
    }

    /// Valid cached voice: sizes above the floors and the .onnx.json readable
    /// as JSON. A partial .onnx passes existence but fails here.
    static func cachedVoiceValid(onnx: URL, json: URL) -> Bool {
        let fm = FileManager.default
        guard let attrsO = try? fm.attributesOfItem(atPath: onnx.path),
              let attrsJ = try? fm.attributesOfItem(atPath: json.path),
              cachedVoiceSizesValid(onnxSize: attrsO[.size] as? Int, jsonSize: attrsJ[.size] as? Int),
              let data = try? Data(contentsOf: json),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return false }
        return true
    }

    /// Effective sentence duration: the one measured in the WAV; only falls back to the declared
    /// when the measurement is missing or zero. Pure (testable without audio).
    static func effectiveDuration(measured: Double?, declared: Double) -> Double {
        if let m = measured, m > 0 { return m }
        return declared
    }

    /// `Rate.percent` into Piper's `length_scale`: +30% faster = 1/1.3 audio.
    static func lengthScale(for rate: EdgeTTS.Rate) -> Double {
        1.0 / (1.0 + Double(rate.percent) / 100.0)
    }

    // MARK: - Preparation (venv + voice, on demand)

    /// Ensures the venv with Piper installed; readable error for the UI.
    static func ensureVenv() throws {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: venvPython.path) { return }
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: venvDir.path) {
            let (st, err) = runSync("/usr/bin/python3", ["-m", "venv", venvDir.path])
            guard st == 0 else {
                throw makeError(key: "error.offlineVenvCreate", args: [tail(err)])
            }
        }
        let pip = venvDir.appendingPathComponent("bin/pip").path
        let (st, err) = runSync(pip, ["install", "--quiet", wheelURL], timeout: 600)
        guard st == 0, fm.isExecutableFile(atPath: venvPython.path) else {
            throw makeError(key: "error.offlineInstall", args: [tail(err)])
        }
    }

    static func ensureVoice(_ voice: String, locale: L.Language = .en, progress: @escaping (String) -> Void) async throws -> String {
        guard let (file, remote) = voiceFiles(for: voice) else {
            throw makeError(key: "error.unknownOfflineVoice", args: [voice])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        let onnx = voicesDir.appendingPathComponent(file + ".onnx")
        let json = voicesDir.appendingPathComponent(file + ".onnx.json")
        if fm.fileExists(atPath: onnx.path), fm.fileExists(atPath: json.path) {
            // Existence is not enough: a partial from a previous drop fails
            // validation and is removed to download again.
            if cachedVoiceValid(onnx: onnx, json: json) {
                return onnx.path
            }
            try? fm.removeItem(at: onnx)
            try? fm.removeItem(at: json)
        }
        // Voice bundled in the app: use it directly (read-only), no download.
        if let dir = bundledVoicesDir {
            let b = dir.appendingPathComponent(file + ".onnx")
            let bj = dir.appendingPathComponent(file + ".onnx.json")
            if fm.fileExists(atPath: b.path), fm.fileExists(atPath: bj.path) {
                return b.path
            }
        }
        progress(L.get("progress.downloadingVoiceFile", locale: locale, args: file))
        try await download(from: remote + ".onnx", to: onnx, label: file, locale: locale, progress: progress)
        try await download(from: remote + ".onnx.json", to: json, label: file, locale: locale, progress: progress)
        return onnx.path
    }

    private static func download(from url: String, to destination: URL, label: String, locale: L.Language, progress: @escaping (String) -> Void) async throws {
        guard let source = URL(string: url) else { throw makeError(key: "error.invalidVoiceAddress", args: [label]) }
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        let total = response.expectedContentLength
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Temporary in the SAME directory (same volume): the final target only
        // appears via atomic rename after validation; a partial is never accepted.
        let tmp = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        var received: Int64 = 0
        do {
            var lastReport = Date.distantPast
            // `AsyncBytes` delivers byte by byte: join in blocks before writing.
            var bloco = Data()
            bloco.reserveCapacity(65536)
            func drain() throws {
                if !bloco.isEmpty {
                    try handle.write(contentsOf: bloco)
                    bloco.removeAll(keepingCapacity: true)
                }
            }
            for try await byte in bytes {
                bloco.append(byte)
                received += 1
                if bloco.count >= 65536 {
                    try drain()
                    if Date().timeIntervalSince(lastReport) > 0.5 {
                        lastReport = Date()
                        if total > 0 {
                            progress(L.get("progress.downloadingVoiceMBTotal", locale: locale, args: received / 1_048_576, total / 1_048_576))
                        } else {
                            progress(L.get("progress.downloadingVoiceMB", locale: locale, args: received / 1_048_576))
                        }
                    }
                }
            }
            try drain()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try? handle.close()
        let isJSON = destination.path.hasSuffix(".onnx.json")
        let piso = isJSON ? jsonMinBytes : onnxMinBytes
        guard downloadComplete(received: received, expected: total, minBytes: piso) else {
            try? FileManager.default.removeItem(at: tmp)
            throw makeError(key: "error.voiceDownloadIncomplete", args: [label, received, total > 0 ? "\(total)" : "?"])
        }
        if isJSON {
            guard let data = try? Data(contentsOf: tmp),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                try? FileManager.default.removeItem(at: tmp)
                throw makeError(key: "error.voiceDownloadCorrupt", args: [label])
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - Reading a child without blocking

    /// Reads what is already in the pipe without blocking: `availableData` blocks until 1 byte
    /// or EOF, so it is only called when `poll` reports data or HUP. With
    /// nothing to read, it returns empty and the caller re-evaluates the deadline — a live
    /// and silent process never holds the thread (same narrowing as `EdgeTTS.run`).
    static func readAvailable(_ fh: FileHandle) -> Data {
        var pfd = pollfd(fd: fh.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&pfd, 1, 0) > 0, (pfd.revents & Int16(POLLIN | POLLHUP)) != 0 else {
            return Data()
        }
        return fh.availableData
    }

    static func killHung(_ proc: Process) {
        if proc.isRunning { proc.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
        }
    }

    // MARK: - Persistent session (child process, dies with the reading)

    private static let sessionLock = NSLock()
    private static var active: PiperSession?

    static func stopActiveSession() {
        sessionLock.lock()
        let s = active
        active = nil
        sessionLock.unlock()
        s?.stop()
    }

    /// Terminates orphan sessions (e.g. after cancellation). Same narrowing
    /// as EdgeTTS: only under the app's path, never someone else's manual run.
    static func killRunningProcesses() {
        stopActiveSession()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "[Ee]dge[Ss]peak.*piper_synth\\.py"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// One session: the voice already loaded, one request per JSON line.
    private final class PiperSession: @unchecked Sendable {
        private let process: Process
        private let stdin: FileHandle
        private let stdout: FileHandle
        private let lock = NSLock()
        private var nextID = 0
        // `closed` has its own lock (never held during I/O): `stop()` sets it
        // from the main thread without waiting for an in-flight `synth()`,
        // whose loop re-checks it every iteration and aborts promptly.
        private let closedLock = NSLock()
        private var _closed = false
        private var closed: Bool {
            get { closedLock.lock(); defer { closedLock.unlock() }; return _closed }
            set { closedLock.lock(); _closed = newValue; closedLock.unlock() }
        }

        init(onnx: String, lengthScale: Double) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: PiperTTS.venvPython.path)
            proc.arguments = [PiperTTS.synthScript, "--onnx", onnx, "--length-scale", "\(lengthScale)"]
            let inPipe = Pipe()
            let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                throw makeError(key: "error.offlineStartFailed", args: [error.localizedDescription])
            }
            process = proc
            stdin = inPipe.fileHandleForWriting
            stdout = outPipe.fileHandleForReading
            // Waits for "ready" (loading the voice is the slow part, with a deadline).
            let limit = Date().addingTimeInterval(300)
            var buffer = Data()
            var pronto = false
            while Date() < limit, !pronto {
                let dataChunk = PiperTTS.readAvailable(stdout)
                if dataChunk.isEmpty {
                    if !proc.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                buffer.append(dataChunk)
                if buffer.contains(0x0A),
                   let linha = String(data: buffer, encoding: .utf8),
                   linha.contains("\"ready\"") {
                    pronto = true
                }
            }
            guard pronto else {
                PiperTTS.killHung(proc)
                throw makeError(key: "error.offlineNotReady")
            }
        }

        /// Synthesizes a text into a WAV; returns the duration DECLARED by the
        /// model (the caller measures the WAV and uses the measurement — see `duration(of:)`
        /// and `effectiveDuration`).
        func synth(text: String, wav: String, lengthScale: Double) throws -> Double {
            lock.lock()
            defer { lock.unlock() }
            guard !closed, process.isRunning else {
                throw makeError(key: "error.offlineTerminated")
            }
            let id = nextID
            nextID += 1
            let request: [String: Any] = ["id": id, "text": text, "wav": wav, "length_scale": lengthScale]
            let data = try JSONSerialization.data(withJSONObject: request)
            stdin.write(data + Data([0x0A]))
            // Response: one JSON line; generous deadline (first sentence includes I/O).
            let deadline = Date().addingTimeInterval(300)
            var accumulated = Data()
            while Date() < deadline {
                // Abort promptly when `stop()` closed the session (see `closed`):
                // without this, `stop()` would wait on the main lock until the deadline.
                if closed { throw makeError(key: "error.offlineTerminated") }
                let dataChunk = PiperTTS.readAvailable(stdout)
                if dataChunk.isEmpty {
                    if !process.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                accumulated.append(dataChunk)
                if let endIndex = accumulated.firstIndex(of: 0x0A) {
                    let linha = accumulated[..<endIndex]
                    accumulated = accumulated[accumulated.index(after: endIndex)...]
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(linha)) as? [String: Any],
                          (obj["id"] as? Int) == id
                    else { continue }
                    if let error = obj["error"] as? String {
                        throw makeError(key: "error.offlinePhraseFailed", args: ["\(error)"])
                    }
                    return (obj["duration"] as? Double) ?? 0
                }
            }
            PiperTTS.killHung(process)
            throw makeError(key: "error.offlineTimeout")
        }

        func stop() {
            // Non-blocking: `closed` uses its own lock (see above), so this
            // never waits for an in-flight `synth()` holding the main lock.
            closed = true
            try? stdin.close()
            if process.isRunning {
                process.terminate()
                let limit = Date().addingTimeInterval(2)
                while process.isRunning, Date() < limit {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    // MARK: - Sentence-by-sentence synthesis, in order (Piper is fast; no parallelism)

    /// Streams synthesis: one delivery per sentence (text+start+page in the same
    /// format as `EdgeTTS.Segment`) and at the end the single concatenated WAV.
    static func synthesizeStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        rate: EdgeTTS.Rate = .normal,
        readFootnotes: Bool = true,
        locale: L.Language = .en,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> AsyncThrowingStream<EdgeTTS.ChunkDelivery, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let final = try await runStreaming(
                        phrases: phrases, voice: voice, rate: rate,
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

    private static func runStreaming(
        phrases: [TextImport.Phrase],
        voice: String,
        rate: EdgeTTS.Rate,
        readFootnotes: Bool,
        locale: L.Language,
        shouldCancel: @escaping () -> Bool,
        progress: @escaping (String) -> Void,
        onChunk: @escaping (EdgeTTS.ChunkDelivery) -> Void
    ) async throws -> EdgeTTS.Result {
        guard !phrases.isEmpty else { throw makeError(key: "error.nothingToSynthesize") }
        try Task.checkCancellation()
        // Bundled environment first (no network); if that fails, the legacy
        // `ensureVenv` tries the dev machines' path.
        if BundledEnv.readyPython() == nil {
            _ = try? BundledEnv.ensure(locale: locale, progress: progress)
        }
        try ensureVenv()
        let onnx = try await ensureVoice(voice, locale: locale, progress: progress)
        try Task.checkCancellation()
        if shouldCancel() { throw makeError(key: "common.synthesisCancelled") }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-\(UUID().uuidString)", isDirectory: true)
        let wavsDir = dir.appendingPathComponent("wavs", isDirectory: true)
        try fm.createDirectory(at: wavsDir, withIntermediateDirectories: true)
        // Registers before purging: without this the next online synthesis
        // would delete these WAVs still referenced by the reading (M4).
        EdgeTTS.keepOfflineDirectory(dir)
        EdgeTTS.purgeStaleDirectories(keeping: dir)
        progress(L.get("progress.loadingOfflineVoice", locale: locale))

        let scale = lengthScale(for: rate)
        let session = try PiperSession(onnx: onnx, lengthScale: scale)
        sessionLock.lock()
        let previous = active
        active = session
        sessionLock.unlock()
        previous?.stop()

        do {
            var urls: [URL] = []
            var segments: [EdgeTTS.Segment] = []
            var offset = 0.0
            let total = phrases.count
            for (i, phrase) in phrases.enumerated() {
                try Task.checkCancellation()
                if shouldCancel() { throw makeError(key: "common.synthesisCancelled") }
                // Text adapted for speech; the published one follows the original.
                // End of paragraph gains a `\n` (the model's pause; the gap enters the
                // measured WAV duration and the accumulated offset stays correct).
                var spokenText = ReadAloudFilter.forSpeech(phrase.text, voice: voice, readFootnotes: readFootnotes, marker: phrase.noteMarker)
                if spokenText.isEmpty { spokenText = phrase.text }
                if phrase.paragraphEnd { spokenText += "\n" }
                let wavURL = wavsDir.appendingPathComponent(String(format: "phrase-%05d.wav", i))
                let declared = try session.synth(text: spokenText, wav: wavURL.path, lengthScale: scale)
                guard let size = (try? fm.attributesOfItem(atPath: wavURL.path))?[.size] as? Int, size > 0 else {
                    throw makeError(key: "error.offlineNoAudioOnPhrase", args: [i + 1])
                }
                // REAL duration of the measured WAV (the online path does the same in
                // `EdgeTTS.duration(of:)`): the declared one accumulates drift in the
                // highlight of the following sentences. No silence inserted: the
                // offset advances exactly the measured duration.
                let dur = effectiveDuration(measured: duration(of: wavURL), declared: declared)
                progress(L.get("progress.chunkFraction", locale: locale, args: i + 1, total))
                let seg = EdgeTTS.Segment(start: offset, duration: dur, text: phrase.text, index: phrase.index, page: phrase.page, rects: phrase.rects)
                segments.append(seg)
                offset += dur
                urls.append(wavURL)
                // Immediate delivery: the first sentence plays without waiting for the rest.
                let local = EdgeTTS.Segment(start: 0, duration: dur, text: phrase.text, index: phrase.index, page: phrase.page, rects: phrase.rects)
                onChunk(.chunk(index: i, url: wavURL, segments: [local]))
            }
            let final = try concatWavs(urls, into: dir.appendingPathComponent("EdgeSpeak.wav"))
            // The session dies with the reading: no leftover process.
            stopActiveSession()
            // `segments` already carries global times (offset accumulated sentence by sentence).
            return EdgeTTS.Result(audioURL: final, segments: segments)
        } catch {
            session.stop()
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - WAV: duration and concatenation

    /// Duration read from the WAV header, without assuming a fixed 44 bytes.
    ///
    /// Walks the RIFF chunks up to `data`: an extra chunk (LIST/fact)
    /// would shift the audio, and the old `(size − 44)` math contaminated
    /// the duration and the offset of the following phrases (B3). Without a
    /// readable `data`, returns nil and the caller falls back to the declared
    /// duration. Internal (not private) so the suite covers the extra chunk.
    static func duration(of url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 8192), head.count >= 44,
              let layout = wavLayout(head),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return nil }
        // The field may lie upward (truncated file): trust what is on disk.
        let pcm = min(layout.dataSize, size - layout.dataOffset)
        guard pcm > 0 else { return nil }
        return Double(pcm) / (layout.sampleRate * layout.bytesPerSample)
    }

    /// Locates the PCM inside the RIFF: rate, bytes per sample, start and
    /// size of the `data` chunk. Pure (testable without a file).
    /// Internal (not private) for the suite and the manual join to use.
    static func wavLayout(_ head: Data) -> (
        sampleRate: Double, bytesPerSample: Double, dataOffset: Int, dataSize: Int
    )? {
        func u32(_ o: Int) -> UInt32 {
            UInt32(head[o]) | (UInt32(head[o + 1]) << 8)
                | (UInt32(head[o + 2]) << 16) | (UInt32(head[o + 3]) << 24)
        }
        func u16(_ o: Int) -> UInt16 {
            UInt16(head[o]) | (UInt16(head[o + 1]) << 8)
        }
        guard head.count >= 44,
              head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46, // "RIFF"
              head[8] == 0x57, head[9] == 0x41, head[10] == 0x56, head[11] == 0x45 // "WAVE"
        else { return nil }
        var sampleRate = 0.0
        var bytesPerSample = 0.0
        var i = 12
        while i + 8 <= head.count {
            let size = Int(u32(i + 4))
            let isFmt = head[i] == 0x66 && head[i + 1] == 0x6D && head[i + 2] == 0x74 && head[i + 3] == 0x20
            let isData = head[i] == 0x64 && head[i + 1] == 0x61 && head[i + 2] == 0x74 && head[i + 3] == 0x61
            if isFmt {
                guard size >= 16, i + 24 <= head.count else { return nil }
                let channels = Double(u16(i + 10))
                let rate = Double(u32(i + 12))
                let bits = Double(u16(i + 22))
                guard rate > 0, channels > 0, bits > 0 else { return nil }
                sampleRate = rate
                bytesPerSample = channels * bits / 8.0
            } else if isData {
                guard sampleRate > 0, bytesPerSample > 0 else { return nil }
                return (sampleRate, bytesPerSample, i + 8, size)
            }
            // Odd-sized chunks carry one byte of padding.
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// Joins the WAVs into a single file (ffmpeg when available, else by hand:
    /// concatenates the PCM under a single header, same format/rate/channels).
    static func concatWavs(_ ordered: [URL], into outURL: URL) throws -> URL {
        guard !ordered.isEmpty else { throw makeError(key: "error.nothingToJoin") }
        if ordered.count == 1 {
            try? FileManager.default.removeItem(at: outURL)
            try FileManager.default.copyItem(at: ordered[0], to: outURL)
            return outURL
        }
        if let ffmpeg = EdgeTTS.ffmpegPath {
            let listURL = outURL.deletingLastPathComponent().appendingPathComponent("lista.txt")
            let list = ordered.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
            try list.write(to: listURL, atomically: true, encoding: .utf8)
            let (status, err) = runSync(ffmpeg, ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", outURL.path])
            guard status == 0 else { throw makeError(key: "error.ffmpegFailed", args: [status, tail(err)]) }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int, size > 0 else {
                throw makeError(key: "error.joinEmpty")
            }
            return outURL
        }
        // By hand: first file's header (up to `data`, with any extra chunks)
        // + PCM from all (same format). Sizes in RIFF and `data` are
        // recalculated for the real offset (see B3).
        var pcm = Data()
        var headerSize: Data?
        var dataOffset = 0
        for url in ordered {
            let data = try Data(contentsOf: url)
            guard let layout = wavLayout(data), data.count > layout.dataOffset else {
                throw makeError(key: "error.invalidWavOnJoin")
            }
            if headerSize == nil {
                headerSize = data.prefix(layout.dataOffset)
                dataOffset = layout.dataOffset
            }
            pcm.append(data.suffix(from: layout.dataOffset))
        }
        guard var head = headerSize else { throw makeError(key: "error.joinEmpty") }
        func writeU32(_ v: UInt32, within o: Int) {
            head[o] = UInt8(v & 0xFF)
            head[o + 1] = UInt8((v >> 8) & 0xFF)
            head[o + 2] = UInt8((v >> 16) & 0xFF)
            head[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        writeU32(UInt32(pcm.count + head.count - 8), within: 4)
        writeU32(UInt32(pcm.count), within: dataOffset - 4)
        try? FileManager.default.removeItem(at: outURL)
        var final = head
        final.append(pcm)
        try final.write(to: outURL, options: .atomic)
        return outURL
    }

    // MARK: - Helpers

    private static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> (Int32, String) {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory.appendingPathComponent("edgespeak-err-\(UUID().uuidString).log")
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: errURL) }
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else { return (1, L.get("common.noStderr", locale: .en)) }
        defer { try? errHandle.close() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errHandle
        do {
            try proc.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let endIndex = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < endIndex {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            // Same hardening as the engines (B6): SIGTERM, grace, then SIGKILL.
            // Stays synchronous on purpose — this is the offline-setup path
            // (venv/pip/ffmpeg), never the cooperative pool, so no Task.sleep.
            killHung(proc)
            return (1, L.get("common.timedOut", args: [Int(timeout)]))
        }
        proc.waitUntilExit()
        try? errHandle.close()
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (proc.terminationStatus, err)
    }

    private static func tail(_ text: String, max: Int = 400) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return L.get("common.noDetails") }
        return t.count <= max ? t : "…" + String(t.suffix(max))
    }

    /// Error with a catalog key: the message comes from `L` in the current language and
    /// the key+args go in `userInfo` so `failureKey` re-resolves on
    /// language switch.
    private static func makeError(key: String, args: [Any] = []) -> NSError {
        NSError(domain: "EdgeSpeak.PiperTTS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.resolve(key, args: args),
                           "l10nKey": key, "l10nArgs": args])
    }
}
