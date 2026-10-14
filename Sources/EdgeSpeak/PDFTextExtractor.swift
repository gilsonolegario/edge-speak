import Foundation
import PDFKit

/// Extracts the text of a PDF in **reading order**, regrouping by geometry.
///
/// `PDFPage.string` returns the text line by line, in print order —
/// each visual break becomes a `\n`. That chopped the reading, and worse: on
/// **two-column** pages the print order alternates left/right, which
/// shuffles the text. Here each line comes with its box, and the order is
/// rebuilt by **recursive cut (XY-cut)**: the page is split by the largest
/// horizontal gutter (bands) and vertical (columns), top to bottom and
/// left to right, until no gutter remains. Thus a two-column page
/// is read as a whole left column, then the right one.
///
/// Headers and footers are removed by frequency (same text on several pages) and
/// by being in the margin band.
enum PDFTextExtractor {

    /// One printed line, with the box PDFKit reports (origin at the
    /// page's bottom-left corner).
    private struct Line {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        let page: Int
        /// Line words with boxes (via PyMuPDF); empty on the PDFKit path.
        var words: [(text: String, box: CGRect, page: Int, sup: Bool)] = []
        /// Bounds of the column the line belongs to, defined in
        /// reading order (XY-cut). Without this, indent and "full line" would be measured
        /// against the whole page width and would fail on two columns.
        var colLeft: CGFloat = 0
        var colRight: CGFloat = 0

    var width: CGFloat { maxX - minX }
    /// Line box in page coordinates (origin at the bottom-
    /// left), for the geometric highlight.
    var box: CGRect {
        CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
        var columnWidth: CGFloat { max(1, colRight - colLeft) }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func extract(_ document: PDFDocument) -> String {
        extractSegments(document).segmentos.map { $0.text }.joined(separator: "\n")
    }

    /// Paragraphs with page and line boxes (0-based), for the per-page
    /// geometric highlight.
    ///
    /// The XY-cut, header/footer, paragraph and hyphen logic is the same as
    /// `extract`: the page is that of each paragraph's first line, and the
    /// rects are only from that page (the rest of the crossing is ignored).
    /// Segments + per-note-rule page (top in PDFKit coords, only on
    /// pages with a rule). The rule tells the note zone; without it, the
    /// number+position heuristics apply.
    static func extractSegments(_ document: PDFDocument) -> (
        segmentos: [(text: String, page: Int, rects: [CGRect], words: [(text: String, box: CGRect, page: Int, sup: Bool)])],
        pageRules: [Int: CGFloat]
    ) {
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }

        var perPage: [[Line]] = []
        var pageRules: [Int: CGFloat] = [:]
        // PyMuPDF first (words with boxes: no glued words);
        // PDFKit as fallback (no Python or no PyMuPDF).
        if let url = document.documentURL,
           let ext = PdfWords.linesRules(pdfURL: url, pageCount: document.pageCount),
           ext.count == pages.count {
            perPage = ext.enumerated().map { (i, page) in
                page.lines.compactMap { lineFromExternal(text: $0.text, box: $0.box, words: $0.words.map { (text: $0.text, box: $0.box, page: i, sup: $0.sup) }, pageIndex: i) }
            }
            for (i, page) in ext.enumerated() {
                if let ry = page.ruleY { pageRules[i] = ry }
            }
        } else {
            for (index, page) in pages.enumerated() {
                perPage.append(lines(of: page, pageIndex: index))
            }
        }
        var heights: [CGFloat] = []
        for page in pages {
            heights.append(page.bounds(for: .mediaBox).height)
        }

        let repeated = repeatedKeys(perPage)
        let leading = median(spacings(of: perPage)) ?? 12

        var ordered: [Line] = []
        for (index, pageLines) in perPage.enumerated() {
            var kept: [Line] = []
            for line in pageLines {
                let text = line.trimmed
                if text.isEmpty { continue }
                if repeated.contains(repeatedKey(text)) { continue }
                if isMarginNoise(text, line: line, pageHeight: heights[index]) { continue }
                kept.append(line)
            }
            ordered.append(contentsOf: readingOrder(kept, leading: leading))
        }

        return (paragraphs(from: ordered, leading: leading), pageRules)
    }

    // MARK: - Lines

    private static func lines(of page: PDFPage, pageIndex: Int) -> [Line] {
        let crop = page.bounds(for: .cropBox)
        let rect = crop.isEmpty ? page.bounds(for: .mediaBox) : crop
        guard let selection = page.selection(for: rect) else { return [] }

        var out: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            let raw = (lineSelection.string ?? "").replacingOccurrences(of: "\n", with: " ")
            let box = lineSelection.bounds(for: page)
            // The note's superscript index ("(314).⁴") glues to the end of the line and
            // hides the punctuation: without removing it, the line does not "close a sentence" and the
            // footnote is appended to the previous paragraph.
            let withoutNoteMarkers = raw.replacingOccurrences(
                of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#, with: "", options: .regularExpression)
            let trimmed = withoutNoteMarkers.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, box.width > 0, box.height > 0 else { continue }
            out.append(Line(
                text: withoutNoteMarkers,
                minX: box.minX,
                maxX: box.maxX,
                minY: box.minY,
                maxY: box.maxY,
                page: pageIndex
            ))
        }
        // Top first. PDFKit does not guarantee the order; geometry does.
        out.sort { lhs, rhs in
            if abs(lhs.minY - rhs.minY) > 1 { return lhs.minY > rhs.minY }
            return lhs.minX < rhs.minX
        }
        return out
    }

    /// A line from PyMuPDF, with the same treatment as the PDFKit path
    /// (removes note index, discards empty). Nil = discard.
    private static func lineFromExternal(text: String, box: CGRect, words: [(text: String, box: CGRect, page: Int, sup: Bool)], pageIndex: Int) -> Line? {
        let withoutNoteMarkers = text.replacingOccurrences(
            of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#, with: "", options: .regularExpression)
        let trimmed = withoutNoteMarkers.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Line(
            text: withoutNoteMarkers,
            minX: box.minX,
            maxX: box.maxX,
            minY: box.minY,
            maxY: box.maxY,
            page: pageIndex,
            words: words
        )
    }

    // MARK: - Reading order (XY-cut)

    /// Sorts a page's lines by the largest gutter, first vertical
    /// (columns), then horizontal (bands). Choosing the vertical gutter
    /// first is what makes a two-column page be read column by column;
    /// a full-width title "sews" the gutter and forces the horizontal cut
    /// earlier — which is exactly what one wants.
    private static func readingOrder(_ lines: [Line], leading: CGFloat) -> [Line] {
        guard lines.count > 1 else { return leaf(lines) }

        if let (left, right) = splitVertically(lines, minGap: max(12, leading)) {
            return readingOrder(left, leading: leading) + readingOrder(right, leading: leading)
        }
        if let (top, bottom) = splitHorizontally(lines, minGap: leading * 1.25) {
            return readingOrder(top, leading: leading) + readingOrder(bottom, leading: leading)
        }
        return leaf(lines)
    }

    /// Leaf: no useful gutter. Sorts top→bottom (and left→right for lines
    /// at the same height) and marks the column as the block's own box.
    private static func leaf(_ lines: [Line]) -> [Line] {
        let left = lines.map { $0.minX }.min() ?? 0
        let right = lines.map { $0.maxX }.max() ?? 0
        return lines
            .sorted { lhs, rhs in
                if abs(lhs.maxY - rhs.maxY) > 1 { return lhs.maxY > rhs.maxY }
                return lhs.minX < rhs.minX
            }
            .map { line in
                var copy = line
                copy.colLeft = left
                copy.colRight = right
                return copy
            }
    }

    /// Splits into columns by a clean vertical gutter (no line crosses it),
    /// requiring at least three lines on each side — so a weak heuristic
    /// does not cut a single-column page.
    private static func splitVertically(_ lines: [Line], minGap: CGFloat) -> ([Line], [Line])? {
        guard let g = largestGap(lines.map { (lo: $0.minX, hi: $0.maxX) }),
              g.gap >= minGap else { return nil }
        let left = lines.filter { $0.maxX <= g.cut }
        let right = lines.filter { $0.minX >= g.cut }
        guard left.count >= 3, right.count >= 3, left.count + right.count == lines.count else {
            return nil
        }
        return (left, right)
    }

    /// Splits into bands by a clean horizontal gutter (title × body, body ×
    /// footer already removed).
    private static func splitHorizontally(_ lines: [Line], minGap: CGFloat) -> ([Line], [Line])? {
        guard let g = largestGap(lines.map { (lo: $0.minY, hi: $0.maxY) }),
              g.gap >= minGap else { return nil }
        let top = lines.filter { $0.minY >= g.cut }
        let bottom = lines.filter { $0.maxY <= g.cut }
        guard !top.isEmpty, !bottom.isEmpty, top.count + bottom.count == lines.count else {
            return nil
        }
        return (top, bottom)
    }

    /// Largest gap with no box, among intervals `(lo, hi)`. Returns the gap and
    /// the cut coordinate in the middle of it.
    private static func largestGap(_ intervals: [(lo: CGFloat, hi: CGFloat)]) -> (gap: CGFloat, cut: CGFloat)? {
        guard intervals.count > 1 else { return nil }
        let sorted = intervals.sorted { $0.lo < $1.lo }
        var hiSoFar = sorted[0].hi
        var best: (gap: CGFloat, cut: CGFloat)?
        for i in 1..<sorted.count {
            let gap = sorted[i].lo - hiSoFar
            if gap > (best?.gap ?? 0) {
                best = (gap, (hiSoFar + sorted[i].lo) / 2)
            }
            hiSoFar = max(hiSoFar, sorted[i].hi)
        }
        return best
    }

    // MARK: - Headers and footers

    /// Texts repeating on several pages are running headers/footers.
    private static func repeatedKeys(_ perPage: [[Line]]) -> Set<String> {
        var count: [String: Int] = [:]
        var pagesSeen: [String: Set<Int>] = [:]
        for pageLines in perPage {
            for line in pageLines {
                let key = repeatedKey(line.trimmed)
                guard !key.isEmpty, key.count <= 120 else { continue }
                count[key, default: 0] += 1
                pagesSeen[key, default: []].insert(line.page)
            }
        }
        return Set(count.compactMap { key, total in
            total >= 3 && (pagesSeen[key]?.count ?? 0) >= 3 ? key : nil
        })
    }

    /// Comparison key that ignores what changes page to page — in the
    /// running header "394 Rudolf Carnap" the number varies, but the rest
    /// repeats. Replaces each digit block with "#".
    private static func repeatedKey(_ text: String) -> String {
        var out = ""
        var inDigits = false
        for ch in text {
            if ch.isNumber {
                if !inDigits { out.append("#"); inDigits = true }
            } else {
                out.append(ch)
                inDigits = false
            }
        }
        return out
    }

    /// Noise in the margin band: page number, date/time, URL, short label.
    private static func isMarginNoise(_ text: String, line: Line, pageHeight: CGFloat) -> Bool {
        let inTopBand = line.minY > pageHeight * 0.86
        let inBottomBand = line.maxY < pageHeight * 0.14
        guard inTopBand || inBottomBand else { return false }

        if matches(text, #"^(?:Page\s+)?\d{1,4}(?:\s+(?:of|de)\s+\d{1,4})?$"#) { return true }
        if matches(text, #"^\d{1,4}\s*[/.\-]\s*\d{1,4}\s*[/.\-]\s*\d{2,4}"#) { return true }
        if matches(text, #"^(?:about|chrome|file|https?):"#) { return true }
        if text.count <= 12 { return true }
        return false
    }

    // MARK: - Paragraphs

    private static func paragraphs(from lines: [Line], leading: CGFloat) -> [(text: String, page: Int, rects: [CGRect], words: [(text: String, box: CGRect, page: Int, sup: Bool)])] {
        guard !lines.isEmpty else { return [] }

        let globalLeft = median(lines.map { $0.minX }) ?? 0
        let globalRight = median(lines.map { $0.maxX }) ?? 0
        let paragraphGap = leading * 1.6
        let indent = max(8, leading * 0.8)

        // A section title has a larger font: the line box is taller than the
        // body's. That is the signal not to glue the title to the next paragraph.
        let medianHeight = median(lines.map { $0.maxY - $0.minY }.filter { $0 > 0 })
        func isHeading(_ line: Line) -> Bool {
            guard let base = medianHeight, base > 0 else { return false }
            return (line.maxY - line.minY) > base * 1.18
        }
        func colLeft(_ line: Line) -> CGFloat {
            line.colRight > line.colLeft ? line.colLeft : globalLeft
        }
        func colWidth(_ line: Line) -> CGFloat {
            line.colRight > line.colLeft ? line.columnWidth : max(1, globalRight - globalLeft)
        }

        var result: [(text: String, page: Int, rects: [CGRect], words: [(text: String, box: CGRect, page: Int, sup: Bool)])] = []
        var current = ""
        var currentPage = 0
        var currentLines: [Line] = []
        var previous: Line?

        // Closes the current paragraph. Line boxes stay single-page (geometry
        // like rule zones compares tops within one page), but the WORDS span
        // all pages: without the next page's words the tail of a sentence
        // crossing the page break has no highlight boxes downstream
        // (`passagesPerPage` already splits multi-page words per page).
        func flush() {
            let pageLines = currentLines.filter { $0.page == currentPage }
            let rects = pageLines.map { $0.box }
            let words = currentLines.flatMap { line in
                line.words.map { (text: $0.text, box: $0.box, page: line.page, sup: $0.sup) }
            }
            result.append((current, currentPage, rects, words))
        }

        for line in lines {
            let text = collapsed(line.trimmed)
            guard !text.isEmpty else { continue }

            if current.isEmpty {
                current = text
                currentPage = line.page
                currentLines = [line]
                previous = line
                continue
            }

            let continues: Bool
            if let prev = previous {
                let headingBoundary = isHeading(prev) || isHeading(line)
                if prev.page != line.page {
                    // Page break: continues while the sentence has not closed.
                    continues = !headingBoundary && !endsSentence(prev.trimmed)
                } else {
                    // `gap` can be negative at a column turn (the top of the
                    // right is above the foot of the left): in that case the
                    // continuation is decided by "full line" and end of sentence,
                    // which is the correct text flow between columns.
                    let gap = prev.minY - line.maxY
                    let previousFull = prev.width >= colWidth(prev) * 0.82
                    let currentIndented = (line.minX - colLeft(line)) > indent
                        && (prev.minX - colLeft(prev)) <= indent
                    continues = !headingBoundary && previousFull
                        && gap < paragraphGap && !currentIndented
                        && !endsSentenceHard(prev.trimmed)
                }
            } else {
                continues = false
            }

            if continues {
                current = join(current, text)
                currentLines.append(line)
            } else {
                flush()
                current = text
                currentPage = line.page
                currentLines = [line]
            }
            previous = line
        }
        if !current.isEmpty { flush() }
        return result
    }

    /// Vertical spacing between consecutive lines, per page, to estimate
    /// the leading before assembling paragraphs.
    private static func spacings(of perPage: [[Line]]) -> [CGFloat] {
        var out: [CGFloat] = []
        for pageLines in perPage {
            let sorted = pageLines.sorted { $0.minY > $1.minY }
            for (upper, lower) in zip(sorted, sorted.dropFirst()) {
                let gap = upper.minY - lower.maxY
                if gap > 0 { out.append(gap) }
            }
        }
        return out
    }

    /// Joins two lines, handling end-of-line hyphenation.
    private static func join(_ first: String, _ second: String) -> String {
        if let last = first.last, last == "-" || last == "‐" {
            return String(first.dropLast()) + second
        }
        return first + " " + second
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?\"')".contains(last)
    }

    /// Closes a sentence hard (terminal punctuation only): used so as not to glue
    /// two paragraphs that end in a period.
    private static func endsSentenceHard(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?".contains(last)
    }

    private static func collapsed(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\s+"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
