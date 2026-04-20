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

    static func loadCachedLibrary() -> [FontItem]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([FontItem].self, from: data)
    }

    static func saveCachedLibrary(_ items: [FontItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
