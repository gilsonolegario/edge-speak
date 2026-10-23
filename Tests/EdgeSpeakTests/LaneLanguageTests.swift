import Foundation
import Testing

@testable import EdgeSpeak

/// Lane "idioma padrão" (owner decision 2026-10-17): fresh installs open in
/// PT-BR — interface AND voice — while a saved preference keeps winning, plus
/// the pure language detection of plan item 57b. No network, no audio.
struct LaneLanguageTests {
    // MARK: - Fresh-install default (PT-BR)

    /// `@AppStorage` only applies a default when the key is absent, so these
    /// constants are what a brand-new install (no `UserDefaults` entries) sees.
    @Test func freshInstallOpensInPortuguese() {
        #expect(L.defaultLanguage == .pt)
        #expect(AppSetting.languageDefault == L.Language.pt.rawValue)
        #expect(L.get("status.playing", locale: L.Language(rawValue: AppSetting.languageDefault) ?? .pt) == "Tocando…")
    }

    /// The default voice must be PT-BR and OFFLINE: the online Microsoft voices
    /// are blocked worldwide since 2026-10-10 (catalog `status.onlineBlocked`),
    /// and a fresh install must speak out of the box.
    @Test func freshInstallVoiceIsPTBROffline() {
        #expect(AppSetting.voiceDefault == PiperTTS.faberPtBR)
        #expect(AppSetting.isKnown(AppSetting.voiceDefault))
        #expect(PiperTTS.isOfflineVoice(AppSetting.voiceDefault))
    }

    /// A saved value is never overwritten: the default lives only in the
    /// `@AppStorage` expression (absent key), not in any launch-time write.
    /// This pins the constant the store keeps winning against.
    @Test func savedChoiceStillWins() {
        #expect(AppSetting.languageKey == "appLanguage")
        #expect(AppSetting.voiceKey == "voice")

        let ephemeral = UserDefaults(suiteName: #function)!
        defer { ephemeral.removePersistentDomain(forName: #function) }

        ephemeral.set(L.Language.en.rawValue, forKey: AppSetting.languageKey)
        ephemeral.set("en-US-AndrewNeural", forKey: AppSetting.voiceKey)

        // Stored path: the saved raw values, exactly as the views read them.
        #expect(ephemeral.string(forKey: AppSetting.languageKey) != AppSetting.languageDefault)
        #expect(ephemeral.string(forKey: AppSetting.voiceKey) != AppSetting.voiceDefault)
        #expect(L.Language(rawValue: ephemeral.string(forKey: AppSetting.languageKey) ?? "") == .en)
    }

    // MARK: - Document language detection (item 57b, pure)

    @Test func detectsPortugueseAndSuggestsPTBRVoice() {
        let text = "Relatório anual das atividades: o grupo analisou os dados das últimas semanas e preparou este resumo para a reunião de trabalho de hoje."
        guard let suggestion = DocumentLanguage.suggest(for: text) else {
            Issue.record("Portuguese text should yield a suggestion")
            return
        }
        #expect(suggestion.language == .portuguese)
        #expect(suggestion.voice == DocumentLanguage.voice(for: .portuguese))
        #expect(suggestion.voice == PiperTTS.faberPtBR)
    }

    @Test func detectsEnglishAndSuggestsENVoice() {
        let text = "Quarterly report of the activities: the group analyzed the data from the last few weeks and prepared this summary for today's meeting."
        guard let suggestion = DocumentLanguage.suggest(for: text) else {
            Issue.record("English text should yield a suggestion")
            return
        }
        #expect(suggestion.language == .english)
        #expect(suggestion.voice == PiperTTS.lessacEnUS)
    }

    /// No voice for this language: detection still works (honest `nil`), and a
    /// later round surfaces the "no compatible voice" warning.
    @Test func unsupportedLanguageGetsNoVoice() {
        let text = "Jahresbericht über die Tätigkeiten: die Gruppe hat die Daten der letzten Wochen ausgewertet und diese Zusammenfassung vorbereitet."
        guard let suggestion = DocumentLanguage.suggest(for: text) else {
            Issue.record("German text should still be detected")
            return
        }
        #expect(suggestion.language == .german)
        #expect(suggestion.voice == nil)
    }

    /// Empty or blank input has no language to detect.
    @Test func emptyTextYieldsNothing() {
        #expect(DocumentLanguage.suggest(for: "") == nil)
        #expect(DocumentLanguage.suggest(for: "   \n\t ") == nil)
    }

    /// Pure: the same text gives the same answer on repeated calls (no
    /// recognizer state leaking between calls).
    @Test func repeatedCallsAreStable() {
        let text = "Este texto é bem português e servirá para conferir a estabilidade."
        let first = DocumentLanguage.suggest(for: text)
        #expect(first == DocumentLanguage.suggest(for: text))
        #expect(first == DocumentLanguage.suggest(for: text + " " + text))
    }
}
