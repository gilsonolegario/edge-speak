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

    /// System media keys and headphone buttons toggle playback.
    ///
    /// Posts `.edgeSpeakTogglePlay`; the player observes it (same pattern as
    /// `.edgeSpeakOpenFile`). Posting is harmless before any observer exists.
    /// Follows mpv's `osdep/mac/remote_command_center.swift` precedent.
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
            NotificationCenter.default.post(name: .edgeSpeakTogglePlay, object: nil)
            return .success
        }
    }
}

extension Notification.Name {
    static let edgeSpeakOpenFile = Notification.Name("EdgeSpeakOpenFile")
    static let edgeSpeakClearCache = Notification.Name("EdgeSpeakClearCache")
    static let edgeSpeakTogglePlay = Notification.Name("EdgeSpeakTogglePlay")
    static let edgeSpeakSummarize = Notification.Name("EdgeSpeakSummarize")
}

@main
struct EdgeSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("EdgeSpeak") {
            ContentView()
        }
        Settings {
            SettingsView()
        }
        .commands {
            // Posts `.edgeSpeakSummarize`; the reader observes it once the UI
            // lanes land (same post-now-observe-later pattern as toggle-play).
            CommandGroup(after: .textEditing) {
                Button("Summarize Passage") {
                    NotificationCenter.default.post(name: .edgeSpeakSummarize, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}
