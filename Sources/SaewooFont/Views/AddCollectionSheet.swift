import SwiftUI
import AppKit

/// Prompts the user for a new project/palette name using a minimal `NSAlert`.
/// Four previous SwiftUI-based attempts (FocusState, NSViewRepresentable with
/// `makeFirstResponder`, custom NSTextField subclass, custom NSView accessory
/// with NSTextField) all failed due to SwiftUI sheets losing first-responder
/// negotiation inside a NavigationSplitView sidebar column.
///
/// This version uses the simplest possible NSAlert recipe — a bare NSTextField
/// as `accessoryView`, with `initialFirstResponder` set before runModal. This
/// pattern is used across AppKit apps for 20+ years and is the most reliable
/// thing we can do.
enum NewCollectionPrompt {
    @MainActor
    static func show(kind: FontCollection.Kind) -> (name: String, color: String)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = kind == .project ? "New Project" : "New Palette"
        alert.informativeText = kind == .project
            ? "Group the fonts you're using on a specific project. Toggle them all at once from the sidebar. You can change the color later from the collection's right-click menu."
            : "Save a reusable palette — e.g. 'Brand Guidelines' or 'Editorial'. You can change the color later from the collection's right-click menu."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        // Single, plain NSTextField as the accessory — no custom subclass, no
        // wrapper view. This is the tried-and-true NSAlert-with-input recipe.
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        tf.placeholderString = "Name"
        tf.bezelStyle = .roundedBezel
        alert.accessoryView = tf

        // Forcing the alert's window to layout ensures the accessoryView is
        // already installed when we set initialFirstResponder.
        alert.layout()
        alert.window.initialFirstResponder = tf

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, defaultColorHex(for: kind))
    }

    /// A rotating default color so each new collection gets a distinct tint
    /// even though the prompt no longer has a picker.
    private static func defaultColorHex(for kind: FontCollection.Kind) -> String {
        let palette = [
            "#7DD3FC", "#A78BFA", "#F472B6", "#FB923C",
            "#FACC15", "#4ADE80", "#22D3EE", "#F87171"
        ]
        // Rotate on every call so consecutive additions look visually distinct.
        let seed = UInt64(Date().timeIntervalSinceReferenceDate)
        return palette[Int(seed % UInt64(palette.count))]
    }
}
