import Testing
@testable import EdgeSpeak

/// Espalha da palavra parada (timings esgotados): em vez de reiniciar o
/// relógio de alerta em cada passo (0,9 s por palavra), o tick leva os
/// SLOTS com tempos reais, derivados do fim da última palavra cronometrada
/// da frase. O primeiro slot guarda o portão antigo (parada + 0,9 s).
struct NudgeSlotsTests {
    @Test func nothingToCrawlYieldsNoSlots() {
        #expect(StreamingPlayer.nudgeSpread(stallSeconds: 10, wordCount: 3, from: 2, lastEnd: 12).isEmpty)
        #expect(StreamingPlayer.nudgeSpread(stallSeconds: 10, wordCount: 1, from: 0, lastEnd: 12).isEmpty)
    }

    @Test func noRoomLeftYieldsNoSlots() {
        // O primeiro rastejo cairia em 10,9 s mas a frase acaba em 10,5 s:
        // não há onde espalhar, não rasteja.
        #expect(StreamingPlayer.nudgeSpread(stallSeconds: 10, wordCount: 5, from: 1, lastEnd: 10.5).isEmpty)
    }

    @Test func firstSlotKeepsTheOldGate() {
        let slots = StreamingPlayer.nudgeSpread(stallSeconds: 10, wordCount: 5, from: 1, lastEnd: 20)
        #expect(abs(slots[0].at - 10.9) < 1e-9)
        #expect(slots[0].word == 2)
    }

    @Test func wideSpreadCapsTheStepAt09() {
        // 9,1 s para 4 posições: passo truncado em 0,9 s — nunca rasteja
        // mais rápido que o relógio antigo quando o tempo sobra.
        let slots = StreamingPlayer.nudgeSpread(stallSeconds: 10, wordCount: 6, from: 1, lastEnd: 20)
        #expect(slots.map(\.word) == [2, 3, 4, 5])
        let diffs = zip(slots, slots.dropFirst()).map { $1.at - $0.at }
        #expect(diffs.allSatisfy { abs($0 - 0.9) < 1e-9 })
    }

    @Test func tightSpreadDistributesByTheSentencesOwnTime() {
        // 1,1 s para 2 posições: passo 0,55 s — mais rápido que o relógio
        // antigo, mas derivado do tempo real da frase, não de um relógio.
        let slots = StreamingPlayer.nudgeSpread(stallSeconds: 10, wordCount: 4, from: 1, lastEnd: 12)
        #expect(slots.map(\.word) == [2, 3])
        let diffs = zip(slots, slots.dropFirst()).map { $1.at - $0.at }
        #expect(abs(diffs[0] - 0.55) < 1e-9)
    }

    @Test func slotsAreMonotonicAndNeverPastTheEnd() {
        for (lastEnd, from, count) in [(20.0, 1, 6), (12.0, 1, 4), (15.0, 0, 10), (11.0, 3, 7)] {
            let slots = StreamingPlayer.nudgeSpread(
                stallSeconds: 10, wordCount: count, from: from, lastEnd: lastEnd)
            #expect(slots.allSatisfy { $0.word > from && $0.word < count })
            #expect(zip(slots, slots.dropFirst()).allSatisfy { $0.at < $1.at })
            if let last = slots.last {
                #expect(last.at <= lastEnd + 1e-9)
            }
        }
    }
}
