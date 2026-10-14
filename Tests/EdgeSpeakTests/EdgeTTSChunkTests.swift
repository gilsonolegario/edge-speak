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
            index: i, text: String(repeating: "x", count: max(0, length - 1)) + ".",
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

    /// A sentence split across pages (passages without terminal punctuation)
    /// never straddles two slices: the cut waits for the period.
    @Test func sliceNeverCutsMidSentence() {
        let a = TextImport.Phrase(index: 0, text: "The first half of the thought", page: 3, rects: [])
        let b = TextImport.Phrase(index: 1, text: "ends on the next page.", page: 4, rects: [])
        let c = TextImport.Phrase(index: 2, text: String(repeating: "y.", count: 200), page: 4, rects: [])
        let slices = EdgeTTS.buildChunks([a, b, c], maxChars: 120, firstChars: 120)
        #expect(slices[0].map(\.index) == [0, 1])
    }

    /// Runaway text without punctuation still splits (hard 2x ceiling).
    @Test func runawayTextStillSplits() {
        let a = TextImport.Phrase(index: 0, text: String(repeating: "z", count: 100), page: nil, rects: [])
        let b = TextImport.Phrase(index: 1, text: String(repeating: "z", count: 100), page: nil, rects: [])
        let c = TextImport.Phrase(index: 2, text: String(repeating: "z", count: 100), page: nil, rects: [])
        let slices = EdgeTTS.buildChunks([a, b, c], maxChars: 120, firstChars: 120)
        #expect(slices.count == 2)
        #expect(slices[0].count == 2)
    }

    /// Leading-silence parser: the end of the silence starting at zero.
    @Test func leadingSilenceParses() {
        let err = """
        [Parsed_silencedetect_0] silence_start: 0
        [Parsed_silencedetect_0] silence_end: 0.189917 | silence_duration: 0.189917
        [Parsed_silencedetect_0] silence_start: 1.142333
        """
        #expect(abs(EdgeTTS.parseLeadingSilence(err) - 0.189917) < 0.0001)
        #expect(EdgeTTS.parseLeadingSilence("no silence here") == 0)
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

    /// Lead slices stay short: with `leadChunks` covering the player's start
    /// gate, the first sound (and the yellow) no longer waits on a huge
    /// second slice; coverage and order are unchanged.
    @Test func leadSlicesStayShort() {
        let phrases = (0..<9).map { phrase($0, length: 200) }
        let slices = EdgeTTS.buildChunks(phrases, maxChars: 1800, leadChunks: 3)
        #expect(slices.map { $0.map(\.index) } == [[0, 1], [2, 3], [4, 5], [6, 7, 8]])
        #expect(slices.flatMap { $0.map(\.index) } == Array(0..<9))
    }
}
