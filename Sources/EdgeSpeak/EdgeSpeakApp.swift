import SwiftUI
import AppKit

/// Abre PDFs/texto por duplo-clique no Finder ("Abrir com") ou arraste ao ícone.
///
/// Sem isto, o app só importava pelo botão interno — e o documento declarado
/// no Info.plist era ignorado.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .edgeSpeakOpenFile, object: url)
        }
    }
}

extension Notification.Name {
    static let edgeSpeakOpenFile = Notification.Name("EdgeSpeakOpenFile")
    static let edgeSpeakClearCache = Notification.Name("EdgeSpeakClearCache")
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
    }
}
