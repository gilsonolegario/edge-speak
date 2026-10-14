import CoreGraphics
import Testing

@testable import EdgeSpeak

/// Alignment between the spoken words and the PDF words.
///
/// The case that motivated everything: in the test article, "R= ∃uT (u,o), C= R →T (t,o)."
/// becomes in speech "R equals there exists u such that T of u o, C equals R implies
/// T of t o" — 6 spoken words for 3 boxes in the PDF. The word-by-word
/// lookup made the expansions ("and", "such", "there") steal the box of
/// a prose word further on: the highlight jumped side to side. Here the
/// expansion word stays WITHOUT a box, which is the only honest answer.
@MainActor
struct WordAlignerTests {
    private func pdf(_ textos: [String]) -> [WordAligner.Box] {
        textos.enumerated().map { i, t in
            TextImport.Phrase.WordBox(
                text: t, rect: CGRect(x: CGFloat(i) * 10, y: 0, width: 8, height: 10))
        }
    }

    /// The article's case: the expansions take no box at all, and the real
    /// words stay in the right box.
    @Test func expansionsDoNotStealBox() {
        let aligner = WordAligner()
        // Spoken: "R equals there exists u such that T of u o" (11 words).
        // PDF: "R= ∃uT (u,o)" → extractor tokens.
        let spokenWords = ["R", "equals", "there", "exists", "u", "such", "that", "T", "of", "u", "o"]
        let wordBoxes = pdf(["R=", "∃uT", "(u,o)"])
        let mapping = aligner.align(spokenWords: spokenWords, pdf: wordBoxes)
        // The word "R" (same at both ends) stays in the first box.
        #expect(mapping[0] == 0)
        // No expansion ("equals", "there", "such"…) may match a box:
        // if they did, they would be stealing the prose box further on.
        for i in 1..<spokenWords.count {
            #expect(mapping[i] == nil, "palavra \(spokenWords[i]) não devia ter caixa")
        }
    }

    /// Repeated with different neighbors: each utterance goes to its own occurrence.
    @Test func repeatedWithDifferentNeighbors() {
        let aligner = WordAligner()
        let spokenWords = ["the", "role", "the", "test"]
        let wordBoxes = pdf(["the", "role", "the", "test"])
        let mapping = aligner.align(spokenWords: spokenWords, pdf: wordBoxes)
        #expect(mapping == [0, 1, 2, 3])
    }

    /// "the" every few words (the article's text is full of it) does not
    /// shift the rest of the sentence.
    @Test func repeatedTheDoesNotShift() {
        let aligner = WordAligner()
        let spokenWords = ["the", "theory", "of", "the", "theory", "is", "the", "gap"]
        let wordBoxes = pdf(["the", "theory", "of", "the", "theory", "is", "the", "gap"])
        let mapping = aligner.align(spokenWords: spokenWords, pdf: wordBoxes)
        #expect(mapping == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    /// A spoken word that exists in the PDF matches even with one box fewer: the
    /// sequence is shorter than the PDF's (a symbol the voice does not speak).
    @Test func pdfWithUnspokenSymbol() {
        let aligner = WordAligner()
        // Spoken: "R equals R" (the "=" is a voice expansion, not from the PDF).
        let spokenWords = ["R", "equals", "R"]
        let wordBoxes = pdf(["R", "=", "R"])
        let mapping = aligner.align(spokenWords: spokenWords, pdf: wordBoxes)
        #expect(mapping[0] == 0)
        #expect(mapping[1] == nil)
        #expect(mapping[2] == 2)
    }

    /// Real case from the article (Neutrality_v80, p. 5): the sentence "Avery's title … the
    /// laboratory." is read against the words of the WHOLE paragraph (80 real
    /// tokens from the extractor), and the next sentence contains "the laboratory" again.
    /// Skipping the middle or skipping the end costs the same, and the backtrace from the
    /// end prefers the LATE occurrence: the 2nd "the" went to box 63 instead
    /// of 52, and the highlight jumped to the next sentence. The spoken words go through
    /// `forSpeech` as in the app.
    @Test func repeatedTheInArticleStaysInItsOwnPhrase() {
        let aligner = WordAligner()
        let sentence = "Avery’s title named a role and left the identity of its occupant to the laboratory."
        let spokenWords = ReadAloudFilter.forSpeech(sentence, voice: "en-US")
            .split(separator: " ").map(String.init)
        #expect(spokenWords.count == 15)
        let wordBoxes = pdf([
            "The", "two", "uses", "of", "Carnap", "assign", "different", "work", "to", "a",
            "choice.", "The", "reconstruction", "fixes", "an", "inter-", "pretation", "under", "which", "realization",
            "suffices", "for", "theoretical", "truth.", "The", "realist", "frame", "makes", "a", "general",
            "existential", "commitment", "part", "of", "engaging", "in", "an", "explanatory", "practice.", "Avery’s",
            "title", "named", "a", "role", "and", "left", "the", "identity", "of", "its",
            "occupant", "to", "the", "laboratory.", "Whether", "either", "device", "leaves", "questions", "of",
            "that", "kind", "where", "the", "laboratory", "found", "them", "depends", "on", "how",
            "theoretical", "terms", "are", "understood,", "and", "Carnap", "himself", "marked", "the", "difference.",
        ])
        let mapping = aligner.align(spokenWords: spokenWords, pdf: wordBoxes)
        for i in 0..<13 {
            #expect(mapping[i] == 39 + i, "palavra \(spokenWords[i]) devia estar na caixa \(39 + i)")
        }
        #expect(mapping[13] == 52)
        #expect(mapping[14] == 53)
    }

    /// Mirror of the article's case: the next sentence ("… where the laboratory
    /// found them …") matches "the laboratory" at ITS OWN occurrence (63–64), not
    /// at the previous one (52–53). Locks the other side: context cannot push
    /// everything to the first occurrence.
    @Test func nextPhraseMatchesItsOwnOccurrence() {
        let aligner = WordAligner()
        let sentence = "Whether either device leaves questions of that kind where the laboratory found them depends on how theoretical terms are understood, and Carnap himself marked the difference."
        let spokenWords = ReadAloudFilter.forSpeech(sentence, voice: "en-US")
            .split(separator: " ").map(String.init)
        #expect(spokenWords.count == 26)
        let wordBoxes = pdf([
            "The", "two", "uses", "of", "Carnap", "assign", "different", "work", "to", "a",
            "choice.", "The", "reconstruction", "fixes", "an", "inter-", "pretation", "under", "which", "realization",
            "suffices", "for", "theoretical", "truth.", "The", "realist", "frame", "makes", "a", "general",
            "existential", "commitment", "part", "of", "engaging", "in", "an", "explanatory", "practice.", "Avery’s",
            "title", "named", "a", "role", "and", "left", "the", "identity", "of", "its",
            "occupant", "to", "the", "laboratory.", "Whether", "either", "device", "leaves", "questions", "of",
            "that", "kind", "where", "the", "laboratory", "found", "them", "depends", "on", "how",
            "theoretical", "terms", "are", "understood,", "and", "Carnap", "himself", "marked", "the", "difference.",
        ])
        let mapping = aligner.align(spokenWords: spokenWords, pdf: wordBoxes)
        #expect(mapping == Array(54..<80).map { Optional($0) })
    }

    /// Expansion before repeats: the word that does not exist in the PDF stays
    /// without a box even with the context bonus (only the equal pair earns the bonus).
    @Test func expansionBeforeRepeatedDoesNotStealBox() {
        let aligner = WordAligner()
        let mapping = aligner.align(
            spokenWords: ["oh", "the", "role", "the", "test"],
            pdf: pdf(["the", "role", "the", "test"]))
        #expect(mapping == [nil, 0, 1, 2, 3])
    }

    /// The target word's box leaves the map; with no match, nil (never
    /// an invented neighboring box).
    @Test func targetBox() {
        let aligner = WordAligner()
        let wordBoxes = pdf(["a", "b", "c"])
        let mapping = aligner.align(spokenWords: ["a", "b", "c"], pdf: wordBoxes)
        #expect(aligner.box(aligned: mapping, target: 1, pdf: wordBoxes)?.origin.x == CGFloat(10))
        // Missing target (index beyond the list) does not crash.
        #expect(aligner.box(aligned: mapping, target: 9, pdf: wordBoxes) == nil)
    }

    /// Repeating the request (as on every highlight tick) returns the SAME box.
    @Test func repeatingTickDoesNotChangeBox() {
        let aligner = WordAligner()
        let spokenWords = ["the", "role", "the", "test"]
        let wordBoxes = pdf(["the", "role", "the", "test"])
        let primeira = aligner.box(sentence: 1, target: 2, spokenWords: spokenWords, pdf: wordBoxes)
        for _ in 0..<20 {
            #expect(aligner.box(sentence: 1, target: 2, spokenWords: spokenWords, pdf: wordBoxes) == primeira)
        }
    }

    /// Switching sentences recalculates the alignment.
    @Test func phraseSwitchRecalculates() {
        let aligner = WordAligner()
        let spokenWords = ["a", "b"]
        let wordBoxes = pdf(["a", "b"])
        #expect(aligner.box(sentence: 1, target: 0, spokenWords: spokenWords, pdf: wordBoxes)?.origin.x == CGFloat(0))
        #expect(aligner.box(sentence: 2, target: 0, spokenWords: spokenWords, pdf: wordBoxes)?.origin.x == CGFloat(0))
    }

    /// The comparison ignores punctuation, case and hyphen.
    @Test func normalizationRoundTrip() {
        #expect(WordAligner.normalized("Carnap’s") == "carnaps")
        #expect(WordAligner.normalized("well-known") == "wellknown")
        #expect(WordAligner.normalized("(") == "")
        #expect(WordAligner.normalized("1944") == "1944")
    }

    /// New document with the same sentence index and counts: without dropping
    /// the cache the old map returns (stale); `invalidate` restores the fresh one.
    @Test func documentSwitchInvalidatesCache() {
        let aligner = WordAligner()
        func box(_ text: String, _ x: CGFloat) -> WordAligner.Box {
            WordAligner.Box(text: text, rect: CGRect(x: x, y: 0, width: 8, height: 10))
        }
        let first = aligner.box(
            sentence: 5, target: 1, spokenWords: ["a", "b"],
            pdf: [box("a", 0), box("b", 10)])
        #expect(first?.origin.x == 10)
        // Same key (sentence + counts), other document with another map:
        // "q" has no box, "a" goes to box 0 — reusing the old [0,1] map
        // would point target 1 at box 1 (x=110) instead of box 0 (x=100).
        let stale = aligner.box(
            sentence: 5, target: 1, spokenWords: ["q", "a"],
            pdf: [box("a", 100), box("b", 110)])
        #expect(stale?.origin.x == 110)
        aligner.invalidate()
        let fresh = aligner.box(
            sentence: 5, target: 1, spokenWords: ["q", "a"],
            pdf: [box("a", 100), box("b", 110)])
        #expect(fresh?.origin.x == 100)
    }
}