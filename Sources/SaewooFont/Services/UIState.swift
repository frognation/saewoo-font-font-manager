import Foundation
import SwiftUI

/// Small, focused observable objects split out of `FontLibrary`.
///
/// Why they exist: `FontLibrary` is a single `ObservableObject` that 14 views
/// observe via `@EnvironmentObject`. SwiftUI has no per-property granularity
/// there — *any* `@Published` mutation re-evaluates *every* observing view's
/// body. Selection changes, preview-slider drags and search keystrokes are
/// high-frequency and touch nothing the sidebar renders, yet each one used to
/// force a full `SidebarView` rebuild.
///
/// Keeping these out of `FontLibrary` means the sidebar only rebuilds when the
/// library itself actually changes (items / favorites / collections / active
/// set), which is the whole point.

/// Which face the inspector is showing. Mutated on every row tap.
@MainActor
final class SelectionModel: ObservableObject {
    @Published var selectedFontID: String? = nil
}

/// Live preview text + size. Mutated continuously while dragging the size
/// slider, so it must not be able to invalidate the sidebar.
@MainActor
final class PreviewSettings: ObservableObject {
    @Published var text: String = "The quick brown fox jumps over the lazy dog"
    @Published var size: Double = 36

    /// Called (debounced) when a value changes, so `FontLibrary` can persist
    /// the new prefs without owning the published state itself.
    var onCommit: ((String, Double) -> Void)?

    private var saveTask: Task<Void, Never>?

    /// Coalesces writes — a slider drag emits dozens of changes per second and
    /// each one would otherwise rewrite state.json.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            onCommit?(text, size)
        }
    }
}
