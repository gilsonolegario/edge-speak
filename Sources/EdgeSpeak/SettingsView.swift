import SwiftUI

/// Janela de Ajustes do EdgeSpeak (item padrão do menu, ⌘,).
///
/// Todo controle grava via `@AppStorage` nas chaves de `AppSetting` — as
/// MESMAS que o `ContentView` usa — então a preferência sobrevive ao
/// relançamento e os dois lugares nunca divergem.
struct SettingsView: View {
    @AppStorage(AppSetting.voiceKey) private var voice: String = AppSetting.voiceDefault
    @AppStorage(AppSetting.rateKey) private var ratePercent: Int = AppSetting.rateDefault
    @AppStorage(AppSetting.followKey) private var followReading: Bool = AppSetting.followDefault
    @AppStorage(AppSetting.integralKey) private var integralMode: Bool = AppSetting.integralDefault
    @AppStorage(AppSetting.fontKey) private var fontSize: Double = AppSetting.fontDefault

    /// Idioma da interface (PT padrão); os rótulos saem do catálogo `L`.
    /// Os nomes das opções ficam fixos no idioma nativo ("Português"/"English"),
    /// como fazem os seletores de idioma do sistema.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var idioma: L.Idioma { L.Idioma(rawValue: appLanguageRaw) ?? .pt }

    var body: some View {
        TabView {
            readingTab
                .tabItem { Label(L.get("settings.readingTab", locale: idioma), systemImage: "book") }
            textTab
                .tabItem { Label(L.get("settings.textTab", locale: idioma), systemImage: "textformat") }
            advancedTab
                .tabItem { Label(L.get("settings.advancedTab", locale: idioma), systemImage: "gear") }
        }
        .frame(width: 440, height: 300)
    }

    /// Voz, ritmo e acompanhamento da leitura.
    private var readingTab: some View {
        Form {
            Picker(L.get("ui.voiceLabel", locale: idioma), selection: $voice) {
                Section(L.get("section.offline", locale: idioma)) {
                    ForEach(PiperTTS.offlineVoices, id: \.self) { option in
                        Text(AppSetting.label(for: option)).tag(option)
                    }
                }
                Section(L.get("section.english", locale: idioma)) {
                    ForEach(AppSetting.englishVoices, id: \.self) { option in
                        Text(AppSetting.label(for: option)).tag(option)
                    }
                }
                Section(L.get("section.portuguese", locale: idioma)) {
                    ForEach(AppSetting.portugueseVoices, id: \.self) { option in
                        Text(AppSetting.label(for: option)).tag(option)
                    }
                }
            }
            // A cena de Ajustes não enxerga o controller da janela principal,
            // então não há como desabilitar durante a síntese como o menu faz;
            // a cadência vale para a próxima síntese de todo modo.
            Picker(L.get("settings.rateLabel", locale: idioma), selection: $ratePercent) {
                ForEach(EdgeTTS.Rate.choices, id: \.percent) { option in
                    Text(option.label).tag(option.percent)
                }
            }
            .help(L.get("help.rateHelp", locale: idioma))
            Toggle(L.get("ui.followReading", locale: idioma), isOn: $followReading)
                .help(L.get("help.followHelp", locale: idioma))
            // Idioma da interface, na aba mais visível; vale na hora (as vistas
            // leem o mesmo `@AppStorage` e o status guardado se re-resolve).
            Picker(L.get("settings.languageLabel", locale: idioma), selection: $appLanguageRaw) {
                Text("Português").tag(L.Idioma.pt.rawValue)
                Text("English").tag(L.Idioma.en.rawValue)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Tamanho da fonte e modo de texto.
    private var textTab: some View {
        Form {
            Stepper(
                L.get("settings.fontSize", locale: idioma, args: Int(fontSize)),
                value: $fontSize,
                in: AppSetting.minFontSize...AppSetting.maxFontSize,
                step: 1
            )
            Button(L.get("settings.restoreDefaultSize", locale: idioma)) {
                fontSize = AppSetting.fontDefault
            }
            Toggle(L.get("settings.integralText", locale: idioma), isOn: $integralMode)
                .help(L.get("help.integralHelp", locale: idioma))
            Text(L.get("settings.integralNote", locale: idioma))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var advancedTab: some View {
        Form {
            // PENDENTE: limpar o cache de áudio depende de função nova em CacheDisco.swift (fora do escopo) — item deixado de fora até lá.
            Text(L.get("settings.noAdvanced", locale: idioma))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
