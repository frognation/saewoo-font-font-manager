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
    @StateObject private var selection = SelectionModel()
    @StateObject private var preview = PreviewSettings()

    init() {
        // Headless perf harness — runs before any window is created so the
        // numbers aren't polluted by SwiftUI setup. See Benchmark.swift.
        if Benchmark.shouldRun() {
            MainActor.assumeIsolated { Benchmark.run() }
            exit(0)
        }
        if let f = ForkCLI.requestedArguments() {
            ForkCLI.run(font: f.font, out: f.out, variable: f.variable)
            exit(0)
        }
        if DuplicateAuditCLI.requested() {
            let done = Flag()
            Task { @MainActor in
                await DuplicateAuditCLI.run()
                done.value = true
            }
            while !done.value { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        // Headless RightFont import — see RightFontImportCLI.
        if let args = RightFontImportCLI.requestedArguments() {
            // Pump the run loop rather than blocking on a semaphore: the work
            // is @MainActor, so parking the main thread would deadlock it.
            let done = Flag()
            Task { @MainActor in
                await RightFontImportCLI.run(bundle: args.bundle, map: args.map)
                done.value = true
            }
            while !done.value {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Saewoo Font") {
            ContentView()
                .environmentObject(library)
                .environmentObject(selection)
                .environmentObject(preview)
                .frame(minWidth: 1100, minHeight: 680)
                .task {
                    await library.bootstrap()
                    // Seed the live preview state from persisted prefs, then
                    // route future edits back for persistence.
                    preview.text = library.previewText
                    preview.size = library.previewSize
                    preview.onCommit = { [weak library] text, size in
                        library?.updatePreviewPrefs(text: text, size: size)
                    }
                }
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
