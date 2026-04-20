import Foundation
import SwiftUI

@MainActor
final class FontLibrary: ObservableObject {
    // MARK: - Published state
    @Published private(set) var items: [FontItem] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanStatus: String = ""

    @Published var favorites: Set<String> = []
    @Published var collections: [FontCollection] = []
    @Published var activeFontIDs: Set<String> = []
    @Published var customScanPaths: [URL] = []

    @Published var previewText: String = "The quick brown fox jumps over the lazy dog"
    @Published var previewSize: Double = 36

    // MARK: - Selection
    @Published var sidebarSelection: SidebarItem = .allFonts
    @Published var searchQuery: String = ""
    @Published var selectedFontID: String? = nil

    private let activator = FontActivator()

    // MARK: - Bootstrap

    func bootstrap() async {
        let state = Persistence.loadState()
        self.favorites = state.favorites
        self.collections = state.collections
        self.activeFontIDs = state.activeFontIDs
        self.customScanPaths = state.customScanPaths
        self.previewText = state.userText.isEmpty ? previewText : state.userText
        self.previewSize = state.previewSize > 0 ? state.previewSize : previewSize

        if let cached = Persistence.loadCachedLibrary(), !cached.isEmpty {
            self.items = cached
        } else {
            await rescan()
        }

        // Re-apply activation state from last launch (session scope clears on logout).
        await reapplyActivations()
    }

    // MARK: - Scanning

    func rescan() async {
        isScanning = true
        scanStatus = "Scanning fonts…"
        let roots = FontScanner.defaultSearchRoots + customScanPaths
        let scanned = await Task.detached(priority: .userInitiated) {
            FontScanner.scan(roots: roots)
        }.value

        // Sort by family then style for stable listing
        self.items = scanned.sorted {
            if $0.familyName.lowercased() == $1.familyName.lowercased() {
                return $0.styleName < $1.styleName
            }
            return $0.familyName.lowercased() < $1.familyName.lowercased()
        }
        scanStatus = "\(items.count) faces across \(Set(items.map{$0.familyKey}).count) families"
        isScanning = false
        Persistence.saveCachedLibrary(items)
    }

    // MARK: - Derived data

    var familyGroups: [FontFamilyGroup] {
        let filtered = currentItems()
        let grouped = Dictionary(grouping: filtered, by: { $0.familyKey })
        return grouped
            .map { key, faces in
                FontFamilyGroup(
                    key: key,
                    name: faces.first?.familyName ?? key,
                    faces: faces.sorted { $0.weight < $1.weight }
                )
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func currentItems() -> [FontItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let scope: [FontItem]
        switch sidebarSelection {
        case .allFonts:
            scope = items
        case .active:
            scope = items.filter { activeFontIDs.contains($0.id) }
        case .inactive:
            scope = items.filter { !activeFontIDs.contains($0.id) }
        case .favorites:
            scope = items.filter { favorites.contains($0.id) }
        case .category(let cat):
            scope = items.filter { $0.category == cat }
        case .mood(let mood):
            scope = items.filter { $0.moods.contains(mood) }
        case .collection(let id):
            if let c = collections.first(where: { $0.id == id }) {
                scope = items.filter { c.fontIDs.contains($0.id) }
            } else { scope = [] }
        }
        if q.isEmpty { return scope }
        return scope.filter {
            $0.familyName.lowercased().contains(q) ||
            $0.styleName.lowercased().contains(q) ||
            $0.postScriptName.lowercased().contains(q)
        }
    }

    var categoryCounts: [(FontCategory, Int)] {
        var counts: [FontCategory: Int] = [:]
        for it in items { counts[it.category, default: 0] += 1 }
        return FontCategory.allCases
            .filter { counts[$0, default: 0] > 0 }
            .map { ($0, counts[$0]!) }
    }

    var moodCounts: [(FontMood, Int)] {
        var counts: [FontMood: Int] = [:]
        for it in items {
            for m in it.moods { counts[m, default: 0] += 1 }
        }
        return FontMood.allCases
            .filter { counts[$0, default: 0] > 0 }
            .map { ($0, counts[$0]!) }
    }

    // MARK: - Favorites

    func toggleFavorite(_ item: FontItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) }
        else { favorites.insert(item.id) }
        persist()
    }

    // MARK: - Activation

    func isActive(_ item: FontItem) -> Bool { activeFontIDs.contains(item.id) }

    func setActive(_ item: FontItem, active: Bool) async {
        if active {
            try? await activator.activate([item])
            activeFontIDs.insert(item.id)
        } else {
            try? await activator.deactivate([item])
            activeFontIDs.remove(item.id)
        }
        persist()
    }

    func setActiveMany(_ items: [FontItem], active: Bool) async {
        if active {
            try? await activator.activate(items)
            activeFontIDs.formUnion(items.map { $0.id })
        } else {
            try? await activator.deactivate(items)
            activeFontIDs.subtract(items.map { $0.id })
        }
        persist()
    }

    func toggleCollectionActive(_ collection: FontCollection) async {
        let targets = items.filter { collection.fontIDs.contains($0.id) }
        let allActive = targets.allSatisfy { activeFontIDs.contains($0.id) }
        await setActiveMany(targets, active: !allActive)
    }

    func isCollectionFullyActive(_ collection: FontCollection) -> Bool {
        guard !collection.fontIDs.isEmpty else { return false }
        return collection.fontIDs.allSatisfy { activeFontIDs.contains($0) }
    }

    private func reapplyActivations() async {
        let active = items.filter { activeFontIDs.contains($0.id) }
        guard !active.isEmpty else { return }
        try? await activator.activate(active)
    }

    // MARK: - Collections (projects + palettes)

    func addCollection(name: String, kind: FontCollection.Kind, colorHex: String = "#7DD3FC") {
        let c = FontCollection(name: name, kind: kind, colorHex: colorHex)
        collections.append(c)
        sidebarSelection = .collection(c.id)
        persist()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        if case .collection(let s) = sidebarSelection, s == id {
            sidebarSelection = .allFonts
        }
        persist()
    }

    func addToCollection(_ id: UUID, fontIDs: [String]) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].fontIDs.formUnion(fontIDs)
        persist()
    }

    func removeFromCollection(_ id: UUID, fontIDs: [String]) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].fontIDs.subtract(fontIDs)
        persist()
    }

    // MARK: - Scan paths

    func addCustomScanPath(_ url: URL) {
        guard !customScanPaths.contains(url) else { return }
        customScanPaths.append(url)
        persist()
        Task { await rescan() }
    }

    func removeCustomScanPath(_ url: URL) {
        customScanPaths.removeAll { $0 == url }
        persist()
    }

    // MARK: - Persistence helper

    private func persist() {
        let state = LibraryState(
            favorites: favorites,
            collections: collections,
            activeFontIDs: activeFontIDs,
            customScanPaths: customScanPaths,
            userText: previewText,
            previewSize: previewSize
        )
        Persistence.saveState(state)
    }

    func savePreviewPrefs() { persist() }
}

struct FontFamilyGroup: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let faces: [FontItem]
}

enum SidebarItem: Hashable {
    case allFonts
    case active
    case inactive
    case favorites
    case category(FontCategory)
    case mood(FontMood)
    case collection(UUID)
}
