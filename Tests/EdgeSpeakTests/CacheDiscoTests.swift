import Foundation
import Testing

@testable import EdgeSpeak

/// Limpeza do cache com autopreservação da leitura corrente.
///
/// Usa chaves únicas "teste-*" e limpa tudo ao fim: não sobra nada no
/// diretório real de cache.
struct CacheDiscoTests {
    private func audio(_ nome: String, em dir: URL) -> URL {
        let u = dir.appendingPathComponent(nome)
        try? Data("x".utf8).write(to: u)
        return u
    }

    private func segs() -> [EdgeTTS.Segment] {
        [EdgeTTS.Segment(start: 0, duration: 1, text: "t", words: [])]
    }

    @Test func limpaPreservandoAtual() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        CacheDisco.store(key: "teste-a", audioURL: audio("a.mp3", em: tmp), segments: segs())
        CacheDisco.store(key: "teste-b", audioURL: audio("b.mp3", em: tmp), segments: segs())
        #expect(CacheDisco.lookup(key: "teste-a") != nil)
        #expect(CacheDisco.lookup(key: "teste-b") != nil)
        let livres = CacheDisco.clearAll(preserving: "teste-a")
        #expect(livres > 0)
        #expect(CacheDisco.lookup(key: "teste-a") != nil)
        #expect(CacheDisco.lookup(key: "teste-b") == nil)
        CacheDisco.remove(key: "teste-a")
        #expect(CacheDisco.lookup(key: "teste-a") == nil)
        #expect(CacheDisco.totalBytes() >= 0)
    }
}