import Foundation
import os

/// Disk side of the user highlights (SPEC-DESTAQUES-2026-10-17 §2).
///
/// Location: `~/Library/Application Support/EdgeSpeak/Highlights/<sha256>.json`
/// — Application Support and NOT the `.cachesDirectory` the app already uses
/// (`DiskCache.swift`), because the cache is erasable and these are user data.
/// Writes mimic `DiskCache.store`: JSON in `Data` (no escaped slashes, sorted
/// keys), `.atomic` write, silent on failure — a failed write can never
/// interrupt the reading, and nothing here ever throws up to the UI.
enum HighlightDiskStore {
    static let logger = Logger(subsystem: "EdgeSpeak", category: "highlights")

    /// Same shape in tests (injected) and in the app (default root).
    static var defaultDirectory: URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
            .appendingPathComponent("Highlights", isDirectory: true)
    }

    /// `<sha256>.json` — one sidecar per content hash.
    static func sidecarURL(directory: URL, key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// Fingerprint of the open PDF (background work; one hash + one stat).
    /// `nil` only when the reply is unusable (unreadable file).
    static func fingerprint(for fileURL: URL) -> DocumentFingerprint? {
        guard let key = HighlightKey.contentKey(of: fileURL)
        else { return nil }
        let fileManager = FileManager.default
        let byteCount = (try? fileManager.attributesOfItem(
            atPath: fileURL.path))?[.size] as? Int ?? 0
        let bookmark = (try? fileURL.bookmarkData())
            .flatMap { $0.base64EncodedString() } ?? ""
        return DocumentFingerprint(
            contentSHA256: key,
            byteCount: byteCount,
            lastKnownName: fileURL.lastPathComponent,
            lastKnownPath: fileURL.path,
            bookmarkData: bookmark)
    }

    /// Tolerant read: anything unreadable or out-of-format is `[]` (spec §2).
    /// The file is NEVER deleted here — a corrupt/foreign version must not be
    /// erased before a future migrator sees it.
    static func read(directory: URL, key: String, pageCount: Int?) -> [StoredHighlight] {
        guard key.count == 64 else { return [] }
        let data = try? Data(contentsOf: sidecarURL(directory: directory, key: key))
        return HighlightStore.decode(data, pageCount: pageCount)
    }

    /// Atomic write of the whole document, silent on failure (logged, never
    /// thrown): the caller owns the throttle and the main-queue coordination.
    static func write(
        document: HighlightDocument, directory: URL, key: String
    ) {
        guard key.count == 64 else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(
                to: sidecarURL(directory: directory, key: key), options: [.atomic])
        } catch {
            // Volume full, permissions, folder gone: reading continues without
            // persistence — the documented behavior, mirrored from DiskCache.
            logger.error("highlight sidecar write failed: \(error.localizedDescription)")
        }
    }

    /// Builds the on-disk document for a mutation (single writer path —
    /// create/remove/undo/redo all end here, no parallel logic).
    static func document(
        fingerprint: DocumentFingerprint, highlights: [StoredHighlight], now: Date = .init()
    ) -> HighlightDocument {
        HighlightDocument(
            formatVersion: HighlightStore.formatVersion,
            fingerprint: fingerprint,
            updatedAt: now,
            highlights: highlights)
    }

    /// Orphan sweep at opening (spec §2, non-blocking): sidecars other than the
    /// just-opened document whose file vanished over 180 days ago. Evaluation
    /// only, never underneath the open path: this runs AFTER the current
    /// document's sidecar was read, on the same background queue, and a failing
    /// sweep must not affect it in any way.
    static func sweepOrphans(directory: URL, excluding currentKey: String, now: Date) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names where name.hasSuffix(".json") {
            guard name != "\(currentKey).json" else { continue }
            guard let key = name.split(separator: ".").first.map(String.init),
                  key.count == 64
            else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(
                      HighlightDocument.self, from: data)
            else { continue }
            let shouldPrune = HighlightStore.pruneDecision(
                lastKnownPath: document.fingerprint.lastKnownPath,
                bookmark: document.fingerprint.bookmarkData,
                updatedAt: document.updatedAt,
                now: now)
            guard shouldPrune
            else { continue }
            // Removal fails silently: the sidecar stays and the next sweep tries
            // again — pruning is an optimization, like DiskCache's.
            try? fileManager.removeItem(at: url)
        }
    }
}

/// The throttled writer that owns ONE document's sidecar while it is open.
///
/// - Rapid mutations collapse: mutating marks `dirty` and schedules one
///   trailing write within `throttleInterval` (1 s); only one write is pending
///   at a time, so a burst of highlights causes ONE write after the window.
/// - `flushNow` (document switch, window closing) writes immediately.
/// - Mutation "always" ends in a write exactly because the trailing flush is
///   bounded to 1 s of delay; nothing carries over an unbounded memory list.
///
/// Testable without app (spec §7.3): `clock` and `schedule` are injectable, so
/// the tests count writes and fire the scheduled block themselves.
///
/// Main-thread by contract: every mutator is called from the main queue
/// (annotation creation/removal and the unwinding both happen there), which is
/// also how two windows of the same document serialize — last write wins.
final class HighlightSidecarStore {
    let fingerprint: DocumentFingerprint
    ///Backing source of truth on the main thread, in creation order.
    private(set) var records: [StoredHighlight] = []

    /// 1 s trailing window; injectable so the tests can count precisely.
    var throttleInterval: TimeInterval = 1
    private(set) var writeCount = 0

    private let directory: URL
    private let now: () -> Date
    private let schedule: (_ delay: TimeInterval, @escaping () -> Void) -> Void
    private var dirty = false
    private var pendingFlush = false

    init(
        fingerprint: DocumentFingerprint,
        records: [StoredHighlight] = [],
        directory: URL = HighlightDiskStore.defaultDirectory,
        now: @escaping () -> Date = { Date() },
        schedule: @escaping (_ delay: TimeInterval, @escaping () -> Void) -> Void =
            { delay, block in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay, execute: block)
            }
    ) {
        self.fingerprint = fingerprint
        self.records = records
        self.directory = directory
        self.now = now
        self.schedule = schedule
    }

    /// Adds a created record (create or redo). Duplicate ids overwrite —
    /// identical ids are the same record, not two states to persist.
    func add(_ record: StoredHighlight) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    /// Removes by id (context menu or undo-of-create).
    func remove(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id })
        else { return }
        records.remove(at: index)
        persist()
    }

    /// Release the last write immediately (document switch, window closing,
    /// before relaunching the store for a new document). No-op when nothing
    /// changed — never an extra disk hit.
    func flushNow() {
        pendingFlush = false
        writeThrough()
    }

    /// Marks the change and coalesces: one trailing write pending at a time.
    private func persist() {
        dirty = true
        guard !pendingFlush else { return }
        pendingFlush = true
        schedule(throttleInterval) { [weak self] in
            guard let self else { return }
            self.pendingFlush = false
            self.writeThrough()
        }
    }

    /// The single disk entry point: builds the document, writes it, counts it.
    private func writeThrough() {
        guard dirty else { return }
        dirty = false
        writeCount += 1
        HighlightDiskStore.write(
            document: HighlightDiskStore.document(
                fingerprint: fingerprint, highlights: records, now: now()),
            directory: directory,
            key: fingerprint.contentSHA256)
    }
}
