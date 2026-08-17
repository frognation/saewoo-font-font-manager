import Foundation

enum Persistence {
    static let appFolder: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SaewooFont", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var stateURL: URL { appFolder.appendingPathComponent("state.json") }
    static var cacheURL: URL { appFolder.appendingPathComponent("library-cache.json") }
    static var backupFolder: URL { appFolder.appendingPathComponent("StateBackups", isDirectory: true) }

    /// Hard write-lock. Any tool that builds a `FontLibrary` without running
    /// `bootstrap()` MUST set this first.
    ///
    /// This exists because the `--bench` harness did exactly that: it created a
    /// fresh `FontLibrary` (so favorites / collections / customScanPaths were
    /// all empty), called `toggleFavorite` to measure the invalidation cascade,
    /// and `persist()` happily wrote that empty state over the user's real
    /// `state.json` — losing every custom scan folder and favorite. Never
    /// remove this guard.
    static var readOnly = false

    /// Keeps the last `maxStateBackups` versions of state.json. It is under a
    /// kilobyte, so this is essentially free insurance against the class of bug
    /// described above.
    private static let maxStateBackups = 30

    /// Copies the current state.json aside before it is overwritten.
    private static func backupExistingState() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) else { return }
        try? fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = backupFolder.appendingPathComponent("state-\(stamp).json")
        if !fm.fileExists(atPath: dest.path) {
            try? fm.copyItem(at: stateURL, to: dest)
        }
        // Trim oldest.
        guard let files = try? fm.contentsOfDirectory(at: backupFolder,
                                                      includingPropertiesForKeys: nil) else { return }
        let sorted = files.filter { $0.lastPathComponent.hasPrefix("state-") }
                          .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if sorted.count > maxStateBackups {
            for old in sorted.prefix(sorted.count - maxStateBackups) {
                try? fm.removeItem(at: old)
            }
        }
    }

    /// Records what a duplicate purge removed and which identical copy it kept.
    ///
    /// The deleted files are byte-identical to a survivor, so the *content* is
    /// never actually gone — but the paths are, and something outside this app
    /// may point at them. The manifest makes that recoverable and auditable.
    @discardableResult
    static func writeDeletionManifest(_ entries: [[String: String]]) -> URL? {
        guard !entries.isEmpty, !readOnly else { return nil }
        let dir = appFolder.appendingPathComponent("DeletionManifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("deleted-\(Int(Date().timeIntervalSince1970)).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(entries) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Most recent backups, newest first — for a future "restore" UI.
    static func stateBackups() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: backupFolder,
                                                      includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("state-") }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func loadState() -> LibraryState {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(LibraryState.self, from: data)
        else { return LibraryState() }
        return s
    }

    static func saveState(_ state: LibraryState) {
        guard !readOnly else { return }
        backupExistingState()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    static func loadCachedLibrary() -> [FontItem]? {
        // autoreleasepool: JSONDecoder goes through NSJSONSerialization, which
        // leaves a large graph of autoreleased temporaries behind. Without the
        // pool they survive until the enclosing task drains, roughly doubling
        // peak footprint on a 60 MB cache.
        autoreleasepool {
            guard let data = try? Data(contentsOf: cacheURL) else { return nil }
            return try? JSONDecoder().decode([FontItem].self, from: data)
        }
    }

    /// Off-main-actor variant. Decoding the reference library takes ~1.3 s;
    /// doing that inside `@MainActor bootstrap()` froze the window before it
    /// ever drew.
    static func loadCachedLibraryOffMain() async -> [FontItem]? {
        await Task.detached(priority: .userInitiated) { loadCachedLibrary() }.value
    }

    static func saveCachedLibrary(_ items: [FontItem]) {
        guard !readOnly else { return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
