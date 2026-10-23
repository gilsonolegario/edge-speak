import Testing
import Foundation
@testable import EdgeSpeak

/// The sentence boundary of an academic page. Every case here was a defect
/// measured on 2026-10-17: a boundary that closes where it should not cuts a
/// sentence in half (the highlight jumps early and the voice pauses
/// mid-thought), and a pattern that swallows the trailing period leaves the
/// sentence open, which then merges with the next one.
@Suite struct SentenceBoundaryTests {

    // MARK: - Abbreviations and initials

    /// "et al." and "e.g." are everywhere in an academic text: splitting after
    /// them halves the sentence.
    @Test func abbreviationDoesNotSplitSentence() {
        let parts = TextImport.splitSentences("Autor et al. escrevem isso. Depoisнопoutro.")
        #expect(parts.count == 2)
        #expect(parts[0].contains("et al."))
    }

    /// A name initial ("J. Smith") is not a sentence end.
    @Test func initialDoesNotSplitSentence() {
        let parts = TextImport.splitSentences("Segundo J. Smith o texto muda. Fim.")
        #expect(parts.count == 2)
        #expect(parts[0].contains("J. Smith"))
    }

    /// "I" and "A" as words of their own really do close sentences
    /// ("… and so do I. Then …") — the initial rule must not swallow them.
    @Test func standaloneIStillSplits() {
        let parts = TextImport.splitSentences("They waited and so do I. Then he left.")
        #expect(parts.count == 2)
        #expect(parts[0].trimmingCharacters(in: .whitespaces) == "They waited and so do I.")
    }

    /// "etc." and "al." are deliberately NOT in the abbreviation set: both
    /// close sentences often enough that refusing them would merge two
    /// sentences. The test below pins that decision so it is not "helpfully"
    /// reversed later.
    @Test func etcStillClosesSentence() {
        #expect(TextImport.endsWithAbbreviation("as usual, etc.") == false)
        let parts = TextImport.splitSentences("Um exemplo, etc. Depois disso.")
        #expect(parts.count == 2)
    }

    /// The rule itself, over the shapes that reach it.
    ///
    /// The input is what `splitSentences` passes: the text UP TO AND INCLUDING
    /// the candidate period (the boundary regex splits on the whitespace after
    /// it), so a judgment needs that period.
    @Test func abbreviationRuleRefusesTheBoundary() {
        #expect(TextImport.endsWithAbbreviation("Autor et al."))
        #expect(TextImport.endsWithAbbreviation("veja a Fig."))
        #expect(TextImport.endsWithAbbreviation("(cf."))          // opening paren
        #expect(TextImport.endsWithAbbreviation("citando M."))     // name initial
        #expect(TextImport.endsWithAbbreviation("isto é i.e."))    // dotted pair
        #expect(TextImport.endsWithAbbreviation("na pág. no."))    // "no"
    }

    /// The complementary half: a period that really closes the sentence is
    /// still a boundary. Without these, "fixing" the abbreviations would
    /// merge paragraphs.
    @Test func abbreviationRuleAcceptsRealSentenceEnd() {
        #expect(TextImport.endsWithAbbreviation("um ponto qualquer.") == false)
        #expect(TextImport.endsWithAbbreviation("disse \"alto.") == false)   // quote separator
        #expect(TextImport.endsWithAbbreviation("ele disse A.") == false)    // "A" exempt
        #expect(TextImport.endsWithAbbreviation("e ele disse I.") == false)   // "I" exempt
        #expect(TextImport.endsWithAbbreviation("sem ponto") == false)       // no period to judge
    }

    /// "Sect." before a number is a cross-reference, not a sentence end:
    /// splitting there produced the digit-initial fragment ("2 for a further
    /// discussion of this point."), which then read as a false note body
    /// (schiemer2015.pdf p. 3, measured 2026-10-17).
    @Test func sectionAbbreviationDoesNotSplitSentence() {
        let parts = TextImport.splitSentences("A relação está discutida em Sect. 2 para maiores detalhes. Fim.")
        #expect(parts.count == 2)
        #expect(parts[0].contains("Sect. 2"))
        #expect(TextImport.endsWithAbbreviation("como na Sect."))
    }

    /// "Eq. 3" has the same shape (abbreviation + number) and the same risk
    /// of feeding a digit-initial fragment as a false note body.
    @Test func equationAbbreviationDoesNotSplitSentence() {
        let parts = TextImport.splitSentences("O resultado segue da Eq. 3 com as premissas dadas. Fim.")
        #expect(parts.count == 2)
        #expect(parts[0].contains("Eq. 3"))
        #expect(TextImport.endsWithAbbreviation("ver a Eq."))
    }

    /// A runaway text with no punctuation at all still comes back as ONE
    /// phrase — the refusal must not drop text, only boundaries.
    @Test func runawayTextIsNotDropped() {
        let parts = TextImport.splitSentences("sem nenhuma pontuação aqui")
        #expect(parts.count == 1)
        #expect(parts[0].contains("pontuação"))
    }

    // MARK: - Terminal punctuation eaten by a stripped URL/DOI

    /// A URL closing a sentence used to take the period with it (bare
    /// `\S+`), so the sentence never closed and merged with the next one.
    @Test func urlAtEndOfSentenceKeepsThePeriod() {
        let parts = TextImport.splitSentences("Veja https://exemplo.org/pagina. Depois disso.")
        #expect(parts.count == 2)
    }

    /// A DOI closing a sentence: same defect, worse case because the DOI
    /// pattern is applied before the sentence split.
    @Test func doiAtEndOfSentenceKeepsThePeriod() {
        let parts = TextImport.splitSentences("Veja doi: 10.1234/abc-def. Depois disso.")
        #expect(parts.count == 2)
    }

    /// The DOI is still REMOVED from the spoken text — the punctuation fix
    /// must not turn into "the DOI is now read out loud".
    @Test func doiIsStillStripped() {
        let out = CitationSkip.stripDOI("Veja doi: 10.1234/abc-def. Depois.")
        #expect(!out.contains("10.1234"))
        #expect(out.contains("."))
    }

    /// The same for a bare DOI without the prefix, and for one inside a URL.
    @Test func doiVariantsAreStripped() {
        #expect(!CitationSkip.stripDOI("texto 10.1234/x-y fim").contains("10.1234"))
        #expect(!CitationSkip.stripDOI("https://doi.org/10.1234/x-y fim").contains("10.1234"))
    }

    // MARK: - Marker as a word of its own (paragraph-wide words)

    /// When the superscript marker comes as its own word, `words` (the whole
    /// paragraph's, per `makePhrases`) carries it into EVERY sentence of the
    /// paragraph. The geometric-only recall (`core == ns`) then gave every
    /// sentence support and the body landed one sentence before the real
    /// marker. The digits IN the sentence's own text must win the anchor;
    /// the recall itself stays for spans dropped from the text entirely.
    @Test func standaloneMarkerWordAnchorsToItsSentence() {
        let words = [
            TextImport.Phrase.WordBox(text: "argumento", rect: .zero, page: 0, sup: false),
            TextImport.Phrase.WordBox(text: "segue", rect: .zero, page: 0, sup: false),
            TextImport.Phrase.WordBox(text: "2", rect: .zero, page: 0, sup: true),
            TextImport.Phrase.WordBox(text: "aqui", rect: .zero, page: 0, sup: false),
        ]
        let list = [
            TextImport.Phrase(index: 0, text: "primeira frase do parágrafo sem marcador",
                              page: 0, rects: [], words: words),
            TextImport.Phrase(index: 1, text: "argumento segue.2 aqui",
                              page: 0, rects: [], words: words),
            TextImport.Phrase(index: 2, text: "2 Corpo longo da nota aqui",
                              page: 0, rects: []),
        ]
        let fora = TextImport.resolveFootnotes(list)
        // The body enters right after the marker's sentence (1), not after 0.
        #expect(fora.map(\.index) == [0, 1, 2])
        #expect(fora[1].noteMarker == 2)
        #expect(fora[2].noteNumber == 2)
        #expect(fora[0].noteNumber == nil)
    }
}