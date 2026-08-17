import Foundation

/// Headless RightFont import:
///
///     SaewooFont --import-rightfont <library.rightfontlibrary> <map.json>
///
/// Why this exists as a CLI rather than only the right-click menu action:
/// the in-app importer resolves each font's RightFont `location` *inside* the
/// package. Once the fonts have been lifted out of the package and reorganised
/// into family folders, that resolution no longer works — but the collections
/// are only readable while the package still exists. So the extraction step
/// writes a `location → new absolute path` map, and this command replays the
/// import against that map, letting us keep the curation after the package is
/// gone.
///
/// `map.json` is `{ "<location relative to fonts/>": "<new absolute path>" }`.
/// Tiny box so the run-loop pump in `SaewooFontApp.init()` can observe
/// completion of a `@MainActor` task without capturing a mutating local.
final class Flag {
    var value = false
}

enum RightFontImportCLI {

    static func requestedArguments() -> (bundle: URL, map: URL)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--import-rightfont"),
              args.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: args[i + 1]), URL(fileURLWithPath: args[i + 2]))
    }

    @MainActor
    static func run(bundle: URL, map mapURL: URL) async {
        print("\n=== RightFont import ===")

        guard let mapData = try? Data(contentsOf: mapURL),
              let map = try? JSONDecoder().decode([String: String].self, from: mapData) else {
            print("could not read map: \(mapURL.path)"); exit(1)
        }
        print("location map entries: \(map.count)")

        let lib = FontLibrary()
        await lib.bootstrap()
        print("rescanning so the extracted fonts are indexed…")
        await lib.rescan()
        print("library: \(lib.items.count) faces")

        // path → our FontItem ids (a file can hold several faces).
        var idsByPath: [String: [String]] = [:]
        for item in lib.items {
            idsByPath[item.fileURL.standardizedFileURL.path, default: []].append(item.id)
        }

        // RightFont font-uuid → our ids, via location → new path.
        let entries = await RightFontImporter.parseAllFontEntries(in: bundle)
        var idsByUUID: [String: [String]] = [:]
        var starred: Set<String> = []
        var resolved = 0, unresolved = 0
        for (uuid, entry) in entries {
            guard let loc = entry.location else { continue }
            guard let newPath = map[loc],
                  let ids = idsByPath[URL(fileURLWithPath: newPath).standardizedFileURL.path] else {
                unresolved += 1; continue
            }
            idsByUUID[uuid] = ids
            resolved += 1
            if entry.starred == true { starred.formUnion(ids) }
        }
        print("font records: \(entries.count) · resolved \(resolved) · unresolved \(unresolved)")

        // Fontlists → palettes.
        let libName = RightFontImporter.parseManifest(in: bundle)?.name
            ?? bundle.deletingPathExtension().lastPathComponent
        let lists = RightFontImporter.parseAllFontLists(in: bundle)
        var created: [(String, Set<String>)] = []
        var empty = 0
        for list in lists {
            guard let name = list.name, let fonts = list.fonts, !fonts.isEmpty else {
                empty += 1; continue
            }
            // normalizeUUID, not uppercased(): `parseAllFontEntries` keys its
            // map by hyphen-stripped UUID, while fontlists store hyphenated
            // ones. Uppercasing alone silently matches almost nothing.
            let ids = Set(fonts.flatMap { idsByUUID[RightFontImporter.normalizeUUID($0)] ?? [] })
            if ids.isEmpty { empty += 1; continue }
            created.append((name, ids))
        }

        let n = lib.importPalettes(created, libraryName: libName)
        lib.addFavorites(starred)
        print("fontlists: \(lists.count) · imported \(n) palettes · skipped \(empty) empty/unresolvable")
        print("starred fonts added to favorites: \(starred.count)")
        print("done.\n")
    }
}
