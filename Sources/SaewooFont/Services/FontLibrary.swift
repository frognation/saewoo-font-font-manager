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

    /// Bumped when favorites / collections / variableInstances change. Kept
    /// separate from `derivedVersion` on purpose: starring a font must NOT
    /// invalidate `duplicateGroups`, `itemsByFileSize`, `foundryCounts` or the
    /// source/foundry buckets, none of which depend on membership. Before this
    /// split a single star click cost ~170 ms of pure recompute.
    private var membershipVersion: Int = 0

    /// Full invalidation — only for mutations that change `items` itself.
    private func invalidateDerived() {
        derivedVersion &+= 1
        categoryCountsCache = nil
        moodCountsCache = nil
        foundryCountsCache = nil
        variableCountCache = nil
        duplicateGroupsCache = nil
        itemsByFileSizeCache = nil
        missingRefsCache = nil
        sourceBucketsCache = nil
        foundryBucketsCache = nil
        displayableSourcesCache = nil
        searchIndexCache = nil
        facesByPathCache = nil
        invalidateDerivedViews()
    }

    /// Cheap invalidation for favorites / collection / instance edits.
    private func invalidateMembership() {
        membershipVersion &+= 1
        missingRefsCache = nil
        invalidateDerivedViews()
    }

    private var categoryCountsCache: (Int, [(FontCategory, Int)])? = nil
    private var moodCountsCache: (Int, [(FontMood, Int)])? = nil
    private var foundryCountsCache: (Int, [(String, Int)])? = nil
    private var variableCountCache: (Int, Int)? = nil
    private var duplicateGroupsCache: (Int, [(name: String, items: [FontItem])])? = nil
    private var itemsByFileSizeCache: (Int, [FontItem])? = nil
    private var missingRefsCache: (derived: Int, membership: Int, refs: [MissingReference])? = nil

    /// Root path → items underneath it, built in a single pass over `items`.
    /// `itemsInSource` used to re-filter the whole library *and* call
    /// `standardizedFileURL` on every element — 419 ms a pop, and the sidebar
    /// called it about nine times per render. Now it is a dictionary lookup.
    private var sourceBucketsCache: (Int, [String: [Int]])? = nil
    /// Foundry name → indices of its faces. Same rationale; the sidebar has
    /// 546 foundry rows.
    private var foundryBucketsCache: (Int, [String: [Int]])? = nil
    private var displayableSourcesCache: (Int, [URL])? = nil

    @Published var favorites: Set<String> = []
    @Published var collections: [FontCollection] = []
    @Published var activeFontIDs: Set<String> = []
    @Published var customScanPaths: [URL] = []
    @Published var variableInstances: [VariableInstance] = []
    @Published var hiddenDefaultSources: Set<String> = []
    /// When true, rescan merges every font CoreText currently knows about —
    /// catches fonts activated by other managers (RightFont, FontBase, Adobe CC).
    @Published var includeSystemActive: Bool = true
    /// Files with font extensions that Core Text couldn't read — populated each scan.
    /// Not cached to disk; rebuilt from the current scan.
    @Published private(set) var orphanURLs: [URL] = []

    /// Availability of every known scan root, keyed by `standardizedFileURL.path`.
    /// Refreshed on a coarse timer and after every rescan — see
    /// `refreshSourceStatuses()`. This is a low-frequency signal (a drive
    /// unmounting), unlike `items`, so publishing it doesn't cost the other
    /// views observing `FontLibrary`.
    @Published private(set) var sourceStatuses: [String: SourceStatus] = [:]
    private var sourceStatusTask: Task<Void, Never>?

    /// Preview prefs are persisted here but are NOT `@Published` — the live,
    /// high-frequency values live in `PreviewSettings` so that dragging the
    /// size slider cannot invalidate the sidebar. See `UIState.swift`.
    private(set) var previewText: String = "The quick brown fox jumps over the lazy dog"
    private(set) var previewSize: Double = 36

    func updatePreviewPrefs(text: String, size: Double) {
        previewText = text
        previewSize = size
        persist()
    }

    // MARK: - Selection

    @Published var sidebarSelection: SidebarItem = .allFonts

    /// What the family list actually filters on. Updated from the search field
    /// after a short debounce so that 78 000 faces aren't re-scanned on every
    /// keystroke.
    ///
    /// Note there is deliberately no published `searchInput` here. It used to
    /// live on this object, and because every view observes `FontLibrary`,
    /// each keystroke rebuilt the entire UI — which made the debounce below
    /// pointless. The text field now owns its own `@State`.
    @Published private(set) var searchQuery: String = ""

    private var searchDebounceTask: Task<Void, Never>?
    private var pendingSearch: String = ""

    /// Called from the search TextField's `onChange`. Schedules a debounced
    /// commit to `searchQuery`; nothing is published until the debounce fires.
    func updateSearchInput(_ text: String) {
        pendingSearch = text
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)  // 180ms
            guard !Task.isCancelled, self.pendingSearch == text else { return }
            if self.searchQuery != text {
                self.searchQuery = text
                // Drop the (large) lowercased index once searching stops.
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.searchIndexCache = nil
                }
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
        self.includeSystemActive = state.includeSystemActive
        self.previewText = state.userText.isEmpty ? previewText : state.userText
        self.previewSize = state.previewSize > 0 ? state.previewSize : previewSize

        // Palettes were merged into Projects — fold any legacy ones over.
        var migrated = false
        for i in collections.indices where collections[i].kind == .palette {
            collections[i].kind = .project
            migrated = true
        }
        if migrated { persist() }

        if let cached = await Persistence.loadCachedLibraryOffMain(), !cached.isEmpty,
           !Self.cacheLooksStale(cached) {
            self.items = cached
            invalidateDerived()
        } else {
            await rescan()
        }

        // Re-apply activation state from last launch (session scope clears on logout).
        await reapplyActivations()

        startSourceStatusMonitoring()
    }

    // MARK: - Scanning

    func rescan() async {
        isScanning = true
        scanStatus = "Scanning fonts…"
        let previousItems = items
        let roots = visibleDefaultSources + customScanPaths
        let result = await FontScanner.scanParallel(roots: roots)
        var merged = result.items

        // Optional: ask Core Text for every font currently registered with
        // the OS and merge in anything we haven't seen. This catches fonts
        // activated by other managers (RightFont, FontBase, Typeface, Adobe
        // CC's font daemon) even when their files live outside our scan
        // paths.
        if includeSystemActive {
            scanStatus = "Merging system-active fonts…"
            let knownURLs = Set(merged.map { $0.fileURL.standardizedFileURL })
            let extra = await Task.detached(priority: .userInitiated) {
                FontScanner.scanAvailableInSystem(excluding: knownURLs)
            }.value
            // Rebuild ids against the merged set to keep them stable.
            merged.append(contentsOf: extra)
        }

        // Sort by family then style for stable listing
        self.items = merged.sorted {
            if $0.familyName.lowercased() == $1.familyName.lowercased() {
                return $0.styleName < $1.styleName
            }
            return $0.familyName.lowercased() < $1.familyName.lowercased()
        }
        invalidateDerived()
        migrateReferences(from: previousItems)
        self.orphanURLs = result.orphanURLs
        let systemExtra = max(0, merged.count - result.items.count)
        scanStatus = "\(items.count) faces across \(Set(items.map{$0.familyKey}).count) families"
            + (systemExtra > 0 ? " · +\(systemExtra) from other managers" : "")
            + (result.orphanURLs.isEmpty ? "" : " · \(result.orphanURLs.count) orphan\(result.orphanURLs.count == 1 ? "" : "s")")
        isScanning = false
        saveCacheNow()
        // A rescan is also the moment a root reappearing (drive remounted) or
        // disappearing (drive ejected mid-scan) is most likely to be noticed,
        // so refresh availability now rather than waiting for the next tick.
        refreshSourceStatuses()
    }

    /// Re-points favorites / collections / variable instances at the new
    /// `FontItem.id`s after a rescan.
    ///
    /// `FontItem.id` hashes the absolute path, so moving a file changes its ID.
    /// `moveFontFile` patches the in-memory record to keep the old ID, but the
    /// *next* rescan regenerated it from the new path — silently dropping the
    /// font out of every Favorite, Project and Palette it belonged to. We
    /// rebuild the mapping using an identity that survives a move: PostScript
    /// name + filename + byte size.
    private func migrateReferences(from previous: [FontItem]) {
        guard !previous.isEmpty else { return }

        func identity(_ i: FontItem) -> String {
            "\(i.postScriptName)::\(i.fileURL.lastPathComponent)::\(i.fileSize)"
        }

        // Which IDs do we actually care about? Only referenced ones.
        var referenced = favorites
        for c in collections { referenced.formUnion(c.fontIDs) }
        referenced.formUnion(variableInstances.map { $0.baseFontID })
        guard !referenced.isEmpty else { return }

        let currentIDs = Set(items.map { $0.id })
        let dangling = referenced.subtracting(currentIDs)
        guard !dangling.isEmpty else { return }

        // identity → new id. Ambiguous identities (true duplicate files) are
        // skipped: guessing there could silently retarget the wrong copy.
        var newByIdentity: [String: String] = [:]
        var ambiguous: Set<String> = []
        for i in items {
            let k = identity(i)
            if newByIdentity[k] != nil { ambiguous.insert(k) } else { newByIdentity[k] = i.id }
        }

        var remap: [String: String] = [:]
        for old in previous where dangling.contains(old.id) {
            let k = identity(old)
            guard !ambiguous.contains(k), let newID = newByIdentity[k] else { continue }
            remap[old.id] = newID
        }
        guard !remap.isEmpty else { return }

        favorites = Set(favorites.map { remap[$0] ?? $0 })
        for idx in collections.indices {
            collections[idx].fontIDs = Set(collections[idx].fontIDs.map { remap[$0] ?? $0 })
        }
        for idx in variableInstances.indices {
            if let newID = remap[variableInstances[idx].baseFontID] {
                variableInstances[idx].baseFontID = newID
            }
        }
        invalidateMembership()
        persist()
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

    /// Lowercased "family⇥style⇥postscript" per item, positionally parallel to
    /// `items`. Built lazily on the first non-empty search and dropped when the
    /// search clears, so an idle library pays nothing for it. Without this,
    /// every search lowercased three strings per item — 78 000 × 3 allocations.
    private var searchIndexCache: (Int, [String])? = nil

    private var searchIndex: [String] {
        if let c = searchIndexCache, c.0 == derivedVersion { return c.1 }
        let idx = items.map {
            "\($0.familyName)\t\($0.styleName)\t\($0.postScriptName)".lowercased()
        }
        searchIndexCache = (derivedVersion, idx)
        return idx
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

        // Scope test as a predicate so scoping and searching run in ONE pass
        // instead of materializing an intermediate array.
        let inScope: (FontItem) -> Bool
        switch sidebarSelection {
        case .allFonts, .tool, .cloud:
            // Tool and Cloud views render their own data; family list is
            // unused there, so "everything" is the sensible fallback.
            inScope = { _ in true }
        case .active:
            inScope = { [activeFontIDs] in activeFontIDs.contains($0.id) }
        case .inactive:
            inScope = { [activeFontIDs] in !activeFontIDs.contains($0.id) }
        case .favorites:
            inScope = { [favorites] in favorites.contains($0.id) }
        case .variable:
            inScope = { $0.isVariable }
        case .category(let cat):
            inScope = { $0.categories.contains(cat) }
        case .mood(let mood):
            inScope = { $0.moods.contains(mood) }
        case .foundry(let name):
            inScope = { $0.foundry == name }
        case .source(let url):
            // Item URLs are standardized at scan time — raw `.path` is correct
            // here and ~8× cheaper than re-standardizing per element.
            let prefix = url.standardizedFileURL.path
            inScope = { $0.fileURL.path.hasPrefix(prefix) }
        case .collection(let id):
            if let c = collections.first(where: { $0.id == id }) {
                inScope = { c.fontIDs.contains($0.id) }
            } else { inScope = { _ in false } }
        }

        var filtered: [FontItem] = []
        if q.isEmpty {
            for item in items where inScope(item) { filtered.append(item) }
        } else {
            let hay = searchIndex
            for (i, item) in items.enumerated() {
                guard hay[i].contains(q), inScope(item) else { continue }
                filtered.append(item)
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

    /// Bucket every item under each known scan root in one pass.
    ///
    /// Stores *indices* rather than `FontItem` copies: at 78 000 faces a
    /// struct-copy bucket map duplicates ~17 MB per index, and there are two
    /// of them. Indices cost 8 bytes each and materialize on demand.
    ///
    /// Item URLs are standardized once at scan time (`FontScanner.buildItem`),
    /// so matching here uses the raw `.path` — 8× cheaper than re-standardizing
    /// per element, which is what made the old implementation cost 419 ms.
    private var sourceBuckets: [String: [Int]] {
        if let c = sourceBucketsCache, c.0 == derivedVersion { return c.1 }
        let roots = (visibleDefaultSources + customScanPaths)
            .map { $0.standardizedFileURL.path }
        var buckets: [String: [Int]] = [:]
        for r in roots { buckets[r] = [] }
        if !roots.isEmpty {
            for (i, item) in items.enumerated() {
                let p = item.fileURL.path
                for r in roots where p.hasPrefix(r) {
                    buckets[r]!.append(i)
                }
            }
        }
        sourceBucketsCache = (derivedVersion, buckets)
        return buckets
    }

    /// Face count under a scan root. This is all the sidebar needs, and it
    /// avoids materializing an array of tens of thousands of items per render.
    func itemCountInSource(_ url: URL) -> Int {
        let prefix = url.standardizedFileURL.path
        if let hit = sourceBuckets[prefix] { return hit.count }
        return items.reduce(0) { $0 + ($1.fileURL.path.hasPrefix(prefix) ? 1 : 0) }
    }

    // MARK: - Source availability

    /// Current availability for a scan root, from the cache built by
    /// `refreshSourceStatuses()`. Never stats the filesystem itself — safe to
    /// call from a view body. Defaults to `.available` for a root we haven't
    /// classified yet (e.g. the very first render before bootstrap's initial
    /// check completes), so a brand-new source doesn't flash "Offline".
    func status(for url: URL) -> SourceStatus {
        sourceStatuses[url.standardizedFileURL.path] ?? .available
    }

    /// Re-checks every known scan root's reachability. Per root this is one
    /// `stat` (via `SourceStatusChecker`) plus a lookup into the already-built
    /// `sourceBuckets` — never a directory walk, so it's safe to run on a
    /// timer even with tens of thousands of cached fonts.
    ///
    /// Deliberately does NOT touch `items`: an unmounted drive must not wipe
    /// the cached FontItems for fonts that live on it. This only updates the
    /// status map the sidebar reads to grey a row out.
    func refreshSourceStatuses() {
        var next: [String: SourceStatus] = [:]
        for url in visibleDefaultSources + customScanPaths {
            let path = url.standardizedFileURL.path
            next[path] = SourceStatusChecker.classify(url, itemCount: itemCountInSource(url))
        }
        // Equatable check avoids publishing (and re-rendering the sidebar)
        // when nothing actually changed, which is the common case on every
        // 10s tick.
        if next != sourceStatuses {
            sourceStatuses = next
        }
    }

    /// Starts the periodic reachability check. Idempotent — safe to call
    /// again (e.g. if bootstrap ever re-ran) since it cancels any prior loop.
    /// Not started from `init` on purpose: benchmarking builds a `FontLibrary`
    /// without calling `bootstrap()`, and a background timer touching
    /// `Persistence`-adjacent state during `--bench` is exactly the kind of
    /// thing `Persistence.readOnly` exists to guard against elsewhere — no
    /// sense running it where it isn't needed at all.
    private func startSourceStatusMonitoring() {
        refreshSourceStatuses()
        sourceStatusTask?.cancel()
        sourceStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)  // ~10s
                guard !Task.isCancelled, let self else { return }
                self.refreshSourceStatuses()
            }
        }
    }

    /// Full item list for a scan root. Only for callers that genuinely need the
    /// items (context-menu bulk activate, Organize) — not for per-render use.
    func itemsInSource(_ url: URL) -> [FontItem] {
        let prefix = url.standardizedFileURL.path
        if let idx = sourceBuckets[prefix] { return idx.map { items[$0] } }
        // Not a registered root (e.g. an arbitrary folder passed by Organize) —
        // fall back to a direct scan.
        return items.filter { $0.fileURL.path.hasPrefix(prefix) }
    }

    private var foundryBuckets: [String: [Int]] {
        if let c = foundryBucketsCache, c.0 == derivedVersion { return c.1 }
        var buckets: [String: [Int]] = [:]
        for (i, item) in items.enumerated() {
            buckets[item.foundry, default: []].append(i)
        }
        foundryBucketsCache = (derivedVersion, buckets)
        return buckets
    }

    /// Quick activate-all / deactivate-all helpers for a foundry.
    /// Materializes from indices — a single foundry averages ~140 faces.
    func itemsInFoundry(_ name: String) -> [FontItem] {
        (foundryBuckets[name] ?? []).map { items[$0] }
    }

    /// True when every face from this foundry is active, plus whether any is.
    /// Computed straight off the indices so the sidebar's 546 rows never
    /// materialize their item arrays.
    func foundryActivation(_ name: String) -> (all: Bool, any: Bool) {
        let idx = foundryBuckets[name] ?? []
        guard !idx.isEmpty else { return (false, false) }
        var all = true, any = false
        for i in idx {
            if activeFontIDs.contains(items[i].id) { any = true } else { all = false }
            if any && !all { break }
        }
        return (all, any)
    }

    // MARK: - Favorites

    func toggleFavorite(_ item: FontItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) }
        else { favorites.insert(item.id) }
        favoritesVersion &+= 1
        invalidateMembership()
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
        invalidateMembership()
        persist()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        if case .collection(let s) = sidebarSelection, s == id {
            sidebarSelection = .allFonts
        }
        invalidateMembership()
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
        invalidateMembership()
        persist()
    }

    func removeFromCollection(_ id: UUID, fontIDs: [String]) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].fontIDs.subtract(fontIDs)
        invalidateMembership()
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
        if let c = missingRefsCache,
           c.derived == derivedVersion, c.membership == membershipVersion {
            return c.refs
        }
        let existing = Set(items.map { $0.id })
        var map: [String: [String]] = [:]
        for id in favorites where !existing.contains(id) {
            map[id, default: []].append("Favorites")
        }
        for c in collections {
            for id in c.fontIDs where !existing.contains(id) {
                map[id, default: []].append("Project: \(c.name)")
            }
        }
        for vi in variableInstances where !existing.contains(vi.baseFontID) {
            map[vi.baseFontID, default: []].append("Variable Instance: \(vi.name)")
        }
        let refs = map
            .map { MissingReference(id: $0.key, locations: $0.value) }
            .sorted { $0.id < $1.id }
        missingRefsCache = (derivedVersion, membershipVersion, refs)
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
        invalidateMembership()
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
        persist()
        scheduleCacheSave()
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
        invalidateMembership()
        persist()
    }

    func deleteVariableInstance(_ id: UUID) {
        variableInstances.removeAll { $0.id == id }
        invalidateMembership()
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
            // normalizeUUID, not uppercased(): `parseAllFontEntries` keys its
            // map by hyphen-stripped UUID, while fontlists store hyphenated
            // ones. Uppercasing alone matched only the minority of lists whose
            // UUIDs happened to already be hyphen-less — on a real 313-list
            // library this silently imported 90 instead of 158.
            let mappedIDs: Set<String> = Set(fonts.compactMap {
                uuidToOurID[RightFontImporter.normalizeUUID($0)]
            })
            guard !mappedIDs.isEmpty else { skipped += 1; continue }

            let paletteName = palettePrefix + name
            if let existingIdx = collections.firstIndex(where: { $0.name == paletteName }) {
                collections[existingIdx].fontIDs = mappedIDs
            } else {
                collections.append(FontCollection(
                    name: paletteName, kind: .project,
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

    private var cacheSaveTask: Task<Void, Never>?

    /// Encoding the library costs ~1 s. It used to run synchronously on the
    /// main actor inside `deleteFontFile` / `moveFontFile`, so every single
    /// delete froze the UI for a second. Now it is debounced and detached, so
    /// a burst of deletes writes once, off the main thread.
    private func scheduleCacheSave() {
        cacheSaveTask?.cancel()
        let snapshot = items
        cacheSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            Persistence.saveCachedLibrary(snapshot)
        }
    }

    /// Flush any pending library write immediately (used on rescan completion).
    private func saveCacheNow() {
        cacheSaveTask?.cancel()
        let snapshot = items
        Task.detached(priority: .utility) { Persistence.saveCachedLibrary(snapshot) }
    }

    private func persist() {
        let state = LibraryState(
            favorites: favorites,
            collections: collections,
            activeFontIDs: activeFontIDs,
            customScanPaths: customScanPaths,
            userText: previewText,
            previewSize: previewSize,
            variableInstances: variableInstances,
            hiddenDefaultSources: hiddenDefaultSources,
            includeSystemActive: includeSystemActive
        )
        Persistence.saveState(state)
    }

    /// Call when the user flips `includeSystemActive` from the UI.
    func setIncludeSystemActive(_ enabled: Bool) {
        guard enabled != includeSystemActive else { return }
        includeSystemActive = enabled
        persist()
        Task { await rescan() }
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
    ///
    /// Cached: `SidebarView` reads this on every body evaluation, and each read
    /// used to trigger one full-library scan per root.
    var displayableDefaultSources: [URL] {
        if let c = displayableSourcesCache, c.0 == derivedVersion { return c.1 }
        let out = visibleDefaultSources.filter { itemCountInSource($0) >= 2 }
        displayableSourcesCache = (derivedVersion, out)
        return out
    }

    /// Roots that exist but are being hidden from the sidebar, either
    /// explicitly or because they hold fewer than two fonts. Computed from the
    /// shared buckets so the sidebar doesn't rescan to answer this.
    var autoHiddenDefaultSources: [URL] {
        visibleDefaultSources.filter { itemCountInSource($0) < 2 }
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
        if path.contains("/SaewooFont/GoogleFonts") { return "Google Fonts (downloaded)" }
        if path.contains("/CoreSync/plugins/livetype") { return "Adobe Fonts (synced)" }
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
                isBold: old.isBold, format: old.formatKind, categories: old.categories,
                moods: old.moods, glyphCount: old.glyphCount, fileSize: old.fileSize,
                dateAdded: old.dateAdded, panose: old.panose,
                variationAxes: old.variationAxes, foundry: old.foundry
            )
            invalidateDerived()
        }
        scheduleCacheSave()
    }

    // MARK: - Content-identical duplicates

    @Published private(set) var contentDuplicates: [DuplicateScanner.Group] = []
    @Published private(set) var duplicateScanProgress: DuplicateScanner.Progress?
    @Published private(set) var isScanningDuplicates = false

    /// Snapshot for the `--scan-duplicates` audit, which must hand the file
    /// list off the main actor before scanning.
    var uniqueFilesForAudit: [(url: URL, size: Int64)] { uniqueFiles }

    /// Distinct files in the library, with their sizes.
    private var uniqueFiles: [(url: URL, size: Int64)] {
        var seen = Set<String>()
        var out: [(URL, Int64)] = []
        for item in items where seen.insert(item.fileURL.path).inserted {
            out.append((item.fileURL, item.fileSize))
        }
        return out
    }

    func scanContentDuplicates() async {
        guard !isScanningDuplicates else { return }
        isScanningDuplicates = true
        duplicateScanProgress = nil
        let files = uniqueFiles
        let groups = await DuplicateScanner.scan(files: files) { [weak self] p in
            Task { @MainActor in self?.duplicateScanProgress = p }
        }
        contentDuplicates = groups
        duplicateScanProgress = nil
        isScanningDuplicates = false
    }

    /// Which copy to keep, in descending order of "the user would miss this".
    ///
    /// Because every copy is byte-identical, this only decides *where* the
    /// surviving file lives — never what the user ends up with.
    func recommendedKeeper(in group: DuplicateScanner.Group) -> URL {
        let scored = group.paths.map { url -> (URL, Int) in
            var score = 0
            let faces = itemsAtPath(url)
            // Never delete something the guard considers untouchable.
            if faces.contains(where: { SystemFontGuard.isProtected($0) }) { score += 1000 }
            if faces.contains(where: { favorites.contains($0.id) })       { score += 100 }
            if faces.contains(where: { activeFontIDs.contains($0.id) })   { score += 50 }
            if faces.contains(where: { id in
                collections.contains { $0.fontIDs.contains(id.id) }
            }) { score += 40 }
            // Prefer a stable local folder over a cloud-synced one.
            if !Self.isCloudSynced(url) { score += 10 }
            if SystemFontGuard.isInUserFolder(url) { score += 5 }
            return (url, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? group.paths[0]
    }

    /// path → the faces parsed out of that file, built once per library
    /// version.
    ///
    /// `itemsAtPath` used to filter the whole library on every call. The
    /// duplicates screen calls it per row, and the safety audit calls it once
    /// per copy per group — at 23 644 groups over 106 950 faces that is about
    /// 7 billion comparisons, which read exactly like a hang.
    private var facesByPathCache: (Int, [String: [FontItem]])? = nil

    private var facesByPath: [String: [FontItem]] {
        if let c = facesByPathCache, c.0 == derivedVersion { return c.1 }
        var map: [String: [FontItem]] = [:]
        map.reserveCapacity(items.count)
        for item in items { map[item.fileURL.path, default: []].append(item) }
        facesByPathCache = (derivedVersion, map)
        return map
    }

    func itemsAtPath(_ url: URL) -> [FontItem] {
        facesByPath[url.path] ?? []
    }

    /// Dropbox / Google Drive / iCloud live under predictable roots. Deleting
    /// there propagates to every synced machine, so it is worth surfacing.
    static func isCloudSynced(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/CloudStorage/") || p.contains("/Dropbox")
            || p.contains("/Library/Mobile Documents/")
    }

    struct DuplicateDeletionReport {
        var filesDeleted = 0
        var facesRemoved = 0
        var bytesReclaimed: Int64 = 0
        var referencesRemapped = 0
        var skipped: [String] = []
        var errors: [String] = []
        var manifestURL: URL?
    }

    /// Deletes every copy except `keeper` in each group.
    ///
    /// Safe by construction:
    /// - the API takes a group plus its keeper, so it is impossible to ask for
    ///   "delete all copies";
    /// - protected files (SIP / macOS essentials) are never deleted;
    /// - favorites, projects and variable instances pointing at a deleted copy
    ///   are re-pointed at the identical face in the keeper, so nothing the
    ///   user curated is lost;
    /// - a manifest records deleted → kept for every file.
    func deleteDuplicates(_ decisions: [(group: DuplicateScanner.Group, keeper: URL)])
        async -> DuplicateDeletionReport
    {
        var report = DuplicateDeletionReport()
        var remap: [String: String] = [:]        // deleted FontItem.id -> kept id
        var deletedPaths: [String] = []
        var manifest: [[String: String]] = []

        // Deterministic ordering used to pair faces between two identical
        // files when their PostScript names don't match. That happens more
        // than you'd expect: Core Text invents placeholder names like
        // "font0000000030329341" for fonts with no usable name table, and the
        // number differs per registration — so byte-identical files can report
        // different PostScript names. 747 faces in the reference library hit
        // this. Pairing by position rescues them; without it their favorites
        // would silently dangle.
        func sortKey(_ f: FontItem) -> String {
            "\(f.styleName)\u{1}\(f.familyName)\u{1}\(f.postScriptName)"
        }

        for (group, keeper) in decisions {
            let keeperFaces = itemsAtPath(keeper).sorted { sortKey($0) < sortKey($1) }
            var keeperByPS: [String: String] = [:]
            for f in keeperFaces { keeperByPS[f.postScriptName] = f.id }

            for victim in group.paths where victim != keeper {
                let faces = itemsAtPath(victim).sorted { sortKey($0) < sortKey($1) }
                if faces.contains(where: { SystemFontGuard.isProtected($0) }) {
                    report.skipped.append("\(victim.lastPathComponent) — protected system font")
                    continue
                }
                do {
                    try await activator.deactivate(faces)
                } catch { /* deactivation is best-effort; the file still goes */ }
                activeFontIDs.subtract(faces.map { $0.id })

                do {
                    try FileManager.default.trashItem(at: victim, resultingItemURL: nil)
                } catch {
                    report.errors.append("\(victim.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                for (i, f) in faces.enumerated() {
                    if let keptID = keeperByPS[f.postScriptName] {
                        remap[f.id] = keptID
                    } else if faces.count == keeperFaces.count {
                        // Same file, same face count, unusable names — pair by
                        // position. Safe because the bytes are identical.
                        remap[f.id] = keeperFaces[i].id
                    }
                }
                deletedPaths.append(victim.path)
                manifest.append(["deleted": victim.path, "kept": keeper.path,
                                 "sha256": group.digest, "size": String(group.size)])
                report.filesDeleted += 1
                report.facesRemoved += faces.count
                report.bytesReclaimed += group.size
            }
        }

        guard report.filesDeleted > 0 else { return report }

        // Re-point curation at the surviving identical copy.
        let before = favorites.count + collections.reduce(0) { $0 + $1.fontIDs.count }
        favorites = Set(favorites.map { remap[$0] ?? $0 })
        for i in collections.indices {
            collections[i].fontIDs = Set(collections[i].fontIDs.map { remap[$0] ?? $0 })
        }
        for i in variableInstances.indices {
            if let newID = remap[variableInstances[i].baseFontID] {
                variableInstances[i].baseFontID = newID
            }
        }
        report.referencesRemapped = remap.count
        _ = before

        let gone = Set(deletedPaths)
        items.removeAll { gone.contains($0.fileURL.path) }
        contentDuplicates.removeAll { g in g.paths.allSatisfy { gone.contains($0.path) } }
        invalidateDerived()
        persist()
        scheduleCacheSave()
        report.manifestURL = Persistence.writeDeletionManifest(manifest)
        return report
    }

    // MARK: - Bulk import helpers

    /// Creates one palette per entry, prefixed with the source library name so
    /// imported sets stay visually grouped. Re-running updates an existing
    /// palette of the same name rather than duplicating it.
    @discardableResult
    func importPalettes(_ palettes: [(String, Set<String>)], libraryName: String) -> Int {
        let prefix = "[\(libraryName)] "
        // Merge same-named entries *within this run* before touching the store.
        // RightFont fontlists are a folder tree, so the same leaf name can
        // legitimately appear under several parents. Replacing instead of
        // merging silently collapsed 155 imported lists into 88 palettes and
        // discarded the membership of everything that lost the race.
        var merged: [(String, Set<String>)] = []
        var indexByName: [String: Int] = [:]
        for (name, ids) in palettes {
            if let i = indexByName[name] {
                merged[i].1.formUnion(ids)
            } else {
                indexByName[name] = merged.count
                merged.append((name, ids))
            }
        }

        var n = 0
        for (name, ids) in merged {
            let paletteName = prefix + name
            if let idx = collections.firstIndex(where: { $0.name == paletteName }) {
                collections[idx].fontIDs = ids
            } else {
                collections.append(FontCollection(
                    name: paletteName, kind: .project,
                    colorHex: Self.rotatingPaletteColor(seed: collections.count),
                    fontIDs: ids
                ))
            }
            n += 1
        }
        invalidateMembership()
        persist()
        return n
    }

    func addFavorites(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        favorites.formUnion(ids)
        favoritesVersion &+= 1
        invalidateMembership()
        persist()
    }

    // MARK: - Benchmark support (see Benchmark.swift / `--bench`)

    /// Installs a pre-decoded item array without touching disk or Core Text,
    /// so the harness can measure derived-data cost in isolation.
    func installForBenchmark(_ newItems: [FontItem]) {
        self.items = newItems
        invalidateDerived()
    }

    /// Drops every derived cache so the next getter measures a cold build.
    func invalidateForBenchmark() { invalidateDerived() }

    /// Bypasses the debounce so the harness measures the filter itself.
    func commitSearchForBenchmark(_ text: String) {
        searchQuery = text
        invalidateDerivedViews()
    }
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
    case cloud(CloudSource)

    /// Is this a Tools-section selection? Used to swap the content area
    /// away from the family list when a tool view should render instead.
    var isTool: Bool {
        if case .tool = self { return true }
        return false
    }

    /// Is this a Cloud-section selection (Google Fonts / Adobe Fonts browse)?
    /// Same rationale as `isTool` — swaps away from the family list.
    var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }
}

/// The two cloud "sources" exposed in the sidebar under the Cloud section.
/// Google Fonts is a true cloud-backed catalog (public API). Adobe Fonts is
/// a filtered view of the Creative Cloud sync cache already present on disk —
/// there's no public Adobe API to browse or download.
enum CloudSource: String, Codable, Hashable, CaseIterable, Identifiable {
    case google
    case adobe

    var id: String { rawValue }
    var label: String {
        switch self {
        case .google: return "Google Fonts"
        case .adobe:  return "Adobe Fonts"
        }
    }
    var icon: String {
        switch self {
        case .google: return "g.circle.fill"
        case .adobe:  return "a.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .google: return .blue
        case .adobe:  return Color(red: 0.98, green: 0.2, blue: 0.2) // Adobe red
        }
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
        case .duplicates:  return "Identical Files"
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
