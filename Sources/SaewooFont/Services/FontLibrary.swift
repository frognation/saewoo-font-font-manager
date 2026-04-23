import Foundation
import SwiftUI

@MainActor
final class FontLibrary: ObservableObject {
    // MARK: - Published state
    @Published private(set) var items: [FontItem] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanStatus: String = ""

    /// Versioning tag bumped whenever derived data (counts, grouped views,
    /// duplicates, etc.) should be considered stale. All expensive `var` getters
    /// check this and reuse a cached result if the version matches. This is
    /// critical for perf: without it, the sidebar re-iterates `items` dozens of
    /// times per keystroke.
    private var derivedVersion: Int = 0
    private func invalidateDerived() {
        derivedVersion &+= 1
        // Clear every cache slot. Getters will repopulate lazily.
        categoryCountsCache = nil
        moodCountsCache = nil
        foundryCountsCache = nil
        variableCountCache = nil
        duplicateGroupsCache = nil
        itemsByFileSizeCache = nil
        missingRefsCache = nil
    }

    private var categoryCountsCache: (Int, [(FontCategory, Int)])? = nil
    private var moodCountsCache: (Int, [(FontMood, Int)])? = nil
    private var foundryCountsCache: (Int, [(String, Int)])? = nil
    private var variableCountCache: (Int, Int)? = nil
    private var duplicateGroupsCache: (Int, [(name: String, items: [FontItem])])? = nil
    private var itemsByFileSizeCache: (Int, [FontItem])? = nil
    private var missingRefsCache: (Int, [MissingReference])? = nil

    @Published var favorites: Set<String> = []
    @Published var collections: [FontCollection] = []
    @Published var activeFontIDs: Set<String> = []
    @Published var customScanPaths: [URL] = []
    @Published var variableInstances: [VariableInstance] = []
    @Published var hiddenDefaultSources: Set<String> = []
    /// Files with font extensions that Core Text couldn't read — populated each scan.
    /// Not cached to disk; rebuilt from the current scan.
    @Published private(set) var orphanURLs: [URL] = []

    @Published var previewText: String = "The quick brown fox jumps over the lazy dog"
    @Published var previewSize: Double = 36

    // MARK: - Selection

    @Published var sidebarSelection: SidebarItem = .allFonts
    @Published var selectedFontID: String? = nil

    /// What the user is currently typing. Bound to the search text field so
    /// every keystroke only updates this one tiny string — no derived data
    /// is recomputed. Fast to redraw.
    @Published var searchInput: String = ""

    /// What the family list actually filters on. Updated from `searchInput`
    /// after a short debounce so that 45 000 fonts aren't re-scanned on
    /// every keystroke.
    @Published private(set) var searchQuery: String = ""

    private var searchDebounceTask: Task<Void, Never>?

    /// Called from the search TextField's `onChange`. Stores the keystroke
    /// immediately and schedules a debounced commit to `searchQuery`.
    func updateSearchInput(_ text: String) {
        searchInput = text
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)  // 180ms
            guard !Task.isCancelled, self.searchInput == text else { return }
            if self.searchQuery != text {
                self.searchQuery = text
                self.invalidateDerivedViews()
            }
        }
    }

    /// Invalidate only the per-selection caches that depend on `searchQuery`
    /// or `sidebarSelection` — not the heavy `derivedVersion` counter that
    /// gates the whole library.
    fileprivate func invalidateDerivedViews() {
        currentItemsCache = nil
        familyGroupsCache = nil
    }

    private let activator = FontActivator()

    // MARK: - Bootstrap

    func bootstrap() async {
        let state = Persistence.loadState()
        self.favorites = state.favorites
        self.collections = state.collections
        self.activeFontIDs = state.activeFontIDs
        self.customScanPaths = state.customScanPaths
        self.variableInstances = state.variableInstances
        self.hiddenDefaultSources = state.hiddenDefaultSources
        self.previewText = state.userText.isEmpty ? previewText : state.userText
        self.previewSize = state.previewSize > 0 ? state.previewSize : previewSize

        if let cached = Persistence.loadCachedLibrary(), !cached.isEmpty,
           !Self.cacheLooksStale(cached) {
            self.items = cached
            invalidateDerived()
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
        let roots = visibleDefaultSources + customScanPaths
        let result = await FontScanner.scanParallel(roots: roots)

        // Sort by family then style for stable listing
        self.items = result.items.sorted {
            if $0.familyName.lowercased() == $1.familyName.lowercased() {
                return $0.styleName < $1.styleName
            }
            return $0.familyName.lowercased() < $1.familyName.lowercased()
        }
        invalidateDerived()
        self.orphanURLs = result.orphanURLs
        scanStatus = "\(items.count) faces across \(Set(items.map{$0.familyKey}).count) families"
        + (result.orphanURLs.isEmpty ? "" : " · \(result.orphanURLs.count) orphan\(result.orphanURLs.count == 1 ? "" : "s")")
        isScanning = false
        Persistence.saveCachedLibrary(items)
    }

    // MARK: - Derived data

    /// Cache of the last `currentItems()` result, keyed by the inputs that
    /// produced it. With 45 000+ fonts, re-filtering on every SwiftUI render
    /// is the difference between smooth and unusable.
    fileprivate var currentItemsCache: (derivedVersion: Int,
                                        selection: SidebarItem,
                                        query: String,
                                        activeVer: Int,
                                        favVer: Int,
                                        result: [FontItem])? = nil

    fileprivate var familyGroupsCache: (derivedVersion: Int,
                                        selection: SidebarItem,
                                        query: String,
                                        activeVer: Int,
                                        favVer: Int,
                                        result: [FontFamilyGroup])? = nil

    /// Bumps each time `activeFontIDs` or `favorites` changes so the view
    /// caches know to recompute for selections that depend on them.
    fileprivate var activeVersion: Int = 0
    fileprivate var favoritesVersion: Int = 0

    var familyGroups: [FontFamilyGroup] {
        if let c = familyGroupsCache,
           c.derivedVersion == derivedVersion,
           c.selection == sidebarSelection,
           c.query == searchQuery,
           c.activeVer == activeVersion,
           c.favVer == favoritesVersion {
            return c.result
        }
        let filtered = currentItems()
        let grouped = Dictionary(grouping: filtered, by: { $0.familyKey })
        let result = grouped
            .map { key, faces in
                FontFamilyGroup(
                    key: key,
                    name: faces.first?.familyName ?? key,
                    faces: faces.sorted { $0.weight < $1.weight }
                )
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        familyGroupsCache = (derivedVersion, sidebarSelection, searchQuery,
                             activeVersion, favoritesVersion, result)
        return result
    }

    func currentItems() -> [FontItem] {
        if let c = currentItemsCache,
           c.derivedVersion == derivedVersion,
           c.selection == sidebarSelection,
           c.query == searchQuery,
           c.activeVer == activeVersion,
           c.favVer == favoritesVersion {
            return c.result
        }
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
        case .variable:
            scope = items.filter { $0.isVariable }
        case .category(let cat):
            scope = items.filter { $0.categories.contains(cat) }
        case .mood(let mood):
            scope = items.filter { $0.moods.contains(mood) }
        case .foundry(let name):
            scope = items.filter { $0.foundry == name }
        case .source(let url):
            let prefix = url.standardizedFileURL.path
            scope = items.filter { $0.fileURL.standardizedFileURL.path.hasPrefix(prefix) }
        case .collection(let id):
            if let c = collections.first(where: { $0.id == id }) {
                scope = items.filter { c.fontIDs.contains($0.id) }
            } else { scope = [] }
        case .tool:
            // Tool views render their own data; family list is unused here,
            // but return all so the fallback is sensible if ever visible.
            scope = items
        }
        let filtered: [FontItem]
        if q.isEmpty {
            filtered = scope
        } else {
            filtered = scope.filter {
                $0.familyName.lowercased().contains(q) ||
                $0.styleName.lowercased().contains(q) ||
                $0.postScriptName.lowercased().contains(q)
            }
        }
        currentItemsCache = (derivedVersion, sidebarSelection, searchQuery,
                             activeVersion, favoritesVersion, filtered)
        return filtered
    }

    var categoryCounts: [(FontCategory, Int)] {
        if let c = categoryCountsCache, c.0 == derivedVersion { return c.1 }
        var counts: [FontCategory: Int] = [:]
        for it in items {
            for cat in it.categories { counts[cat, default: 0] += 1 }
        }
        let out = FontCategory.allCases
            .filter { counts[$0, default: 0] > 0 }
            .map { ($0, counts[$0]!) }
        categoryCountsCache = (derivedVersion, out)
        return out
    }

    var moodCounts: [(FontMood, Int)] {
        if let c = moodCountsCache, c.0 == derivedVersion { return c.1 }
        var counts: [FontMood: Int] = [:]
        for it in items {
            for m in it.moods { counts[m, default: 0] += 1 }
        }
        let out = FontMood.allCases
            .filter { counts[$0, default: 0] > 0 }
            .map { ($0, counts[$0]!) }
        moodCountsCache = (derivedVersion, out)
        return out
    }

    var foundryCounts: [(String, Int)] {
        if let c = foundryCountsCache, c.0 == derivedVersion { return c.1 }
        var counts: [String: Int] = [:]
        for it in items { counts[it.foundry, default: 0] += 1 }
        let out = counts
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                if a.0 == "Unknown" && b.0 != "Unknown" { return false }
                if b.0 == "Unknown" && a.0 != "Unknown" { return true }
                return a.0.lowercased() < b.0.lowercased()
            }
        foundryCountsCache = (derivedVersion, out)
        return out
    }

    var variableCount: Int {
        if let c = variableCountCache, c.0 == derivedVersion { return c.1 }
        let n = items.reduce(0) { $0 + ($1.isVariable ? 1 : 0) }
        variableCountCache = (derivedVersion, n)
        return n
    }

    func itemsInSource(_ url: URL) -> [FontItem] {
        let prefix = url.standardizedFileURL.path
        return items.filter { $0.fileURL.standardizedFileURL.path.hasPrefix(prefix) }
    }

    /// Quick activate-all / deactivate-all helpers for a foundry.
    func itemsInFoundry(_ name: String) -> [FontItem] {
        items.filter { $0.foundry == name }
    }

    // MARK: - Favorites

    func toggleFavorite(_ item: FontItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) }
        else { favorites.insert(item.id) }
        favoritesVersion &+= 1
        invalidateDerived()
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
        activeVersion &+= 1
        invalidateDerivedViews()
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
        activeVersion &+= 1
        invalidateDerivedViews()
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

    /// Returns true if the cache predates a field we now rely on (e.g. foundry).
    /// We detect this by checking whether every single item has the fallback value —
    /// which is virtually impossible for a real library scanned with the current
    /// scanner, but is exactly what happens after decoding a pre-foundry cache.
    private static func cacheLooksStale(_ cached: [FontItem]) -> Bool {
        guard cached.count >= 20 else { return false }  // too small to judge
        return cached.allSatisfy { $0.foundry == "Unknown" }
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
        invalidateDerived()
        persist()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        if case .collection(let s) = sidebarSelection, s == id {
            sidebarSelection = .allFonts
        }
        invalidateDerived()
        persist()
    }

    func setCollectionColor(_ id: UUID, hex: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].colorHex = hex
        persist()
    }

    func addToCollection(_ id: UUID, fontIDs: [String]) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].fontIDs.formUnion(fontIDs)
        invalidateDerived()
        persist()
    }

    func removeFromCollection(_ id: UUID, fontIDs: [String]) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].fontIDs.subtract(fontIDs)
        invalidateDerived()
        persist()
    }

    // MARK: - Tools: orphans

    /// Trash an orphan file and drop it from the in-memory list.
    func trashOrphan(_ url: URL) async throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        orphanURLs.removeAll { $0 == url }
    }

    // MARK: - Tools: missing references

    /// Any FontItem.id referenced by favorites or a collection but no longer
    /// present in `items` (because the underlying file vanished between scans).
    struct MissingReference: Identifiable, Hashable {
        let id: String           // the FontItem.id that can't be resolved
        let locations: [String]  // human-readable descriptions of where it's referenced
    }

    var missingReferences: [MissingReference] {
        if let c = missingRefsCache, c.0 == derivedVersion { return c.1 }
        let existing = Set(items.map { $0.id })
        var map: [String: [String]] = [:]
        for id in favorites where !existing.contains(id) {
            map[id, default: []].append("Favorites")
        }
        for c in collections {
            for id in c.fontIDs where !existing.contains(id) {
                let kind = c.kind == .project ? "Project" : "Palette"
                map[id, default: []].append("\(kind): \(c.name)")
            }
        }
        for vi in variableInstances where !existing.contains(vi.baseFontID) {
            map[vi.baseFontID, default: []].append("Variable Instance: \(vi.name)")
        }
        let refs = map
            .map { MissingReference(id: $0.key, locations: $0.value) }
            .sorted { $0.id < $1.id }
        missingRefsCache = (derivedVersion, refs)
        return refs
    }

    /// Remove every dangling favorite/collection/variable-instance reference
    /// that points at a missing FontItem.id. Non-destructive to files.
    func cleanupMissingReferences() {
        let existing = Set(items.map { $0.id })
        favorites = favorites.filter { existing.contains($0) }
        for i in 0..<collections.count {
            collections[i].fontIDs = collections[i].fontIDs.filter { existing.contains($0) }
        }
        variableInstances.removeAll { !existing.contains($0.baseFontID) }
        invalidateDerived()
        persist()
    }

    // MARK: - Tools: large files

    /// FontItems sorted by file size, largest first. Useful for the Largest
    /// Files tool (disk-space audit).
    var itemsByFileSize: [FontItem] {
        if let c = itemsByFileSizeCache, c.0 == derivedVersion { return c.1 }
        let sorted = items.sorted { $0.fileSize > $1.fileSize }
        itemsByFileSizeCache = (derivedVersion, sorted)
        return sorted
    }

    // MARK: - Tools: duplicates

    /// Groups of FontItems that share a PostScript name — i.e. files the OS
    /// will disambiguate arbitrarily. Only groups with >1 member are returned.
    /// Sorted alphabetically by PS name.
    var duplicateGroups: [(name: String, items: [FontItem])] {
        if let c = duplicateGroupsCache, c.0 == derivedVersion { return c.1 }
        let groups = Dictionary(grouping: items, by: { $0.postScriptName })
            .filter { $0.value.count > 1 }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (name: $0.key, items: $0.value) }
        duplicateGroupsCache = (derivedVersion, groups)
        return groups
    }

    /// Moves the underlying font file to the Trash and removes all references.
    /// Throws on permission errors (e.g. system fonts in /Library/Fonts require admin).
    func deleteFontFile(_ item: FontItem) async throws {
        // 1. Release Core Text handle before touching the file.
        if activeFontIDs.contains(item.id) {
            try? await activator.deactivate([item])
            activeFontIDs.remove(item.id)
        }
        // 2. Move to Trash (safer than outright unlink). This can fail — let it propagate.
        try FileManager.default.trashItem(at: item.fileURL, resultingItemURL: nil)
        // 3. Scrub every reference we keep in-memory / on-disk.
        favorites.remove(item.id)
        for i in 0..<collections.count {
            collections[i].fontIDs.remove(item.id)
        }
        variableInstances.removeAll { $0.baseFontID == item.id }
        items.removeAll { $0.id == item.id }
        invalidateDerived()
        if selectedFontID == item.id { selectedFontID = nil }
        persist()
        Persistence.saveCachedLibrary(items)
    }

    // MARK: - Variable font instances

    func instances(for item: FontItem) -> [VariableInstance] {
        variableInstances.filter { $0.baseFontID == item.id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func saveVariableInstance(base: FontItem, name: String, axisValues: [String: Double]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let inst = VariableInstance(baseFontID: base.id, name: trimmed, axisValues: axisValues)
        variableInstances.append(inst)
        invalidateDerived()
        persist()
    }

    func deleteVariableInstance(_ id: UUID) {
        variableInstances.removeAll { $0.id == id }
        invalidateDerived()
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

    // MARK: - RightFont library import

    /// Result of a RightFont library import, surfaced to the user as a summary.
    struct RightFontImportReport {
        var libraryName: String
        var paletteCount: Int          // number of Palettes created
        var skippedCount: Int          // fontlists skipped (empty, no resolvable fonts, etc.)
        var starredMatchCount: Int     // fonts flagged starred in RightFont that we favorited
        var enrichedCount: Int         // fonts we matched to a RightFont metadata record
    }

    /// Imports collections + per-font metadata from a `.rightfontlibrary`
    /// package that's already been added as a scan path. Creates Palettes
    /// named after each RightFont "fontlist" and auto-favorites any fonts
    /// RightFont had starred. Safe to re-run — existing palettes with the
    /// same name under the same library are updated, not duplicated.
    @discardableResult
    func importRightFontLibrary(_ bundle: URL) async -> RightFontImportReport? {
        guard RightFontImporter.isLibrary(bundle) else { return nil }

        let manifest = RightFontImporter.parseManifest(in: bundle)
        let libName = manifest?.name ?? bundle.deletingPathExtension().lastPathComponent

        // Build lookup: hyphen-less UUID → RightFont font entry.
        let entries = await RightFontImporter.parseAllFontEntries(in: bundle)

        // Index our own items by absolute URL for quick resolution.
        let itemsByPath: [String: FontItem] = Dictionary(
            uniqueKeysWithValues: items.map {
                ($0.fileURL.standardizedFileURL.path, $0)
            }
        )

        // UUID → FontItem.id (ours). We resolve by absolute path so rescans
        // that regenerate our IDs still work correctly.
        var uuidToOurID: [String: String] = [:]
        var starredMatches = 0
        var enriched = 0
        for (hyphenless, entry) in entries {
            guard let loc = entry.location else { continue }
            let url = RightFontImporter.resolve(location: loc, in: bundle)
                .standardizedFileURL
            if let ours = itemsByPath[url.path] {
                uuidToOurID[hyphenless] = ours.id
                enriched += 1
                if entry.starred == true, !favorites.contains(ours.id) {
                    favorites.insert(ours.id)
                    starredMatches += 1
                }
            }
        }

        // Fontlists → Palettes.
        let lists = RightFontImporter.parseAllFontLists(in: bundle)
        var created = 0
        var skipped = 0
        // Tag imported palettes with a prefix so they're grouped visually.
        let palettePrefix = "[\(libName)] "

        for list in lists {
            guard let name = list.name, let fonts = list.fonts, !fonts.isEmpty else {
                skipped += 1; continue
            }
            let mappedIDs: Set<String> = Set(fonts.compactMap { uuidToOurID[$0.uppercased()] })
            guard !mappedIDs.isEmpty else { skipped += 1; continue }

            let paletteName = palettePrefix + name
            if let existingIdx = collections.firstIndex(where: {
                $0.kind == .palette && $0.name == paletteName
            }) {
                collections[existingIdx].fontIDs = mappedIDs
            } else {
                collections.append(FontCollection(
                    name: paletteName, kind: .palette,
                    colorHex: Self.rotatingPaletteColor(seed: collections.count),
                    fontIDs: mappedIDs
                ))
            }
            created += 1
        }

        persist()

        return RightFontImportReport(
            libraryName: libName,
            paletteCount: created,
            skippedCount: skipped,
            starredMatchCount: starredMatches,
            enrichedCount: enriched
        )
    }

    private static func rotatingPaletteColor(seed: Int) -> String {
        let palette = ["#7DD3FC", "#A78BFA", "#F472B6", "#FB923C",
                       "#FACC15", "#4ADE80", "#22D3EE", "#F87171"]
        return palette[abs(seed) % palette.count]
    }

    // MARK: - Persistence helper

    private func persist() {
        let state = LibraryState(
            favorites: favorites,
            collections: collections,
            activeFontIDs: activeFontIDs,
            customScanPaths: customScanPaths,
            userText: previewText,
            previewSize: previewSize,
            variableInstances: variableInstances,
            hiddenDefaultSources: hiddenDefaultSources
        )
        Persistence.saveState(state)
    }

    // MARK: - Sources visibility

    /// Default scan roots the sidebar should show (hidden ones filtered out).
    var visibleDefaultSources: [URL] {
        FontScanner.defaultSearchRoots.filter {
            !hiddenDefaultSources.contains($0.standardizedFileURL.path)
        }
    }

    /// Same as `visibleDefaultSources` but also drops any folder with fewer
    /// than two fonts — silences the sidebar when `/Library/Fonts` is empty
    /// (modern macOS keeps almost nothing there by default).
    var displayableDefaultSources: [URL] {
        visibleDefaultSources.filter { itemsInSource($0).count >= 2 }
    }

    /// The full list of all default scan roots (regardless of hidden state).
    var allDefaultSources: [URL] { FontScanner.defaultSearchRoots }

    /// Human-friendly label for a default scan root. Distinguishes between the
    /// two "Fonts" folders that macOS uses.
    static func label(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        if path == home + "/Library/Fonts"        { return "User Fonts" }
        if path == "/Library/Fonts"               { return "Shared Fonts" }
        if path.hasPrefix("/System/Library/Fonts"){ return "System Fonts" }
        return url.lastPathComponent
    }

    func hideDefaultSource(_ url: URL) {
        hiddenDefaultSources.insert(url.standardizedFileURL.path)
        persist()
        Task { await rescan() }
    }

    func unhideDefaultSource(_ url: URL) {
        hiddenDefaultSources.remove(url.standardizedFileURL.path)
        persist()
        Task { await rescan() }
    }

    // MARK: - Tools: Organize

    /// PostScript / family name prefixes that indicate "don't touch" Apple system fonts.
    /// Conservative — we'd rather skip movable fonts than break a user's OS.
    static let essentialSystemFamilies: Set<String> = [
        "Helvetica", "Helvetica Neue", "Menlo", "Monaco", "Courier", "Courier New",
        "Geneva", "Symbol", "Apple Symbols", "Apple Braille", "Apple Color Emoji",
        "Apple SD Gothic Neo", "AppleGothic", "AppleMyungjo", "Keyboard",
        "Lucida Grande", "STIX Two Math", "Hiragino Sans", "Hiragino Kaku Gothic",
        "Hiragino Mincho", "PingFang SC", "PingFang TC", "PingFang HK",
        "Kohinoor Telugu", "Kohinoor Devanagari", "Kohinoor Bangla",
        "LastResort", "GB18030 Bitmap", "Noteworthy", "Snell Roundhand",
        "Zapfino", "Times", "Times New Roman", "Arial", "Arial Unicode MS",
    ]

    /// True if this font should be treated as a system essential — i.e.
    /// the Organize tool leaves it in place by default.
    static func isSystemEssential(_ item: FontItem) -> Bool {
        if item.postScriptName.hasPrefix(".") { return true }
        if essentialSystemFamilies.contains(item.familyName) { return true }
        // /System/Library/Fonts is Apple's — we should never move these.
        if item.fileURL.path.hasPrefix("/System/") { return true }
        return false
    }

    /// Moves a single font file to a destination folder. Updates the in-memory
    /// item record to point at the new URL and re-indexes favorites/collections
    /// by the (unchanged) FontItem.id.
    /// Throws on permission or collision errors.
    func moveFontFile(_ item: FontItem, to destinationFolder: URL) async throws {
        // Deactivate before moving so Core Text's URL handle is released.
        if activeFontIDs.contains(item.id) {
            try? await activator.deactivate([item])
            activeFontIDs.remove(item.id)
        }
        let destURL = destinationFolder
            .standardizedFileURL
            .appendingPathComponent(item.fileURL.lastPathComponent)
        try FileManager.default.moveItem(at: item.fileURL, to: destURL)

        // Patch the item: fileURL changes, id stays stable since we hash on path+ps.
        // However our original ID hashed in the old path, so to keep references
        // valid (favorites/collections) we *replace* the item preserving id.
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let old = items[idx]
            items[idx] = FontItem(
                id: old.id, fileURL: destURL, postScriptName: old.postScriptName,
                familyName: old.familyName, styleName: old.styleName,
                displayName: old.displayName, weight: old.weight, width: old.width,
                slant: old.slant, isItalic: old.isItalic, isMonospaced: old.isMonospaced,
                isBold: old.isBold, format: old.format, categories: old.categories,
                moods: old.moods, glyphCount: old.glyphCount, fileSize: old.fileSize,
                dateAdded: old.dateAdded, panose: old.panose,
                variationAxes: old.variationAxes, foundry: old.foundry
            )
            invalidateDerived()
        }
        Persistence.saveCachedLibrary(items)
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
    case variable
    case category(FontCategory)
    case mood(FontMood)
    case foundry(String)
    case source(URL)
    case collection(UUID)
    case tool(ToolKind)

    /// Is this a Tools-section selection? Used to swap the content area
    /// away from the family list when a tool view should render instead.
    var isTool: Bool {
        if case .tool = self { return true }
        return false
    }
}

/// Library-maintenance utilities that take over the main content pane
/// when their sidebar row is selected.
enum ToolKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case duplicates
    case organize
    case proofSheet
    case orphans
    case missingRefs
    case largeFiles
    case fork

    var id: String { rawValue }
    var label: String {
        switch self {
        case .duplicates:  return "Find Duplicates"
        case .organize:    return "Organize"
        case .proofSheet:  return "Proof Sheet"
        case .orphans:     return "Orphan Files"
        case .missingRefs: return "Missing References"
        case .largeFiles:  return "Largest Files"
        case .fork:        return "Fork (UFO / Designspace)"
        }
    }
    var icon: String {
        switch self {
        case .duplicates:  return "doc.on.doc"
        case .organize:    return "folder.badge.gearshape"
        case .proofSheet:  return "text.word.spacing"
        case .orphans:     return "doc.badge.ellipsis"
        case .missingRefs: return "link.badge.plus"
        case .largeFiles:  return "arrow.up.arrow.down.circle"
        case .fork:        return "arrow.triangle.branch"
        }
    }
    var tint: Color {
        switch self {
        case .duplicates:  return .orange
        case .organize:    return .teal
        case .proofSheet:  return .pink
        case .orphans:     return .gray
        case .missingRefs: return .indigo
        case .largeFiles:  return .blue
        case .fork:        return .mint
        }
    }
}
