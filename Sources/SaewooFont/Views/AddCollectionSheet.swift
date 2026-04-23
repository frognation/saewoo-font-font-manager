import AppKit
import Foundation

/// Modal prompt for naming a new project/palette.
///
/// History — everything we tried before this worked visually (cursor blinks in
/// the field) but failed to receive keyboard input:
///
/// 1. SwiftUI `.sheet` + `@FocusState`                           — no input
/// 2. `NSViewRepresentable` + `makeFirstResponder`               — no input
/// 3. Custom `NSTextField` subclass forcing `becomeFirstResponder` — no input
/// 4. `NSAlert` + `accessoryView` + `initialFirstResponder`      — no input
/// 5. `NSAlert` + `Task { @MainActor }` + `makeFirstResponder`   — no input
/// 6. Bespoke `NSWindow` + `NSApp.runModal(for:)`                — still no input
///
/// Why #6 failed: in SwiftUI `@main` apps the scene's window retains some kind
/// of lock on keyboard event dispatch that `NSApp.runModal` can't override.
/// The modal window is visible and visually key, but key events don't reach
/// its first-responder field editor.
///
/// This version (#7) attaches the prompt as an AppKit **sheet** to the
/// SwiftUI scene's own window via `beginSheet`. Sheets ride the parent
/// window's key chain natively — there is no separate modal session for
/// SwiftUI to fight over — so keyboard events flow to the sheet's field
/// editor the same way they would to any native sheet (Save dialog, etc.).
@MainActor
final class NewCollectionPrompt: NSObject {

    /// Shows the prompt and returns the entered name + a default color, or nil
    /// if the user cancelled / left the name blank. Async because sheets are
    /// fundamentally async — the parent window's event loop keeps running.
    static func show(kind: FontCollection.Kind) async -> (name: String, color: String)? {
        guard let parent = Self.findParentWindow() else { return nil }
        // Strong self-reference is held by beginSheet's completion block and
        // by the continuation, so the controller lives until the sheet ends.
        let controller = NewCollectionPrompt(kind: kind)
        return await controller.runSheet(on: parent)
    }

    // MARK: - Private state

    private let kind: FontCollection.Kind
    private let window: NSWindow
    private let textField: NSTextField
    private var continuation: CheckedContinuation<(name: String, color: String)?, Never>?

    private init(kind: FontCollection.Kind) {
        self.kind = kind

        // Layout metrics
        let width: CGFloat = 460
        let height: CGFloat = 210
        let pad: CGFloat = 20

        // Sheet window — no title bar needed (sheet has none); use .titled for
        // a sane content margin. `.fullSizeContentView` so we draw our own
        // heading without visual conflict with a system title bar.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false

        // Content view
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Heading
        let heading = NSTextField(labelWithString:
            kind == .project ? "New Project" : "New Palette")
        heading.font = .boldSystemFont(ofSize: 15)
        heading.frame = NSRect(x: pad, y: height - 48, width: width - pad*2, height: 22)
        content.addSubview(heading)

        // Description
        let desc = kind == .project
            ? "Group the fonts you're using on a specific project. Toggle them all at once from the sidebar. You can change the color later from the collection's right-click menu."
            : "Save a reusable palette — e.g. 'Brand Guidelines' or 'Editorial'. You can change the color later from the collection's right-click menu."
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: pad, y: 90, width: width - pad*2, height: 64)
        content.addSubview(descLabel)

        // Text field
        let tf = NSTextField(frame: NSRect(x: pad, y: 58, width: width - pad*2, height: 24))
        tf.placeholderString = "Name"
        tf.bezelStyle = .roundedBezel
        tf.isEditable = true
        tf.isSelectable = true
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.focusRingType = .default
        content.addSubview(tf)

        self.window = win
        self.textField = tf

        super.init()

        // Buttons (need self for target/action, hence post-super.init)
        let cancel = NSButton(title: "Cancel",
                              target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: width - pad - 95 - 100 - 10, y: 15,
                              width: 100, height: 28)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"  // Escape
        content.addSubview(cancel)

        let create = NSButton(title: "Create",
                              target: self, action: #selector(createTapped))
        create.frame = NSRect(x: width - pad - 95, y: 15, width: 95, height: 28)
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"      // Return — also makes this the default (highlighted) button
        content.addSubview(create)

        win.contentView = content
        win.initialFirstResponder = tf
    }

    // MARK: - Sheet lifecycle

    private func runSheet(on parent: NSWindow) async -> (name: String, color: String)? {
        return await withCheckedContinuation { (cont: CheckedContinuation<(name: String, color: String)?, Never>) in
            self.continuation = cont
            parent.beginSheet(window) { [weak self] response in
                guard let self = self else { return }
                // Resume with the captured text on OK; nil on Cancel or blank.
                if response == .OK {
                    let trimmed = self.textField.stringValue
                        .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        self.continuation?.resume(
                            returning: (trimmed, Self.defaultColorHex(for: self.kind))
                        )
                        self.continuation = nil
                        return
                    }
                }
                self.continuation?.resume(returning: nil)
                self.continuation = nil
            }
            // The sheet is now up — force focus into the field. beginSheet
            // configures the responder chain to route to the sheet, so this
            // call sticks even in SwiftUI-hosted apps.
            self.window.makeFirstResponder(self.textField)
        }
    }

    @objc private func cancelTapped() {
        guard let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: .cancel)
    }

    @objc private func createTapped() {
        guard let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: .OK)
    }

    // MARK: - Helpers

    /// Finds the SwiftUI scene's backing NSWindow. Checks keyWindow first,
    /// falls back to mainWindow, then any visible window. Returns nil only if
    /// the app genuinely has no visible windows (prompt can't attach anywhere).
    private static func findParentWindow() -> NSWindow? {
        if let key = NSApp.keyWindow { return key }
        if let main = NSApp.mainWindow { return main }
        return NSApp.windows.first(where: { $0.isVisible })
    }

    /// A rotating default color so each new collection gets a distinct tint.
    private static func defaultColorHex(for kind: FontCollection.Kind) -> String {
        let palette = [
            "#7DD3FC", "#A78BFA", "#F472B6", "#FB923C",
            "#FACC15", "#4ADE80", "#22D3EE", "#F87171"
        ]
        let seed = UInt64(Date().timeIntervalSinceReferenceDate)
        return palette[Int(seed % UInt64(palette.count))]
    }
}
