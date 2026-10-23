import Foundation
import CryptoKit
import CoreGraphics

/// Pure model of the user's PDF highlights: what the sidecar stores and the
/// decisions that do not need a running app. Nothing here imports UI or PDFKit
/// beyond CoreGraphics — the precedent is `PDFDocumentView.isUserScroll` and the
/// injectable stores of `AppSettings.swift`.
///
/// File format (SPEC-DESTAQUES-2026-10-17 §1): JSON keyed by the SHA-256 of the
/// PDF CONTENT (not by URL — the PDF moves, the highlights follow; the PDF is
/// edited outside, the hash changes and the old version's highlights stay
/// dormant, never painted over new content). Reuses `DiskCache.key`'s SHA-256
/// pattern, but the two keys intentionally DIVERGE: position is per
/// (URL ## voice), highlights are per physical content.

/// One user highlight. Phase 1 has a single color (`colorSlug == "magenta"`),
/// but the field is versioned in from the start so more colors never rewrite
/// the format.
struct StoredHighlight: Codable, Equatable {
    /// UUID string, stable across time (annotation↔record↔undo all speak by id).
    let id: String
    /// 0-based page, page space (same space the reader's ephemeral boxes use).
    let page: Int
    /// One quad (4 vertices) per selection line; page space, zoom-independent.
    let quads: [[CGPoint]]
    /// Literal text of the selection (human review; never used to re-anchor).
    let text: String
    /// Phase 1 always "magenta" (HighlightMarks.colorSlug).
    let colorSlug: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, page, quads, text, colorSlug, createdAt
    }

    /// Tolerant decoding on purpose (spec §2): a highlight with a missing or
    /// mistyped field must fall out ALONE, not drag the whole sidecar down.
    /// The sentinels (`page: -1`, empty `quads`, empty `id`) are invalid, and
    /// `HighlightStore.validate` drops them; a well-formed highlight keeps
    /// every field intact (round-trips `Equatable`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? ""
        self.page = (try? container.decode(Int.self, forKey: .page)) ?? -1
        // Null/net-numeric coordinates make this decode throw: they arrive here
        // as an empty array and the record falls out in `validate`.
        self.quads = (try? container.decode([[CGPoint]].self, forKey: .quads)) ?? []
        self.text = (try? container.decode(String.self, forKey: .text)) ?? ""
        self.colorSlug = (try? container.decode(String.self, forKey: .colorSlug)) ?? ""
        self.createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
    }

    init(
        id: String, page: Int, quads: [[CGPoint]],
        text: String, colorSlug: String, createdAt: Date
    ) {
        self.id = id
        self.page = page
        self.quads = quads
        self.text = text
        self.colorSlug = colorSlug
        self.createdAt = createdAt
    }
}

/// What the app signs its annotations with: `userName` AND the `/T`
/// (`textLabel`) key. The reader's ephemeral blue/yellow annotations NEVER set
/// a `textLabel`, so a context menu can tell "mine" from "theirs" (third-party
/// annotations stay untouched).
enum HighlightMarks {
    static let owner = "EdgeSpeak"
    static let colorSlug = "magenta"
    /// Marca das EFÊMERAS de leitura (`userName`): o menu de contexto delas
    /// jamais abre "Remover destaque" (o seletor é `textLabel == "EdgeSpeak"`,
    /// que elas não têm — PDFKit lhes põe o nome do usuário do Sistema) e a
    /// exportação as retira antes do burn-in por esta marca.
    static let readingOwner = "EdgeSpeak.reading"
    /// Nomes de undo (spec §4): menu do Sistema ⌘Z/⇧⌘Z os exibe de graça.
    static let undoCreateName = "Destacar"
    static let undoRemoveName = "Remover destaque"
}

struct DocumentFingerprint: Codable, Equatable {
    /// SHA-256 of the whole file — the sidecar key and file name (hex).
    let contentSHA256: String
    let byteCount: Int
    /// Only for debugging and the 180-day orphan sweep; never a key.
    let lastKnownName: String
    let lastKnownPath: String
    /// base64 of the file bookmark — a location hint only, never a key.
    let bookmarkData: String
}

struct HighlightDocument: Codable, Equatable {
    let formatVersion: Int
    let fingerprint: DocumentFingerprint
    let updatedAt: Date
    /// In creation order.
    let highlights: [StoredHighlight]
}

/// The pure half: decode/validate, selection splitting, quads, orphan pruning.
enum HighlightStore {
    static let formatVersion = 1
    /// Orphan grace window (spec §2): the sidecar leaves only after this many
    /// days without the document opening AND with no file to point at.
    static let orphanAgeLimitDays = 180

    // MARK: - Decode / validate

    /// Tolerant reader. `nil`/empty/invalid JSON/bad UTF-8/missing or
    /// non-numeric `formatVersion` → `[]` — never throws, never assumes an
    /// erasure (the file stays; a future migrator decides). A FUTURE version is
    /// ignored whole ("ignore first, decode later").
    static func decode(_ data: Data?, pageCount: Int? = nil) -> [StoredHighlight] {
        guard let data, !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(
            HighlightDocument.self, from: data)
        else { return [] }
        // Written by this app? No version check means future formats would be
        // mangled into empty records below; keeping them dormant is the
        // documented behavior.
        guard document.formatVersion == formatVersion else { return [] }
        return validate(document.highlights, pageCount: pageCount)
    }

    /// Per-highlight validation: empty `quads`, negative `page`, out-of-document
    /// `page`, empty or duplicated `id`, non-finite or empty coordinate, empty
    /// color — the record drops, ITS NEIGHBORS STAY. Pure; the tests consume it
    /// directly, and the decoder above routes through it.
    static func validate(
        _ highlights: [StoredHighlight], pageCount: Int? = nil
    ) -> [StoredHighlight] {
        var seen = Set<String>()
        var kept: [StoredHighlight] = []
        kept.reserveCapacity(highlights.count)
        for record in highlights {
            guard record.page >= 0 else { continue }
            if let pageCount, record.page >= pageCount { continue }
            guard !record.quads.isEmpty else { continue }
            guard let id = normalizedID(record), seen.insert(id).inserted
            else { continue }
            guard record.quads.allSatisfy(finiteQuad) else { continue }
            guard !record.colorSlug.isEmpty else { continue }
            kept.append(record)
        }
        return kept
    }

    // MARK: - Selection → pages → quads

    /// One selection line clipped from PDFKit: the page it belongs to
    /// (`document.index(for: line.pages.first)`), its box in page space and its
    /// literal text.
    struct HighlightLine: Equatable {
        let page: Int
        let rect: CGRect
        let text: String
    }

    /// Per-page fold of the selection: one selection crossing pages becomes ONE
    /// record per page (spec §3), preserving the pages' first-appearance order.
    struct HighlightPageGroup: Equatable {
        let page: Int
        let rects: [CGRect]
        let text: String
    }

    static func groupLinesByPage(_ lines: [HighlightLine]) -> [HighlightPageGroup] {
        var order: [Int] = []
        var perPage: [Int: (rects: [CGRect], texts: [String])] = [:]
        for line in lines {
            if perPage[line.page] == nil {
                order.append(line.page)
                perPage[line.page] = ([], [])
            }
            perPage[line.page]!.rects.append(line.rect)
            perPage[line.page]!.texts.append(line.text)
        }
        return order.map { page in
            let gathered = perPage[page]!
            return HighlightPageGroup(
                page: page,
                rects: gathered.rects,
                text: gathered.texts.joined(separator: "\n"))
        }
    }

    /// Four vertices per line box, in the de-facto Adobe order the spec fixes:
    /// top-left → top-right → bottom-left → bottom-right (page space has the
    /// origin at the bottom-left, so "top" = the larger y). Degenerate boxes
    /// (zero width or height) come out empty and fall out of the record.
    static func quads(forLineRects rects: [CGRect], rotation: Int = 0) -> [[CGPoint]] {
        rects.map { rect in
            guard rect.width > 0, rect.height > 0 else { return [CGPoint]() }
            let rotated = rotate(rect, rotation: rotation)
            return [
                // T-L → T-R → B-L → B-R
                CGPoint(x: rotated.minX, y: rotated.maxY),
                CGPoint(x: rotated.maxX, y: rotated.maxY),
                CGPoint(x: rotated.minX, y: rotated.minY),
                CGPoint(x: rotated.maxX, y: rotated.minY),
            ]
        }
    }

    /// O inverso de `quads(forLineRects:)` para a PINTURA: um retângulo de
    /// linha por quad (`minX/minY/maxX/maxY` dos vértices), na mesma ordem dos
    /// quads. Quad degenerado (largura ou altura 0) sai da lista — a anotação
    /// de leitura também nunca pinta caixa nula.
    static func lineRects(forQuads quads: [[CGPoint]]) -> [CGRect] {
        quads.compactMap { quad in
            guard !quad.isEmpty else { return nil }
            var bounds = CGRect.null
            for vertex in quad {
                bounds = bounds.union(
                    CGRect(x: vertex.x, y: vertex.y, width: 0, height: 0))
            }
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return bounds
        }
    }

    /// Page rotation (`/Rotate 90/180/270`): Apple warns `bounds(for:)` may
    /// arrive already transformed; until the rotating-PDF script proves the
    /// live behavior, the transformation is deterministic and pivot-centered —
    /// the 90° case is pinned by a reference value in the tests and can be
    /// re-pinned after that script runs (spec §3, risk §9). Anything other
    /// than a 90° multiple is the identity.
    private static func rotate(_ rect: CGRect, rotation: Int) -> CGRect {
        let normalizedRotation = ((rotation % 360) + 360) % 360
        switch normalizedRotation {
        case 90:
            // 90° clockwise about the box's own center: the box keeps its
            // center and swaps width/height.
            return CGRect(
                x: rect.midX - rect.height / 2,
                y: rect.midY - rect.width / 2,
                width: rect.height,
                height: rect.width)
        case 180, 270:
            return rect
        default:
            return rect
        }
    }

    // MARK: - Orphan pruning

    /// The orphan decision (spec §2): the sidecar should be erased when the
    /// document went more than 180 days without opening AND neither the
    /// remembered path nor the bookmark resolves any file. Evaluated ONLY at
    /// opening and never blocking it (the sweep runs on the background queue).
    ///
    /// Signature note: the spec lists `ageInDays` AND `now`; reading them
    /// together, the age is computed from the sidecar's `updatedAt` against
    /// `now`, so the decision keeps a single clock and Past dates stay in test
    /// control.
    static func pruneDecision(
        lastKnownPath: String?,
        bookmark: String?,
        updatedAt: Date,
        now: Date
    ) -> Bool {
        let ageInDays = max(0, now.timeIntervalSince(updatedAt)) / 86_400
        guard ageInDays >= Double(orphanAgeLimitDays) else { return false }

        let fileManager = FileManager.default
        // A live document keeps its sidecar: the remembered path resolves.
        if let lastKnownPath, !lastKnownPath.isEmpty,
           fileManager.fileExists(atPath: lastKnownPath) {
            return false
        }
        // Same for a bookmark that still lands on a real file (a hint, never a
        // key): a sidecar whose hint resolves stays. A failed resolution never
        // counts as alive.
        if let bookmark, !bookmark.isEmpty,
           let data = Data(base64Encoded: bookmark) {
            // macOS needs the staleness out-param even when the app ignores it.
            var stale = false
            if let resolved = try? URL(
                   resolvingBookmarkData: data,
                   options: [],
                   relativeTo: nil,
                   bookmarkDataIsStale: &stale),
               fileManager.fileExists(atPath: resolved.path) {
                return false
            }
        }
        return true
    }
}

/// A stored id is real when it is non-empty (blank = the tolerant decoder
/// arrived at no value).
private func normalizedID(_ record: StoredHighlight) -> String? {
    record.id.isEmpty ? nil : record.id
}

/// A single quad (4 vertices) must be finite and complete; a NaN/∞ or absent
/// coordinate drops the record (`validate`).
private func finiteQuad(_ quad: [CGPoint]) -> Bool {
    quad.count == 4 && quad.allSatisfy { coordinate in
        coordinate.x.isFinite && coordinate.y.isFinite
    }
}

/// The content key: streaming SHA-256 of the whole file (hex), same digest
/// shape as `DiskCache.key` and one reading per open, off the main thread for
/// large PDFs.
enum HighlightKey {
    /// Streaming hash so a 100 MB PDF does not balloon memory; `nil` when the
    /// file is unreadable (the caller treats a missing key as "no sidecar yet").
    static func contentKey(of fileURL: URL) -> String? {
        let fileManager = FileManager.default
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let byteCount = attributes[.size] as? Int,
            byteCount > 0,
            let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
