import Foundation
import CoreText

/// `SaewooFont --fork <font-file> <output-dir> [--variable]`
///
/// Runs the real `UFOExporter` on a real font and then validates the bundle it
/// produced against the parts of the UFO 3 spec that Glyphs / RoboFont / fontmake
/// actually refuse to open without. Exists because "does Fork work?" is not a
/// question you can answer by reading the exporter — you have to look at the
/// bytes it writes.
///
/// Everything here is synchronous on purpose. `UFOExporter.export` is a plain
/// throwing function, so this path needs no concurrency at all — which matters,
/// because these CLI entry points run before `NSApplication` starts and the
/// cooperative pool does not schedule reliably there.
enum ForkCLI {

    static func requestedArguments() -> (font: URL, out: URL, variable: Bool)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--fork"), a.count > i + 2 else { return nil }
        return (URL(fileURLWithPath: a[i + 1]),
                URL(fileURLWithPath: a[i + 2]),
                a.contains("--variable"))
    }

    static func run(font url: URL, out: URL, variable: Bool) {
        setvbuf(stdout, nil, _IONBF, 0)
        print("\n=== Fork export test ===\n")

        guard let item = makeItem(from: url) else {
            print("could not parse: \(url.path)"); exit(1)
        }
        print("font   : \(item.displayName)")
        print("format : \(item.format)")
        print("axes   : \(item.variationAxes.map { $0.tagString }.joined(separator: ", "))")
        print("glyphs : \(item.glyphCount)")
        print("fvar named instances read by app: \(UFOExporter.readNamedInstances(item: item).count)\n")

        let fid = UFOFidelity.inspect(item: item)
        print("--- what will survive the export ---")
        print("  glyphs        : \(fid.glyphsExported) of \(fid.glyphsInFont)")
        print("  composites    : \(fid.compositeGlyphs)  \(fid.compositesPreserved ? "(preserved as <component> references)" : "(flattened — lose base/accent link)")")
        switch fid.kerningSource {
        case .none:      print("  kerning       : none in font")
        case .kernTable: print("  kerning       : \(fid.kerningPairs) pairs from legacy kern table")
        case .gposOnly:  print("  kerning       : GPOS only — NOT extractable")
        }
        print("  GSUB features : \(fid.gsubFeatures.isEmpty ? "none" : fid.gsubFeatures.joined(separator: " "))")
        print("  GPOS features : \(fid.gposFeatures.isEmpty ? "none" : fid.gposFeatures.joined(separator: " "))")
        print("  -> features are NOT regenerated into features.fea")
        print("")

        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let options = UFOExporter.Options(glyphMode: .full, resetIdentity: false)

        do {
            if variable {
                let started = Date()
                let r = try UFOExporter.exportDesignspaceFromVariable(
                    item: item, to: out, options: options)
                print(String(format: "designspace written in %.1fs", Date().timeIntervalSince(started)))
                print("masters: \(r.ufoURLs.count)")
                print("axes   : \(r.axes.map { "\($0.tag) \($0.min)…\($0.max)" }.joined(separator: ", "))\n")
                validateDesignspace(r.outputURL, ufos: r.ufoURLs)
            } else {
                let started = Date()
                let r = try UFOExporter.export(item: item, to: out, options: options)
                print(String(format: "ufo written in %.1fs", Date().timeIntervalSince(started)))
                print("glyphs written: \(r.glyphCount) · UPM \(r.unitsPerEm)\n")
                validateUFO(r.outputURL)
            }
        } catch {
            print("EXPORT FAILED: \(error)")
            exit(1)
        }
    }

    /// Minimal FontItem for a file, without touching the library cache.
    private static func makeItem(from url: URL) -> FontItem? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor], let desc = descs.first else { return nil }
        let f = CTFontCreateWithFontDescriptor(desc, 14, nil)
        let ps = CTFontCopyPostScriptName(f) as String
        let fam = (CTFontCopyName(f, kCTFontFamilyNameKey) as String?) ?? "Unknown"
        let sty = (CTFontCopyName(f, kCTFontStyleNameKey) as String?) ?? "Regular"
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return FontItem(
            id: "cli", fileURL: url, postScriptName: ps, familyName: fam, styleName: sty,
            displayName: "\(fam) \(sty)", weight: 0, width: 0, slant: 0,
            isItalic: false, isMonospaced: false, isBold: false,
            format: FontFormat(fileExtension: url.pathExtension),
            categories: [], moods: [], glyphCount: CTFontGetGlyphCount(f),
            fileSize: size, dateAdded: Date(), panose: [],
            variationAxes: VariationAxisReader.read(font: f), foundry: "CLI")
    }

    // MARK: - Validation

    private static func validateUFO(_ ufo: URL) {
        print("--- UFO 3 structure ---")
        var problems: [String] = []
        let fm = FileManager.default

        func require(_ rel: String, _ label: String) -> Bool {
            let ok = fm.fileExists(atPath: ufo.appendingPathComponent(rel).path)
            print("  \(ok ? "ok  " : "MISS") \(label)")
            if !ok { problems.append("missing \(rel)") }
            return ok
        }
        _ = require("metainfo.plist", "metainfo.plist")
        _ = require("fontinfo.plist", "fontinfo.plist")
        _ = require("layercontents.plist", "layercontents.plist (UFO3 requires this)")
        let hasContents = require("glyphs/contents.plist", "glyphs/contents.plist (name → file map)")

        // contents.plist must list every .glif actually present.
        if hasContents {
            let cURL = ufo.appendingPathComponent("glyphs/contents.plist")
            let listed: [String: String] = {
                guard let d = try? Data(contentsOf: cURL),
                      let o = try? PropertyListSerialization.propertyList(from: d, format: nil),
                      let m = o as? [String: String] else { return [:] }
                return m
            }()
            let onDisk = (try? fm.contentsOfDirectory(atPath: ufo.appendingPathComponent("glyphs").path))?
                .filter { $0.hasSuffix(".glif") } ?? []
            print("  contents.plist entries : \(listed.count)")
            print("  .glif files on disk    : \(onDisk.count)")
            if listed.count != onDisk.count {
                problems.append("contents.plist (\(listed.count)) != .glif count (\(onDisk.count))")
            }
            // Every mapped filename must exist, and names must be unique
            // case-insensitively — macOS filesystems are case-preserving but
            // not case-sensitive, so "A.glif" and "a.glif" would collide.
            var lowerSeen = Set<String>()
            var collisions = 0, dangling = 0
            for (_, file) in listed {
                if !lowerSeen.insert(file.lowercased()).inserted { collisions += 1 }
                if !fm.fileExists(atPath: ufo.appendingPathComponent("glyphs/\(file)").path) {
                    dangling += 1
                }
            }
            print("  case-insensitive filename collisions: \(collisions)")
            print("  contents.plist entries with no file : \(dangling)")
            if collisions > 0 { problems.append("\(collisions) case-insensitive .glif collisions") }
            if dangling > 0 { problems.append("\(dangling) dangling contents.plist entries") }

            // Peek at one glyph with actual outlines.
            if let sample = onDisk.first(where: {
                ((try? String(contentsOf: ufo.appendingPathComponent("glyphs/\($0)"), encoding: .utf8))?
                    .contains("<contour>")) == true
            }) {
                let text = (try? String(contentsOf: ufo.appendingPathComponent("glyphs/\(sample)"),
                                        encoding: .utf8)) ?? ""
                print("\n  sample glyph: \(sample)")
                for line in text.split(separator: "\n").prefix(12) { print("    \(line)") }
                for t in ["curve", "qcurve", "offcurve", "line", "move", "component"] {
                    let n = text.components(separatedBy: "type=\"\(t)\"").count - 1
                    if n > 0 { print("    point type '\(t)': \(n)") }
                }
                if text.contains("<component") { print("    NOTE: composite glyphs preserved") }
            }
        }

        // fontinfo sanity
        let fURL = ufo.appendingPathComponent("fontinfo.plist")
        if let d = try? Data(contentsOf: fURL),
           let obj = try? PropertyListSerialization.propertyList(from: d, format: nil),
           let info = obj as? [String: Any] {
            print("\n  fontinfo keys: \(info.keys.sorted().joined(separator: ", "))")
            for k in ["unitsPerEm", "ascender", "descender", "familyName", "styleName"] {
                if info[k] == nil { problems.append("fontinfo missing \(k)") }
            }
        } else {
            problems.append("fontinfo.plist is not a readable plist")
        }

        print("\n--- verdict ---")
        if problems.isEmpty { print("  OK — opens as a UFO 3 package") }
        else { problems.forEach { print("  PROBLEM: \($0)") } }
        print("")
    }

    private static func validateDesignspace(_ ds: URL, ufos: [URL]) {
        print("--- designspace ---")
        let xml = (try? String(contentsOf: ds, encoding: .utf8)) ?? ""
        print("  <axis> elements   : \(xml.components(separatedBy: "<axis").count - 1)")
        print("  <source> elements : \(xml.components(separatedBy: "<source").count - 1)")
        print("  <instance>        : \(xml.components(separatedBy: "<instance").count - 1)")
        print("  UFOs on disk      : \(ufos.count)")

        // The real question for a variable fork: are the masters actually
        // different? If variation coordinates were not applied, every master
        // holds the same default outlines and the designspace is useless.
        var digests: [String] = []
        for u in ufos {
            let g = u.appendingPathComponent("glyphs")
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: g.path) else { continue }
            let sample = files.filter { $0.hasSuffix(".glif") }.sorted().prefix(20)
            var blob = ""
            for f in sample {
                blob += (try? String(contentsOf: g.appendingPathComponent(f), encoding: .utf8)) ?? ""
            }
            digests.append(String(blob.hashValue))
        }
        let distinct = Set(digests).count
        print("  distinct master outlines: \(distinct) of \(digests.count)")
        print(distinct > 1
              ? "  OK — masters genuinely differ (variation coordinates applied)"
              : "  PROBLEM: every master has identical outlines")
        for u in ufos.prefix(3) { validateUFO(u) }
    }
}
