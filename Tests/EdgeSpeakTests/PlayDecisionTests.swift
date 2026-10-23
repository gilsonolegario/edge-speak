import Testing

@testable import EdgeSpeak

/// Tests for the pure decision function extracted from SpeechController.play().
struct PlayDecisionTests {

    @Test func resumePausedWhenSameInput() {
        let d = SpeechController.decidePlay(
            isPaused: true, isPlaying: false, isBusy: false,
            sameInput: true, hasAudio: false, hasAudioURL: false,
            inflightKey: nil, key: "k", cacheHit: false)
        #expect(d == .resumePaused)
    }

    @Test func resumePausedSynthesizingWhenInFlight() {
        let d = SpeechController.decidePlay(
            isPaused: true, isPlaying: false, isBusy: true,
            sameInput: false, hasAudio: false, hasAudioURL: false,
            inflightKey: "k", key: "k", cacheHit: false)
        #expect(d == .resumePausedSynthesizing)
    }

    @Test func noOpWhenPlayingSameInputBusy() {
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: true, isBusy: true,
            sameInput: true, hasAudio: false, hasAudioURL: false,
            inflightKey: "k", key: "k", cacheHit: false)
        #expect(d == .noOpPlaying)
    }

    @Test func noOpWhenInFlightSameKey() {
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: true,
            sameInput: false, hasAudio: false, hasAudioURL: false,
            inflightKey: "k", key: "k", cacheHit: false)
        #expect(d == .noOpInFlight)
    }

    @Test func cancelAndRestartWhenDifferentKey() {
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: true,
            sameInput: false, hasAudio: false, hasAudioURL: false,
            inflightKey: "old", key: "new", cacheHit: false)
        #expect(d == .cancelAndRestart)
    }

    @Test func replayCachedWhenSameInputHasAudio() {
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: false,
            sameInput: true, hasAudio: true, hasAudioURL: true,
            inflightKey: nil, key: "k", cacheHit: false)
        #expect(d == .replayCached)
    }

    @Test func playFromDiskCacheWhenCacheHit() {
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: false,
            sameInput: false, hasAudio: false, hasAudioURL: false,
            inflightKey: nil, key: "k", cacheHit: true)
        #expect(d == .playFromDiskCache)
    }

    @Test func synthesizeByDefault() {
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: false,
            sameInput: false, hasAudio: false, hasAudioURL: false,
            inflightKey: nil, key: "k", cacheHit: false)
        #expect(d == .synthesize)
    }

    @Test func orderingCancelOnlyWhenDifferent() {
        // Same key in flight must NOT cancel — it's a no-op.
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: true,
            sameInput: false, hasAudio: false, hasAudioURL: false,
            inflightKey: "k", key: "k", cacheHit: false)
        #expect(d == .noOpInFlight)
    }

    @Test func staleSynthesisCancelsEvenWithSameInput() {
        // currentKey already points to a COMPLETED reading ("k", with audio),
        // while ANOTHER run ("outro") synthesizes: the press must cancel the
        // obsolete run, never reach replayCached (the old slice would hijack
        // the replay via streamer.start in the middle).
        let d = SpeechController.decidePlay(
            isPaused: false, isPlaying: false, isBusy: true,
            sameInput: true, hasAudio: true, hasAudioURL: true,
            inflightKey: "outro", key: "k", cacheHit: false)
        #expect(d == .cancelAndRestart)
    }
}