import Foundation

enum Persistence {
    static let appFolder: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SaewooFont", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var stateURL:    URL { appFolder.appendingPathComponent("state.json") }
    /// Binary-plist cache (fast). Introduced in the perf-pass; JSON fallback kept for migration.
    static var cacheURL:    URL { appFolder.appendingPathComponent("library-cache.plist") }
    /// Legacy JSON cache — read on first run after upgrade, then replaced by binary plist.
    static var cacheLegacyURL: URL { appFolder.appendingPathComponent("library-cache.json") }
    static var snapshotURL: URL { appFolder.appendingPathComponent("file-snapshot.plist") }

    static var cacheModificationDate: Date? {
        let values = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    // MARK: - State

    static func loadState() -> LibraryState {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(LibraryState.self, from: data)
        else { return LibraryState() }
        return s
    }

    static func saveState(_ state: LibraryState) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: - Library cache  (binary PropertyList — ~3× faster than JSON for large arrays)

    static func loadCachedLibrary() -> [FontItem]? {
        // Try fast binary plist first.
        if let data = try? Data(contentsOf: cacheURL),
           let items = try? PropertyListDecoder().decode([FontItem].self, from: data) {
            return items
        }
        // Fall back to old JSON cache (migration path — written on first launch).
        if let data = try? Data(contentsOf: cacheLegacyURL),
           let items = try? JSONDecoder().decode([FontItem].self, from: data) {
            return items
        }
        return nil
    }

    static func saveCachedLibrary(_ items: [FontItem]) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        // Remove the old JSON cache once we've successfully written the binary one.
        try? FileManager.default.removeItem(at: cacheLegacyURL)
    }

    /// Fire-and-forget: encode and write on a detached background task so the
    /// main thread (and therefore the UI) is never blocked by disk I/O.
    static func saveCachedLibraryBackground(_ items: [FontItem]) {
        let snapshot = items          // value-type copy, safe to capture
        Task.detached(priority: .utility) {
            saveCachedLibrary(snapshot)
        }
    }

    // MARK: - File snapshot  (mtime + size per font file, for incremental rescans)

    /// Compact record stored once per font file on disk.
    struct FileSnapshot: Codable {
        /// Standardised absolute path.
        let path: String
        /// `contentModificationDate.timeIntervalSinceReferenceDate` — stored as
        /// a Double so the binary plist is compact and comparison is exact.
        let mtime: Double
        let size: Int64
    }

    static func loadFileSnapshot() -> [FileSnapshot] {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snap = try? PropertyListDecoder().decode([FileSnapshot].self, from: data)
        else { return [] }
        return snap
    }

    static func saveFileSnapshot(_ snapshots: [FileSnapshot]) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(snapshots) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
