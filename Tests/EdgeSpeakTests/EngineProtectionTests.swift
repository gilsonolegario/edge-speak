import Foundation
import Testing

@testable import EdgeSpeak

/// Cross-engine protection (M4) and duration with an extra chunk (B3).
struct EngineProtectionTests {
    private func u16(_ v: UInt16, into data: inout Data) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    private func u32(_ v: UInt32, into data: inout Data) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    /// 2 s WAV (22050 Hz, mono, 16-bit) with a LIST chunk between `fmt`
    /// and `data`: the measured duration must ignore the extra chunk.
    private func wavWithList() -> Data {
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        u32(0, into: &data)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        u32(16, into: &data)
        u16(1, into: &data) // PCM
        u16(1, into: &data) // mono
        u32(22050, into: &data)
        u32(44100, into: &data) // byte rate
        u16(2, into: &data) // block align
        u16(16, into: &data) // bits
        data.append(contentsOf: [0x4C, 0x49, 0x53, 0x54]) // "LIST"
        u32(100, into: &data)
        data.append(Data(repeating: 0, count: 100))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        u32(88200, into: &data) // 44100 2-byte samples = 2 s
        data.append(Data(repeating: 0, count: 88200))
        let total = UInt32(data.count - 8)
        data[4] = UInt8(total & 0xFF)
        data[5] = UInt8((total >> 8) & 0xFF)
        data[6] = UInt8((total >> 16) & 0xFF)
        data[7] = UInt8((total >> 24) & 0xFF)
        return data
    }

    /// The online engine's purge preserves the registered offline directory:
    /// without this the in-progress reading silently lost its WAVs (M4).
    @Test func purgePreservesOfflineReading() {
        let fm = FileManager.default
        let suffix = UUID().uuidString
        let online = fm.temporaryDirectory.appendingPathComponent("EdgeSpeak-test-online-\(suffix)")
        let offline = fm.temporaryDirectory.appendingPathComponent("EdgeSpeak-test-offline-\(suffix)")
        try? fm.createDirectory(at: online, withIntermediateDirectories: true)
        try? fm.createDirectory(at: offline, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: online)
            try? fm.removeItem(at: offline)
        }
        EdgeTTS.keepOfflineDirectory(offline)
        EdgeTTS.purgeStaleDirectories(keeping: online)
        #expect(fm.fileExists(atPath: online.path))
        #expect(fm.fileExists(atPath: offline.path))
    }

    /// Extra chunk (LIST) does not contaminate the duration: 2 s measured, not ~2.002 s.
    @Test func durationCrossesExtraChunk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phrase-\(UUID().uuidString).wav")
        try wavWithList().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = PiperTTS.duration(of: url)
        #expect(abs((duration ?? -1) - 2.0) < 0.001)
    }
}
