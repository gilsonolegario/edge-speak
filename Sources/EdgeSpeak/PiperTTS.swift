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

    /// The server refused the file: status >= 400. Internal (not private) so
    /// the suite covers the rule without network.
    static func httpFailureStatus(of response: URLResponse) -> Int? {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return nil }
        return http.statusCode
    }

    /// Bounded diagnostic of a rejected download: the status followed by the
    /// head of the error page (the title of an HTML page lives at the start;
    /// unbounded bodies never enter memory — same spirit as the stderr tail).
    /// Pure, for tests.
    static func httpStatusDetail(status: Int, body: Data) -> String {
        var text = "HTTP \(status)"
        let head = body.prefix(200)
        let snippet = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty { text += ": " + snippet }
        return text
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
        // Prune orphaned `.part` files left by interrupted downloads (> 1 week).
        if let items = try? fm.contentsOfDirectory(at: voicesDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            for u in items where u.pathExtension == "part" {
                let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m = mtime, m < cutoff { try? fm.removeItem(at: u) }
            }
        }
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
        // Disk guard before the download (item 48) and pruning of orphans from
        // previous interrupted downloads (item 50): the `.part` files survive a
        // crash or a dropped network and would grow forever.
        guard DiskSpace.hasRoom(at: voicesDir, floor: DiskSpace.downloadFloor) else {
            throw makeError(key: "error.diskFull", args: [DiskSpace.freeSpaceText(at: voicesDir)])
        }
        pruneStaleParts(in: voicesDir)
        progress(L.get("progress.downloadingVoiceFile", locale: locale, args: file))
        try await download(from: remote + ".onnx", to: onnx, label: file, locale: locale, progress: progress)
        try await download(from: remote + ".onnx.json", to: json, label: file, locale: locale, progress: progress)
        return onnx.path
    }

    /// A `.part` older than this is an orphan (an app killed mid-download).
    /// Well beyond any real download: pruning never races a live one.
    static let partMaxAge: TimeInterval = 7 * 24 * 3_600

    /// Removes the orphaned `*.part` of `dir` (item 50). Pure about the clock:
    /// `now` comes in, so the test drives time without waiting a week.
    @discardableResult
    static func pruneStaleParts(in dir: URL, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var removed: [URL] = []
        for url in items where url.pathExtension == "part" {
            // An unreadable date is not an orphan: do not erase what cannot be judged.
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            else { continue }
            guard now.timeIntervalSince(mtime) > partMaxAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    private static func download(from url: String, to destination: URL, label: String, locale: L.Language, progress: @escaping (String) -> Void) async throws {
        guard let source = URL(string: url) else { throw makeError(key: "error.invalidVoiceAddress", args: [label]) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Temporary in the SAME directory (same volume): the final target only
        // appears via atomic rename after validation; a partial is never accepted.
        let tmp = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        let received: Int64
        let total: Int64
        do {
            // BY BLOCKS, never `for try await byte in bytes`: that looped ~63 M
            // times through `URLSession.AsyncBytes` for one voice file (one
            // `await` per byte on the cooperative pool).
            (received, total) = try await fetchInBlocks(from: source, handle: handle, label: label, locale: locale, progress: progress)
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

    /// Pumps one download into an open handle, block by block (tens of KB per
    /// delegate call), instead of one `await` per byte on `AsyncBytes`.
    /// The validation and the atomic rename stay in `download` above — this
    /// only moves bytes. Cancellation arrives as `URLError(.cancelled)` from
    /// `task.cancel()` and is rethrown as `CancellationError`, the contract
    /// the callers already treat as a cancelled reading.
    private static func fetchInBlocks(from source: URL, handle: FileHandle, label: String, locale: L.Language, progress: @escaping (String) -> Void) async throws -> (received: Int64, expected: Int64) {
        let pump = BlockDownload(handle: handle, label: label, locale: locale, progress: progress)
        do {
            return try await pump.run(source)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    /// `URLSessionDataDelegate` that writes each delivered network block
    /// straight to disk. The session delivers its delegate callbacks serially
    /// (one operation queue), so `received`/`expected`/`lastReport` need no
    /// lock; only the task handle (cancellation can land before the task
    /// exists) is guarded.
    private final class BlockDownload: NSObject, URLSessionDataDelegate {
        private let handle: FileHandle
        private let label: String
        private let locale: L.Language
        private let progress: (String) -> Void
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelRequested = false
        private var continuation: CheckedContinuation<(received: Int64, expected: Int64), Error>?
        private var session: URLSession?
        private var received: Int64 = 0
        private var expected: Int64 = -1
        private var lastReport = Date.distantPast
        private var writeError: Error?
        // Rejected request (4xx/5xx): the error-page body goes to this bounded
        // buffer, never to the `.part` — both fields only on the delegate queue.
        private var httpStatus: Int?
        private var errorBody = Data()

        init(handle: FileHandle, label: String, locale: L.Language, progress: @escaping (String) -> Void) {
            self.handle = handle
            self.label = label
            self.locale = locale
            self.progress = progress
        }

        func run(_ source: URL) async throws -> (received: Int64, expected: Int64) {
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    continuation = cont
                    let task = session.dataTask(with: source)
                    // Flag and task become visible together under the lock, so
                    // a cancellation landing at any instant is not lost.
                    let cancelNow = lock.withLock { () -> Bool in
                        self.task = task
                        return cancelRequested
                    }
                    if cancelNow { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                self.lock.withLock {
                    self.cancelRequested = true
                    self.task?.cancel()
                }
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            expected = response.expectedContentLength
            // Status BEFORE any byte reaches the disk: the body of a 4xx page
            // must never be recorded as the voice. The transfer continues so
            // the error page itself feeds the diagnostic.
            httpStatus = PiperTTS.httpFailureStatus(of: response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if httpStatus != nil {
                // Rejected download: bounded memory for the snippet, never to disk.
                if errorBody.count < 256 { errorBody.append(data) }
                return
            }
            guard writeError == nil else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Disk full/closed handle: stop the transfer now, the error
                // resumes the download in `didCompleteWithError`.
                writeError = error
                dataTask.cancel()
                return
            }
            received += Int64(data.count)
            reportProgress()
        }

        /// Progress of "X of Y MB": at most every 0.5 s — the throttle must not
        /// waste one event per block, tens per second.
        private func reportProgress() {
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.5 else { return }
            lastReport = now
            emitProgress()
        }

        private func emitProgress() {
            if expected > 0 {
                progress(L.get("progress.downloadingVoiceMBTotal", locale: locale, args: received / 1_048_576, expected / 1_048_576))
            } else {
                progress(L.get("progress.downloadingVoiceMB", locale: locale, args: received / 1_048_576))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            session.finishTasksAndInvalidate()
            guard let cont = continuation else { return }
            continuation = nil
            let wasCancelled = lock.withLock { cancelRequested }
            if let writeError {
                cont.resume(throwing: writeError)
            } else if let status = httpStatus, !wasCancelled {
                // The server refused the file: the status rules and the error
                // page goes as a bounded detail (stderr-tail spirit). The local
                // base keeps the voice name; the `.part` is cleaned in `download`.
                cont.resume(throwing: PiperTTS.withStderr(
                    makeError(key: "error.voiceDownloadIncomplete", args: [label, received, expected > 0 ? "\(expected)" : "?"]),
                    PiperTTS.httpStatusDetail(status: status, body: errorBody)))
            } else if let error {
                cont.resume(throwing: error)
            } else {
                // Final progress beyond the throttle: without it the interface
                // stays at the last "X of Y MB" while the file already landed.
                emitProgress()
                cont.resume(returning: (received, expected))
            }
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
            // Breaks the session→delegate→session retention pair.
            self.session = nil
        }
    }

    // MARK: - Child stderr (bounded tail, so a failure reaches the UI with a cause)

    /// Keeps only the last bytes of a stream (the child's stderr): a voice or
    /// model failure must arrive in the interface with its cause, but an
    /// unbounded log in memory would grow for the whole reading — few KB of
    /// tail are what a Python traceback needs. Internal (not private) so the
    /// suite covers the ring and the UTF-8 tail.
    final class TailBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let limit: Int

        init(limit: Int) { self.limit = max(1, limit) }

        func append(_ chunk: Data) {
            lock.withLock {
                bytes.append(chunk)
                if bytes.count > limit { bytes = Data(bytes.suffix(limit)) }
            }
        }

        /// Last bytes as text; a byte orphaned by the trim (mid UTF-8
        /// sequence) is dropped from the head so decoding never fails.
        var text: String {
            lock.withLock {
                var d = bytes
                while !d.isEmpty {
                    if let s = String(data: d, encoding: .utf8) { return s }
                    d = d.dropFirst()
                }
                return ""
            }
        }
    }

    /// Sendable wrapper of `FileHandle` (not Sendable in the Foundation
    /// contract) for the stderr drain queue.
    private final class HandleBox: @unchecked Sendable {
        let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
    }

    /// Drains the child's stderr into `tail` until EOF, on a GCD queue: an
    /// undrained pipe fills its ~64 KB buffer and blocks the child right when
    /// it is printing the failure — and `availableData` blocks until data or
    /// EOF, which must never happen on a cooperative thread.
    static func drainStderr(_ handle: FileHandle, into tail: TailBuffer) {
        let box = HandleBox(handle)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = box.handle.availableData
                if data.isEmpty { break } // EOF: the child exited.
                tail.append(data)
            }
        }
    }

    /// Appends the child's stderr tail to a localized error, keeping
    /// `l10nKey`/`l10nArgs` so `failureKey` still re-resolves on language
    /// switch (the re-resolution drops the raw diagnostic — acceptable: it is
    /// a detail, the localized message is the contract).
    static func withStderr(_ error: NSError, _ tail: String) -> NSError {
        let detail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return error }
        var info = error.userInfo
        info[NSLocalizedDescriptionKey] = error.localizedDescription + "\n" + detail
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }

    /// The fallback's error with the root cause of the bundled environment
    /// appended (item 51 of the robustness lane, 2026-10-17).
    ///
    /// Why it exists: `try? BundledEnv.ensure` swallowed the bundled failure,
    /// so when the LEGACY path also failed the user (and support) saw only the
    /// legacy message — the wrong trail. The cause is appended as a diagnostic
    /// line, the same shape as the stderr tail (`withStderr`), which keeps
    /// `l10nKey`/`l10nArgs` so the language switch still re-resolves the
    /// localized sentence.
    static func withCause(_ error: Error, cause: Error?) -> NSError {
        guard let cause else { return error as NSError }
        return withStderr(error as NSError, cause.localizedDescription)
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
        let s = sessionLock.withLock { () -> PiperSession? in
            let cur = active
            active = nil
            return cur
        }
        s?.stop()
    }

    /// Sendable wrapper of `Process` (not Sendable in the Foundation contract)
    /// just to carry the process to the background kill task in `PiperSession.stop`.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { process = p }
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
        // `waitUntilExit` only on a launched process: on a never-launched one
        // it raises NSInternalInconsistencyException.
        if (try? p.run()) != nil {
            p.waitUntilExit()
        }
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
        /// Child's stderr tail (last few KB): the cause attached to the
        /// blind errors below (`nullDevice` used to discard it).
        private let stderrTail = TailBuffer(limit: 8192)

        /// `async` because the ready wait uses `Task.sleep`: this init runs on
        /// the cooperative pool (called from `runStreaming`), and the old
        /// `Thread.sleep(0.1)` could hold a pool thread for up to 300 s — the
        /// same reason `EdgeTTS.run` sleeps with `Task.sleep` (B2).
        init(onnx: String, lengthScale: Double) async throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: PiperTTS.venvPython.path)
            proc.arguments = [PiperTTS.synthScript, "--onnx", onnx, "--length-scale", "\(lengthScale)"]
            let inPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            // Captured, not `nullDevice`: a bad model/voice fails HERE, and
            // without the cause the UI only says "did not respond".
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                throw makeError(key: "error.offlineStartFailed", args: [error.localizedDescription])
            }
            process = proc
            stdin = inPipe.fileHandleForWriting
            stdout = outPipe.fileHandleForReading
            // Drain starts AFTER all stored properties are set (async init).
            PiperTTS.drainStderr(errPipe.fileHandleForReading, into: stderrTail)
            // Waits for "ready" (loading the voice is the slow part, with a deadline).
            let limit = Date().addingTimeInterval(300)
            var buffer = Data()
            var pronto = false
            while Date() < limit, !pronto {
                let dataChunk = PiperTTS.readAvailable(stdout)
                if dataChunk.isEmpty {
                    if !proc.isRunning { break }
                    // Cancellable wait: never `Thread.sleep` here (it blocks a
                    // cooperative-pool thread for up to 300 s). Cancellation
                    // must not leak the child — this session is not registered
                    // in `active` yet, so nothing else would kill it.
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {
                        PiperTTS.killHung(proc)
                        throw error
                    }
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
                throw PiperTTS.withStderr(makeError(key: "error.offlineNotReady"), stderrTail.text)
            }
        }

        /// Synthesizes a text into a WAV; returns the duration DECLARED by the
        /// model (the caller measures the WAV and uses the measurement — see `duration(of:)`
        /// and `effectiveDuration`).
        ///
        /// `async` for the same reason as the init: the response wait uses
        /// `Task.sleep`, never `Thread.sleep` (up to 300 s on a cooperative
        /// thread). The main lock now covers ONLY the synchronous part
        /// (checks + id + write): `lock.lock()` is unavailable from async
        /// contexts, and the wait loop touches nothing it guards (`closed`
        /// has its own lock). The single caller is the sequential loop of
        /// `runStreaming`, so the shorter critical section changes no ordering.
        func synth(text: String, wav: String, lengthScale: Double) async throws -> Double {
            let id = try lock.withLock { () -> Int in
                guard !closed, process.isRunning else {
                    throw makeError(key: "error.offlineTerminated")
                }
                let id = nextID
                nextID += 1
                let request: [String: Any] = ["id": id, "text": text, "wav": wav, "length_scale": lengthScale]
                let data = try JSONSerialization.data(withJSONObject: request)
                // `stop()` closes `stdin` from another thread WITHOUT the main lock
                // (on purpose: it must not wait for an in-flight `synth()`), so the
                // `closed` check above can pass and the close can land before this
                // write. Three guards: re-check `closed` here, write with the
                // THROWING API — `FileHandle.write(_:)` raises
                // `NSFileHandleOperationException` on a closed handle, an
                // Objective-C exception no `catch` in Swift can take, which would
                // take the app down mid-cancel — and turn the broken pipe into a
                // session error the caller's recovery already handles.
                guard !closed else { throw makeError(key: "error.offlineTerminated") }
                do {
                    try stdin.write(contentsOf: data + Data([0x0A]))
                } catch {
                    throw makeError(key: "error.offlineTerminated")
                }
                return id
            }
            // Response: one JSON line; generous deadline (first sentence includes I/O).
            let deadline = Date().addingTimeInterval(300)
            var accumulated = Data()
            while Date() < deadline {
                // Abort promptly when `stop()` closed the session (see `closed`):
                // without this, `stop()` would wait for an in-flight `synth()`.
                if closed { throw makeError(key: "error.offlineTerminated") }
                let dataChunk = PiperTTS.readAvailable(stdout)
                if dataChunk.isEmpty {
                    if !process.isRunning { break }
                    // Cancellable wait (async context; no `Thread.sleep`).
                    // On cancellation the caller's `catch` runs `stop()`, which
                    // terminates the child itself.
                    try await Task.sleep(nanoseconds: 50_000_000)
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
            throw PiperTTS.withStderr(makeError(key: "error.offlineTimeout"), stderrTail.text)
        }

        func stop() {
            // Non-blocking: `closed` uses its own lock (see above), so this
            // never waits for an in-flight `synth()` holding the main lock.
            // The kill wait (up to 2 s) runs in the background: `stop()` is
            // called from the main thread (stop button/discard) and used to
            // freeze the UI for the graces of SIGTERM.
            closed = true
            try? stdin.close()
            guard process.isRunning else { return }
            process.terminate()
            let box = ProcessBox(process)
            Task.detached(priority: .utility) {
                let limit = Date().addingTimeInterval(2)
                while box.process.isRunning, Date() < limit {
                    // Cancellable sleep (async context; no `Thread.sleep`).
                    _ = try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if box.process.isRunning {
                    kill(box.process.processIdentifier, SIGKILL)
                }
                box.process.waitUntilExit()
            }
        }
    }

    // MARK: - Sentence-by-sentence synthesis, in order (Piper is fast; no parallelism)

    /// Longest text sent to the model in ONE request (item 47).
    ///
    /// Rationale measured live below (see the test file): the synthesis time of
    /// a request grows with its length, and one runaway sentence of tens of
    /// thousands of characters runs past the 300 s response deadline of
    /// `PiperSession.synth` — the session is killed and the WHOLE reading dies
    /// with `error.offlineTimeout`, with no partial recovery. The cap keeps
    /// every request in the same order of magnitude as the online slice
    /// (`SpeechController` synthesizes online with `maxChars: 1800`).
    static let maxPhraseChars = 1800

    /// Splits one sentence's speech text into the pieces synthesized in
    /// sequence (item 47). Under the cap the text comes back untouched —
    /// exactly one piece, the reading's normal case.
    ///
    /// Why not `EdgeTTS.buildChunks`, which the plan names: it groups whole
    /// sentences and never cuts one (a single runaway phrase is returned
    /// unchanged, by design), and its "hard ceiling of 2x the cap" deliberately
    /// lets a group past the cap — neither behavior slices ONE sentence at the
    /// cap. The slicer is here instead, pure and covered by tests; the pieces
    /// keep the word order and no piece exceeds the cap.
    ///
    /// Boundaries fall at whitespace whenever possible. A single word longer
    /// than the cap is cut anyway: leaving it whole is exactly the request that
    /// times out, and silence would be worse than a word split in two.
    static func speechPieces(for text: String, maxChars: Int = PiperTTS.maxPhraseChars) -> [String] {
        let cap = max(1, maxChars)
        guard text.count > cap else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= cap {
                current = candidate
                continue
            }
            if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            var rest = Substring(word)
            while rest.count > cap {
                let limit = rest.index(rest.startIndex, offsetBy: cap)
                pieces.append(String(rest[rest.startIndex..<limit]))
                rest = rest[limit...]
            }
            current = String(rest)
        }
        if !current.isEmpty { pieces.append(current) }
        // Nothing to pack (whitespace-only text): an empty plan would leave the
        // phrase without its WAV. The whole text goes as it did before item 47.
        if pieces.isEmpty { return [text] }
        return pieces
    }

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
        rate: EdgeTTS.Rate,
        readFootnotes: Bool,
        locale: L.Language,
        shouldCancel: @escaping () -> Bool,
        progress: @escaping (String) -> Void,
        onChunk: @escaping (EdgeTTS.ChunkDelivery) -> Void
    ) async throws -> EdgeTTS.Result {
        guard !phrases.isEmpty else { throw makeError(key: "error.nothingToSynthesize") }
        if !hasEnoughDiskSpace() { throw makeError(key: "error.insufficientDiskSpace") }
        try Task.checkCancellation()
        // Disk guard before the venv/pip step, the voice download and hours of
        // audio (item 48): the failure belongs here, not hours later with a
        // generic message.
        let fm0 = FileManager.default
        guard DiskSpace.hasRoom(at: fm0.temporaryDirectory, floor: DiskSpace.synthesisFloor) else {
            throw makeError(key: "error.diskFull",
                            args: [DiskSpace.freeSpaceText(at: fm0.temporaryDirectory)])
        }
        // Bundled environment first (no network); if that fails, the legacy
        // `ensureVenv` tries the dev machines' path. The bundled failure is
        // KEPT: if the legacy path also fails, that is the root cause the
        // support case needs (item 51).
        var bundledFailure: Error?
        if BundledEnv.readyPython() == nil {
            do {
                _ = try BundledEnv.ensure(locale: locale, progress: progress)
            } catch {
                bundledFailure = error
            }
        }
        do {
            try ensureVenv()
        } catch {
            throw Self.withCause(error, cause: bundledFailure)
        }
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
        registerRunDirectory(dir)
        EdgeTTS.purgeStaleDirectories(keeping: dir)
        progress(L.get("progress.loadingOfflineVoice", locale: locale))

        let scale = lengthScale(for: rate)
        let session = try await PiperSession(onnx: onnx, lengthScale: scale)
        // `withLock`: this is an `async` function and the raw lock/unlock pair
        // is unavailable from asynchronous contexts (Swift 6 language mode).
        let previous = sessionLock.withLock { () -> PiperSession? in
            let old = active
            active = session
            return old
        }
        previous?.stop()

        do {
            var urls: [URL] = []
            var segments: [EdgeTTS.Segment] = []
            var offset = 0.0
            let total = phrases.count
            for (i, phrase) in phrases.enumerated() {
                try Task.checkCancellation()
                if shouldCancel() { throw makeError(key: "common.synthesisCancelled") }
                // Text adapted for speech (and the citation pass when the toggle
                // is on); the published one follows the original.
                // End of paragraph gains a `\n` (the model's pause; the gap enters the
                // measured WAV duration and the accumulated offset stays correct).
                var spokenBody = CitationSkip.speechText(phrase.text, voice: voice, readFootnotes: readFootnotes, marker: phrase.noteMarker)
                if spokenBody.isEmpty { spokenBody = phrase.text }
                let spokenText = phrase.paragraphEnd ? spokenBody + "\n" : spokenBody
                let wavURL = wavsDir.appendingPathComponent(String(format: "phrase-%05d.wav", i))
                // Item 47: a sentence above the cap is synthesized in pieces, in
                // sequence, and joined into THIS phrase's WAV — the request that
                // used to run past the deadline and kill the reading is now N
                // requests that each fit. One piece (the normal case) is the
                // untouched path: same single request, same file.
                let pieces = speechPieces(for: spokenBody)
                var measured = 0.0
                var declared = 0.0
                var partURLs: [URL] = []
                for (k, piece) in pieces.enumerated() {
                    // The paragraph pause goes to the last piece only.
                    let isLast = k == pieces.count - 1
                    let partText = isLast && phrase.paragraphEnd ? piece + "\n" : piece
                    let partURL = pieces.count == 1
                        ? wavURL
                        : wavsDir.appendingPathComponent(
                            String(format: "phrase-%05d-%02d.wav", i, k))
                    declared += try await session.synth(
                        text: partText, wav: partURL.path, lengthScale: scale)
                    guard let size = (try? fm.attributesOfItem(atPath: partURL.path))?[.size] as? Int,
                          size > 0
                    else { throw makeError(key: "error.offlineNoAudioOnPhrase", args: [i + 1]) }
                    measured += duration(of: partURL) ?? 0
                    partURLs.append(partURL)
                }
                if pieces.count > 1 {
                    _ = try concatWavs(partURLs, into: wavURL)
                    // The pieces were consumed by the join and are referenced by
                    // nobody (the player opens the phrase's WAV): dropping them
                    // keeps the temp at the reading's size, not at its double
                    // (the same rule as item 49 for the phrase partials).
                    for partURL in partURLs where partURL != wavURL {
                        try? fm.removeItem(at: partURL)
                    }
                }
                // REAL duration of the measured WAV (the online path does the same in
                // `EdgeTTS.duration(of:)`): the declared one accumulates drift in the
                // highlight of the following sentences. No silence inserted: the
                // offset advances exactly the measured duration. With pieces, the
                // join inserts no silence either, so the sum of the pieces is the
                // phrase's duration.
                let dur = effectiveDuration(
                    measured: measured > 0 ? measured : nil, declared: declared)
                progress(L.get("progress.chunkFraction", locale: locale, args: i + 1, total))
                // Piper does not emit word timings: estimate them from the spoken
                // text so the karaoke (yellow) works offline too. Distribution
                // is proportional to character count, with a small gap between
                // words (the model's natural pause).
                let words = estimateWordTimings(text: spokenText, totalDuration: dur)
                // Words start LOCAL to the sentence; in the final assembled list they
                // advance by the accumulated offset: the playback of the single WAV feeds
                // the `wordIndex` binary search with GLOBAL seconds, against words[].start.
                // Without the shift, every replay/restart pinned the yellow at the END of
                // the sentence (the online shift is in EdgeTTS.runStreaming).
                let shifted = words.map { w in EdgeTTS.Segment.Word(
                    start: w.start + offset, duration: w.duration, text: w.text) }
                let seg = EdgeTTS.Segment(start: offset, duration: dur, text: phrase.text, words: shifted, index: phrase.index, page: phrase.page, rects: phrase.rects)
                segments.append(seg)
                offset += dur
                urls.append(wavURL)
                // Immediate delivery: the first sentence plays without waiting for the rest.
                let localWords = words.map { w in EdgeTTS.Segment.Word(start: w.start, duration: w.duration, text: w.text) }
                let local = EdgeTTS.Segment(start: 0, duration: dur, text: phrase.text, words: localWords, index: phrase.index, page: phrase.page, rects: phrase.rects)
                onChunk(.chunk(index: i, url: wavURL, segments: [local]))
            }
            let final = try concatWavs(urls, into: dir.appendingPathComponent("EdgeSpeak.wav"))
            // Each phrase WAV is consumed by the concat above: drop it so the
            // three copies (phrase + final + cache) do not coexist on disk.
            for u in urls { try? fm.removeItem(at: u) }
            try? fm.removeItem(at: wavsDir)
            // The session dies with the reading: no leftover process.
            stopActiveSession()
            // `segments` already carries global times (offset accumulated sentence by sentence).
            return EdgeTTS.Result(audioURL: final, segments: segments)
        } catch {
            session.stop()
            failOfflineRun(dir: dir)
            throw error
        }
    }

    // MARK: - Offline reading directory: protection, pruning and failure

    /// Directory of the offline reading (the one holding the assembled
    /// `EdgeSpeak.wav` and the `phrase-NNNNN.wav`), registered next to the
    /// `EdgeTTS` protection so `releasePhraseWavs` knows what to prune.
    private static let runDirLock = NSLock()
    private static var runDir: URL?

    /// Registers the directory of the current offline reading. Internal so the
    /// suite covers the release without a live Piper.
    static func registerRunDirectory(_ url: URL) {
        runDirLock.withLock { runDir = url }
    }

    /// Removes the per-sentence WAVs of the offline reading — the partials the
    /// chunk queue already consumed — keeping the assembled `EdgeSpeak.wav`,
    /// which is what a replay/restart replays (item 49 of the robustness lane,
    /// 2026-10-17).
    ///
    /// The moment is what makes this safe: the player opens each
    /// `phrase-NNNNN.wav` when its turn comes (`StreamingPlayer.playChunk`) and
    /// a click can jump BACK to an earlier sentence, so the partials cannot be
    /// deleted while the queue is alive — not even right after `concatWavs`
    /// read them. The controller calls this when it drops the chunk queue
    /// (stop/discard). `dir` defaults to the registered reading.
    static func releasePhraseWavs(in dir: URL? = nil) {
        guard let target = dir ?? runDirLock.withLock({ runDir }) else { return }
        try? FileManager.default.removeItem(
            at: target.appendingPathComponent("wavs", isDirectory: true))
    }

    /// Failure path of an offline run: withdraws the protection registered by
    /// `runStreaming` and removes the temporary directory (items 49 and 53).
    ///
    /// Why the protection must go: without this, a failed synthesis left
    /// `protectedOfflineDir` pointing at a path that no longer exists —
    /// harmless today, but it makes the next `purge` preserve a ghost. Internal
    /// so the suite covers the withdrawal.
    static func failOfflineRun(dir: URL) {
        EdgeTTS.clearOfflineDirectory()
        runDirLock.withLock { runDir = nil }
        try? FileManager.default.removeItem(at: dir)
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
        return try concatWavsByHand(ordered, into: outURL)
    }

    /// Manual join (no ffmpeg): the first file's header (up to `data`, with any
    /// extra chunks) + the PCM of all (same format/rate/channels). Sizes in
    /// RIFF and `data` are recalculated for the real offset (see B3).
    ///
    /// Internal (not private) so the suite exercises the path that only runs on
    /// machines WITHOUT ffmpeg — this host has ffmpeg, and the item 46
    /// measurement and the byte-identity check need to reach the manual join
    /// directly.
    ///
    /// PCM is copied in blocks, never assembled in a single `Data`: the whole
    /// book's PCM in memory twice (`pcm` + `final`) was the item 46 symptom —
    /// hours of audio ≈ hundreds of MB, and memory pressure at the end of a
    /// long reading. The output bytes are the same either way.
    static func concatWavsByHand(_ ordered: [URL], into outURL: URL) throws -> URL {
        guard !ordered.isEmpty else { throw makeError(key: "error.nothingToJoin") }
        var head: Data?
        var dataOffset = 0
        var totalPCM = 0
        var offsets: [Int] = []
        var sizes: [Int] = []
        // First pass: the header (from the first file) and the total PCM size.
        // Reads only the head of each file — the PCM is not touched here.
        for (i, url) in ordered.enumerated() {
            let headOnly = try readHead(of: url)
            guard let layout = wavLayout(headOnly) else {
                throw makeError(key: "error.invalidWavOnJoin")
            }
            let size = try fileSize(of: url)
            let pcmBytes = size - layout.dataOffset
            guard pcmBytes > 0 else { throw makeError(key: "error.invalidWavOnJoin") }
            if i == 0 {
                head = headOnly.prefix(layout.dataOffset)
                dataOffset = layout.dataOffset
            }
            offsets.append(layout.dataOffset)
            sizes.append(pcmBytes)
            totalPCM += pcmBytes
        }
        guard var headBytes = head else { throw makeError(key: "error.joinEmpty") }
        func writeU32(_ v: UInt32, within o: Int) {
            headBytes[o] = UInt8(v & 0xFF)
            headBytes[o + 1] = UInt8((v >> 8) & 0xFF)
            headBytes[o + 2] = UInt8((v >> 16) & 0xFF)
            headBytes[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        writeU32(UInt32(totalPCM + headBytes.count - 8), within: 4)
        writeU32(UInt32(totalPCM), within: dataOffset - 4)
        // One chunk of PCM at a time (1 MiB): the peak no longer grows with the
        // reading's length — it is the header plus the block.
        let blockSize = 1 << 20
        try? FileManager.default.removeItem(at: outURL)
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL)
        else { throw makeError(key: "error.joinEmpty") }
        do {
            try out.write(contentsOf: headBytes)
            for (i, url) in ordered.enumerated() {
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                try input.seek(toOffset: UInt64(offsets[i]))
                var remaining = sizes[i]
                while remaining > 0 {
                    let want = min(blockSize, remaining)
                    // Explicit pool per block: `FileHandle.read(upToCount:)`
                    // bridges to an autoreleased `NSData`, and without a pool
                    // the blocks pile up until the enclosing scope returns —
                    // the peak would follow the reading's length again, exactly
                    // what this rewrite exists to avoid (measured: 200 MB of
                    // PCM kept 200 MB resident without this).
                    var read = 0
                    try autoreleasepool {
                        guard let block = try input.read(upToCount: want), !block.isEmpty else {
                            throw makeError(key: "error.invalidWavOnJoin")
                        }
                        try out.write(contentsOf: block)
                        read = block.count
                    }
                    remaining -= read
                }
            }
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        // A zero-byte join would be indistinguishable from silence: same guard
        // as the ffmpeg path.
        guard ((try? fileSize(of: outURL)) ?? 0) > 0 else {
            throw makeError(key: "error.joinEmpty")
        }
        return outURL
    }

    /// File size without loading the file (the whole-book PCM never enters
    /// memory).
    private static func fileSize(of url: URL) throws -> Int {
        guard let size = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? Int else {
            throw makeError(key: "error.invalidWavOnJoin")
        }
        return size
    }

    /// First bytes of a file: enough for `wavLayout` (8192 covers any real
    /// header, as in `duration(of:)`).
    private static func readHead(of url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 8192)
        else { throw makeError(key: "error.invalidWavOnJoin") }
        try? handle.close()
        return head
    }

    // MARK: - Helpers

    /// Estimates word timings for a sentence when the engine does not provide
    /// them (Piper). Distribution is proportional to character count, with a
    /// small gap between words. The total duration matches the sentence's.
    ///
    /// Pure function: testable without audio or network.
    static func estimateWordTimings(text: String, totalDuration: Double) -> [EdgeTTS.Segment.Word] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, totalDuration > 0 else { return [] }

        // Gap between words (model's natural pause), capped so short sentences
        // don't lose all their time to gaps.
        let gapRaw: Double = min(0.05, totalDuration / Double(words.count + 1) * 0.1)
        let speechRaw = max(0.1, totalDuration - gapRaw * Double(words.count - 1))
        // Very short sentence: floor + cap can still sum past the measured
        // duration. Scale durations AND gaps so the cursor ends INSIDE the
        // sentence — a last word beyond its end held the highlight alive over
        // a sentence already finished.
        let totalRaw = speechRaw + gapRaw * Double(words.count - 1)
        let scale = totalRaw > totalDuration ? totalDuration / totalRaw : 1.0
        let gap = gapRaw * scale
        let speechTime = speechRaw * scale

        // Weight by character count, but with a minimum floor so short
        // function words ("the", "a") don't get disproportionately little
        // time (which made the nudge imprecise). A floor of 3 chars
        // approximates a minimum syllable duration.
        let weights = words.map { max(3, $0.count) }
        let totalWeight = weights.reduce(0, +)

        var result: [EdgeTTS.Segment.Word] = []
        var cursor: Double = 0
        for (i, word) in words.enumerated() {
            let wordDur = speechTime * Double(weights[i]) / Double(totalWeight)
            result.append(EdgeTTS.Segment.Word(start: cursor, duration: wordDur, text: word))
            cursor += wordDur + (i < words.count - 1 ? gap : 0)
        }
        return result
    }

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
