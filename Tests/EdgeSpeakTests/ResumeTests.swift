import Foundation
import Testing

@testable import EdgeSpeak

/// Retomada por documento: guardar, buscar, esquecer e a guarda de cobertura.
///
/// Uses an ephemeral `UserDefaults` suite: does not touch the real preferences.
struct ResumeTests {
    private func clean() -> UserDefaults {
        let d = UserDefaults(suiteName: "EdgeSpeakTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "EdgeSpeakTests-\(UUID().uuidString)")
        return d
    }

    @Test func roundTrip() {
        let d = clean()
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == nil)
        ReadingPositionStore.save(documentID: "a", voice: "v", position: 42, defaults: d)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == 42)
        // Another document/voice does not inherit.
        #expect(ReadingPositionStore.load(documentID: "b", voice: "v", defaults: d) == nil)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "w", defaults: d) == nil)
        ReadingPositionStore.clear(documentID: "a", voice: "v", defaults: d)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == nil)
    }

    @Test func below3sDoesNotStore() {
        let d = clean()
        ReadingPositionStore.save(documentID: "a", voice: "v", position: 2.9, defaults: d)
        #expect(ReadingPositionStore.load(documentID: "a", voice: "v", defaults: d) == nil)
    }

    @Test func coverageStore() {
        // No saved point, no audio, or point beyond what was measured: from scratch.
        #expect(ReadingPositionStore.shouldResume(saved: nil, knownDuration: 100) == false)
        #expect(ReadingPositionStore.shouldResume(saved: 50, knownDuration: 0) == false)
        #expect(ReadingPositionStore.shouldResume(saved: 50, knownDuration: 30) == false)
        #expect(ReadingPositionStore.shouldResume(saved: 50, knownDuration: 50) == true)
        #expect(ReadingPositionStore.shouldResume(saved: 2, knownDuration: 100) == false)
    }
}