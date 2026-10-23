import Foundation
import Testing

@testable import EdgeSpeak

/// Proof of transcription discard on mode switch (no audio or network):
/// the two lists produce different texts and cache keys, `remove`
/// apaga a entrada e o descarte deixa o estado limpo.
@MainActor
struct TranscriptionResetTests {
    private let voice = "pt-BR-FranciscaNeural"
    private let cadence = EdgeTTS.Rate.normal

    /// Text with author-year citation, which the filter unwraps in filtered mode.
    private var noisyText: String {
        "O argumento central é válido. Como nota a literatura (Carnap 1974, 256), "
            + "a tese se sustenta. A conclusão fecha o capítulo."
    }

    private func textFromList(_ sentences: [TextImport.Phrase]) -> String {
        sentences.map { $0.text }.joined(separator: "\n")
    }

    /// As duas listas de leitura geram textos e chaves de cache diferentes.
    @Test func modesProduceDifferentTextsAndKeys() {
        let integral = TextImport.editorPhrases(noisyText, integral: true)
        let filtrada = TextImport.editorPhrases(noisyText, integral: false)
        let wholeText = textFromList(integral)
        let filteredText = textFromList(filtrada)
        // The filter unwraps the citation (parens out, content kept); the
        // integral mode keeps it verbatim.
        #expect(wholeText != filteredText)
        #expect(wholeText.contains("(Carnap 1974, 256)"))
        #expect(filteredText.contains("Carnap 1974, 256"))
        #expect(filteredText.contains("(Carnap") == false)
        let chaveIntegral = DiskCache.key(text: wholeText, voice: voice, rate: cadence)
        let chaveFiltrada = DiskCache.key(text: filteredText, voice: voice, rate: cadence)
        #expect(chaveIntegral != chaveFiltrada)
    }

    /// `remove(key:)` erases the entry: `lookup` finds it before and not after.
    @Test func removeClearsFromCache() {
        let key = "teste-descarte-\(UUID().uuidString)"
        defer { DiskCache.remove(key: key) }
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-prova-\(UUID().uuidString).mp3")
        try? Data("áudio falso".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let passages = [EdgeTTS.Segment(start: 0, duration: 1.0, text: "Frase de prova.", index: 0)]
        DiskCache.store(key: key, audioURL: audio, segments: passages)
        #expect(DiskCache.lookup(key: key) != nil)
        DiskCache.remove(key: key)
        #expect(DiskCache.lookup(key: key) == nil)
    }

    /// O descarte deixa o estado limpo, sem "tocando" falso nem resto.
    @Test func discardClearsState() {
        let controller = SpeechController()
        #expect(controller.hasTranscription == false)
        controller.discardTranscription()
        #expect(controller.hasTranscription == false)
        #expect(controller.hasAudio == false)
        #expect(controller.segments.isEmpty)
        #expect(controller.phrases.isEmpty)
        #expect(controller.isPlaying == false)
        #expect(controller.isPaused == false)
        #expect(controller.isBusy == false)
    }
}
