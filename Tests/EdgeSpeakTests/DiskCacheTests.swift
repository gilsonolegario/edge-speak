import Foundation
import Testing

@testable import EdgeSpeak

/// Cache cleanup with self-preservation of the current read.
///
/// Uses unique "test-*" keys and cleans everything at the end: nothing is left in
/// the real cache directory.
struct DiskCacheTests {
    private func audio(_ nome: String, within dir: URL) -> URL {
        let u = dir.appendingPathComponent(nome)
        try? Data("x".utf8).write(to: u)
        return u
    }

    private func segs() -> [EdgeTTS.Segment] {
        [EdgeTTS.Segment(start: 0, duration: 1, text: "t", words: [])]
    }

    @Test func pruneKeepsCurrent() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        DiskCache.store(key: "teste-a", audioURL: audio("a.mp3", within: tmp), segments: segs())
        DiskCache.store(key: "teste-b", audioURL: audio("b.mp3", within: tmp), segments: segs())
        #expect(DiskCache.lookup(key: "teste-a") != nil)
        #expect(DiskCache.lookup(key: "teste-b") != nil)
        let freed = DiskCache.clearAll(preserving: "teste-a")
        #expect(freed > 0)
        #expect(DiskCache.lookup(key: "teste-a") != nil)
        #expect(DiskCache.lookup(key: "teste-b") == nil)
        DiskCache.remove(key: "teste-a")
        #expect(DiskCache.lookup(key: "teste-a") == nil)
        #expect(DiskCache.totalBytes() >= 0)
    }
}