import Testing

@testable import EdgeSpeak

/// Tests for PiperTTS.estimateWordTimings (pure function, no audio).
struct PiperWordTimingTests {

    @Test func emptyTextReturnsEmpty() {
        let result = PiperTTS.estimateWordTimings(text: "", totalDuration: 1.0)
        #expect(result.isEmpty)
    }

    @Test func zeroDurationReturnsEmpty() {
        let result = PiperTTS.estimateWordTimings(text: "hello world", totalDuration: 0)
        #expect(result.isEmpty)
    }

    @Test func singleWordGetsFullDuration() {
        let result = PiperTTS.estimateWordTimings(text: "hello", totalDuration: 2.0)
        #expect(result.count == 1)
        #expect(result[0].text == "hello")
        #expect(abs(result[0].start - 0.0) < 0.01)
        #expect(abs(result[0].duration - 2.0) < 0.01)
    }

    @Test func multipleWordsSumToTotalDuration() {
        let result = PiperTTS.estimateWordTimings(text: "hello world foo", totalDuration: 3.0)
        #expect(result.count == 3)
        let totalDur = result.reduce(0.0) { $0 + $1.duration }
        // Sum of word durations = speech time (total - gaps), which is
        // less than total. The last word ends at speechTime.
        #expect(totalDur < 3.0)
        #expect(totalDur > 2.5)
    }

    /// The estimated timeline must END inside the sentence, for very short ones
    /// too. The per-word floor ("the"/"a" must not get a sliver) plus the gaps
    /// could sum PAST the measured duration; a last word beyond the sentence end
    /// held the highlight alive over a sentence already finished, and the yellow
    /// only moved when the next slice started. The durations and the gaps are
    /// scaled together, so the relation "sum of durations + gaps <= total" holds.
    @Test func estimatesNeverOvershootTheSentence() {
        for (text, dur) in [("a b c d e f", 0.25),      // 6 words, 0.25 s: floor binds
                            ("one two", 0.2),
                            ("the of a in", 0.15),
                            ("word", 0.05)] {
            let words = PiperTTS.estimateWordTimings(text: text, totalDuration: dur)
            guard let last = words.last else { continue }
            let end = last.start + last.duration
            #expect(end <= dur + 0.0001,
                    "texto \(text) a \(dur) s terminou em \(end) s")
            // And nothing goes backwards.
            for (a, b) in zip(words, words.dropFirst()) {
                #expect(b.start >= a.start)
            }
        }
    }

    @Test func wordsStartInOrder() {
        let result = PiperTTS.estimateWordTimings(text: "one two three", totalDuration: 1.5)
        #expect(result.count == 3)
        #expect(result[0].start < result[1].start)
        #expect(result[1].start < result[2].start)
    }

    @Test func longerWordsGetMoreTime() {
        let result = PiperTTS.estimateWordTimings(text: "a extraordinary", totalDuration: 2.0)
        #expect(result.count == 2)
        // "extraordinary" (13 chars) should get more time than "a" (1 char)
        #expect(result[1].duration > result[0].duration)
    }

    @Test func newlineSeparatesWords() {
        let result = PiperTTS.estimateWordTimings(text: "hello\nworld", totalDuration: 1.0)
        #expect(result.count == 2)
    }
}
