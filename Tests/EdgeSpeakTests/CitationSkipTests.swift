import Foundation
import Testing

@testable import EdgeSpeak

/// Citation unwrapping: content kept, delimiters out; DOI and page lines out,
// prose untouched; toggleable with a stable key for the future switch.
///
/// `.serialized`: os testes do weld (toggle real e o de regressão da flag)
/// escrevem a chave `citationUnwrap` no `UserDefaults` de verdade; em
/// paralelo, um lia a escrita do outro no meio do próprio corpo — a
/// intermitência de 2026-10-17/18.
@Suite(.serialized)
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

    // MARK: - Wiring to the speech path (plan item 38)

    /// The weld the engines call: `ReadAloudFilter`'s speech text plus the
    /// citation pass on top. Mutation: make `speechText` return `spoken`
    /// without `forSpeech` and this test goes red.
    @Test func speechWeldAppliesCitationsWhenOn() {
        let raw = "as shown (Smith, 2020) at doi:10.1234/abc.def end"
        let spoken = CitationSkip.speechText(
            raw, voice: "en-US-AndrewNeural", unwrapping: true)
        #expect(spoken.contains("Smith, 2020"))
        #expect(spoken.contains("(Smith, 2020)") == false)
        #expect(spoken.contains("10.1234/abc.def") == false)
    }

    /// Toggle off: the engines emit exactly what `ReadAloudFilter` emits today,
    /// byte for byte — the weld is a no-op, the old behavior is preserved.
    @Test func speechWeldIsNoOpWhenOff() {
        let raw = "as shown (Smith, 2020) at doi:10.1234/abc.def end"
        let today = ReadAloudFilter.forSpeech(raw, voice: "en-US-AndrewNeural")
        #expect(CitationSkip.speechText(
            raw, voice: "en-US-AndrewNeural", unwrapping: false) == today)
    }

    /// The engines' weld (no flag) reads the real toggle, so the Settings
    /// switch reaches speech. Writes the key and puts it back: the assertions
    /// cannot use the flag variant without losing the point of the test.
    /// A DOI is the discriminator here — `ReadAloudFilter` alone leaves it.
    @Test func speechWeldFollowsTheSettingsToggle() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: CitationSkip.settingKey)
        defer {
            if let previous { defaults.set(previous, forKey: CitationSkip.settingKey) }
            else { defaults.removeObject(forKey: CitationSkip.settingKey) }
        }
        let raw = "see doi:10.1234/abc.def end"
        CitationSkip.setEnabled(true)
        #expect(CitationSkip.speechText(raw, voice: "en-US-AndrewNeural").contains("10.1234/abc.def") == false)
        CitationSkip.setEnabled(false)
        #expect(CitationSkip.speechText(raw, voice: "en-US-AndrewNeural").contains("10.1234/abc.def"))
    }

    /// A flag explícita VENCE a chave: a variante de flag precisa ficar fora do
    /// estado global (contrato dela). Regressão: até 2026-10-18 o ramo `true`
    /// do weld chamava `forSpeech` de um argumento, que relê `isEnabled` — com
    /// a chave em `false`, "(Smith, 2020)" sobrevivia aqui, quebrando o teste
    /// vizinho de forma intermitente (a falha que as duas lanes viram).
    @Test func flagVariantIgnoresTheGlobalToggle() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: CitationSkip.settingKey)
        defer {
            if let previous { defaults.set(previous, forKey: CitationSkip.settingKey) }
            else { defaults.removeObject(forKey: CitationSkip.settingKey) }
        }
        CitationSkip.setEnabled(false)
        let raw = "as shown (Smith, 2020) at doi:10.1234/abc.def end"
        let spoken = CitationSkip.speechText(
            raw, voice: "en-US-AndrewNeural", unwrapping: true)
        #expect(spoken.contains("Smith, 2020"))
        #expect(spoken.contains("(Smith, 2020)") == false)
        #expect(spoken.contains("10.1234/abc.def") == false)
    }

    /// Source guard for the weld's three call sites (`EdgeTTS.swift` twice,
    /// `PiperTTS.swift` once). Needed because the engines cannot be driven from
    /// a unit test — the online path needs the service and python, the offline
    /// one needs the ONNX model — so a refactor could drop the weld from a call
    /// line and every behavioral test above would stay green (verified: with the
    /// call site reverted to `ReadAloudFilter.forSpeech` the suite passes). The
    /// guard fails in that case; updating this test is the reminder that the
    /// citation policy must not be bypassed silently.
    @Test func enginesRouteSpeechTextThroughTheWeld() throws {
        // Tests/EdgeSpeakTests → Tests → the package root.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected = ["EdgeTTS.swift": 2, "PiperTTS.swift": 1]
        for (file, count) in expected {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent("Sources/EdgeSpeak/\(file)"),
                encoding: .utf8)
            #expect(
                source.components(separatedBy: "CitationSkip.speechText(").count - 1 == count,
                "\(file): esperava \(count) chamada(s) ao weld das citações")
            #expect(
                source.contains("ReadAloudFilter.forSpeech(") == false,
                "\(file): chama ReadAloudFilter.forSpeech direto, sem o passe de citações")
        }
    }
}
