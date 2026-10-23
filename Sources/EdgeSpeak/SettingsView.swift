import SwiftUI
import AppKit

/// The voice menu, ONE copy for both surfaces (toolbar and Settings). The
/// three sections were hand-copied in the two places; extracting the picker
/// keeps them from drifting again. No architecture beyond the view itself.
struct VoicePicker: View {
    @Binding var voice: String
    let language: L.Language

    var body: some View {
        Picker(L.get("ui.voiceLabel", locale: language), selection: $voice) {
            Section(L.get("section.offline", locale: language)) {
                ForEach(PiperTTS.offlineVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option, locale: language)).tag(option)
                }
            }
            Section(L.get("section.english", locale: language)) {
                ForEach(AppSetting.englishVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option, locale: language)).tag(option)
                }
            }
            Section(L.get("section.portuguese", locale: language)) {
                ForEach(AppSetting.portugueseVoices, id: \.self) { option in
                    Text(AppSetting.label(for: option, locale: language)).tag(option)
                }
            }
        }
        .accessibilityLabel(Text(L.get("ui.voiceLabel", locale: language)))
    }
}

/// EdgeSpeak Settings window (standard menu item, ⌘,)
///
/// Every control writes via `@AppStorage` into the `AppSetting` keys — the
/// SAME ones `ContentView` uses — so the preference survives
/// relaunch and the two places never diverge.
struct SettingsView: View {
    @AppStorage(AppSetting.voiceKey) private var voice: String = AppSetting.voiceDefault
    @AppStorage(AppSetting.rateKey) private var ratePercent: Int = AppSetting.rateDefault
    @AppStorage(AppSetting.followKey) private var followReading: Bool = AppSetting.followDefault
    @AppStorage(AppSetting.integralKey) private var integralMode: Bool = AppSetting.integralDefault
    @AppStorage(AppSetting.footnoteKey) private var readFootnotes: Bool = AppSetting.footnoteDefault
    @AppStorage(AppSetting.fontKey) private var fontSize: Double = AppSetting.fontDefault
    @AppStorage(AppSetting.resumeKey) private var resumeFromLast: Bool = AppSetting.resumeDefault

    /// Citation policy: same key `CitationSkip` reads in the speech path, so
    /// the switch and the filter cannot diverge. Default on (`defaultOn`).
    @AppStorage(CitationSkip.settingKey) private var citationUnwrap: Bool = CitationSkip.defaultOn

    /// Interface language (PT default since 2026-10-17); labels come from the `L` catalog.
    /// The option names stay fixed in their native language ("Português"/"English"),
    /// as system language pickers do.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var language: L.Language { L.Language(rawValue: appLanguageRaw) ?? .en }

    var body: some View {
        TabView {
            readingTab
                .tabItem { Label(L.get("settings.readingTab", locale: language), systemImage: "book") }
            textTab
                .tabItem { Label(L.get("settings.textTab", locale: language), systemImage: "textformat") }
            advancedTab
                .tabItem { Label(L.get("settings.advancedTab", locale: language), systemImage: "gear") }
        }
        // Plano item 28: janela NÃO fica na 440×300 — mínima/ideal, o diagnóstico
        // longo na aba Avançado pode crescer sem cortar texto.
        .frame(minWidth: 440, idealWidth: 480, minHeight: 300, idealHeight: 340)
    }

    /// Voice, cadence and reading follow.
    private var readingTab: some View {
        Form {
            Section {
                // Plano item 29: o mesmo picker interno da toolbar — as três
                // seções vivem num só lugar (`VoicePicker` em ContentView.swift).
                VoicePicker(voice: $voice, language: language)
            } header: {
                Text(L.get("settings.voiceSection", locale: language))
                    .font(.headline)
            }
            // The Settings scene cannot see the main window's controller,
            // so there is no way to disable during synthesis as the menu does;
            // the cadence applies to the next synthesis regardless.
            Section {
                Picker(L.get("settings.rateLabel", locale: language), selection: $ratePercent) {
                    ForEach(EdgeTTS.Rate.choices, id: \.percent) { option in
                        Text(option.label).tag(option.percent)
                    }
                }
                .help(L.get("help.rateHelp", locale: language))
                .accessibilityLabel(Text(L.get("settings.rateLabel", locale: language)))
                .accessibilityHint(Text(L.get("help.rateHelp", locale: language)))
            } header: {
                Text(L.get("settings.playbackSection", locale: language))
                    .font(.headline)
            }
            Section {
                Toggle(L.get("ui.followReading", locale: language), isOn: $followReading)
                    .help(L.get("help.followHelp", locale: language))
                    .accessibilityHint(Text(L.get("help.followHelp", locale: language)))
                Toggle(L.get("ui.resumeFromLast", locale: language), isOn: $resumeFromLast)
                    .help(L.get("help.resumeFromLast", locale: language))
                    .accessibilityHint(Text(L.get("help.resumeFromLast", locale: language)))
            }
            Section {
                // Interface language, on the most visible tab; it applies at once (the views
                // read the same `@AppStorage` and the saved status re-resolves).
                Picker(L.get("settings.languageLabel", locale: language), selection: $appLanguageRaw) {
                    Text("Português").tag(L.Language.pt.rawValue)
                    Text("English").tag(L.Language.en.rawValue)
                }
                .accessibilityLabel(Text(L.get("settings.languageLabel", locale: language)))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Font size and text mode.
    private var textTab: some View {
        Form {
            Section {
                Stepper(
                    L.get("settings.fontSize", locale: language, args: Int(fontSize)),
                    value: $fontSize,
                    in: AppSetting.minFontSize...AppSetting.maxFontSize,
                    step: 1
                )
                .accessibilityLabel(Text(L.get("settings.fontSize", locale: language, args: Int(fontSize))))
                Button(L.get("settings.restoreDefaultSize", locale: language)) {
                    fontSize = AppSetting.fontDefault
                }
                .accessibilityLabel(Text(L.get("settings.restoreDefaultSize", locale: language)))
            } header: {
                Text(L.get("settings.appearanceSection", locale: language))
                    .font(.headline)
            }
            Section {
                Toggle(L.get("settings.integralText", locale: language), isOn: $integralMode)
                    .help(L.get("help.integralHelp", locale: language))
                    .accessibilityHint(Text(L.get("help.integralHelp", locale: language)))
                Text(L.get("settings.integralNote", locale: language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L.get("settings.footnotes", locale: language), isOn: $readFootnotes)
                    .help(L.get("help.footnotesHelp", locale: language))
                    .accessibilityHint(Text(L.get("help.footnotesHelp", locale: language)))
                Toggle(L.get("settings.citations", locale: language), isOn: $citationUnwrap)
                    .help(L.get("help.citationsHelp", locale: language))
                    .accessibilityHint(Text(L.get("help.citationsHelp", locale: language)))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @State private var cacheSizeText: String? = nil
    /// Plano item 28: retorno do "Limpar cache" NA janela de Ajustes — antes a
    /// única resposta era o banner da janela principal (invisível no momento).
    @State private var cacheFeedback: String? = nil
    @State private var clearingCache = false
    /// Plano item 28: a ação destrutiva pede confirmação própria (não dispara
    /// sem alerta) e o botão carrega `role: .destructive`.
    @State private var confirmingCacheClear = false
    @State private var diagnosticText: String = ""
    /// Clear-cache confirmation and its in-tab result (item 28).
    @State private var showClearCacheConfirm = false
    @State private var cacheClearedDone = false

    private var advancedTab: some View {
        Form {
            Section {
                HStack {
                    Text(L.get("settings.cacheSize", locale: language, args: cacheSizeText ?? "…"))
                    Spacer()
                    Button(L.get("settings.clearCache", locale: language), role: .destructive) {
                        confirmingCacheClear = true
                    }
                    .disabled(clearingCache)
                    .help(L.get("help.clearCacheHelp", locale: language))
                }
                if let cacheFeedback {
                    Text(cacheFeedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                L.get("settings.clearCacheConfirm", locale: language),
                isPresented: $confirmingCacheClear,
                titleVisibility: .visible
            ) {
                Button(L.get("settings.clearCache", locale: language), role: .destructive) {
                    clearCacheInWindow()
                }
            }

            // Copyable diagnostics: the text appears selectable and there is a button
            // that puts it on the clipboard (a user action, not automatic).
            Section {
                Button(L.get("ui.copyDiagnostics", locale: language)) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(diagnosticText, forType: .string)
                }
                .disabled(diagnosticText.isEmpty)
                Text(diagnosticText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await reloadCache()
            let text = await Task.detached(priority: .utility) { Diagnostics.text() }.value
            await MainActor.run { diagnosticText = text }
        }
    }

    private func reloadCache() async {
        let bytes = await Task.detached(priority: .utility) {
            DiskCache.totalBytes()
        }.value
        let text = bytes >= 1_048_576
            ? "\(bytes / 1_048_576) MB" : "\(bytes / 1_024) KB"
        await MainActor.run { cacheSizeText = text }
    }

    /// Plano item 28: mede ANTES, pede a limpeza pelo MESMO canal (o dono da
    /// política `clearCache` continua sendo o `SpeechController`, que preserva
    /// a leitura corrente) e informa na própria janela o que foi liberado —
    /// medição antes/depois, nunca um número estimado. Resposta do "antes" e
    /// do "depois" pela mesma régua de formatação (`CacheFeedback.freedText`).
    ///
    /// Janela principal fechada: a notificação não tem ouvinte e nada é
    /// apagado; o retorno que aparece é "liberados 1 KB" (= delta real 0) —
    /// honesto, porque a limpeza Preserva a leitura corrente e, sem janela,
    /// não há nem leitura nem limpeza. Estado raro; documentado em vez de
    /// duplicar o `clearAll` aqui.
    private func clearCacheInWindow() {
        clearingCache = true
        Task {
            let before = await Task.detached(priority: .utility) {
                DiskCache.totalBytes()
            }.value
            NotificationCenter.default.post(name: .edgeSpeakClearCache, object: nil)
            // Same beat the old code gave the detached clear to finish.
            try? await Task.sleep(nanoseconds: 800_000_000)
            let after = await Task.detached(priority: .utility) {
                DiskCache.totalBytes()
            }.value
            let freed = Swift.max(0, before - after)
            let message = L.get(
                "status.cacheCleared", locale: language,
                args: CacheFeedback.freedText(freed))
            await MainActor.run {
                clearingCache = false
                cacheFeedback = message
                cacheSizeText = CacheFeedback.freedText(after)
            }
        }
    }
}

/// Plano item 28: formatação pura dos bytes liberados — a MESMA régua do
/// `SpeechController.clearCache` (MB a partir de 1 MiB, piso de 1 KB), testável
/// sem controller nem disco.
enum CacheFeedback {
    static func freedText(_ bytes: Int) -> String {
        bytes >= 1_048_576
            ? "\(bytes / 1_048_576) MB"
            : "\(Swift.max(1, bytes / 1_024)) KB"
    }
}
