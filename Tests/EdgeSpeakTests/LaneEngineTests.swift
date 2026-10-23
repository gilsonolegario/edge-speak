import Foundation
import Testing

@testable import EdgeSpeak

/// Engines of the lanes (online EdgeTTS / offline Piper): capture of the
/// child's stderr with a bounded tail, and duration measurement with the
/// real fallback (the silent 0 shifted every slice after the failed one).
struct LaneEngineTests {
    // MARK: - Piper: bounded stderr tail

    @Test func tailBufferKeepsOnlyTheLastBytes() {
        let tail = PiperTTS.TailBuffer(limit: 8)
        tail.append(Data("0123456789".utf8))
        #expect(tail.text == "23456789")
    }

    @Test func tailBufferAccumulatesChunksUnderTheLimit() {
        let tail = PiperTTS.TailBuffer(limit: 64)
        tail.append(Data("Traceback (most recent call last):\n".utf8))
        tail.append(Data("OSError: model not found\n".utf8))
        #expect(tail.text.contains("Traceback"))
        #expect(tail.text.contains("OSError: model not found"))
    }

    /// The ring can trim mid multi-byte sequence: the orphan byte must be
    /// dropped from the head, or the whole tail fails to decode.
    @Test func tailBufferDropsOrphanUTF8Byte() {
        let tail = PiperTTS.TailBuffer(limit: 2)
        tail.append(Data([0xC3, 0xA9])) // "é" fills the ring exactly.
        tail.append(Data([0x7A]))       // "z" evicts 0xC3: ring is 0xA9 0x7A.
        #expect(tail.text == "z")
    }

    @Test func withStderrAppendsTailKeepingTheKey() {
        let base = NSError(
            domain: "EdgeSpeak.PiperTTS", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "The offline voice did not respond while loading. Try again.",
                "l10nKey": "error.offlineNotReady",
                "l10nArgs": [String](),
            ])
        let detailed = PiperTTS.withStderr(base, " \nTraceback: model not found\n")
        #expect(detailed.localizedDescription.contains("did not respond"))
        #expect(detailed.localizedDescription.contains("model not found"))
        // The key survives so `failureKey` can re-resolve on language switch.
        #expect(detailed.userInfo["l10nKey"] as? String == "error.offlineNotReady")
    }

    @Test func withStderrEmptyTailKeepsTheSameError() {
        let base = NSError(domain: "EdgeSpeak.PiperTTS", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "no cause"])
        #expect(PiperTTS.withStderr(base, "  \n") === base)
    }

    /// Real child: stderr reaches the tail, stdout stays out, and the drain
    /// ends by itself at EOF (no pipe that could fill and block the child).
    @Test func drainStderrCapturesChildStderr() throws {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "printf 'stdout stay out\\n'; printf 'fatal: model not found\\n' >&2; exit 3"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = pipe
        try proc.run()
        let tail = PiperTTS.TailBuffer(limit: 4096)
        PiperTTS.drainStderr(pipe.fileHandleForReading, into: tail)
        proc.waitUntilExit()
        // EOF lands right after the exit; give the drain a moment.
        let deadline = Date().addingTimeInterval(5)
        while !tail.text.contains("fatal: model not found"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(proc.terminationStatus == 3)
        #expect(tail.text.contains("fatal: model not found"))
        #expect(!tail.text.contains("stdout stay out"))
    }

    // MARK: - EdgeTTS: duration measured by a real path

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

    /// Plain 16-bit mono PCM WAV with a quiet tone (pure zeros risk a
    /// decoder reporting an indefinite duration).
    private func makeWAV(seconds: Double, sampleRate: Int = 8000) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        let dataSize = frames * 2
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        u32(UInt32(36 + dataSize), into: &data)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        u32(16, into: &data)
        u16(1, into: &data) // PCM
        u16(1, into: &data) // mono
        u32(UInt32(sampleRate), into: &data)
        u32(UInt32(sampleRate * 2), into: &data) // byte rate
        u16(2, into: &data) // block align
        u16(16, into: &data) // bits
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        u32(UInt32(dataSize), into: &data)
        for i in 0..<frames {
            let sample = Int16(sin(2.0 * .pi * 440.0 * Double(i) / Double(sampleRate)) * 8_000.0)
            u16(UInt16(bitPattern: sample), into: &data)
        }
        return data
    }

    private func writeTemp(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-engine-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    /// The fallback probe (`AVAudioPlayer`, the path the player itself uses)
    /// measures the file when the asset path cannot.
    @Test func playerDurationMeasuresRealAudio() throws {
        let url = try writeTemp(makeWAV(seconds: 0.25), ext: "wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let measured = EdgeTTS.playerDuration(of: url)
        #expect(measured != nil)
        #expect(abs((measured ?? -1) - 0.25) < 0.02)
    }

    @Test func playerDurationIsNilWhenUnreadable() throws {
        let url = try writeTemp(Data("not audio at all".utf8), ext: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EdgeTTS.playerDuration(of: url) == nil)
    }

    @Test func durationMeasuresTheRealFileNotZero() async throws {
        let url = try writeTemp(makeWAV(seconds: 0.25), ext: "wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let measured = await EdgeTTS.duration(of: url)
        #expect(measured > 0)
        #expect(abs(measured - 0.25) < 0.02)
    }

    /// Unreadable file: both parsers fail together and the result is a finite
    /// 0 — never NaN, which would poison every offset after that slice.
    @Test func durationOfUnreadableFileIsFiniteZero() async throws {
        let url = try writeTemp(Data(repeating: 0x5A, count: 4096), ext: "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let measured = await EdgeTTS.duration(of: url)
        #expect(measured.isFinite)
        #expect(measured == 0)
    }

    // MARK: - The pure duration rule (asset vs player fallback)

    /// The asset measure wins when it is valid, whichever the player says.
    @Test func chooseDurationKeepsTheAssetMeasure() {
        #expect(EdgeTTS.chooseDuration(asset: 0.3, player: 0.7) == 0.3)
        #expect(EdgeTTS.chooseDuration(asset: 0.3, player: nil) == 0.3)
    }

    /// Asset 0/nil/NaN/∞ (or a load failure, seen here as nil) must fall to the
    /// PLAYER measure — restoring the old behavior ("use the asset or a silent
    /// 0, no fallback") makes every one of these expectations fail.
    @Test func chooseDurationFallsToPlayerWhenAssetFails() {
        let badAssets: [Double?] = [nil, 0, .nan, .infinity, -.infinity]
        for bad in badAssets {
            #expect(EdgeTTS.chooseDuration(asset: bad, player: 2.25) == 2.25)
        }
        #expect(EdgeTTS.chooseDuration(asset: 0, player: .infinity) == 0)
    }

    /// Only BOTH probes failing yields the finite 0 (the contract of the old
    /// `durationOfUnreadableFileIsFiniteZero`).
    @Test func chooseDurationZeroOnlyWhenBothProbesFail() {
        #expect(EdgeTTS.chooseDuration(asset: nil, player: nil) == 0)
        #expect(EdgeTTS.chooseDuration(asset: 0, player: 0) == 0)
        #expect(EdgeTTS.chooseDuration(asset: .nan, player: .nan) == 0)
    }

    // MARK: - Piper download: the HTTP status rules before any byte

    @Test func httpFailureStatusCatchesRejectedRequests() {
        #expect(PiperTTS.httpFailureStatus(of: HTTPURLResponse(
            url: URL(string: "https://x/y.onnx")!, statusCode: 404,
            httpVersion: nil, headerFields: nil)!) == 404)
        #expect(PiperTTS.httpFailureStatus(of: HTTPURLResponse(
            url: URL(string: "https://x/y.onnx")!, statusCode: 503,
            httpVersion: nil, headerFields: nil)!) == 503)
        #expect(PiperTTS.httpFailureStatus(of: HTTPURLResponse(
            url: URL(string: "https://x/y.onnx")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!) == nil)
        #expect(PiperTTS.httpFailureStatus(of: URLResponse(
            url: URL(string: "https://x/y.onnx")!, mimeType: nil,
            expectedContentLength: -1, textEncodingName: nil)) == nil)
    }

    /// The diagnostic carries the status and a BOUNDED head of the page: a
    /// huge HTML error body never floods the interface.
    @Test func httpStatusDetailCarriesStatusAndBoundedHead() {
        let long = Data("Much text before the error. ".utf8) + Data(repeating: 0x78, count: 500)
        let detail = PiperTTS.httpStatusDetail(status: 404, body: long)
        #expect(detail.hasPrefix("HTTP 404: "))
        #expect(detail.count <= "HTTP 404: ".count + 200)
        #expect(PiperTTS.httpStatusDetail(status: 503, body: Data()) == "HTTP 503")
        // A orphan byte mid UTF-8 sequence must not crash the conversion.
        #expect(PiperTTS.httpStatusDetail(status: 500, body: Data([0xC3, 0xA9])) == "HTTP 500: é")
    }
}
