import Foundation
import Testing

@testable import EdgeSpeak

/// Retomada por documento: guardar, buscar, esquecer e a guarda de cobertura.
///
/// Usa suite efêmera de `UserDefaults`: não toca nas preferências reais.
struct ResumeTests {
    private func limpo() -> UserDefaults {
        let d = UserDefaults(suiteName: "EdgeSpeakTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "EdgeSpeakTests-\(UUID().uuidString)")
        return d
    }

    @Test func roundTrip() {
        let d = limpo()
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == nil)
        ReadingPositionStore.save(documentID: "a", voice: "v", position: 42, defaults: d)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == 42)
        // Outro documento/voz não herda.
        #expect(ReadingPositionStore.load(documentID: "b", voice: "v", defaults: d) == nil)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "w", defaults: d) == nil)
        ReadingPositionStore.clear(documentID: "a", voice: "v", defaults: d)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == nil)
    }

    @Test func abaixoDe3sNaoGuarda() {
        let d = limpo()
        ReadingPositionStore.save(documentID: "a", voice: "v", position: 2.9, defaults: d)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == nil)
    }

    @Test func guardaDeCobertura() {
        // Sem ponto salvo, sem áudio ou ponto além do medido: do zero.
        #expect(ReadingPositionStore.shouldResume(saved: nil, knownDuration: 100) == false)
        #expect(ReadingPositionStore.shouldResume(saved: 50, knownDuration: 0) == false)
        #expect(ReadingPositionStore.shouldResume(saved: 50, knownDuration: 30) == false)
        #expect(ReadingPositionStore.shouldResume(saved: 50, knownDuration: 50) == true)
        #expect(ReadingPositionStore.shouldResume(saved: 2, knownDuration: 100) == false)
    }
}