import AppKit
import SwiftUI

@main
struct SaewooFontApp: App {
    // @NSApplicationDelegateAdaptor lets a SwiftUI @main App hook the real
    // NSApplication lifecycle. We need this because SPM executables don't
    // ship with a proper .app bundle / Info.plist — without an explicit
    // activation policy, windows appear but macOS never treats the process
    // as a regular foreground app. The symptom: text fields show a blinking
    // cursor but keyboard events never reach their first responder.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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

/// Bridges NSApplication lifecycle for a SwiftUI @main app. Without this the
/// SPM-built executable runs as a "floating" process with no activation
/// policy — windows are visible but keyboard focus is broken.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make us a proper foreground app (dock icon, menu bar, keyboard).
        NSApp.setActivationPolicy(.regular)
        // Pull ourselves to the front on first launch — otherwise we can
        // spawn behind Xcode/Terminal and never become key.
        NSApp.activate(ignoringOtherApps: true)
    }

    // When the user closes the last window, quit. Keeps things tidy while
    // prototyping; we can change to menu-bar-stays-running later.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
