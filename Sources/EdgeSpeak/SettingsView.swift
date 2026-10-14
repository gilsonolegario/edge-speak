import SwiftUI
import AppKit

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

    /// Interface language (EN default); labels come from the `L` catalog.
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
        .frame(width: 440, height: 300)
    }

    /// Voice, cadence and reading follow.
    private var readingTab: some View {
        Form {
            Section {
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
                Toggle(L.get("ui.resumeFromLast", locale: language), isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "resumeFromLast") },
                    set: { UserDefaults.standard.set($0, forKey: "resumeFromLast") }
                ))
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
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @State private var cacheSizeText: String? = nil
    @State private var diagnosticText: String = ""

    private var advancedTab: some View {
        Form {
            Section {
                HStack {
                    Text(L.get("settings.cacheSize", locale: language, args: cacheSizeText ?? "…"))
                    Spacer()
                    Button(L.get("settings.clearCache", locale: language)) {
                        NotificationCenter.default.post(name: .edgeSpeakClearCache, object: nil)
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await reloadCache()
                        }
                    }
                    .help(L.get("help.clearCacheHelp", locale: language))
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
}
