import Foundation

/// Reads the on-disk format of a `.rightfontlibrary` bundle. RightFont's library
/// is a "package" (bundle) with a simple JSON-per-file layout:
///
///     MyLib.rightfontlibrary/
///     ├── manifest.rightfontmetadata             # library info (name, uuid, created…)
///     ├── fonts/                                 # alphabet-bucketed
///     │   ├── A/<FamilyFolder>/<file>.otf
///     │   └── …
///     └── metadata/
///         ├── fonts/<UUID>.rightfontmetadata     # one per font file
///         ├── fontlists/<UUID>.rightfontmetadata # one per RightFont collection
///         └── tags/                              # (empty in the libraries we've seen)
///
/// Each metadata file is just JSON — there's no proprietary binary to decode.
/// Fonts reference is by UUID with hyphens (e.g. `001187C9-C134-…`);
/// fontlists reference fonts by the *hyphen-less* 32-char variant. We
/// normalise on the hyphen-less form internally.
enum RightFontImporter {

    static let packageExtension = "rightfontlibrary"
    static let metadataExtension = "rightfontmetadata"

    /// True if the URL ends in `.rightfontlibrary` and looks structurally
    /// like a real library (has a `fonts/` child). We don't want to false-
    /// positive on an empty folder that happens to share the extension.
    static func isLibrary(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == packageExtension else { return false }
        let fontsDir = url.appendingPathComponent("fonts", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fontsDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The directory inside the bundle that actually contains the `.otf`/.ttf
    /// files — this is what we hand to `FontScanner.collectFiles` so it sees
    /// a normal font folder instead of a package.
    static func fontsRoot(in bundle: URL) -> URL {
        bundle.appendingPathComponent("fonts", isDirectory: true)
    }

    // MARK: - Manifest

    struct Manifest: Decodable {
        var name: String?
        var uuid: String?
        var createdBy: String?
        var modifiedBy: String?
        var created: Double?
        var modified: Double?
        var kind: String?
    }

    static func parseManifest(in bundle: URL) -> Manifest? {
        let url = bundle.appendingPathComponent("manifest.\(metadataExtension)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Font entries

    /// Per-font metadata record. All fields are optional because RightFont's
    /// schema has drifted across versions — we accept whatever is present.
    struct FontEntry: Decodable {
        var uuid: String?               // hyphenated
        var name: String?               // postscript-like short name
        var displayName: String?
        var fullName: String?
        var family: String?
        var familyGroup: String?
        var style: String?
        var postscriptName: String?
        var fileName: String?
        var fileType: String?
        var location: String?           // path relative to `<lib>/fonts/`
        var designer: String?
        var manufacturer: String?
        var version: String?
        var starred: Bool?
        var isRegularStyle: Bool?
        var isItalicStyle: Bool?
        var hasVariations: Bool?
        var hasColorGlyphs: Bool?
        var weight: Int?
        var width: Int?
        var classification: String?
        var xheightRatio: Double?
        var oldStyleRatio: Double?
        var supportedLanguages: String?
    }

    /// Reads every `metadata/fonts/*.rightfontmetadata` file concurrently and
    /// returns a map keyed by hyphen-less UUID (the form used by fontlists).
    /// Entries without a usable `uuid` are skipped.
    static func parseAllFontEntries(in bundle: URL) async -> [String: FontEntry] {
        let dir = bundle.appendingPathComponent("metadata/fonts", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let metaURLs = urls.filter { $0.pathExtension == metadataExtension }
        let chunkSize = max(1, (metaURLs.count + 7) / 8)
        let chunks = stride(from: 0, to: metaURLs.count, by: chunkSize).map {
            Array(metaURLs[$0..<min($0 + chunkSize, metaURLs.count)])
        }

        return await withTaskGroup(of: [(String, FontEntry)].self) { group in
            for chunk in chunks {
                group.addTask {
                    let dec = JSONDecoder()
                    var out: [(String, FontEntry)] = []
                    for u in chunk {
                        guard let data = try? Data(contentsOf: u),
                              let entry = try? dec.decode(FontEntry.self, from: data),
                              let uuid = entry.uuid else { continue }
                        out.append((normalizeUUID(uuid), entry))
                    }
                    return out
                }
            }
            var merged: [String: FontEntry] = [:]
            for await partial in group {
                for (k, v) in partial { merged[k] = v }
            }
            return merged
        }
    }

    // MARK: - Font lists (collections)

    struct FontListEntry: Decodable {
        var uuid: String?
        var name: String?
        var kind: String?
        var parent: String?
        var fonts: [String]?           // hyphen-less font UUIDs
        var type: Int?
        var createdBy: String?
        var modifiedBy: String?
    }

    static func parseAllFontLists(in bundle: URL) -> [FontListEntry] {
        let dir = bundle.appendingPathComponent("metadata/fontlists", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let dec = JSONDecoder()
        return urls
            .filter { $0.pathExtension == metadataExtension }
            .compactMap { u -> FontListEntry? in
                guard let data = try? Data(contentsOf: u) else { return nil }
                return try? dec.decode(FontListEntry.self, from: data)
            }
    }

    // MARK: - Helpers

    /// Strip hyphens and uppercase so hyphenated and hyphen-less UUIDs compare equal.
    static func normalizeUUID(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: "").uppercased()
    }

    /// Resolve a RightFont `location` field ("M/Maax Raw Trial Regular/…")
    /// against the bundle's `fonts/` root.
    static func resolve(location: String, in bundle: URL) -> URL {
        fontsRoot(in: bundle).appendingPathComponent(location)
    }
}
