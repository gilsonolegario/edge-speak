import Foundation
import Testing

@testable import EdgeSpeak

/// Citation unwrapping: content kept, delimiters out; DOI and page lines out,
// prose untouched; toggleable with a stable key for the future switch.
struct CitationSkipTests {
    @Test func bracketCitationsUnwrapped() {
        #expect(CitationSkip.forSpeech("as shown [12] before", unwrapping: true) == "as shown 12 before")
        #expect(CitationSkip.forSpeech("works [12, 13] agree", unwrapping: true) == "works 12, 13 agree")
    }

    @Test func disabledKeepsDelimiters() {
        #expect(CitationSkip.forSpeech("as shown [12] before", unwrapping: false) == "as shown [12] before")
        #expect(CitationSkip.forSpeech("said (Smith, 2020) loudly", unwrapping: false) == "said (Smith, 2020) loudly")
    }

    @Test func bracketProseSurvives() {
        #expect(CitationSkip.forSpeech("see [Fig. 2] here", unwrapping: true) == "see [Fig. 2] here")
    }

    @Test func authorYearUnwrapped() {
        #expect(CitationSkip.forSpeech("said (Smith, 2020) loudly", unwrapping: true) == "said Smith, 2020 loudly")
        #expect(CitationSkip.forSpeech("noted (Smith et al., 2019) twice", unwrapping: true) == "noted Smith et al., 2019 twice")
        #expect(CitationSkip.forSpeech("acid (Avery et al., 1944, 155). The rest", unwrapping: true) == "acid Avery et al., 1944, 155. The rest")
    }

    @Test func plainParentheticalSurvives() {
        #expect(CitationSkip.forSpeech("(in 2020 we saw) rain", unwrapping: true) == "(in 2020 we saw) rain")
    }

    @Test func doiOut() {
        #expect(CitationSkip.forSpeech("at doi:10.1234/abc.def end", unwrapping: true) == "at end")
        #expect(CitationSkip.forSpeech("see https://doi.org/10.1234/xyz end", unwrapping: true) == "see end")
    }

    @Test func pageNumberLineOut() {
        #expect(CitationSkip.forSpeech("first line\n123\nlast line", unwrapping: true) == "first line\n\nlast line")
    }

    @Test func toggleDefaultsOn() {
        #expect(CitationSkip.defaultOn == true)
        #expect(CitationSkip.settingKey == "citationUnwrap")
    }
}
