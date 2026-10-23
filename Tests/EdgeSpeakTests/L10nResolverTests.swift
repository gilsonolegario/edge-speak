import Foundation
import Testing

@testable import EdgeSpeak

/// Default resolver of `L.get`: positional interpolation and fallback.
/// No network and no audio - just the in-memory catalog.
struct L10nResolverTests {
    /// Without `locale`, `L.get` resolves English (its fixed parameter is
    /// `.en`); the APP's default interface language, however, is Portuguese
    /// since the owner decision 2026-10-17 — `@AppStorage` starts there.
    @Test func defaultIsEnglish() {
        #expect(L.get("status.playing") == "Playing…")
        #expect(L.get("status.playing", locale: .pt) == "Tocando…")
        #expect(L.defaultLanguage == .pt)
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
    /// (Plano item 34: a mensagem também convide ao Enter — o convite faz
    /// parte do copys, pinado aqui junto da interpolação.)
    @Test func interpolatesSeveralArguments() {
        #expect(L.get("status.fileLoaded", locale: .pt, args: "tese.pdf", 4120) == "Arquivo carregado: tese.pdf (4120 caracteres). Pressione Enter para começar a ouvir.")
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

    /// `@AppStorage` key for the interface language and its default (PT).
    @Test func languageKeyAndDefault() {
        #expect(AppSetting.languageKey == "appLanguage")
        #expect(AppSetting.languageDefault == "pt")
    }
}
