import SwiftUI
import AppKit
import MediaPlayer

/// Opens PDFs/text via double-click in Finder ("Open With") or drag onto the icon.
///
/// Without this, the app only imported via the internal button — and the declared
/// document in Info.plist was ignored.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .edgeSpeakOpenFile, object: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupRemoteCommands()
    }

    /// Quitting does not leave children behind (item 44 of the robustness lane,
    /// 2026-10-17).
    ///
    /// ⌘Q in the middle of a synthesis used to keep the Python child alive for
    /// up to 600 s (the engine's timeout), consuming network and CPU, with a
    /// temporary directory nobody would clean. `.edgeSpeakStopReading` already
    /// exists for the media keys and its handler (`ContentView.requestStop`)
    /// cancels the synthesis in flight — which kills the children — and stops
    /// the playback otherwise.
    ///
    /// The post is synchronous, so the handler runs before the process exits:
    /// `ContentView` subscribes with `NotificationCenter.Publisher`, which
    /// delivers on the posting thread.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopReadingBeforeTerminating()
        return .terminateNow
    }

    /// Split from the delegate callback so the suite proves the channel is
    /// posted without standing up an `NSApplication`.
    func stopReadingBeforeTerminating() {
        NotificationCenter.default.post(name: .edgeSpeakStopReading, object: nil)
    }

    /// System media keys and headphone buttons drive the reading.
    ///
    /// Posts `.edgeSpeakTogglePlay` / `.edgeSpeakStopReading`; `ContentView`
    /// observes both (same pattern as `.edgeSpeakOpenFile`). Posting is
    /// harmless before any observer exists. Follows mpv's
    /// `osdep/mac/remote_command_center.swift` precedent.
    ///
    /// `stop` stops instead of toggling: with a single handler for all four
    /// commands, the system stop button paused or RESUMED the reading. The
    /// observer cancels a synthesis in flight and stops the playback otherwise,
    /// so "stop" does not leave a synthesis running in the background.
    ///
    /// Delivery precondition: macOS routes the keys to the app that owns the
    /// Now Playing state. `SpeechController.publishNowPlaying()` writes that
    /// state while a reading is active and clears it when the reading ends —
    /// so these handlers only fire while something is actually being read.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .edgeSpeakTogglePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .edgeSpeakTogglePlay, object: nil)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .edgeSpeakTogglePlay, object: nil)
            return .success
        }
        center.stopCommand.addTarget { _ in
            NotificationCenter.default.post(name: .edgeSpeakStopReading, object: nil)
            return .success
        }
    }
}

extension Notification.Name {
    static let edgeSpeakOpenFile = Notification.Name("EdgeSpeakOpenFile")
    static let edgeSpeakOpenPanel = Notification.Name("EdgeSpeakOpenPanel")
    static let edgeSpeakClearCache = Notification.Name("EdgeSpeakClearCache")
    static let edgeSpeakTogglePlay = Notification.Name("EdgeSpeakTogglePlay")
    static let edgeSpeakStopReading = Notification.Name("EdgeSpeakStopReading")
    static let edgeSpeakSummarize = Notification.Name("EdgeSpeakSummarize")
    /// UITests lane 2026-10-17: ⌘⇧H (toggle do modo destacar, spec §5) e ⌘F
    /// (buscar) — menu bar → `ContentView`, mesmo padrão dos antecessores.
    static let edgeSpeakToggleHighlight = Notification.Name("EdgeSpeakToggleHighlight")
    static let edgeSpeakFind = Notification.Name("EdgeSpeakFind")
}

/// Bridge between the reading state and the system's Now Playing entry.
///
/// macOS delivers the media keys (and the headphone button) to whichever app
/// owns the Now Playing state, so a reader that never writes
/// `MPNowPlayingInfoCenter` never receives them — the handlers in
/// `AppDelegate.setupRemoteCommands` would be dead code. `SpeechController`
/// builds a ``Snapshot`` on every real state change and on seek; `info(for:)`
/// returns nil when there is no active reading, which REMOVES the entry —
/// a ghost entry keeps the keys pointed at a silent app, worse than none.
enum NowPlaying {
    /// Reading state at one instant. Equatable so an unchanged snapshot is
    /// not re-sent (dedupe in `SpeechController.publishNowPlaying`).
    struct Snapshot: Equatable {
        var isPlaying: Bool
        var isPaused: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval
        var title: String?
        var artist: String
    }

    /// Playback rate coherent with the state: 1.0 while playing, 0.0 while
    /// paused. The system extrapolates the elapsed time between updates
    /// using this rate, so it must never lie (a playing-looking paused entry
    /// keeps counting).
    nonisolated static func playbackRate(_ snapshot: Snapshot) -> Double {
        snapshot.isPlaying ? 1.0 : 0.0
    }

    /// The dictionary for `MPNowPlayingInfoCenter`; nil when idle/finished/
    /// stopped. Elapsed and duration are the controller's real measured
    /// values, not estimates.
    nonisolated static func info(for snapshot: Snapshot) -> [String: Any]? {
        guard snapshot.isPlaying || snapshot.isPaused else { return nil }
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate(snapshot),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate(snapshot),
        ]
        // Unknown duration is omitted, not published as 0 (the scrubber
        // shows a zero-length track otherwise).
        if snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        if let title = snapshot.title { info[MPMediaItemPropertyTitle] = title }
        if !snapshot.artist.isEmpty { info[MPMediaItemPropertyArtist] = snapshot.artist }
        return info
    }

    /// `MPNowPlayingPlaybackState` for the same snapshot.
    nonisolated static func playbackState(_ snapshot: Snapshot) -> MPNowPlayingPlaybackState {
        if snapshot.isPlaying { return .playing }
        if snapshot.isPaused { return .paused }
        return .stopped
    }
}

/// Where the Now Playing entry goes. A protocol so tests substitute a
/// recorder and prove the wiring without a live `MPNowPlayingInfoCenter`.
protocol NowPlayingSink: AnyObject {
    func apply(info: [String: Any]?, state: MPNowPlayingPlaybackState)
}

/// Real sink: the shared system center itself.
final class SystemNowPlayingSink: NowPlayingSink {
    func apply(info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state
    }
}

/// Mirrors the persisted recent documents so the menu rebuilds when one is
/// added. `RecentDocuments` (AppSettings) owns the storage and stays
/// Foundation-only; this is the observable seam for SwiftUI, and the only
/// place the two meet.
@MainActor
final class RecentDocumentsModel: ObservableObject {
    static let shared = RecentDocumentsModel()

    @Published private(set) var urls: [URL] = RecentDocuments.load()

    private init() {}

    func note(_ url: URL) {
        RecentDocuments.note(url)
        urls = RecentDocuments.load()
    }
}

@main
struct EdgeSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var recents = RecentDocumentsModel.shared

    /// Interface language of the menu item, from the same key the interface uses.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var language: L.Language { L.Language(rawValue: appLanguageRaw) ?? .en }

    /// Plano item 36: o mesmo raw (`@AppStorage`) que `RecentDocumentsPolicy`
    /// escreve via UserDefaults. Store nativo do SwiftUI para INVALIDAR a
    /// cena quando a lista muda — um `UserDefaults` cru não re-renderiza os
    /// menus; o item novato só apareceria num relançamento.
    @AppStorage(RecentDocumentsPolicy.defaultsKey) private var recentRaw: String = ""

    var body: some Scene {
        WindowGroup("EdgeSpeak") {
            ContentView()
        }
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                // Plano item 2: "Open…" ⌘O. Posts the SAME `.edgeSpeakOpenFile`
                // channel the AppDelegate uses, with object nil — the observer
                // treats nil as "open the file panel" instead of "load URL".
                Button(L.get("ui.menu.open", locale: language)) {
                    NotificationCenter.default.post(name: .edgeSpeakOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                // Plano item 36: menu "Abrir recente". The store is OUR
                // UserDefaults list, not `NSDocumentController.noteNewRecentDocumentURL`:
                // the app is not NSDocument-based (custom `load(url:)`), and
                // the SwiftUI WindowGroup never shows the system Open Recent
                // submenu — URLs recorded there would populate an invisible
                // menu. A tiny persisted list keeps menu and storage consistent
                // and lets `RecentDocumentsPolicy` (pure) own the ordering.
                Menu(L.get("ui.menu.recent", locale: language)) {
                    let recent = RecentDocumentsPolicy.urls(fromJSON: recentRaw)
                    if recent.isEmpty {
                        Text(L.get("ui.recent.none", locale: language))
                            .frame(maxWidth: 260)
                    } else {
                        ForEach(recent, id: \.absoluteString) { url in
                            Button(url.lastPathComponent) {
                                NotificationCenter.default
                                    .post(name: .edgeSpeakOpenFile, object: url)
                            }
                        }
                    }
                }
            }

            // Plano item 2: menu próprio "Leitura" — o ⌘⇧M sai do menu Edit
            // (ação de app em menu de edição) e ganha a casa dos comandos de
            // leitura; transporte (play/pause, parar) postando os canais que
            // `ContentView` já observa. Nenhuma lógica nova fora das notificações.
            CommandMenu(L.get("ui.menu.reading", locale: language)) {
                // Plano item 40: ⌘F abre o campo de busca (painel + PDF).
                Button(L.get("ui.menu.find", locale: language)) {
                    NotificationCenter.default.post(name: .edgeSpeakFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button(L.get("menu.summarize", locale: language)) {
                    NotificationCenter.default.post(name: .edgeSpeakSummarize, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                // Plano S2 (spec §5): o toggle do modo destacar foi do Options
                // menu apenas; ⌘⇧H no app frame fecha a coluna dos atalhos,
                // postando o canal (consumer + Esc já existem).
                Button(L.get("ui.highlightText", locale: language)) {
                    NotificationCenter.default.post(name: .edgeSpeakToggleHighlight, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()
                Button(L.get("ui.menu.playPause", locale: language)) {
                    NotificationCenter.default.post(name: .edgeSpeakTogglePlay, object: nil)
                }
                Button(L.get("ui.menu.stop", locale: language)) {
                    NotificationCenter.default.post(name: .edgeSpeakStopReading, object: nil)
                }
            }

            // Plano S3: o desvio Espaço = play/pause (liberado ao controle
            // focado pelo item 19) está DOCUMENTADO no app — ponto discreto
            // no menu Help, sem tela nova.
            CommandGroup(after: .help) {
                Button(L.get("help.spaceKeyItem", locale: language)) {
                    SpaceKeyNote.present(locale: language)
                }
            }
        }
    }
}

/// Plano S3: the Help-menu item explains the Space deviation in place.
enum SpaceKeyNote {
    static func present(locale: L.Language) {
        let alert = NSAlert()
        alert.messageText = L.get("help.spaceKeyTitle", locale: locale)
        alert.informativeText = L.get("help.spaceKeyText", locale: locale)
        alert.addButton(withTitle: L.get("summary.close", locale: locale))
        alert.runModal()
    }
}

/// Plano item 36: documentos recentes, política PURA e persistida.
enum RecentDocumentsPolicy {
    /// Key shared with `EdgeSpeakApp`'s `@AppStorage` (menu invalidation).
    static let defaultsKey = "recentDocuments"
    /// File→menu shape fits; beyond this the list stops being scannable.
    static let limit = 8

    /// JSON-encoded array of absoluteString URLs — a list cannot live in a
    /// single `@AppStorage` scalar otherwise.
    static func urls(fromJSON raw: String) -> [URL] {
        guard let data = raw.data(using: .utf8) else { return [] }
        guard let strings = (try? JSONDecoder()
            .decode([String].self, from: data)) else { return [] }
        return strings.compactMap(URL.init(string:))
    }

    /// Pure: most recent first, oldest the first to fall off the limit.
    /// Invalid URLs are never recorded: `URL(string:)` is lenient — it
    /// accepts bare relative strings like "%%" — so an entry only counts
    /// when it has a scheme (this app records file URLs exclusively).
    static func list(_ existing: [String], adding rawURL: String) -> [String] {
        let trimmed = rawURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let parsed = URL(string: trimmed),
              parsed.scheme?.isEmpty == false
        else { return existing }
        var result = [trimmed]
        for entry in existing where entry != trimmed { result.append(entry) }
        return Array(result.prefix(limit))
    }

    /// Persist + re-read in the SAME store `EdgeSpeakApp`'s menu reads.
    static func record(_ url: URL, defaults: UserDefaults = .standard) {
        let current = (defaults.string(forKey: defaultsKey) ?? "")
        let updated = list(urls(fromJSON: current).map(\.absoluteString), adding: url.absoluteString)
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(String(data: data, encoding: .utf8) ?? "", forKey: defaultsKey)
    }

    /// Convenience for commands: read straight from defaults.
    static func urls(defaults: UserDefaults = .standard) -> [URL] {
        urls(fromJSON: defaults.string(forKey: defaultsKey) ?? "")
    }
}
