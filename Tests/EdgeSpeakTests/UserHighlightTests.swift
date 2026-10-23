import Foundation
import CoreGraphics
import CryptoKit
import Testing
import PDFKit

@testable import EdgeSpeak

/// Pure suites of the user-highlight model and sidecar
/// (SPEC-DESTAQUES-2026-10-17 §7): format round-trip, quads, disk store,
/// orphan pruning — all without a living app, following
/// `PDFFollowTests` (pure decision) and `ResumeTests` (injectable storage).

private func record(
    id: String = "h1",
    page: Int = 0,
    quads: [[CGPoint]] = [[CGPoint(x: 10, y: 800), CGPoint(x: 500, y: 800),
                           CGPoint(x: 10, y: 790), CGPoint(x: 500, y: 790)]],
    text: String = "some passage",
    colorSlug: String = "magenta",
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> StoredHighlight {
    StoredHighlight(
        id: id, page: page, quads: quads, text: text,
        colorSlug: colorSlug, createdAt: createdAt)
}

private func document(
    formatVersion: Int = HighlightStore.formatVersion,
   	key: String = String(repeating: "a", count: 64),
    records: [StoredHighlight]
) -> HighlightDocument {
    HighlightDocument(
        formatVersion: formatVersion,
        fingerprint: DocumentFingerprint(
            contentSHA256: key, byteCount: 1024,
            lastKnownName: "sample.pdf", lastKnownPath: "/tmp/sample.pdf",
            bookmarkData: ""),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        highlights: records)
}

// MARK: - §7.1 HighlightFormatTests

/// Ida e volta do formato, versões futuras dormentes, JSON maculado → vazio e
/// validação que derruba SÓ o destaque inválido.
struct HighlightFormatTests {
    /// Whole-document round trip: what is written is what is read back,
    /// including the `createdAt` Date and the color slug.
    @Test func roundTripKeepsEveryField() throws {
        let original = document(records: [record(), record(
            id: "h2", page: 3, text: "segunda página",
            createdAt: Date(timeIntervalSince1970: 1_700_000_050))])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        #expect(HighlightStore.decode(data, pageCount: 10) == original.highlights)
    }

    /// A future formatVersion is dormant whole — never half-decoded. The
    /// encoder matches the FORMAT's contract (iso8601) so the version guard,
    /// not a date-strategy mismatch, is what yields the empty result.
    @Test func futureVersionYieldsEmpty() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document(formatVersion: 2, records: [record()]))
        #expect(HighlightStore.decode(data, pageCount: 10).isEmpty)
        #expect(HighlightStore.decode(data, pageCount: 10) == [])
    }

    /// Corrupt JSON, invalid UTF-8, empty file, nil data: empty, never a throw,
    /// never "delete the file".
    @Test func damagedPayloadsYieldEmptyWithoutThrow() {
        #expect(HighlightStore.decode(nil, pageCount: nil).isEmpty)
        #expect(HighlightStore.decode(Data(), pageCount: nil).isEmpty)
        #expect(HighlightStore.decode(Data("{\"formatVersion\":".utf8), pageCount: nil).isEmpty)
        // Invalid UTF-8 (a truncated multibyte sequence inside a JSON envelope).
        let badUTF8 = Data([0x7b, 0x7d, 0xff, 0xfe, 0x22])
        #expect(HighlightStore.decode(badUTF8, pageCount: nil).isEmpty)
    }

    /// `formatVersion` missing or non-numeric: the payload never becomes
    /// highlights (and nothing in this path erases the file — the READ side has
    /// no write).
    @Test func missingOrNonNumericVersionYieldsEmpty() {
        let key = String(repeating: "a", count: 64)
        let noVersion = Data("""
            {"fingerprint":{"contentSHA256":"\(key)","byteCount":1,"lastKnownName":"","lastKnownPath":"","bookmarkData":""},"updatedAt":"2026-01-01T00:00:00Z","highlights":[]}
            """.utf8)
        #expect(HighlightStore.decode(noVersion, pageCount: nil).isEmpty)

        let stringVersion = Data("""
            {"formatVersion":"two","fingerprint":{"contentSHA256":"\(key)","byteCount":1,"lastKnownName":"","lastKnownPath":"","bookmarkData":""},"updatedAt":"2026-01-01T00:00:00Z","highlights":[]}
            """.utf8)
        #expect(HighlightStore.decode(stringVersion, pageCount: nil).isEmpty)
    }

    /// Bad fields inside ONE highlight drop only that record; the neighbors
    /// stay. Null coordinates decode as empty quads, so they ride the same
    /// rule; a straight non-finite coordinate is caught by `validate`.
    @Test func invalidHighlightDroppedAlone() {
        let good = record(id: "good", page: 1)
        let input = [
            record(id: "noQuads", page: 1, quads: []),      // empty quads
            good,
            record(id: "negPage", page: -1),                // negative page
            good,
            record(id: "beyond", page: 9),                  // page beyond the count
            good,
            record(id: "", page: 1),                        // missing id
            good,
            record(id: "good", page: 1),                    // duplicated id
            good,
            record(id: "noColor", page: 1, colorSlug: ""),  // empty color
            good,
            record(id: "nullCoord", page: 1, quads: []),    // null coordinate
        ]
        #expect(HighlightStore.validate(input, pageCount: 5) == [good])
    }

    /// Non-finite coordinates (NaN/∞) drop the record too.
    @Test func validateKeepsFiniteCoordinatesOnly() {
        let good = record(id: "good")
        let infinite = record(id: "infinite", quads: [[
            CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: 1, y: 1),
            CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 3)]])
        let partial = record(id: "partial", quads: [[CGPoint(x: 0, y: 1)]])
        #expect(HighlightStore.validate([good, infinite, partial], pageCount: nil) == [good])
    }
}

// MARK: - §7.2 HighlightQuadsTests

/// The pure selection→quads path: 4 vertices per line box in the de-facto
/// Adobe order (T-L, T-R, B-L, B-R), degenerate boxes dropped, one record per
/// page, rotation 0 = identity, 90° pinned by reference value (§3).
struct HighlightQuadsTests {
    /// TL, TR, BL, BR from a page-space line box.
    @Test func cornerOrderIsTLTRBLBR() {
        let rect = CGRect(x: 40, y: 700, width: 200, height: 12)
        let quads = HighlightStore.quads(forLineRects: [rect])
        #expect(quads.count == 1)
        #expect(quads[0] == [
            CGPoint(x: 40, y: 712),   // T-L (top = larger y)
            CGPoint(x: 240, y: 712),  // T-R
            CGPoint(x: 40, y: 700),   // B-L
            CGPoint(x: 240, y: 700),  // B-R
        ])
    }

    /// Degenerate boxes fall out whole, keeping real ones.
    @Test func degenerateBoxDropped() {
        let rects = [
            CGRect(x: 10, y: 10, width: 0, height: 12),
            CGRect(x: 10, y: 10, width: 100, height: 0),
            CGRect(x: 10, y: 10, width: 100, height: 12),
        ]
        let quads = HighlightStore.quads(forLineRects: rects)
        #expect(quads[0].isEmpty)
        #expect(quads[1].isEmpty)
        #expect(quads[2].count == 4)
    }

    /// A selection across pages folds into one group per page, first seen
    /// first, with the page's lines kept together and its text kept.
    @Test func groupingByPageClothesTheWholeSelection() {
        let lines = [
            HighlightStore.HighlightLine(page: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10), text: "p1 line a"),
            HighlightStore.HighlightLine(page: 0, rect: CGRect(x: 0, y: 20, width: 10, height: 10), text: "p0 line a"),
            HighlightStore.HighlightLine(page: 1, rect: CGRect(x: 0, y: 10, width: 10, height: 10), text: "p1 line b"),
        ]
        let groups = HighlightStore.groupLinesByPage(lines)
        #expect(groups.map(\.page) == [1, 0])
        #expect(groups[0].rects.count == 2)
        #expect(groups[0].text == "p1 line a\np1 line b")
        #expect(groups[1].text == "p0 line a")
    }

    /// Rotation 0 (and any non-90 multiple) is the identity: the same corners
    /// as the unrotated call.
    @Test func rotationZeroIsIdentity() {
        let rect = CGRect(x: 40, y: 700, width: 200, height: 12)
        #expect(HighlightStore.quads(forLineRects: [rect], rotation: 0)
            == HighlightStore.quads(forLineRects: [rect]))
        #expect(HighlightStore.quads(forLineRects: [rect], rotation: 90)
            != HighlightStore.quads(forLineRects: [rect], rotation: 0))
    }

    /// The 90° case pinned by reference value (adjustable after the live
    /// rotating-PDF verification): pivot-centered, width/height swapped.
    @Test func rotation90PinnedReference() {
        let rect = CGRect(x: 40, y: 700, width: 200, height: 12)
        let quads = HighlightStore.quads(forLineRects: [rect], rotation: 90)
        #expect(quads.count == 1)
        // Center (140, 706) kept; width/height swapped → (134, 606, 12, 200).
        #expect(quads[0] == [
            CGPoint(x: 134.0, y: 806.0),   // T-L of the rotated box
            CGPoint(x: 146.0, y: 806.0),   // T-R
            CGPoint(x: 134.0, y: 606.0),   // B-L
            CGPoint(x: 146.0, y: 606.0),   // B-R
        ])
    }
}

// MARK: - §7.3 HighlightStoreTests

/// Keys, round trip in a real temp directory, corrupt file tolerated in place,
/// and the 1 s throttle with ONE pending write.
struct HighlightStoreTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-highlight-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The sidecar key is the CONTENT hash: the same bytes under two different
    /// paths share the key (the PDF moves/renames, the highlights follow), and
    /// different bytes diverge.
    @Test func keyIsContentNotPath() throws {
        let dir = tempDirectory("keys")
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data("same bytes em qualquer lugar\n%PDF-1.4".utf8)
        let first = dir.appendingPathComponent("original name.pdf")
        let second = dir.appendingPathComponent("moved and renamed.pdf")
        try content.write(to: first)
        try content.write(to: second)
        let other = dir.appendingPathComponent("other.pdf")
        try Data("diferente".utf8).write(to: other)

        guard let keyFirst = HighlightKey.contentKey(of: first),
              let keySecond = HighlightKey.contentKey(of: second),
              let keyOther = HighlightKey.contentKey(of: other)
        else {
            Issue.record("hash must not fail on a readable file")
            return
        }
        #expect(keyFirst == keySecond)
        #expect(keyFirst != keyOther)
        #expect(keyFirst.count == 64)
        // Hex of the independent digest — SHA-256("same bytes em qualquer lugar\n%PDF-1.4").
        let digest = SHA256.hash(data: content)
            .map { String(format: "%02x", $0) }.joined()
        #expect(keyFirst == digest)
    }

    /// Write → read round trip through a real (temp) directory.
    @Test func diskRoundTrip() {
        let dir = tempDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = String(repeating: "b", count: 64)
        let records = [record(id: "h1", page: 0), record(id: "h2", page: 2, text: "page two")]
        let doc = HighlightDiskStore.document(
            fingerprint: DocumentFingerprint(
                contentSHA256: key, byteCount: 5,
                lastKnownName: "x.pdf", lastKnownPath: "/x.pdf", bookmarkData: ""),
            highlights: records,
            now: Date(timeIntervalSince1970: 1_700_000_200))
        HighlightDiskStore.write(document: doc, directory: dir, key: key)

        let sidecarURL = HighlightDiskStore.sidecarURL(directory: dir, key: key)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let read = HighlightDiskStore.read(directory: dir, key: key, pageCount: 10)
        #expect(read == records)
        // An unknown key reads empty, never throws.
        #expect(HighlightDiskStore.read(
            directory: dir, key: String(repeating: "c", count: 64), pageCount: nil).isEmpty)
    }

    /// A corrupt sidecar on disk reads empty AND STAYS — deletion is never the
    /// reader's business.
    @Test func corruptFileReadsEmptyAndIsKept() throws {
        let dir = tempDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = String(repeating: "d", count: 64)
        let url = HighlightDiskStore.sidecarURL(directory: dir, key: key)
        try Data("{\"highlight\": [".utf8).write(to: url)
        #expect(HighlightDiskStore.read(directory: dir, key: key, pageCount: 5).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Throttle: two mutations inside the 1 s window coalesce into ONE pending
    /// write (none before it fires); after the window, exactly one write with
    /// both records. `flushNow` short-circuits the window.
    @Test func throttleCoalescesAndFlushShortCircuits() {
        let dir = tempDirectory("throttle")
        defer { try? FileManager.default.removeItem(at: dir) }
        var pending: [() -> Void] = []
        var clockNow = Date(timeIntervalSince1970: 1_000)
        let fingerprint = DocumentFingerprint(
            contentSHA256: String(repeating: "e", count: 64), byteCount: 9,
            lastKnownName: "sample.pdf", lastKnownPath: "/sample.pdf", bookmarkData: "")

        do {
            let storeWithFlush = HighlightSidecarStore(
                fingerprint: fingerprint, records: [], directory: dir,
                now: { clockNow },
                schedule: { _, block in pending.append(block) })
            storeWithFlush.add(record(id: "a1"))
            storeWithFlush.add(record(id: "a2"))
            // Inside the window: ONE coalesced write pending, nothing on disk yet.
            #expect(storeWithFlush.writeCount == 0)
            #expect(pending.count == 1)
            storeWithFlush.flushNow()
            #expect(storeWithFlush.writeCount == 1)
            let read = HighlightDiskStore.read(
                directory: dir, key: fingerprint.contentSHA256, pageCount: 10)
            #expect(read.map(\.id) == ["a1", "a2"])
            // A flush without dirt is a no-op.
            storeWithFlush.flushNow()
            #expect(storeWithFlush.writeCount == 1)
        }
        pending.removeAll()

        do {
            let storeCoalesced = HighlightSidecarStore(
                fingerprint: fingerprint, records: [], directory: dir,
                now: { clockNow },
                schedule: { _, block in pending.append(block) })
            storeCoalesced.add(record(id: "b1"))
            storeCoalesced.add(record(id: "b2"))
            #expect(storeCoalesced.writeCount == 0)
            clockNow = Date(timeIntervalSince1970: 1_100) // ahead of the window
            pending[0]()
            #expect(storeCoalesced.writeCount == 1)
            let read = HighlightDiskStore.read(
                directory: dir, key: fingerprint.contentSHA256, pageCount: 10)
            // A fresh store over the SAME sidecar is the documented
            // last-write-wins outcome: the file carries what THAT store held.
            #expect(read.map(\.id) == ["b1", "b2"])
        }
    }

    /// Removal persists too: add then remove inside two flushes leaves the
    /// final record set only.
    @Test func removalPersists() {
        let dir = tempDirectory("removal")
        defer { try? FileManager.default.removeItem(at: dir) }
        var pending: [() -> Void] = []
        let fingerprint = DocumentFingerprint(
            contentSHA256: String(repeating: "f", count: 64), byteCount: 9,
            lastKnownName: "sample.pdf", lastKnownPath: "/sample.pdf", bookmarkData: "")
        let store = HighlightSidecarStore(
            fingerprint: fingerprint, records: [record(id: "keep", page: 0)], directory: dir,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            schedule: { _, block in pending.append(block) })
        store.add(record(id: "temporary", page: 1))
        store.flushNow()
        store.remove("temporary")
        store.flushNow()
        #expect(store.records.map(\.id) == ["keep"])
        #expect(store.writeCount == 2)
        let read = HighlightDiskStore.read(
            directory: dir, key: fingerprint.contentSHA256, pageCount: 10)
        #expect(read.map(\.id) == ["keep"])
    }
}

// MARK: - §7.5 PruneTests

/// The orphan decision: >180 days stale AND no file behind the remembered hint
/// → remove; a live document or a young sidecar never goes.
struct PruneTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let alivePath: String = ("/tmp/edgespeak-prune-alive-\(UUID().uuidString).pdf")

    /// A file that exists blocks pruning no matter the age.
    @Test func liveDocumentKept() throws {
        try Data("pdf content".utf8).write(
            to: URL(fileURLWithPath: alivePath))
        defer { try? FileManager.default.removeItem(atPath: alivePath) }
        let old = now.addingTimeInterval(-400 * 86_400)
        #expect(!HighlightStore.pruneDecision(
            lastKnownPath: alivePath, bookmark: nil, updatedAt: old, now: now))
    }

    /// Dead remembered path + gone bookmark + 400 days → the sidecar leaves.
    @Test func deadOldOrphanPruned() {
        let old = now.addingTimeInterval(-400 * 86_400)
        #expect(HighlightStore.pruneDecision(
            lastKnownPath: "/Volumes/onde-o-arquivo-vivia/apagado.pdf",
            bookmark: nil,
            updatedAt: old, now: now))
    }

    /// Under 180 days the sidecar stays even with a dead path.
    @Test func youngOrphanKept() {
        let young = now.addingTimeInterval(-10 * 86_400)
        #expect(!HighlightStore.pruneDecision(
            lastKnownPath: "/inexistentemente/apagado.pdf",
            bookmark: nil,
            updatedAt: young, now: now))
    }

    /// Exactly at the limit the sidecar already goes (the spec's "after 180
    /// days"), and a non-empty stale bookmark that resolves keeps the sidecar.
    @Test func boundaryAndBookmark() throws {
        let boundary = now.addingTimeInterval(-180 * 86_400)
        #expect(HighlightStore.pruneDecision(
            lastKnownPath: nil, bookmark: nil, updatedAt: boundary, now: now))

        let emptyBookmarkWeak: String? = ""
        #expect(HighlightStore.pruneDecision(
            lastKnownPath: "/inexistente.pdf", bookmark: emptyBookmarkWeak,
            updatedAt: boundary, now: now))

        // A bookmark of a REAL file keeps the sidecar alive.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-prune-bookmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("real.pdf")
        try Data("pdf".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try target.bookmarkData().base64EncodedString()
        #expect(!HighlightStore.pruneDecision(
            lastKnownPath: "/intencionalmente-moved.pdf", bookmark: bookmark,
            updatedAt: now.addingTimeInterval(-400 * 86_400), now: now))
    }
}

// MARK: - §7.4 UserHighlightCleanupTests

/// A garantia da spec §6 em forma de teste: as anotações do usuário têm CASA
/// própria — nenhum caminho de limpeza do karaokê as alcança, e a assinatura
/// (textLabel/name) separa "meu" de "dele" até no menu de contexto.
struct UserHighlightCleanupTests {
    private func freshPage() -> PDFPage { PDFPage() }

    @Test func clearsNeverTouchUserAnnotations() {
        let page = freshPage()
        let userAnnots = PDFDocumentView.makeUserAnnotation(
            record(id: "u1"), on: page)
        #expect(!userAnnots.isEmpty)
        for annot in userAnnots { page.addAnnotation(annot) }
        var coordinator = PDFDocumentView.Coordinator()

        // O azul da frase na lista própria; a do usuário FORA dela (nunca
        // entra — ela só vive no mapa por id).
        let phraseAnnot = PDFAnnotation(
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
            forType: .highlight, withProperties: nil)
        page.addAnnotation(phraseAnnot)
        coordinator.phraseAnnotations = [phraseAnnot]
        coordinator.phrasePage = page
        PDFDocumentView.clearPhraseAnnotations(coordinator)
        #expect(coordinator.phraseAnnotations.isEmpty)
        #expect(userAnnots.allSatisfy { page.annotations.contains($0) })
        #expect(!coordinator.phraseAnnotations.contains { phrase in
            userAnnots.contains { $0 === phrase }
        })

        // A amarela da palavra: mesmo resultado.
        coordinator.attachUserHighlight(record: record(id: "u1"), on: page, notify: false)
        let wordAnnot = PDFAnnotation(
            bounds: CGRect(x: 0, y: 9, width: 8, height: 8),
            forType: .highlight, withProperties: nil)
        page.addAnnotation(wordAnnot)
        coordinator.wordAnnotation = wordAnnot
        coordinator.wordPage = page
        PDFDocumentView.clearWordAnnotation(coordinator)
        #expect(userAnnots.allSatisfy { page.annotations.contains($0) })
        #expect(coordinator.userRecords["u1"] != nil)
        #expect(coordinator.userAnnotations["u1"] != nil)
    }

    /// O separador é o VALOR: PDFKit preenche `textLabel` de anotação nova com
    /// o nome do usuário do Sistema (nunca `nil`), e a leitura/terceiros ficam
    /// com esse valor; só as nossas têm selo "EdgeSpeak" (menu, spec §6) e o id
    /// do registro em `.name`. A construção é POR LINHA: uma anotação por
    /// retângulo, cada uma assinada, nenhuma com `quadrilateralPoints`.
    @Test func signatureSplitsUserFromReading() {
        let page = freshPage()
        let labeled = PDFDocumentView.makeUserAnnotation(
            record(id: "s1"), on: page)
        #expect(!labeled.isEmpty)
        #expect(labeled.allSatisfy {
            $0.value(forAnnotationKey: .textLabel) as? String == HighlightMarks.owner
        })
        #expect(labeled.allSatisfy {
            $0.value(forAnnotationKey: .name) as? String == "s1"
        })
        // Anotação criada hoje no caminho de leitura (só bounds/color): PDFKit
        // autodeclara o autor, mas JAMAIS o selo "EdgeSpeak".
        let ephemeral = PDFAnnotation(
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            forType: .highlight, withProperties: nil)
        ephemeral.color = NSColor.controlAccentColor.withAlphaComponent(0.28)
        #expect(ephemeral.value(forAnnotationKey: .textLabel) as? String != HighlightMarks.owner)
    }
}

// MARK: - §7.5 UserHighlightLinePaintTests

/// A pintura POR LINHA do destaque do usuário (correção medida do ⌘⇧H): um
/// retângulo exato por quad, na ordem dos quads, sem `quadrilateralPoints` —
/// o PDFKit ao vivo e o poppler do export traduzem quads absolutos por
/// +bounds.origin, e a faixa saía deslocada; a construção por linha (mesmo
/// padrão da anotação de leitura) pintou exata no ensaio controlado.
struct UserHighlightLinePaintTests {
    /// Mesma ordem Adobe de `HighlightStore.quads(forLineRects:)` (T-L, T-R,
    /// B-L, B-R) — é o formato em que os quads vivem no sidecar.
    private func quad(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
        ]
    }

    /// Quad único → o retângulo EXATO de origem (ida e volta sem inset).
    @Test func singleQuadYieldsExactRect() {
        let rect = CGRect(x: 40, y: 700, width: 200, height: 12)
        #expect(HighlightStore.lineRects(forQuads: [quad(rect)]) == [rect])
    }

    /// Vários quads → um retângulo cada, na MESMA ordem (a ordem das linhas
    /// da seleção; a pintura não pode inverter nem agrupar).
    @Test func manyQuadsKeepOrder() {
        let boxes = [
            CGRect(x: 10, y: 800, width: 500, height: 10),
            CGRect(x: 10, y: 780, width: 480, height: 10),
            CGRect(x: 12, y: 760, width: 300, height: 14),
        ]
        #expect(HighlightStore.lineRects(forQuads: boxes.map(quad)) == boxes)
    }

    /// Degenerado (largura 0, altura 0, quad vazio) cai SOZINHO: os vizinhos
    /// continuam na lista, na posição original.
    @Test func degenerateQuadsDropAlone() {
        let keep = CGRect(x: 5, y: 5, width: 100, height: 8)
        let zeroWidth = CGRect(x: 5, y: 25, width: 0, height: 8)
        let zeroHeight = CGRect(x: 5, y: 45, width: 100, height: 0)
        let alsoKeep = CGRect(x: 5, y: 65, width: 90, height: 9)
        #expect(HighlightStore.lineRects(forQuads: [
            quad(keep), quad(zeroWidth), [], quad(zeroHeight), quad(alsoKeep),
        ]) == [keep, alsoKeep])
    }

    /// Uma anotação POR retângulo de linha, `bounds` EXATOS (o inset de -2 da
    /// construção antiga sumiu) e a assinatura + id em `.name` em CADA
    /// anotação — é o que faz o clique em qualquer linha achar o registro
    /// inteiro no menu de contexto.
    @Test func oneAnnotationPerLineExactBounds() {
        let rects = [
            CGRect(x: 40, y: 700, width: 200, height: 12),
            CGRect(x: 40, y: 684, width: 180, height: 12),
        ]
        let annots = PDFDocumentView.makeUserAnnotation(
            record(id: "p1", quads: rects.map(quad)), on: PDFPage())
        #expect(annots.count == rects.count)
        #expect(annots.map(\.bounds) == rects)
        #expect(annots.allSatisfy {
            $0.value(forAnnotationKey: .name) as? String == "p1"
                && $0.value(forAnnotationKey: .textLabel) as? String == HighlightMarks.owner
        })
    }
}
