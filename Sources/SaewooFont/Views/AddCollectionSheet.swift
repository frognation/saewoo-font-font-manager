import AppKit
import Foundation

/// Modal prompt for naming a new project/palette. Built from scratch on top of
/// a plain `NSWindow` + `NSApp.runModal(for:)` because every prior approach
/// failed to accept keyboard input inside this SwiftUI app:
///
/// 1. SwiftUI `.sheet` + `@FocusState`  → cursor blinks, no input
/// 2. `NSViewRepresentable` + `makeFirstResponder` in `updateNSView` → same
/// 3. Custom `NSTextField` subclass forcing `becomeFirstResponder` → same
/// 4. `NSAlert` with `accessoryView` + `initialFirstResponder`     → same
/// 5. `NSAlert` + `Task { @MainActor }` + explicit `makeFirstResponder` → same
///
/// Root pathology in all five: when the app is hosted inside a SwiftUI
/// `NavigationSplitView`, the SwiftUI hosting chain intercepts key events for
/// the duration of any NSAlert or SwiftUI-sheet modal, even while the
/// accessory text field is visually focused.
///
/// Attempt #6 — a bespoke `NSWindow`. We own the content view, the text
/// field, the button targets, and we call `NSApp.runModal(for:)` directly.
/// With full control of the responder chain and no NSAlert machinery in the
/// way, key events route to the field editor as expected.
@MainActor
final class NewCollectionPrompt: NSObject {

    /// Shows the prompt and returns the entered name + a default color, or nil
    /// if the user cancelled / left the name blank.
    static func show(kind: FontCollection.Kind) -> (name: String, color: String)? {
        let prompt = NewCollectionPrompt(kind: kind)
        return prompt.runModal()
    }

    // MARK: - Private state

    private let kind: FontCollection.Kind
    private let window: NSWindow
    private let textField: NSTextField

    private init(kind: FontCollection.Kind) {
        self.kind = kind

        // Content metrics
        let width: CGFloat = 460
        let height: CGFloat = 210
        let pad: CGFloat = 20

        // --- Window shell ---
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = kind == .project ? "New Project" : "New Palette"
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.level = .modalPanel

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // --- Heading ---
        let heading = NSTextField(labelWithString:
            kind == .project ? "New Project" : "New Palette")
        heading.font = .boldSystemFont(ofSize: 15)
        heading.frame = NSRect(x: pad, y: height - 40, width: width - pad*2, height: 22)
        content.addSubview(heading)

        // --- Description ---
        let desc = kind == .project
            ? "Group the fonts you're using on a specific project. Toggle them all at once from the sidebar. You can change the color later from the collection's right-click menu."
            : "Save a reusable palette — e.g. 'Brand Guidelines' or 'Editorial'. You can change the color later from the collection's right-click menu."
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: pad, y: 85, width: width - pad*2, height: 62)
        content.addSubview(descLabel)

        // --- Text field ---
        let tf = NSTextField(frame: NSRect(x: pad, y: 55, width: width - pad*2, height: 24))
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

        // --- Buttons (need `self` for target/action, so after super.init) ---
        let cancel = NSButton(title: "Cancel",
                              target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: width - pad - 95 - 100 - 10, y: 15, width: 100, height: 28)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"      // Escape
        content.addSubview(cancel)

        let create = NSButton(title: "Create",
                              target: self, action: #selector(createTapped))
        create.frame = NSRect(x: width - pad - 95, y: 15, width: 95, height: 28)
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"          // Return — this also makes it the default (blue) button
        content.addSubview(create)

        win.contentView = content
        win.center()

        // Mark the text field as the window's initial first responder so that
        // focus is correctly placed the moment the window becomes key.
        win.initialFirstResponder = tf
    }

    // MARK: - Modal

    private func runModal() -> (name: String, color: String)? {
        // makeKeyAndOrderFront must happen *before* runModal so the window is
        // visible and key when the modal event loop spins up.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)

        let response = NSApp.runModal(for: window)
        window.orderOut(nil)

        guard response == .OK else { return nil }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, Self.defaultColorHex(for: kind))
    }

    @objc private func cancelTapped() { NSApp.stopModal(withCode: .cancel) }
    @objc private func createTapped() { NSApp.stopModal(withCode: .OK) }

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
