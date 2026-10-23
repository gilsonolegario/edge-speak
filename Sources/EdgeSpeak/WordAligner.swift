import CoreGraphics
import Foundation

/// Aligns the SPOKEN word sequence with the PDF word sequence,
/// and says which box corresponds to each spoken word.
///
/// Why align instead of searching word by word: read-aloud
/// NEVER has the same word sequence as the PDF. Where the PDF puts a symbol,
/// the voice puts a phrase — "∃uT (u,o)" becomes "there exists u, such that, T of
/// u" (6 words for 3 boxes). Word-by-word search forced the
/// expansion words to match some PDF box, and since they are
/// COMMON words ("and", "such", "there"), they stole the box of a
/// prose word further on: the highlight went to the wrong side. That was
/// the "jumping side to side" the owner saw.
///
/// Why global alignment (Needleman–Wunsch) and not greedy: matching word
/// by word solves the common case, but breaks exactly here, where the
/// length of the two sequences differs by construction. Global alignment
/// prefers to leave the expansion word WITHOUT a box over distorting the rest,
/// because distorting costs more.
///
/// How it sounds aloud: expansion words have no box (the highlight
/// blinks across them, without jumping); real words land in the right box. It is the
/// honest consequence of reading formulas spelled out, and what one expects from
/// a karaoke.
///
/// Cost per operation:
/// - matching equal words: 0
/// - skipping (expansion without box, or box without spoken word): 1
/// - substituting (unequal pair): 3 — more expensive than skipping, because substituting distorts
///   the sequence; skipping only admits there was no box.
@MainActor
final class WordAligner {
    /// PDF box of each word of the sentence, in reading order.
    typealias Box = TextImport.Phrase.WordBox

    private static let costSkip: Int = 1
    private static let costSubstitute: Int = 3

    /// Reduces the word to what it compares: lowercase, letters and digits only.
    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Index of the PDF box matching each spoken word; `nil`
    /// when the word is an expansion (it has no box of its own).
    ///
    /// Global alignment with explicit tie-break: on a diagonal with the same
    /// cost, it prefers MATCHING (the word is the same at both ends), then
    /// skipping the spoken word (expansion), then skipping the PDF box. The
    /// preference for matching is what keeps `the … the` at the right occurrence.
    ///
    /// Context tie-break (±3): matching two equal words costs 0 minus
    /// 1 per neighbor that is also equal (up to 3 each side, only neighbors with
    /// a letter or digit). Why only ±3 and not ±1: the sentence is read against the
    /// words of the WHOLE paragraph, and the next sentence may repeat the same
    /// bigram ("the laboratory" twice in the article). Skipping the middle or skipping
    /// the end costs the same, and the backtrace from the end prefers the late
    /// occurrence — the highlight went to the next sentence. With ±3, the occurrence whose
    /// neighborhood stays equal wins, and each side keeps its own. The bonus only
    /// applies to the equal pair, so an expansion without a box stays without a box
    /// (substituting still costs more than skipping) and the per-sentence cache does not change.
    func align(spokenWords: [String], pdf: [Box]) -> [Int?] {
        let n = spokenWords.count
        let m = pdf.count
        guard n > 0, m > 0 else { return [Int?](repeating: nil, count: n) }

        let spokenNormalized = spokenWords.map(Self.normalized)
        let pdfNorm = pdf.map { Self.normalized($0.text) }

        // dp[i][j] = cost of aligning the first i spoken words with the j boxes.
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { dp[i][0] = i * Self.costSkip }
        for j in 1...m { dp[0][j] = j * Self.costSkip }
        for i in 1...n {
            for j in 1...m {
                let skipSpoken = dp[i - 1][j] + Self.costSkip
                let skipBox = dp[i][j - 1] + Self.costSkip
                dp[i][j] = min(
                    Self.costMatch(spokenNormalized, pdfNorm, i: i, j: j) + dp[i - 1][j - 1],
                    skipSpoken, skipBox)
            }
        }

        // Backtrace: from (n, m) to (0, 0). A tie goes to matching.
        var mapping = [Int?](repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0 && j > 0 {
            let match = spokenNormalized[i - 1] == pdfNorm[j - 1]
            let costMatch = Self.costMatch(spokenNormalized, pdfNorm, i: i, j: j)
            if dp[i][j] == costMatch + dp[i - 1][j - 1] {
                if match, !spokenNormalized[i - 1].isEmpty { mapping[i - 1] = j - 1 }
                i -= 1
                j -= 1
            } else if dp[i][j] == dp[i - 1][j] + Self.costSkip {
                i -= 1
            } else {
                j -= 1
            }
        }
        return mapping
    }

    /// Cost of the diagonal at (i, j) (1-based): an unequal pair costs the substitution;
    /// an equal pair costs 0 minus the context bonus (±3 equal neighbors).
    private static func costMatch(
        _ spokenWords: [String], _ pdf: [String], i: Int, j: Int
    ) -> Int {
        guard spokenWords[i - 1] == pdf[j - 1], !spokenWords[i - 1].isEmpty else {
            return costSubstitute
        }
        var bonus = 0
        for k in 1...3 {
            if i - 1 + k < spokenWords.count, j - 1 + k < pdf.count,
               !spokenWords[i - 1 + k].isEmpty, spokenWords[i - 1 + k] == pdf[j - 1 + k] {
                bonus += 1
            }
            if i - 1 - k >= 0, j - 1 - k >= 0,
               !spokenWords[i - 1 - k].isEmpty, spokenWords[i - 1 - k] == pdf[j - 1 - k] {
                bonus += 1
            }
        }
        return -bonus
    }

    /// Test shortcut: box of word `target` already aligned.
    func box(aligned: [Int?], target: Int, pdf: [Box]) -> CGRect? {
        entry(aligned: aligned, target: target, in: pdf)?.rect
    }

    /// The PDF box matched to the spoken word `target`, whole — not just its
    /// rectangle: whoever draws it needs to know WHICH PAGE it is on.
    private func entry(aligned: [Int?], target: Int, in boxes: [Box]) -> Box? {
        guard target >= 0, target < aligned.count,
              let k = aligned[target], k >= 0, k < boxes.count
        else { return nil }
        return boxes[k]
    }

    /// Whole box of the cached alignment.
    func entry(aligned: [Int?], target: Int) -> Box? {
        entry(aligned: aligned, target: target, in: cachedBoxes)
    }

    // MARK: - Per-sentence cache

    /// Sentence, doc/mode generation and the alignment itself.
    ///
    /// The generation is part of the key BY HOLE: same sentence + same counts
    /// happen across documents (differently-read articles share index 0), and the
    /// `invalidate()` via `onChange` does not close the window between the change
    /// of displayed text and the invalidation — a frame could reuse the previous
    /// document's boxes. Passing the `attrGeneration` of the display to `boxEntry`,
    /// the cache is like this inside the key itself.
    private var currentSentence = -1
    private var currentGeneration = -1
    private var mapping: [Int?] = []
    private var spokenCount = -1
    private var boxCount = -1
    /// Boxes of the saved alignment: kept so `entry` can return the whole box
    /// (the page matters) without re-running the alignment.
    private var cachedBoxes: [Box] = []

    /// Drops the saved alignment: the cache key (sentence + counts) repeats
    /// across documents, so opening a new PDF with the same counts reused the
    /// old document's boxes and the PDF yellow drifted. Called when the
    /// displayed text identity changes (document or text mode).
    func invalidate() {
        currentSentence = -1
        currentGeneration = -1
        mapping = []
        spokenCount = -1
        boxCount = -1
        cachedBoxes = []
    }

    /// Aligns once per sentence and keeps the boxes it aligned against.
    /// Called on every highlight tick (10 Hz): the alignment is O(n·m) and
    /// cannot run on every frame.
    private func cache(
        sentence: Int, generation: Int, spokenWords: [String], pdf: [Box]
    ) {
        guard sentence != currentSentence
                || generation != currentGeneration
                || spokenWords.count != spokenCount
                || pdf.count != boxCount else { return }
        currentSentence = sentence
        currentGeneration = generation
        spokenCount = spokenWords.count
        boxCount = pdf.count
        cachedBoxes = pdf
        mapping = align(spokenWords: spokenWords, pdf: pdf)
    }

    /// Box of word `target` of sentence `sentence`, aligning once and reusing
    /// while it is the same sentence. Called on every highlight tick (10 Hz): the
    /// alignment is O(n·m) and cannot run on every frame.
    func box(
        sentence: Int, generation: Int = -1, target: Int,
        spokenWords: [String], pdf: [Box]
    ) -> CGRect? {
        cache(sentence: sentence, generation: generation, spokenWords: spokenWords, pdf: pdf)
        return box(aligned: mapping, target: target, pdf: pdf)
    }

    /// Whole box (page included) of word `target` of `sentence`: the PDF yellow
    /// needs the page that owns the word, which is not always the sentence's.
    /// `generation` = identity of the displayed text (document+mode): changes
    /// the key and the realignment, without depending on `invalidate()` timing.
    func boxEntry(
        sentence: Int, generation: Int = -1, target: Int,
        spokenWords: [String], pdf: [Box]
    ) -> Box? {
        cache(sentence: sentence, generation: generation, spokenWords: spokenWords, pdf: pdf)
        return entry(aligned: mapping, target: target)
    }
}
