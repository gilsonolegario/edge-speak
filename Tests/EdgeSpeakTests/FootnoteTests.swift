import CoreGraphics
import Testing

@testable import EdgeSpeak

/// End-to-end footnotes: link body to marker, speak on the spot, skip.
///
/// Owner's motivation: the marker was read "point seven"; announced without the body
/// ("footnote 7" + running text) is promise without delivery — it misleads. Here
/// the body goes right after the marker's sentence (it is read directly), a loose
/// number without body is silence, and the option turns everything off (marker becomes a pause).
@MainActor
struct FootnoteTests {
    private let pt = "pt-BR-FranciscaNeural"
    private let en = "en-US-AndrewNeural"

    private func sentence(_ i: Int, _ text: String, page: Int?) -> TextImport.Phrase {
        TextImport.Phrase(index: i, text: text, page: page, rects: [])
    }

    /// Sentence with geometry (top in PDFKit coords, origin at the bottom), for the
    /// rule tests: what is above it is running text.
    private func sentenceBox(_ i: Int, _ text: String, page: Int?, topo: CGFloat) -> TextImport.Phrase {
        TextImport.Phrase(
            index: i, text: text, page: page,
            rects: [CGRect(x: 100, y: topo - 10, width: 300, height: 10)])
    }

    /// With the rule, a date above it stays intact even with a marker nearby;
    /// only the body below links.
    @Test func ruleSeparatesDateFromBody() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "tese aqui.12", page: 0, topo: 500),
            sentenceBox(1, "12 de outubro de 2026 registra o fato aqui", page: 0, topo: 400),
            sentenceBox(2, "12 Corpo longo da nota aqui", page: 0, topo: 50),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].noteNumber == 12)
        #expect(fora[2].text == "12 de outubro de 2026 registra o fato aqui")
        #expect(fora[2].noteNumber == nil)
    }

    /// With the rule, a loose number above it is content and stays; below, it disappears.
    @Test func ruleWithLooseNumber() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let acima = TextImport.resolveFootnotes(
            [sentenceBox(0, "7", page: 0, topo: 500)], pageRules: pageRules)
        #expect(acima.count == 1)
        let abaixo = TextImport.resolveFootnotes(
            [sentenceBox(0, "7", page: 0, topo: 50)], pageRules: pageRules)
        #expect(abaixo.isEmpty)
    }

    /// Without the rule (old JSON, no Python path), the usual heuristic applies.
    @Test func noRuleHeuristic() {
        let list = [
            sentence(0, "tese aqui.5", page: 0),
            sentence(1, "5 Corpo longo da nota aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].noteNumber == 5)
    }

    /// Several notes under the same rule: the linked one moves, the one without a marker stays
    /// without a number and marked (it is not read as running text).
    @Test func severalNotesUnderRule() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "tese aqui.7", page: 0, topo: 500),
            sentenceBox(1, "7 Corpo longo da sete aqui", page: 0, topo: 60),
            sentenceBox(2, "8 Outro corpo longo aqui", page: 0, topo: 40),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        #expect(fora.map(\.index) == [0, 1, 2])
        #expect(fora[1].noteNumber == 7)
        #expect(fora[2].text == "Outro corpo longo aqui")
        #expect(fora[2].noteNumber == 8)
    }

    /// A loose number below the rule stays discarded even in a sequence
    /// (it is a label without body, not a later readable note).
    @Test func looseNumberSequenceBelowRule() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "tese aqui.7", page: 0, topo: 500),
            sentenceBox(1, "7 Corpo longo da sete aqui", page: 0, topo: 60),
            sentenceBox(2, "8", page: 0, topo: 40),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        // The loose "8" below the rule stays discarded (label without body),
        // but the 7→8 sequence is recorded in the link of 7.
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].noteNumber == 7)
    }

    private func sentenceSup(_ i: Int, _ text: String, page: Int?, palavras: [(String, Bool)]) -> TextImport.Phrase {
        let wordBoxes = palavras.map { (t, s) in
            TextImport.Phrase.WordBox(text: t, rect: .zero, page: page, sup: s)
        }
        return TextImport.Phrase(index: i, text: text, page: page, rects: [], words: wordBoxes)
    }

    /// A body on the same page goes right after the marker's sentence, without the
    /// number and marked with the note's number.
    @Test func bodyMovesAfterMarker() {
        let list = [
            sentence(0, "argumento.7 segue aqui", page: 0),
            sentence(1, "outra frase no meio", page: 0),
            sentence(2, "7 Autores afirmam isto aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].text == "Autores afirmam isto aqui")
        #expect(fora[1].noteNumber == 7)
    }

    /// Endnotes (body pages later) link to the nearest previous marker
    /// in the document.
    @Test func endNoteLinksBehind() {
        let list = [
            sentence(0, "tese.3 defendida", page: 0),
            sentence(1, "meio do texto", page: 1),
            sentence(2, "3 Referência completa aqui", page: 5),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].noteNumber == 3)
    }

    /// A loose number with a page (label without body, like the "1".."15" of the test
    /// article) is discarded — read, it would become "one". Without a page (editor),
    /// it stays intact.
    @Test func looseNumberDropsWithPage() {
        let withPage = [sentence(0, "15", page: 2), sentence(1, "texto", page: 2)]
        #expect(TextImport.resolveFootnotes(withPage).map(\.index) == [1])
        let withoutPage = [sentence(0, "15", page: nil)]
        #expect(TextImport.resolveFootnotes(withoutPage).count == 1)
    }

    /// Without a marker, the body stays intact where it is (it may be a date: touching
    /// it would be corruption).
    @Test func noMarkerMovesNothingAndKeepsNumber() {
        let list = [sentence(0, "9 Texto longo sem marcador por aqui", page: 4)]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.count == 1)
        #expect(fora[0].text == "9 Texto longo sem marcador por aqui")
        #expect(fora[0].noteNumber == nil)
    }

    /// The indices of the sentences that stay do not change (they are property, not
    /// position) — highlight and jump still apply after the resolution.
    @Test func indicesPreserved() {
        let list = [
            sentence(0, "abertura.4 aqui", page: 0),
            sentence(1, "4 Corpo longo da nota aqui", page: 0),
            sentence(2, "fecho", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(Set(fora.map(\.index)) == [0, 1, 2])
        #expect(fora.map(\.index) == [0, 1, 2])
    }

    /// Option off: the marker becomes a pause (no "footnote").
    @Test func offOptionSilencesMarker() {
        let silenced = ReadAloudFilter.forSpeech("argumento.7 segue", voice: pt, readFootnotes: false)
        #expect(!silenced.contains("nota de rodapé"))
        #expect(silenced.contains("argumento"))
        #expect(silenced.contains("segue"))
    }

    /// Option on (default): announced in both languages.
    @Test func onOptionAnnounces() {
        #expect(ReadAloudFilter.forSpeech("argumento.7 segue", voice: pt).contains("nota de rodapé 7"))
        #expect(ReadAloudFilter.forSpeech("argumento.7 segue", voice: en).contains("footnote 7"))
    }

    /// Academic text assumes an announced note: default on.
    @Test func defaultReadsNotes() {
        #expect(AppSetting.footnoteDefault == true)
    }

    /// Geometric sign wins: an overwritten marker links the body even without
    /// textual glue (".7"/",7"/"o7") in the sentence.
    @Test func overwrittenMarkerLinksWithoutGlue() {
        let list = [
            sentenceSup(0, "argumento segue aqui", page: 0, palavras: [("argumento", false), ("7", true), ("segue", false)]),
            sentence(1, "outra frase no meio", page: 0),
            sentence(2, "7 Autores afirmam isto aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].noteNumber == 7)
    }

    /// Overwritten with a different number does not match (does not become the note's marker).
    @Test func overwriteOfOtherNumberDoesNotMatch() {
        let list = [
            sentenceSup(0, "argumento segue aqui", page: 0, palavras: [("argumento", false), ("8", true)]),
            sentence(1, "7 Autores afirmam isto aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.count == 2)
        #expect(fora[1].noteNumber == nil)
        #expect(fora[1].text.hasPrefix("7 "))
    }

    /// A non-overwritten word with the number is not a geometric marker (the
    /// textual fallback only applies with glue: without glue, it does not move).
    @Test func numberWithoutSupDoesNotBecomeGeometricMarker() {
        let list = [
            sentenceSup(0, "argumento segue aqui", page: 0, palavras: [("argumento", false), ("7", false)]),
            sentence(1, "7 Autores afirmam isto aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].noteNumber == nil)
    }

    /// Ascending order (archilles-scriptor technique): bodies out of order
    /// in the file each link to their own marker (markers in order, which
    /// is the real case; an out-of-order marker is not searched backwards).
    @Test func ascendingOrderLinksEachToItsOwn() {
        let list = [
            sentence(0, "sete aqui.7", page: 0),
            sentence(1, "nove aqui.9", page: 0),
            sentence(2, "9 corpo longo da nove aqui", page: 0),
            sentence(3, "7 corpo longo da sete aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(Set(fora.map(\.index)) == [0, 1, 2, 3])
        let position = Dictionary(uniqueKeysWithValues: fora.enumerated().map { ($1.index, $0) })
        #expect(position[3] == position[0]! + 1)
        #expect(position[2] == position[1]! + 1)
        #expect(fora[position[3]!].noteNumber == 7)
        #expect(fora[position[2]!].noteNumber == 9)
    }

    /// Regression: with two bodies to link, moving the second cannot
    /// shift the position of the first (before, the wrong sentence left the list).
    @Test func twoLinksWithoutLosingPhrase() {
        let list = [
            sentence(0, "sete aqui.7", page: 0),
            sentence(1, "enchimento um", page: 0),
            sentence(2, "enchimento dois", page: 0),
            sentence(3, "enchimento três", page: 0),
            sentence(4, "nove aqui.9", page: 0),
            sentence(5, "enchimento quatro", page: 0),
            sentence(6, "enchimento cinco", page: 0),
            sentence(7, "7 corpo longo da sete aqui", page: 0),
            sentence(8, "9 corpo longo da nove aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.count == 9)
        #expect(Set(fora.map(\.index)) == Set(0..<9))
        let position = Dictionary(uniqueKeysWithValues: fora.enumerated().map { ($1.index, $0) })
        #expect(position[7] == position[0]! + 1)
        #expect(position[8] == position[4]! + 1)
    }

    /// With no marker in range (after the previous one), the body stays intact
    /// instead of sticking to the wrong marker.
    @Test func outOfRangeDoesNotStickWrongly() {
        let list = [
            sentence(0, "sete aqui.7", page: 0),
            sentence(1, "7 corpo longo da sete aqui", page: 0),
            sentence(2, "8 dias depois do evento central", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 1, 2])
        #expect(fora[2].text == "8 dias depois do evento central")
        #expect(fora[2].noteNumber == nil)
    }

    // MARK: - Body glued to the number (Neutrality v80)

    /// Body glued to the marker ("1The first edition..."), below the rule:
    /// it is still a note and goes to the marker. The typical academic PDF joins
    /// the number to the text without a space; without this the note stayed in the page flow.
    @Test func gluedBodyGoesToMarker() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "tese aqui.1", page: 0, topo: 500),
            sentenceBox(1, "1The first edition associates the way with instrumentalism", page: 0, topo: 50),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].noteNumber == 1)
        #expect(fora[1].text.hasPrefix("The first edition"))
        #expect(!fora[1].text.hasPrefix("1"))
    }

    /// Continuations of the same note (following lines below the rule, with no new
    /// number) rise together with the body, in footnote order. Without this, only the
    /// first sentence went to the marker and the rest of the note stayed in the flow.
    @Test func noteContinuationsRiseTogether() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "tese aqui.2", page: 0, topo: 500),
            sentenceBox(1, "2Demopoulos makes the preservation a condition of adequacy", page: 0, topo: 60),
            sentenceBox(2, "and truth is a condition of the reconstruction of Carnap", page: 0, topo: 45),
            sentenceBox(3, "he argues that a claim of structural similarity is significant", page: 0, topo: 30),
            sentenceBox(4, "frase corrida acima da zona de notas aqui", page: 0, topo: 400),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        #expect(fora.map(\.index) == [0, 1, 2, 3, 4])
        #expect(fora[1].noteNumber == 2)
        #expect(fora[2].noteNumber == 2)
        #expect(fora[3].noteNumber == 2)
        #expect(fora[4].noteNumber == nil)
    }

    /// Above the rule the old rule still holds: a glued number is not a
    /// note (it may be a year or running text), and nothing moves.
    @Test func aboveRuleGluedIsNotNote() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "tese aqui.1", page: 0, topo: 500),
            sentenceBox(1, "1The year 2024 brought a change in the field of study", page: 0, topo: 300),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].noteNumber == nil)
    }

    /// Without the rule (via PDFKit, no PyMuPDF), the glued case does not link: without the
    /// confirmed zone, it would risk eating running text. The old rule holds.
    @Test func withoutRuleGluedDoesNotLink() {
        let list = [
            sentence(0, "tese aqui.1", page: 0),
            sentence(1, "1The first edition associates the way with instrumentalism", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].noteNumber == nil)
    }

    /// M5: the marker may come AFTER the body (the search on the same page has no
    /// ceiling); then body and continuations are removed BEFORE it and markerPos
    /// goes stale. The note must enter exactly after the marker's sentence
    /// — not after the next sentence — accounting for every removal.
    @Test func markerAfterBodyInsertsAtAnchor() {
        let pageRules: [Int: CGFloat] = [0: 100]
        let list = [
            sentenceBox(0, "7 Autores afirmam isto aqui", page: 0, topo: 50),
            sentenceBox(1, "continuação da nota linha dois aqui", page: 0, topo: 40),
            sentenceSup(2, "argumento segue aqui", page: 0, palavras: [("argumento", false), ("7", true), ("segue", false)]),
            sentenceBox(3, "frase corrida depois do marcador aqui", page: 0, topo: 500),
        ]
        let fora = TextImport.resolveFootnotes(list, pageRules: pageRules)
        #expect(fora.map(\.index) == [2, 0, 1, 3])
        #expect(fora[0].noteMarker == 7)
        #expect(fora[1].noteNumber == 7)
        #expect(fora[2].noteNumber == 7)
        #expect(fora[3].noteNumber == nil)
    }

    // MARK: - Announcement by the pipeline (noteMarker)

    /// The pipeline marks the marker's sentence; the announcement no longer depends on the
    /// textual shape of the digit ("world 7", "theory7"), which the regex silences.
    @Test func pipelineMarksMarkerSentence() {
        let list = [
            sentenceSup(0, "argumento segue aqui", page: 0, palavras: [("argumento", false), ("7", true), ("segue", false)]),
            sentence(1, "outra frase no meio", page: 0),
            sentence(2, "7 Autores afirmam isto aqui", page: 0),
        ]
        let fora = TextImport.resolveFootnotes(list)
        #expect(fora[0].noteMarker == 7)
        #expect(fora[1].noteNumber == 7)
    }

    /// With the pipeline mark, `forSpeech` announces once only, even with no
    /// digit at all in the text.
    @Test func pipelineMarkAnnouncesOnce() {
        let spoken = ReadAloudFilter.forSpeech("argumento segue aqui", voice: en, marker: 7)
        #expect(spoken.components(separatedBy: "footnote 7").count - 1 == 1)
    }

    /// The pipeline mark does not duplicate the textual announcement (".7" announces in
    /// place; the end of the sentence does not repeat).
    @Test func pipelineMarkDoesNotDuplicate() {
        let spoken = ReadAloudFilter.forSpeech("argumento.7 segue", voice: en, marker: 7)
        #expect(spoken.components(separatedBy: "footnote 7").count - 1 == 1)
    }

    /// The pipeline mark with the option off stays silent.
    @Test func pipelineMarkSilentWhenOff() {
        let spoken = ReadAloudFilter.forSpeech("argumento segue aqui", voice: en, readFootnotes: false, marker: 7)
        #expect(!spoken.contains("footnote"))
    }
}
