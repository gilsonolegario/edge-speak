import Foundation
import CryptoKit

/// Disk cache of the synthesis: key = hash(text+voice+cadence).
///
/// Stores the final MP3 + the global segments. Reopening the same PDF with the same
/// voice and cadence plays without network. Lives in Caches (not in the temporary folder, which the
/// engine clears on every synthesis).
enum DiskCache {
    struct Hit: Sendable {
        let audioURL: URL
        let segments: [EdgeTTS.Segment]
    }

    /// Stable key for (text, voice, cadence).
    ///
    /// `v3` (splitter generation; before, `v2` of the karaoke): those segments
    /// have no `words`, and reusing them would silence the per-word highlight for
    /// good in the same document.
    /// `readFootnotes` enters the key (audio with and without notes differs); with the
    /// default, the raw material is identical to before — no old cache
    /// is invalidated.
    static func key(text: String, voice: String, rate: EdgeTTS.Rate, readFootnotes: Bool = true) -> String {
        // "v3": sentence-splitter generation. Same raw material, new splitter
        // = new indices — without the generation in the key, an old cache
        // would serve segments with another numbering's indices (found in the
        // parallel review). Changing it here invalidates the cache once.
        let raw = "v3|\(voice)|\(rate.percent)|\(readFootnotes ? "" : "sem-notas|")\(text)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
    }

    private static let lock = NSLock()
    private static var lastPrune = Date.distantPast

    /// Cache cap by age: entries older than this leave, even with space.
    /// 30 days covers re-reads of the same PDF in the month without keeping forever.
    private static let maxAge: TimeInterval = 30 * 24 * 3_600
    /// Cache cap by size: above this, the oldest leave first.
    /// 2 GB ≈ dozens of average audiobooks; below what would fill the disk.
    private static let maxTotalBytes: Int = 2 * 1_024 * 1_024 * 1_024
    /// Expensive pruning (scans the directory): at most once per run/minute.
    private static let pruneInterval: TimeInterval = 60
    /// Anti-floor margin: never removes an entry stored less than this long ago,
    /// even if the total overflows — protects the current reading.
    private static let gracePeriod: TimeInterval = 60

    private static func paths(for key: String) -> (audio: URL, segments: URL) {
        let base = dir.appendingPathComponent(key, isDirectory: true)
        // Offline stores concatenated WAV; online, MP3. The manifest is the same.
        let fm = FileManager.default
        let wav = base.appendingPathComponent("audio.wav")
        let audio = fm.fileExists(atPath: wav.path)
            ? wav : base.appendingPathComponent("audio.mp3")
        return (audio, base.appendingPathComponent("segments.json"))
    }

    /// Returns the stored audio + segments, or nil on any miss.
    /// On hit, touches the entry so frequent readings stay fresh in the LRU.
    static func lookup(key: String) -> Hit? {
        let fm = FileManager.default
        let (audio, json) = paths(for: key)
        guard let size = (try? fm.attributesOfItem(atPath: audio.path))?[.size] as? Int,
              size > 0,
              let data = try? Data(contentsOf: json),
              let segments = try? JSONDecoder().decode([EdgeTTS.Segment].self, from: data),
              !segments.isEmpty
        else { return nil }
        let base = dir.appendingPathComponent(key, isDirectory: true)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: base.path)
        return Hit(audioURL: audio, segments: segments)
    }

    /// Stores the final result. Fails silently: cache is an optimization.
    static func store(key: String, audioURL: URL, segments: [EdgeTTS.Segment]) {
        guard !segments.isEmpty else { return }
        let fm = FileManager.default
        // The extension follows the real audio (WAV offline, MP3 online); the
        // `lookup` finds either one by the same text+voice+rate hash.
        let base = dir.appendingPathComponent(key, isDirectory: true)
        let ext = audioURL.pathExtension.lowercased() == "wav" ? "wav" : "mp3"
        let audio = base.appendingPathComponent("audio.\(ext)")
        let json = base.appendingPathComponent("segments.json")
        do {
            try fm.createDirectory(
                at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
            try fm.copyItem(at: audioURL, to: audio)
            let data = try JSONEncoder().encode(segments)
            try data.write(to: json, options: .atomic)
        } catch {
            // Without cache, only no shortcut: the reading proceeds from the temporary folder.
            try? fm.removeItem(at: audio.deletingLastPathComponent())
        }
        schedulePrune(preserving: key)
    }

    /// Removes the entry for the key (whole folder). Fails silently: cache
    /// is an optimization, like the rest of the type.
    static func remove(key: String) {
        let base = dir.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
    }

    /// Total size in bytes (to display in Settings).
    static func totalBytes() -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total = 0
        for name in names {
            let base = dir.appendingPathComponent(name, isDirectory: true)
            if let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in walker {
                    total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            }
        }
        return total
    }

    /// Erases all entries except the key in use (nil = all).
    /// Returns the bytes freed. Off the main thread (scans and deletes on disk).
    @discardableResult
    static func clearAll(preserving key: String?) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var freed = 0
        for name in names {
            if let key, name == key { continue }
            let base = dir.appendingPathComponent(name, isDirectory: true)
            freed += sizeOf(base)
            try? fm.removeItem(at: base)
        }
        return freed
    }

    private static func sizeOf(_ base: URL) -> Int {
        var total = 0
        if let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    /// Schedules pruning off the current thread and at most once a minute.
    private static func schedulePrune(preserving key: String) {
        lock.lock()
        let due = Date().timeIntervalSince(lastPrune) >= pruneInterval
        if due { lastPrune = Date() }
        lock.unlock()
        guard due else { return }
        Task.detached(priority: .background) { prune(preserving: key) }
    }

    /// Removes entries too old and, above the cap, the oldest.
    /// Never touches the key in use nor entries stored within the margin.
    /// Fails silently: cache is an optimization, it cannot break the reading.
    private static func prune(preserving currentKey: String) {
        let fm = FileManager.default
        let root = dir
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let now = Date()
        var entries: [(name: String, mtime: Date, size: Int)] = []
        var total = 0
        for name in names {
            if name == currentKey { continue }
            let base = root.appendingPathComponent(name, isDirectory: true)
            guard let mtime = (try? fm.attributesOfItem(atPath: base.path))?[.modificationDate] as? Date
            else { continue }
            if now.timeIntervalSince(mtime) < gracePeriod { continue }
            var size = 0
            if let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in walker {
                    size += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            }
            entries.append((name, mtime, size))
            total += size
        }
        // First by age: whatever passed maxAge leaves immediately.
        for e in entries where now.timeIntervalSince(e.mtime) > maxAge {
            try? fm.removeItem(at: root.appendingPathComponent(e.name))
            total -= e.size
        }
        // Then by size: from oldest to newest until it fits the cap.
        if total > maxTotalBytes {
            for e in entries
                .filter({ now.timeIntervalSince($0.mtime) <= maxAge })
                .sorted(by: { $0.mtime < $1.mtime })
            {
                if total <= maxTotalBytes { break }
                try? fm.removeItem(at: root.appendingPathComponent(e.name))
                total -= e.size
            }
        }
    }
}
