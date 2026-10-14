import CoreGraphics
import Foundation
import Testing

@testable import EdgeSpeak

/// Synthesis chunking: paragraph-end boundary and silence trimming.
///
/// Owner's motivation: slice transitions stuttered — the cut landed mid-thought
/// and each slice carried the TTS's final breath.
struct EdgeTTSChunkTests {
    private func phrase(_ i: Int, length: Int, paragraphEnd: Bool = false) -> TextImport.Phrase {
        TextImport.Phrase(
            index: i, text: String(repeating: "x", count: length),
            page: nil, rects: [], paragraphEnd: paragraphEnd)
    }

    /// With overflow into the next paragraph, the cut retreats to the previous
    /// paragraph end instead of splitting the thought.
    @Test func sliceCutsAtParagraphEnd() {
        let phrases = [
            phrase(0, length: 100), phrase(1, length: 100, paragraphEnd: true),
            phrase(2, length: 100), phrase(3, length: 100),
        ]
        let slices = EdgeTTS.buildChunks(phrases, maxChars: 350, firstChars: 350)
        #expect(slices.map { $0.map(\.index) } == [[0, 1], [2, 3]])
    }

    /// Short first slice preserved (audio starts fast).
    @Test func firstSliceKeptShort() {
        let phrases = [phrase(0, length: 200), phrase(1, length: 200), phrase(2, length: 200)]
        let slices = EdgeTTS.buildChunks(phrases, maxChars: 1800)
        #expect(slices.count == 2)
        #expect(slices[0].map(\.index) == [0, 1])
    }

    /// Paragraph larger than the slice still splits (no stall, no lost sentence).
    @Test func giantParagraphStillSplits() {
        let phrases = [phrase(0, length: 2000, paragraphEnd: true), phrase(1, length: 100)]
        let slices = EdgeTTS.buildChunks(phrases, maxChars: 350, firstChars: 350)
        #expect(slices.map { $0.map(\.index) } == [[0], [1]])
    }

    /// The trim asks ffmpeg for exactly the trailing silence.
    @Test func trimRequestsEndSilence() {
        let args = EdgeTTS.silenceTrimArgs(
            input: URL(fileURLWithPath: "/a.mp3"),
            output: URL(fileURLWithPath: "/b.mp3"))
        #expect(args.contains("/a.mp3"))
        #expect(args.contains("/b.mp3"))
        #expect(args.joined(separator: " ").contains("silenceremove=stop_periods=-1"))
    }

    /// Unreadable timings JSON: audio proceeds (empty segments), but the
    /// warning comes back — never zeroed timing in silence.
    @Test func unreadableTimingsWarnInsteadOfZeroing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(UUID().uuidString).json")
        try Data("{não é json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (segments, warning) = EdgeTTS.loadSegments(url, locale: .en)
        #expect(segments.isEmpty)
        #expect(warning?.isEmpty == false)
    }

    /// The timing warning does not match the progress bar's "n/n": it is not
    /// progress, and the bar must not invent progress.
    @Test func warningWithoutTimingsDoesNotLieToBar() {
        let warning = EdgeTTS.warningWithoutTimings(
            slice: 3, reason: "unreadable timings in chunk-0003.json", locale: .en)
        #expect(SpeechController.parseProgress(warning) == nil)
    }
}
