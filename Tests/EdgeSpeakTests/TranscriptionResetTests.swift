import Foundation
import Testing

@testable import EdgeSpeak

/// Prova do descarte de transcrição na troca de modo (sem áudio nem rede):
/// as duas listas geram textos e chaves de cache diferentes, o `remove`
/// apaga a entrada e o descarte deixa o estado limpo.
@MainActor
struct TranscriptionResetTests {
    private let voz = "pt-BR-FranciscaNeural"
    private let cadencia = EdgeTTS.Rate.normal

    /// Texto com citação autor-ano, que o filtro descarta no modo filtrado.
    private var textoComRuido: String {
        "O argumento central é válido. Como nota a literatura (Carnap 1974, 256), "
            + "a tese se sustenta. A conclusão fecha o capítulo."
    }

    private func textoDaLista(_ frases: [TextImport.Phrase]) -> String {
        frases.map { $0.text }.joined(separator: "\n")
    }

    /// As duas listas de leitura geram textos e chaves de cache diferentes.
    @Test func modosGeramTextosEChavesDiferentes() {
        let integral = TextImport.editorPhrases(textoComRuido, integral: true)
        let filtrada = TextImport.editorPhrases(textoComRuido, integral: false)
        let textoIntegral = textoDaLista(integral)
        let textoFiltrado = textoDaLista(filtrada)
        // O filtro remove a citação; o integral a mantém.
        #expect(textoIntegral != textoFiltrado)
        #expect(textoFiltrado.contains("Carnap") == false)
        let chaveIntegral = CacheDisco.key(text: textoIntegral, voice: voz, rate: cadencia)
        let chaveFiltrada = CacheDisco.key(text: textoFiltrado, voice: voz, rate: cadencia)
        #expect(chaveIntegral != chaveFiltrada)
    }

    /// `remove(key:)` apaga a entrada: `lookup` acha antes e não acha depois.
    @Test func removerApagaDoCache() {
        let chave = "teste-descarte-\(UUID().uuidString)"
        defer { CacheDisco.remove(key: chave) }
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-prova-\(UUID().uuidString).mp3")
        try? Data("áudio falso".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let trechos = [EdgeTTS.Segment(start: 0, duration: 1.0, text: "Frase de prova.", index: 0)]
        CacheDisco.store(key: chave, audioURL: audio, segments: trechos)
        #expect(CacheDisco.lookup(key: chave) != nil)
        CacheDisco.remove(key: chave)
        #expect(CacheDisco.lookup(key: chave) == nil)
    }

    /// O descarte deixa o estado limpo, sem "tocando" falso nem resto.
    @Test func descarteLimpaEstado() {
        let controle = SpeechController()
        #expect(controle.hasTranscription == false)
        controle.discardTranscription()
        #expect(controle.hasTranscription == false)
        #expect(controle.hasAudio == false)
        #expect(controle.segments.isEmpty)
        #expect(controle.phrases.isEmpty)
        #expect(controle.isPlaying == false)
        #expect(controle.isPaused == false)
        #expect(controle.isBusy == false)
    }
}
