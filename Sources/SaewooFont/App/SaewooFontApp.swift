import SwiftUI

@main
struct SaewooFontApp: App {
    @StateObject private var library = FontLibrary()

    var body: some Scene {
        WindowGroup("Saewoo Font") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 1100, minHeight: 680)
                .task { await library.bootstrap() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Library") {
                    Task { await library.rescan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
