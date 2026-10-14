import Foundation
import Testing

@testable import EdgeSpeak

/// Default resolver of `L.get`: positional interpolation and fallback.
/// No network and no audio - just the in-memory catalog.
struct L10nResolverTests {
    /// Without `locale`, the default is English.
    @Test func defaultIsEnglish() {
        #expect(L.get("status.playing") == "Playing…")
        #expect(L.get("status.playing", locale: .pt) == "Tocando…")
        #expect(L.defaultLanguage == .en)
    }

    /// With `.en`, English text comes back when the key exists.
    @Test func englishWhenKeyExists() {
        #expect(L.get("status.playing", locale: .en) == "Playing…")
    }

    /// One argument fills `{0}`.
    @Test func interpolatesOneArgument() {
        #expect(L.get("status.openFailed", locale: .pt, args: "fim.pdf") == "Falha ao abrir: fim.pdf")
    }

    /// Several arguments fill `{0}`, `{1}`... in order, in both languages.
    @Test func interpolatesSeveralArguments() {
        #expect(L.get("status.fileLoaded", locale: .pt, args: "tese.pdf", 4120) == "Arquivo carregado: tese.pdf (4120 caracteres).")
        #expect(L.get("progress.chunkFraction", locale: .en, args: 3, 12) == "Synthesizing 3/12…")
    }

    /// Key missing in EN falls back to PT (interpolation applied).
    @Test func fallsBackToPortugueseWhenEnglishMissing() {
        let tables: [L.Language: [String: String]] = [
            .pt: ["só.pt": "Só em PT {0}"],
            .en: [:],
        ]
        #expect(L.resolve("só.pt", locale: .en, args: ["X"], tables: tables) == "Só em PT X")
    }

    /// Key missing in every language returns the key itself (never empty).
    @Test func unknownKeyReturnsKey() {
        #expect(L.get("chave.que.nao.existe", locale: .en) == "chave.que.nao.existe")
    }

    /// An extra argument does not break the sentence.
    @Test func extraArgumentDoesNotBreak() {
        #expect(L.get("status.playing", args: "extra") == "Playing…")
    }

    /// `@AppStorage` key for the interface language and its default (EN).
    @Test func languageKeyAndDefault() {
        #expect(AppSetting.languageKey == "appLanguage")
        #expect(AppSetting.languageDefault == "en")
    }
}
