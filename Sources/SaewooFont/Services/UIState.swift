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

/// Which faces are selected. Mutated on every row tap.
///
/// Supports the standard macOS list idioms: plain click replaces the
/// selection, ⌘-click toggles one row, ⇧-click extends from the last anchor.
@MainActor
final class SelectionModel: ObservableObject {
    /// Every selected face.
    @Published private(set) var selectedIDs: Set<String> = []

    /// The row the inspector follows — the most recently clicked one.
    /// Always a member of `selectedIDs` (or nil). Mutate it through the methods
    /// below rather than assigning directly, so the two stay in step.
    @Published private(set) var selectedFontID: String? = nil

    /// Where a ⇧-click range starts from.
    private(set) var anchorID: String? = nil

    var count: Int { selectedIDs.count }
    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    /// Plain click — this row becomes the whole selection.
    func select(_ id: String) {
        selectedIDs = [id]
        anchorID = id
        selectedFontID = id
    }

    /// ⌘-click — add or remove a single row without disturbing the rest.
    func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedFontID == id { selectedFontID = selectedIDs.first }
        } else {
            selectedIDs.insert(id)
            selectedFontID = id
        }
        anchorID = id
    }

    /// ⇧-click — select everything between the anchor and `id` in the order
    /// the rows are currently displayed. `visibleOrder` must be the flattened,
    /// on-screen row order, otherwise the range means nothing to the user.
    func extend(to id: String, visibleOrder: [String]) {
        guard let anchor = anchorID,
              let a = visibleOrder.firstIndex(of: anchor),
              let b = visibleOrder.firstIndex(of: id) else {
            select(id); return
        }
        let range = a <= b ? a...b : b...a
        selectedIDs = Set(visibleOrder[range])
        selectedFontID = id
        // Anchor deliberately unchanged, so successive ⇧-clicks re-range from
        // the same origin rather than creeping.
    }

    func selectAll(_ ids: [String]) {
        selectedIDs = Set(ids)
        anchorID = ids.first
        selectedFontID = ids.last
    }

    func clear() {
        selectedIDs = []
        anchorID = nil
        selectedFontID = nil
    }

    /// Resolves the selection against the library, preserving display order.
    func selectedItems(in items: [FontItem]) -> [FontItem] {
        guard !selectedIDs.isEmpty else { return [] }
        return items.filter { selectedIDs.contains($0.id) }
    }
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
