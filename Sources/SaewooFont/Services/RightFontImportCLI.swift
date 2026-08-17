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

/// `SaewooFont --scan-duplicates` — read-only audit of the identical-file
/// cleanup. Runs the exact scan the UI runs, then reports what *would* be
/// deleted and audits the result for anything unsafe. Deletes nothing.
/// Carries the scan result back across the semaphore.
final class ResultBox: @unchecked Sendable {
    var groups: [DuplicateScanner.Group] = []
}

enum DuplicateAuditCLI {
    static func requested() -> Bool { CommandLine.arguments.contains("--scan-duplicates") }

    @MainActor
    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: this runs piped
        Persistence.readOnly = true      // audit must never mutate user state
        print("\n=== Identical-file audit (read-only, deletes nothing) ===\n")
        print("[1] bootstrapping…")

        let lib = FontLibrary()
        await lib.bootstrap()
        print("[2] library: \(lib.items.count) faces")

        // Snapshot what the audit needs, then leave the main actor entirely.
        //
        // The scan must NOT be awaited from here. `SaewooFontApp.init()` drives
        // these CLI paths by spinning `RunLoop.main.run(until:)`, and that tight
        // loop starves Swift's cooperative pool: measured on this library, the
        // task group made no progress at all while the pump burned one core for
        // ten minutes. Blocking the main thread on a semaphore instead lets the
        // pool run normally.
        let files = lib.uniqueFilesForAudit

        print("[3] scanning \(files.count) files…")
        let started = Date()
        let groups = await DuplicateScanner.scan(files: files) { p in
            if p.done == p.total { FileHandle.standardError.write(Data(".".utf8)) }
        }
        print(String(format: "\nscan took %.1fs\n", Date().timeIntervalSince(started)))

        let extras = groups.reduce(0) { $0 + $1.paths.count - 1 }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.size * Int64($1.paths.count - 1) }
        print("identical groups     : \(groups.count)")
        print("removable copies     : \(extras)")
        print("reclaimable          : \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")

        // --- safety audit -------------------------------------------------
        func sortKey(_ f: FontItem) -> String {
            "\(f.styleName)\u{1}\(f.familyName)\u{1}\(f.postScriptName)"
        }
        var noKeeper = 0, protectedDeleted = 0, cloudDeleted = 0
        var facesLost = 0, facesPreserved = 0, pairedByOrder = 0, multiFaceFiles = 0
        for g in groups {
            let keeper = lib.recommendedKeeper(in: g)
            guard g.paths.contains(keeper) else { noKeeper += 1; continue }
            let keeperFaces = lib.itemsAtPath(keeper).sorted { sortKey($0) < sortKey($1) }
            let keeperPS = Set(keeperFaces.map { $0.postScriptName })
            for victim in g.paths where victim != keeper {
                let faces = lib.itemsAtPath(victim).sorted { sortKey($0) < sortKey($1) }
                if faces.count > 1 { multiFaceFiles += 1 }
                if faces.contains(where: { SystemFontGuard.isProtected($0) }) { protectedDeleted += 1 }
                if FontLibrary.isCloudSynced(victim) { cloudDeleted += 1 }
                for f in faces {
                    if keeperPS.contains(f.postScriptName) {
                        facesPreserved += 1
                    } else if faces.count == keeperFaces.count {
                        pairedByOrder += 1; facesPreserved += 1
                    } else {
                        facesLost += 1
                    }
                }
            }
        }
        lib.installDuplicatesForAudit(groups)
        // Policy preview timing — this runs on every rules-panel change, so
        // it has to be cheap. It used to hit the disk once per copy per group.
        var t = Date()
        _ = lib.previewPolicy()
        let cold = Date().timeIntervalSince(t) * 1000
        t = Date()
        _ = lib.previewPolicy()
        let warm = Date().timeIntervalSince(t) * 1000
        print(String(format: "\npolicy preview: cold %.0f ms · warm %.0f ms  (%d groups)",
                     cold, warm, groups.count))

        print("\n--- safety audit ---")
        print("groups with no valid keeper            : \(noKeeper)      (must be 0)")
        print("faces whose twin survives in the keeper: \(facesPreserved)")
        print("faces paired by position (unnamed fonts): \(pairedByOrder)")
        print("faces with NO twin in the keeper       : \(facesLost)      (must be 0)")
        print("multi-face files among deletions       : \(multiFaceFiles)  (safe: identical copy kept)")
        print("protected/system files among deletions : \(protectedDeleted)  (skipped at delete time)")
        print("cloud-synced files among deletions     : \(cloudDeleted)  (flagged in UI)")

        let ok = noKeeper == 0 && facesLost == 0
        let verdict = ok
            ? "SAFE — every removed face exists byte-identically in a kept file"
            : "UNSAFE — do not ship this"
        print("\nVERDICT: \(verdict)\n")
    }
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
