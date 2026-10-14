import Foundation
import PDFKit

/// File import (.pdf/.md/.txt): single source of the reading sentences.
///
/// Assembles the sentence list with stable global index + page; the filtered
/// and integral texts derive from the SAME list (integral = no filter).
enum TextImport {
    /// One reading sentence: stable global index in the active list + page
    /// of origin (0-based; nil for text without PDF) + boxes of the lines the
    /// sentence occupies ([] without PDF).
    struct Phrase: Hashable, Sendable {
        struct WordBox: Hashable, Sendable {
            let text: String
            let rect: CGRect
            /// Page of the box (nil when unknown/test). Allows
            /// splitting the sentence at the page break instead of drawing
            /// two pages' boxes on the first.
            let page: Int?
            /// Superscript from the extractor (span flag or small+elevated).
            /// A note marker with `sup == true` always wins in
            /// `markerIndex`; without it, the textual regex applies as fallback.
            let sup: Bool

            /// Explicit `init` (not memberwise): in this toolchain, a member
            /// with a default does not enter the synthesized initializer.
            init(text: String, rect: CGRect, page: Int? = nil, sup: Bool = false) {
                self.text = text
                self.rect = rect
                self.page = page
                self.sup = sup
            }
        }
        let index: Int
        let text: String
        let page: Int?
        let rects: [CGRect]
        let words: [WordBox]
        let paragraphEnd: Bool
        /// Footnote note number when the sentence IS the body of a note
        /// (nil for running text). Filled by `resolveFootnotes`.
        let noteNumber: Int?
        /// Number of the note whose MARKER is in this sentence (nil without marker).
        /// Filled by `resolveFootnotes`: the announcement now comes from the
        /// pipeline (which disambiguated by geometry+sequence), not from
        /// `forSpeech`'s textual regex — which silences "mundo 7" and "teoria7".
        var noteMarker: Int?

        init(index: Int, text: String, page: Int?, rects: [CGRect], words: [WordBox] = [], paragraphEnd: Bool = false, noteNumber: Int? = nil, noteMarker: Int? = nil) {
            self.index = index
            self.text = text
            self.page = page
            self.rects = rects
            self.words = words
            self.paragraphEnd = paragraphEnd
            self.noteNumber = noteNumber
            self.noteMarker = noteMarker
        }
    }

    static func readDocument(url: URL) throws -> (
        filtered: String, integral: String, pdf: PDFDocument?,
        sentences: [Phrase], filteredSentences: [Phrase]
    ) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else {
                throw makeError(key: "error.cannotOpenPDF")
            }
            let extracted = PDFTextExtractor.extractSegments(doc)
            var segments = extracted.segmentos
            let pageRules = extracted.pageRules
            if segments.isEmpty {
                // No geometry layer: falls back to raw text per page.
                var parts: [String] = []
                for i in 0..<doc.pageCount {
                    if let s = doc.page(at: i)?.string, !s.isEmpty {
                        parts.append(s)
                    }
                }
                let joined = parts.joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { segments = [(joined, 0, [], [])] }
            }
            guard !segments.isEmpty else {
                throw makeError(key: "error.pdfWithoutTextLayer")
            }
            // ANALYSIS step between opening and transcribing: with the extracted
            // segments, it separates what is not running text (note bodies
            // linked to markers, loose labels discarded) before
            // splitting into reading sentences. This is where the next
            // separations live (dense formulas, captions) without touching the reader.
            let sentences = resolveFootnotes(makePhrases(from: segments.map { ($0.text, $0.page as Int?, $0.rects, $0.words.map { Phrase.WordBox(text: $0.text, rect: $0.box, page: $0.page, sup: $0.sup) }) }), pageRules: pageRules)
            let filteredSentences = resolveFootnotes(makePhrases(from: filtered(segments.map { ($0.text, $0.page as Int?, $0.rects, $0.words.map { Phrase.WordBox(text: $0.text, rect: $0.box, page: $0.page, sup: $0.sup) }) }, isPDF: true)), pageRules: pageRules)
            return (
                filtered: join(filteredSentences), integral: join(sentences), pdf: doc,
                sentences: sentences, filteredSentences: filteredSentences
            )
        case "md", "markdown", "txt", "text":
            let raw = try String(contentsOf: url, encoding: .utf8)
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw makeError(key: "error.emptyFile")
            }
            let base = normalizeMarkdown(raw)
            let sentences = makePhrases(from: [(base, nil, [], [])])
            let filteredSentences = makePhrases(from: filtered([(base, nil, [], [])], isPDF: false))
            return (
                filtered: join(filteredSentences), integral: join(sentences), pdf: nil,
                sentences: sentences, filteredSentences: filteredSentences
            )
        default:
            throw makeError(key: "error.unsupportedExtension", args: [ext])
        }
    }

    /// Error with a catalog key: the message comes from `L` in the current language and
    /// the key+args go in `userInfo` so `failureKey` re-resolves on
    /// language switch.
    private static func makeError(key: String, args: [Any] = []) -> NSError {
        NSError(domain: "EdgeSpeak", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.resolve(key, args: args),
                           "l10nKey": key, "l10nArgs": args])
    }

    /// Sentences of typed/pasted text (no file): same single integral flag.
    static func editorPhrases(_ text: String, integral: Bool) -> [Phrase] {
        let base = integral ? text : ReadAloudFilter.clean(text)
        return makePhrases(from: [(base, nil, [], [])])
    }

    // MARK: - Pipeline

    /// Cuts the bibliography (doc-scope rule), cleans per passage and preserves
    /// each one's page and boxes to split later.
    private static func filtered(
        _ segments: [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])], isPDF: Bool
    ) -> [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])] {
        var list = segments
        if let cut = ReadAloudFilter.bibliographyStart(in: list.map { $0.text }) {
            list = Array(list[..<cut])
        }
        return list.compactMap { seg in
            let cleaned = ReadAloudFilter.clean(seg.text, isPDF: isPDF)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : (cleaned, seg.page, seg.rects, seg.words)
        }
    }

    /// Splits the passages into sentences, with sequential global index. Each sentence
    /// gets the boxes of the lines it occupies (ordered matching of the
    /// sentence's tokens against the paragraph's words, grouped by line);
    /// with no matched box, it inherits the paragraph's boxes. `words`
    /// remains the paragraph's words (the karaoke matches by text).
    /// The last sentence of each block marks the paragraph's end.
    /// Internal for testing (TextImportTests builds synthetic segments).
    static func makePhrases(from segments: [(text: String, page: Int?, rects: [CGRect], words: [Phrase.WordBox])]) -> [Phrase] {
        var out: [Phrase] = []
        for seg in segments {
            var cursor = 0
            let blocks = seg.text.components(separatedBy: .newlines)
            for block in blocks {
                let t = block.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let sentences = splitSentences(t)
                for (i, sentence) in sentences.enumerated() {
                    let matched = boxesForSentence(sentence, words: seg.words, cursor: &cursor)
                    let passages = passagesPerPage(
                        sentence: sentence, matched: matched, defaultPage: seg.page)
                    if passages.isEmpty {
                        out.append(Phrase(
                            index: out.count, text: sentence, page: seg.page,
                            rects: seg.rects, words: seg.words,
                            paragraphEnd: i == sentences.count - 1))
                        continue
                    }
                    // One sentence, one page: each passage takes only the boxes
                    // and words of its page; only the last one inherits the end.
                    for (k, passage) in passages.enumerated() {
                        let last = k == passages.count - 1
                        let page = passage.page ?? seg.page
                        out.append(Phrase(
                            index: out.count, text: passage.text,
                            page: page,
                            rects: passage.wordBoxes.isEmpty ? seg.rects : passage.wordBoxes,
                            words: seg.words.filter { $0.page == nil || $0.page == page },
                            paragraphEnd: last && i == sentences.count - 1))
                    }
                }
            }
        }
        return out
    }

    /// Links footnote bodies to their markers, in the same list.
///
/// General rule (applies to every PDF): period + superscript number is a marker;
/// the body lives in the page footer (or in endnotes, at the end of the
/// document). What it does here:
/// - a loose 1–2 digit number with a page (label without body, like the
///   test article's "1".."15") is discarded — read, it would become "one";
/// - a body ("12 Authors, ...", number + long text) looks for marker N on the
///   same page and, missing it, the nearest previous marker in the document
///   (covers endnotes); when found, it loses the number and goes right after the
///   marker's sentence — it is read right after the announcement, as the owner asked;
/// - without a marker, the body stays intact where it is (it may be a date or
///   enumeration: touching it would be corruption, and the reading stays correct).
///
/// Documented difficulty (2026-10-13, measured on the test article): the body
/// may simply NOT exist in the file — neither in the text layer, nor
/// in annotation, image, drawing or a mapless glyph (only the loose numbers in
/// the footer, with no smaller font betraying a body). In that case there is nothing to read
/// after the announcement, and nothing is invented: the marker is announced and the text
/// goes on. Verified by inspection (font sizes across the whole document,
/// rawdict of the footer, last pages with only bibliography).
/// The indices of the remaining sentences do NOT change (they are property, not position)
/// — highlight and jump by index still hold.
    /// - `rules`: rule top per page (PDFKit coords). With a rule, only
    ///   what is BELOW it is note zone: a loose number above is
    ///   content and stays; a body above the rule is not even a candidate. Without a rule,
    ///   the old heuristics apply. Empty default (tests, no-Python path).
    static func resolveFootnotes(_ phrases: [Phrase], pageRules: [Int: CGFloat] = [:]) -> [Phrase] {
        /// Top of the sentence (larger y in PDFKit coords); nil without geometry.
        func topo(_ ph: Phrase) -> CGFloat? { ph.rects.map(\.maxY).max() }
        /// In the note zone: below the page's rule (or with no way to know).
        func isNotesZone(_ ph: Phrase) -> Bool {
            guard let pg = ph.page, let ry = pageRules[pg] else { return true }
            guard let t = topo(ph) else { return true }
            return t < ry
        }
        var list = phrases.filter { ph in
            guard ph.page != nil else { return true }
            let t = ph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count <= 2, Int(t) != nil else { return true }
            // Loose number: with a rule, it only disappears below it (above it may be
            // content); without a rule, it disappears as before (label without body).
            if let pg = ph.page, pageRules[pg] != nil {
                return !isNotesZone(ph)
            }
            return false
        }
        struct Body {
            var number: Int
            var text: String
            var sentence: Phrase
            /// Continuations of the same note (same page, below the ruler,
            /// no new number). The PDF interleaves each note line as its own
            /// segment; without taking them along, only the first sentence goes
            /// to the marker and the rest of the note stays in the page flow.
            var continuations: [Phrase] = []
        }
        var bodies: [Body] = []
        for ph in list {
            guard ph.page != nil, ph.noteNumber == nil else { continue }
            // With a rule on the page, a body is only below it (a date in
            // running text never becomes a body, even with a number in front).
            if let pg = ph.page, pageRules[pg] != nil, !isNotesZone(ph) { continue }
            let t = ph.text.drop(while: { $0.isWhitespace })
            let digits = String(t.prefix(while: { $0.isNumber }))
            guard (1...2).contains(digits.count), let n = Int(digits) else { continue }
            let remainder = t.dropFirst(digits.count)
            // BELOW the rule, the number comes glued to the text ("1The first
            // edition..."): a note body, not running text. The extractor already
            // marked these lines by smaller font (edgeparse-core heuristic)
            // and the synthetic rule delimits them; here only the glued form with a
            // note mark is accepted. It requires a letter right after the digit, which is the shape of the
            // glued marker ("1The"); `digits.count <= 2` already excludes a year
            // ("2024 The") and a digit followed by punctuation ("12.)") is not a letter.
            // ABOVE the rule (or with no rule), the old rule holds: it requires
            // number + space, so it does not eat a date or an enumeration in the body.
            let belowRule = pageRules[ph.page ?? -1] != nil && isNotesZone(ph)
            let gluedBody: Substring
            if belowRule,
               digits.count <= 2,
               let firstChar = remainder.first, firstChar.isLetter,
               remainder.count >= 12 {
                gluedBody = remainder
            } else {
                guard remainder.first?.isWhitespace == true else { continue } // "12."/"12)" is not a body
                gluedBody = remainder.drop(while: { $0.isWhitespace })
            }
            guard gluedBody.count >= 12 else { continue }
            var continuations: [Phrase] = []
            if belowRule, let pg = ph.page, let ry = pageRules[pg] {
                var j = ph.index + 1
                while let nextPhrase = list.first(where: { $0.index == j }), nextPhrase.page == pg {
                    guard let nextTop = nextPhrase.rects.map(\.maxY).max(), nextTop < ry else { break }
                    if nextPhrase.text.drop(while: { $0.isWhitespace }).first?.isNumber == true { break }
                    continuations.append(nextPhrase)
                    j += 1
                }
            }
            bodies.append(Body(number: n, text: String(gluedBody), sentence: ph, continuations: continuations))
        }
        // Ascending number order (archilles-scriptor technique): the search
        // for N+1 resumes after N's marker — a lost digit is never
        // substituted. Positions rederived at each body (moving shifts them):
        // storing position ruins the following ones.
        var limit = -1
        for bodyText in bodies.sorted(by: { $0.number < $1.number }) {
            guard let currentPos = list.firstIndex(where: { $0.index == bodyText.sentence.index })
            else { continue }
            guard let markerIndex = markerIndex(
                number: bodyText.number, page: bodyText.sentence.page,
                upToPos: currentPos, afterPos: limit, within: list,
                excludingIndex: bodyText.sentence.index)
            else {
                // No marker, but below the rule: a body without anchor (there are
                // several notes per page) — remove the number and mark, without
                // moving. Sequential numbering confirms it: a loose number
                // below the rule is a note, not running text.
                if let pg = bodyText.sentence.page, let ry = pageRules[pg],
                   let t = bodyText.sentence.rects.map(\.maxY).max(), t < ry {
                    list[currentPos] = Phrase(
                        index: bodyText.sentence.index, text: bodyText.text,
                        page: bodyText.sentence.page, rects: bodyText.sentence.rects,
                        words: bodyText.sentence.words,
                        paragraphEnd: bodyText.sentence.paragraphEnd,
                        noteNumber: bodyText.number)
                }
                continue
            }
            guard let markerPos = list.firstIndex(where: { $0.index == markerIndex })
            else { continue }
            // The note announcement comes from the pipeline, not the textual regex:
            // marks the marker's sentence for `forSpeech` (first link wins).
            if list[markerPos].noteMarker == nil { list[markerPos].noteMarker = bodyText.number }
            // Lifts the body and ALL continuations at once (removing by index
            // shifts the following ones; collecting first avoids skipping lines).
            let idxs = ([bodyText.sentence.index] + bodyText.continuations.map(\.index)).sorted()
            // The anchor cannot be inside the block: removal would take the
            // marker along and there would be nowhere to insert (stays put).
            guard !idxs.contains(markerIndex) else { continue }
            // Removals BEFORE the marker change its position (body or
            // continuations in an earlier position — marker after the body,
            // same-page search with no ceiling). Counts all of them; markerPos alone
            // would cover a single removal and the note would land shifted.
            let removalsBeforeMarker = idxs.filter { ix in
                list.firstIndex(where: { $0.index == ix }).map { $0 < markerPos } ?? false
            }.count
            var blocks: [Phrase] = []
            for ix in idxs {
                if let p = list.firstIndex(where: { $0.index == ix }) {
                    blocks.append(list.remove(at: p))
                }
            }
            guard !blocks.isEmpty else { continue }
            // The first line becomes the numberless body; the rest enter with
            // the same number, read right after, in footer order.
            var joinedPhrases = [Phrase(
                index: bodyText.sentence.index, text: bodyText.text,
                page: bodyText.sentence.page, rects: bodyText.sentence.rects,
                words: bodyText.sentence.words,
                paragraphEnd: bodyText.continuations.isEmpty,
                noteNumber: bodyText.number)]
            for c in bodyText.continuations {
                joinedPhrases.append(Phrase(
                    index: c.index, text: c.text, page: c.page,
                    rects: c.rects, words: c.words,
                    paragraphEnd: false, noteNumber: bodyText.number))
            }
            // Real anchor after removals: the body goes in exactly after the
            // marker's sentence, and the N+1 search resumes from it.
            let anchor = markerPos - removalsBeforeMarker
            let target = min(anchor + 1, list.count)
            list.insert(contentsOf: joinedPhrases, at: target)
            limit = anchor
        }
        return list
    }


    /// Position of the sentence with marker N: same page first (in order),
    /// else the nearest previous one in the document (endnotes). `nil` without
    /// a marker — and with no marker nothing moves.
    ///
    /// The geometric signal (`sup`) always wins: a superscripted word with the
    /// number N is a marker even without textual glue (".7"/",7"/"o7"). The
    /// textual regex remains as fallback (no-PyMuPDF path, no `sup`).
    private static func markerIndex(
        number n: Int, page: Int?, upToPos: Int, afterPos limit: Int,
        within list: [Phrase], excludingIndex: Int
    ) -> Int? {
        let ns = String(n)
        // Superscripted word whose core is exactly N ("7", "7.", ".7"), or a
        // glued token ending in N with punctuation before it ("realist’s.1"
        // for N=1, "commitment.10" for N=10). The punctuation boundary keeps
        // "evidence.11" (digit before) and "mp3" (letter before) from matching
        // N=1/N=3. `sup` already gates to marker-looking spans, so this only
        // extends geometric recall where the textual reserve would miss.
        // A sentence only carries geometric support when the marker's digits
        // are IN its own text: `makePhrases` leaves every sentence with the
        // whole paragraph's boxes, so without this gate the FIRST sentence of
        // a paragraph always wins and the body lands one sentence early (read:
        // note 2's body after "phenomenon." instead of after "true.2", with a
        // second textual announcement at the real marker).
        func hasSupport(_ ph: Phrase) -> Bool {
            ph.words.contains { w in
                guard w.sup else { return false }
                let raw = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let core = raw.trimmingCharacters(in: .punctuationCharacters)
                let present = ph.text.contains(raw) || ph.text.contains(core) || core == ns
                guard present else { return false }
                if core == ns { return true }
                guard raw.hasSuffix(ns), raw.count > ns.count else { return false }
                let idx = raw.index(raw.endIndex, offsetBy: -ns.count)
                let prev = raw[raw.index(before: idx)]
                return !prev.isLetter && !prev.isNumber
            }
        }
        if let page {
            for (i, ph) in list.enumerated()
            where i > limit && ph.index != excludingIndex && ph.page == page {
                if hasSupport(ph) { return ph.index }
            }
        }
        if upToPos - 1 >= limit + 1 {
            for i in stride(from: upToPos - 1, through: limit + 1, by: -1) {
                if hasSupport(list[i]) { return list[i].index }
            }
        }
        // Textual fallback (no-PyMuPDF path, no `sup`).
        let patterns = [
            #"(?<=[A-Za-zÀ-ÿ\)\]"'”’])\."# + ns + #"(?![\dA-Za-zÀ-ÿ.])"#,
            #"(?<=[A-Za-zÀ-ÿ\)\]"'”’]),"# + ns + #"(?![\dA-Za-zÀ-ÿ.])"#,
            #"([A-Za-zÀ-ÿ]{2,}[a-zà-ÿ])"# + ns + #"(?![\dA-Za-zÀ-ÿ.])"#,
        ]
        let res = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        func has(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            return res.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
        }
        if let page {
            for (i, ph) in list.enumerated()
            where i > limit && ph.index != excludingIndex && ph.page == page {
                if has(ph.text) { return ph.index }
            }
        }
        if upToPos - 1 >= limit + 1 {
            for i in stride(from: upToPos - 1, through: limit + 1, by: -1) {
                if has(list[i].text) { return list[i].index }
            }
        }
        return nil
    }

    /// Lowercase, letters and digits only: same normalization as the karaoke.
    /// NFKC first: ligature "ﬁ" becomes "fi" (research §6 — without this, the token
    /// never matches the box).
    static func normalizedWord(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Matches the sentence's tokens with the boxes, in order. Returns, per matched
    /// token, the token position, the box and the page. Internal for testing.
    ///
    /// Each token is searched from the cursor; a miss is skipped without
    /// shifting the cursor. End-of-line hyphen has two extra attempts,
    /// neither consuming on failure:
    /// - raw text ("procu-", "rar") against a joined box ("procurar"):
    ///   token without the "-" plus the next one, joined;
    /// - joined text ("procurar", e.g. old JSON) against split boxes:
    ///   token against the next 2 boxes joined (hyphens aside), with the
    ///   union as the box.
    /// Without this, the hyphenated sentence fell into the whole paragraph's boxes.
    static func boxesForSentence(
        _ sentence: String, words: [Phrase.WordBox], cursor: inout Int
    ) -> [(token: Int, box: CGRect, page: Int?)] {
        var matched: [(token: Int, box: CGRect, page: Int?)] = []
        let tokens = sentence.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var t = 0
        while t < tokens.count {
            let needle = normalizedWord(tokens[t])
            guard !needle.isEmpty else { t += 1; continue }
            var found: Int?
            for j in cursor..<words.count
            where normalizedWord(words[j].text) == needle {
                found = j
                break
            }
            if let j = found {
                matched.append((token: t, box: words[j].rect, page: words[j].page))
                cursor = j + 1
                t += 1
                continue
            }
            // Raw text against joined box.
            if tokens[t].hasSuffix("-"), t + 1 < tokens.count {
                let junto = normalizedWord(String(tokens[t].dropLast()))
                    + normalizedWord(tokens[t + 1])
                if !junto.isEmpty {
                    var found = false
                    for j in cursor..<words.count
                    where normalizedWord(words[j].text) == junto {
                        matched.append((token: t, box: words[j].rect, page: words[j].page))
                        cursor = j + 1
                        t += 2
                        found = true
                        break
                    }
                    if found { continue }
                }
            }
            // Joined text against split boxes (next 2).
            if cursor + 1 < words.count {
                let secondWord = normalizedWord(words[cursor].text)
                    + normalizedWord(words[cursor + 1].text)
                if !secondWord.isEmpty, secondWord == needle {
                    let unionRect = words[cursor].rect.union(words[cursor + 1].rect)
                    matched.append((
                        token: t, box: unionRect,
                        page: words[cursor].page ?? words[cursor + 1].page))
                    cursor += 2
                    t += 1
                    continue
                }
            }
            t += 1
        }
        return matched
    }

    /// Splits the sentence at the page break: returns (text, page, boxes)
    /// per passage, in order. No break, one passage. Internal for testing.
    ///
    /// Why split (research §5): the text joins to narrate, but a
    /// box never crosses pages — before, the sentence carried the first
    /// page's boxes and the highlight came out on the wrong page.
    static func passagesPerPage(
        sentence: String,
        matched: [(token: Int, box: CGRect, page: Int?)],
        defaultPage: Int?
    ) -> [(text: String, page: Int?, wordBoxes: [CGRect])] {
        let tokens = sentence.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Page per token: that of the matched box; with no box, inherits the previous.
        var pagePerToken = [Int?](repeating: nil, count: tokens.count)
        var current = defaultPage
        var c = 0
        for t in 0..<tokens.count {
            while c < matched.count, matched[c].token < t { c += 1 }
            if c < matched.count, matched[c].token == t, let pg = matched[c].page {
                current = pg
            }
            pagePerToken[t] = current
        }
        // Groups consecutive same-page ones.
        var passages: [(text: String, page: Int?, wordBoxes: [CGRect])] = []
        var startIndex = 0
        for t in 1...tokens.count {
            if t == tokens.count || pagePerToken[t] != pagePerToken[startIndex] {
                let range = Array(tokens[startIndex..<t])
                let wordBoxes = matched
                    .filter { $0.token >= startIndex && $0.token < t }
                    .map(\.box)
                passages.append((
                    text: range.joined(separator: " "),
                    page: pagePerToken[startIndex],
                    wordBoxes: groupByLine(wordBoxes)))
                startIndex = t
            }
        }
        return passages
    }

    /// Groups boxes by line (vertical overlap above half of the
    /// smaller height) and unions minX/minY/maxX/maxY per line.
    private static func groupByLine(_ boxes: [CGRect]) -> [CGRect] {
        var rows: [CGRect] = []
        for box in boxes {
            var placed = false
            for i in rows.indices {
                let row = rows[i]
                let overlap = min(row.maxY, box.maxY) - max(row.minY, box.minY)
                let minHeight = min(row.height, box.height)
                let sameLine: Bool = if minHeight <= 0 {
                    abs(row.midY - box.midY) < 1.0
                } else {
                    overlap > 0.5 * minHeight
                }
                if sameLine {
                    rows[i] = row.union(box)
                    placed = true
                    break
                }
            }
            if !placed { rows.append(box) }
        }
        return rows.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    private static func join(_ phrases: [Phrase]) -> String {
        phrases.map { $0.text }.joined(separator: "\n")
    }

    /// Splits a text into sentences by terminal punctuation followed by uppercase.
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        let blocks = text.components(separatedBy: .newlines)
        let pattern = #"(?<=[.!?…])\s+(?=[A-ZÀ-Ú0-9\(\["“'«])"#
        let re = try? NSRegularExpression(pattern: pattern, options: [])
        for block in blocks {
            let t = block.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            guard let re else { out.append(t); continue }
            var parts: [String] = []
            var start = t.startIndex
            let ns = NSRange(t.startIndex..., in: t)
            for m in re.matches(in: t, options: [], range: ns) {
                guard let r = Range(m.range, in: t) else { continue }
                parts.append(String(t[start..<r.lowerBound]))
                start = r.upperBound
            }
            parts.append(String(t[start...]))
            for p in parts {
                let s = p.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
            }
        }
        return out
    }

    /// Light markdown normalization for speech.
    static func normalizeMarkdown(_ s: String) -> String {
        var out = s
        // Remove code fences (``` ... ```), keeping the inner content.
        out = out.replacingOccurrences(of: "```", with: "")
        // [text](url) -> text
        if let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#, options: []) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        // Remove line-start markup (# * > - and numbered "1. ").
        var lines: [String] = []
        for line in out.components(separatedBy: "\n") {
            var l = line
            if let re = try? NSRegularExpression(pattern: #"^\s*(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)"#, options: []) {
                l = re.stringByReplacingMatches(
                    in: l, options: [],
                    range: NSRange(l.startIndex..., in: l), withTemplate: "")
            }
            lines.append(l)
        }
        out = lines.joined(separator: "\n")
        // Remove inline backticks and asterisks/underscores.
        out = out.replacingOccurrences(of: "`", with: "")
        if let re = try? NSRegularExpression(pattern: #"(\*\*|__|\*|_)"#, options: []) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Collapse 3+ blank lines into 2.
        if let re = try? NSRegularExpression(pattern: #"\n{3,}"#, options: []) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
