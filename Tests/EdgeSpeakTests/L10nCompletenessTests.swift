import Foundation
import Testing

@testable import EdgeSpeak

/// Completeness of the PT/EN catalog: no key without a pair and no pattern with
/// gaps between languages. Phase 2 switches language at runtime; a `{0}`
/// missing in EN would break the sentence right in the user's face.
struct L10nCompletenessTests {
    /// Every PT key has EN and vice versa.
    @Test func keysMatchAcrossLanguages() {
        let pt = Set(L.pt.keys)
        let en = Set(L.en.keys)
        #expect(pt == en, "sem EN: \(pt.subtracting(en).sorted()); sem PT: \(en.subtracting(pt).sorted())")
    }

    /// No empty text in either language.
    @Test func noEmptyText() {
        for (key, valor) in L.pt {
            #expect(!valor.isEmpty, "PT vazio: \(key)")
        }
        for (key, valor) in L.en {
            #expect(!valor.isEmpty, "EN vazio: \(key)")
        }
    }

    /// The `{n}` placeholders of each key are the same in PT and EN (same
    /// arity, so phase 2's `L.get` interpolates the same in both).
    @Test func placeholdersMatchAcrossLanguages() {
        for (key, textoPT) in L.pt {
            guard let textoEN = L.en[key] else {
                #expect(Bool(false), "sem EN: \(key)")
                continue
            }
            #expect(
                marcadores(de: textoPT) == marcadores(de: textoEN),
                "marcadores divergem: \(key)")
        }
    }

    /// No leftover Swift interpolation `\(` escaped into the catalog (the
    /// pattern uses `{n}`, never `\(…)`).
    @Test func noSwiftInterpolationInCatalog() {
        for (key, valor) in L.pt {
            #expect(!valor.contains("\\("), "PT with \\(: \(key)")
        }
        for (key, valor) in L.en {
            #expect(!valor.contains("\\("), "EN with \\(: \(key)")
        }
    }

    /// Sample of the keys phase 2 will resolve via `L.get`: all
    /// exist and come back without falling into the key's own fallback.
    @Test func phaseTwoKeysExist() {
        let amostra = [
            "status.playing", "status.paused", "status.finished",
            "status.synthesizing", "status.openFailed", "status.fileLoaded",
            "ui.openFile", "ui.followReading", "ui.settings",
            "player.play", "player.pause", "player.charCount",
            "settings.rateLabel", "settings.fontSize",
            "progress.chunkFraction", "error.synthesisFailed",
            "rate.normal", "section.english",
            "voice.en-US-AndrewNeural", "voice.offline-faber-ptbr",
        ]
        for key in amostra {
            #expect(L.get(key, locale: .pt) == L.pt[key], "sem PT: \(key)")
            #expect(L.get(key, locale: .en) == L.en[key], "sem EN: \(key)")
        }
    }

    /// Reads the indices of the `{n}` placeholders of a pattern, in order.
    private func marcadores(de text: String) -> [Int] {
        var achados: [Int] = []
        var remainder = text[...]
        while let abre = remainder.firstIndex(of: "{") {
            let depois = remainder[remainder.index(after: abre)...]
            if let fecha = depois.firstIndex(of: "}"),
               let n = Int(depois[..<fecha]) {
                achados.append(n)
            }
            remainder = remainder[remainder.index(after: abre)...]
        }
        return achados.sorted()
    }
}
