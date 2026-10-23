import Foundation

/// Builds a copyable diagnostic report (Settings → Advanced), meant for
/// GitHub support: gathers versions, runtime environment, venv and tool
/// presence, and the last shown status/error — no data from the read
/// document (privacy).
///
/// Nothing here invents state: each line is read from the environment at
/// call time; whatever does not exist shows as "missing".
enum Diagnostics {
    static func text() -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        lines.append("EdgeSpeak \(version) (\(build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        lines.append("arch: arm64")
        #elseif arch(x86_64)
        lines.append("arch: x86_64")
        #else
        lines.append("arch: unknown")
        #endif

        lines.append("support: \(BundledEnv.supportDir.path)")
        let venvPresent = FileManager.default.fileExists(atPath: BundledEnv.venvDir.path)
        lines.append("venv: \(venvPresent ? "present" : "missing")")
        if let ready = BundledEnv.readyPython() {
            lines.append("python (ready this run): \(ready)")
        } else if let system = BundledEnv.basePython() {
            lines.append("python (system base): \(system)")
        } else {
            lines.append("python: not found")
        }
        lines.append("ffmpeg: \(EdgeTTS.ffmpegPath ?? "missing")")

        let bytes = DiskCache.totalBytes()
        lines.append("cache: \(bytes / 1_048_576) MB (\(bytes) bytes)")

        let language = UserDefaults.standard.string(forKey: AppSetting.languageKey) ?? AppSetting.languageDefault
        lines.append("interface language: \(language)")
        let last = DiagStatus.lastStatus
        lines.append("last status: \(last.isEmpty ? "(none)" : last)")

        return lines.joined(separator: "\n")
    }
}

/// Thread-safe snapshot of the last shown status/error. Lives outside
/// `SpeechController` (which is `@MainActor`) on purpose: the diagnostic
/// text is assembled in the background, and the controller may write from
/// the main thread. A short lock covers both sides.
enum DiagStatus {
    private static let lock = NSLock()
    private static var text = ""

    static var lastStatus: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }

    static func record(_ s: String) {
        lock.lock(); text = s; lock.unlock()
    }
}
