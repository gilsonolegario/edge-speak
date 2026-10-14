import Foundation
import Testing

@testable import EdgeSpeak

/// Prova do espelho de estado (achado B1): mensagem transitória de status
/// sobrevive aos tiques do `objectWillChange` do streamer — o espelho só
/// republica quando o estado efetivo muda. Headless, sem áudio nem rede.
@MainActor
struct StatusMirrorTests {
    /// Drena o RunLoop.main para o sink `.receive(on: RunLoop.main)` entregar.
    private func drena() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    /// Fila inexistente esvazia de fato (catch do `playChunk` → `handleExhausted`).
    private func urlRuim() -> URL {
        URL(fileURLWithPath: "/inexistente/chunk-\(UUID().uuidString).mp3")
    }

    /// Leva o streamer ao estado "finalizado", o único que o espelho publica
    /// sem áudio: falha na fila + síntese marcada como fechada.
    private func finaliza(_ controle: SpeechController) {
        controle.streamer.start(urls: [urlRuim()], chunkSegments: [[]])
        controle.streamer.markSynthesisComplete()
        controle.streamer.enqueue(urls: [urlRuim()], chunkSegments: [[]])
        drena()
    }

    /// Status transitório sobrevive aos tiques; mudança de estado ainda vence.
    @Test func statusTransitorioSobreviveAosTiques() {
        let controle = SpeechController()
        finaliza(controle)
        // O espelho publicou o fim (status deixou de ser o inicial vazio).
        #expect(controle.status.isEmpty == false)

        // Mensagem transitória, pelo mesmo caminho do "cache limpo".
        controle.discardTranscription()
        let transitorio = controle.status
        #expect(transitorio.isEmpty == false)

        // Tiques sem mudança de estado: antes do fix, "status.finished"
        // sobrescrevia em ~100 ms a mensagem transitória.
        for _ in 0..<5 {
            controle.streamer.volume = Float.random(in: 0...1)
            drena()
        }
        #expect(controle.status == transitorio)

        // Mudança de estado real (nova "leitura" termina): o espelho volta
        // a publicar, sobrescrevendo o transitório — a guarda não o congela.
        // O dreno intermediário registra o estado da fila em espera, sem o
        // qual os tiques enfileirados só veriam o "finalizado" já corrente.
        controle.streamer.start(urls: [urlRuim()], chunkSegments: [[]])
        drena()
        controle.streamer.markSynthesisComplete()
        controle.streamer.enqueue(urls: [urlRuim()], chunkSegments: [[]])
        drena()
        #expect(controle.status != transitorio)
    }
}
