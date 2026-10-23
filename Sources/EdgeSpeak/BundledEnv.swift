import Foundation

/// Bundled Python environment: the app works on a virgin Mac (only macOS 14+
/// arm64 + network), without the system Python or the owner's venvs.
///
/// On first run, `ensure` creates `~/Library/Application
/// Support/EdgeSpeak/venv` from the base bundled in the app
/// (`Resources/pythonbase`) and installs WITH NO network from the bundled
/// wheels (`Resources/wheels`). After that, it is one quick probe.
/// Idempotent: with the venv ready, nothing is recreated or reinstalled.
enum BundledEnv {
    /// Base folder: the same as Piper's (`~/Library/Application Support/EdgeSpeak`).
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
    }

    static var venvDir: URL { supportDir.appendingPathComponent("venv", isDirectory: true) }

    static var supportPython: String {
        venvDir.appendingPathComponent("bin/python").path
    }

    /// Interpreter choice: support when valid, else legacy.
    /// Pure for testing (the probe order in a single place).
    static func pickPython(support: String?, supportValid: Bool, legacy: String) -> String {
        if supportValid, let support { return support }
        return legacy
    }

    private static let stateLock = NSLock()
    private static var readyCache = false
    private static let setupLock = NSLock()

    /// The support venv without spawning a process: valid when `ensure` has
    /// already run in this execution (it verified the imports). Nil otherwise.
    /// This is what keeps the hot path fast (no probe per access).
    static func readyPython() -> String? {
        stateLock.lock()
        let ready = readyCache
        stateLock.unlock()
        guard ready,
              FileManager.default.isExecutableFile(atPath: supportPython)
        else { return nil }
        return supportPython
    }

    private static func markReady() {
        stateLock.lock()
        readyCache = true
        stateLock.unlock()
    }

    /// Ensures the support venv with edge_tts+fitz+piper; returns the
    /// interpreter path. Fast when ready (1 probe). Errors via catalog
    /// keys of `L` (language at call time). Serialized: two
    /// concurrent calls prepare only once.
    static func ensure(locale: L.Language = .en, progress: @escaping (String) -> Void) throws -> String {
        if importsOK(supportPython) {
            markReady()
            return supportPython
        }
        setupLock.lock()
        defer { setupLock.unlock() }
        // Another thread may have finished while this one waited.
        if importsOK(supportPython) {
            markReady()
            return supportPython
        }
        let fm = FileManager.default
        guard let base = basePython() else {
            throw makeError(key: "error.bundledPythonMissing")
        }
        progress(L.get("progress.preparingEnv", locale: locale))
        // Validity is the INTERPRETER, not the directory: an interrupted
        // `venv` (app quit, 300 s timeout, disk full) leaves `venv/` behind
        // with no `bin/python`, and the guard below would call `ensurepip` on
        // a nonexistent interpreter and fail forever after. A half-created
        // venv is removed and rebuilt from the embedded base.
        if !fm.isExecutableFile(atPath: supportPython), fm.fileExists(atPath: venvDir.path) {
            try? fm.removeItem(at: venvDir)
        }
        if !fm.isExecutableFile(atPath: supportPython) {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let (st, err) = runSync(base, ["-m", "venv", venvDir.path], timeout: 300)
            guard st == 0 else {
                // Do not leave a half-made venv behind: the next attempt starts clean.
                try? fm.removeItem(at: venvDir)
                throw makeError(key: "error.localEnvCreate", args: [tail(err)])
            }
        }
        let pip = venvDir.appendingPathComponent("bin/pip").path
        if !fm.isExecutableFile(atPath: pip) {
            // Base without pip (minimal standalone): complete inside the venv,
            // without touching the bundled base.
            let (st, err) = runSync(supportPython, ["-m", "ensurepip"], timeout: 300)
            guard st == 0, fm.isExecutableFile(atPath: pip) else {
                throw makeError(key: "error.localEnvEnsurepip", args: [tail(err)])
            }
        }
        guard let wheels = wheelsDir() else {
            throw makeError(key: "error.bundledWheelsMissing")
        }
        progress(L.get("progress.installingPackages", locale: locale))
        let (stIns, errIns) = runSync(
            pip,
            ["install", "--no-index", "--find-links", wheels.path,
             "edge-tts", "pymupdf", "piper-tts"],
            timeout: 900)
        guard stIns == 0 else {
            throw makeError(key: "error.bundledInstallFailed", args: [tail(errIns)])
        }
        progress(L.get("progress.applyingEdgePatch", locale: locale))
        guard let patch = patchScript(), let site = sitePackages() else {
            throw makeError(key: "error.bundledFilesMissing")
        }
        let (stPatch, errPatch) = runSync(
            supportPython, [patch, site.path], timeout: 120)
        guard stPatch == 0 else {
            throw makeError(key: "error.edgePatchFailed", args: [tail(errPatch)])
        }
        guard importsOK(supportPython) else {
            throw makeError(key: "error.localEnvVerify")
        }
        markReady()
        return supportPython
    }

    /// One probe only: does the interpreter import edge_tts+fitz+piper?
    static func importsOK(_ python: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "import edge_tts, fitz, piper"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    // MARK: - Bundled files (bundle; fallback: repo in dev)

    /// Package root in a dev run (3 levels above this file).
    static var devRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Python 3 from the bundled base (`Resources/pythonbase`), or nil.
    static func basePython() -> String? {
        if let dir = embeddedDir("pythonbase") {
            for name in ["bin/python3", "bin/python"] {
                let p = dir.appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Bundled wheels folder, or nil.
    static func wheelsDir() -> URL? { embeddedDir("wheels") }

    /// Patch script (bundle or `Tools/` in dev), or nil.
    static func patchScript() -> String? {
        if let url = Bundle.main.url(forResource: "patch_edge_tts", withExtension: "py") {
            return url.path
        }
        let p = devRoot.appendingPathComponent("Tools/patch_edge_tts.py").path
        return FileManager.default.isRegularFile(atPath: p) ? p : nil
    }

    private static func embeddedDir(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Dev fallback: Build/staging (from build-app.sh) or Resources/.
        for base in ["Build/staging", "Resources"] {
            let url = devRoot.appendingPathComponent(base).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The support venv's site-packages (nil if it does not exist yet).
    /// Pure on the filesystem (testable with a fake directory).
    static func sitePackages(in dir: URL? = nil) -> URL? {
        let venv = dir ?? venvDir
        let lib = venv.appendingPathComponent("lib")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: nil)
        else { return nil }
        for entry in entries where entry.lastPathComponent.hasPrefix("python") {
            let site = entry.appendingPathComponent("site-packages")
            if FileManager.default.fileExists(atPath: site.path) { return site }
        }
        return nil
    }

    // MARK: - Helpers

    private static func runSync(_ path: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory
            .appendingPathComponent("edgespeak-env-\(UUID().uuidString).log")
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: errURL) }
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else {
            // No locale in scope here (bootstrap helper); app is English by
            // default, so resolve in English rather than hardcoding Portuguese.
            return (1, L.get("common.noStderr", locale: .en))
        }
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
            proc.terminate()
            let hard = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < hard {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            proc.waitUntilExit()
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
        NSError(domain: "EdgeSpeak.BundledEnv", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.resolve(key, args: args),
                           "l10nKey": key, "l10nArgs": args])
    }
}

private extension FileManager {
    func isRegularFile(atPath path: String) -> Bool {
        var dir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }
}
