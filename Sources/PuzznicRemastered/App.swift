import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // also makes `swift run` behave like a normal app (menu bar, focus)
        NSApp.setActivationPolicy(.regular)
        // Set the Dock icon explicitly so it shows even if the system icon cache is stale
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { GameSession.shared.loadROM(url) }
    }
}

@main
struct PuzznicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = GameSession.shared

    var body: some Scene {
        Window("Puzznic Remastered", id: "main") {
            GameContainerView()
                .environmentObject(session)
                .frame(minWidth: 400, minHeight: 300)
        }
        .defaultSize(width: 1180, height: 900)
        .commands { GameCommands(session: session) }

        Settings {
            SettingsView()
                .environmentObject(session)
        }
    }
}

struct GameCommands: Commands {
    let session: GameSession
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open ROM…") { session.openROMPanel() }
                .keyboardShortcut("o")
        }
        CommandMenu("Game") {
            Button("Pause / Resume") { session.togglePause() }
                .keyboardShortcut("p")
            Button("Reset") { session.reset() }
                .keyboardShortcut("r")
            Divider()
            Button("Save State") { session.saveState() }
                .keyboardShortcut("s")
            Button("Load State") { session.loadState() }
                .keyboardShortcut("l")
            Divider()
            Menu("Graphics Preset") {
                ForEach(GraphicsPreset.allCases) { p in
                    Button(p.title) {
                        let store = SettingsStore.shared
                        store.graphics = p.apply(to: store.graphics)
                    }
                }
            }
        }
    }
}

/// macOS 13 fallback (macOS 14+ uses SettingsLink).
func openSettingsWindow() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    NSApp.activate(ignoringOtherApps: true)
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") { openSettingsWindow() }
        }
    }
}
