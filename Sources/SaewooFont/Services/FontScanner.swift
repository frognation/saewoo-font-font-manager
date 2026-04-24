import Foundation
import CoreText

enum FontScanner {
    static let defaultSearchRoots: [URL] = {
        let fm = FileManager.default
        var roots: [URL] = []
        if let user = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            roots.append(user.appendingPathComponent("Fonts"))
        }
        roots.append(URL(fileURLWithPath: "/Library/Fonts"))
        // Adobe Fonts' local sync cache. Present only if the user has an
        // active Adobe CC subscription with Adobe Fonts enabled and
        // Creative Cloud has synced at least one font. Adding it as a
        // default root lets users see their Adobe Fonts alongside their
        // own library without extra setup.
        if let adobe = Self.adobeFontsCacheURL {
            roots.append(adobe)
        }
        // Google Fonts download cache — populated by the Cloud > Google Fonts
        // browse view. Always included so downloaded families surface as
        // regular FontItems in Library / Foundries / Categories without the
        // user having to add a custom scan source.
        roots.append(Self.googleFontsCacheURL)
        return roots
    }()

    /// Where `GoogleFontsClient` downloads its per-family TTFs / WOFF2s.
    static let googleFontsCacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SaewooFont/GoogleFonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let supportedExt: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2"]

    /// What a library scan produces — the parsed font faces plus files we
    /// found with a font extension but couldn't read. Orphans get their own
    /// tool view so the user can investigate / delete.
    struct Result {
        var items: [FontItem]
        var orphanURLs: [URL]
    }

    /// Synchronous scan — kept for callers that want the simple API.
    static func scan(roots: [URL]) -> Result {
        let files = collectFiles(in: roots)
        var items: [FontItem] = []
        var orphans: [URL] = []
        items.reserveCapacity(files.count)
        for url in files {
            let extracted = extract(from: url)
            if extracted.isEmpty { orphans.append(url) }
            else { items.append(contentsOf: extracted) }
        }
        return Result(items: items, orphanURLs: orphans)
    }

    /// Parallel scan — partitions the file list into N chunks and parses each
    /// chunk concurrently. For thousands of fonts this is typically 3–4× faster
    /// than the serial path on a modern Mac. Core Text's descriptor creation is
    /// thread-safe for disjoint URLs.
    static func scanParallel(roots: [URL], chunkCount: Int = 8) async -> Result {
        let files = collectFiles(in: roots)
        guard !files.isEmpty else { return Result(items: [], orphanURLs: []) }

        let stride = max(1, (files.count + chunkCount - 1) / chunkCount)
        var chunks: [[URL]] = []
        var i = 0
        while i < files.count {
            chunks.append(Array(files[i..<min(i + stride, files.count)]))
            i += stride
        }

        return await withTaskGroup(of: (items: [FontItem], orphans: [URL]).self) { group in
            for chunk in chunks {
                group.addTask(priority: .userInitiated) {
                    var localItems: [FontItem] = []
                    var localOrphans: [URL] = []
                    for url in chunk {
                        let extracted = extract(from: url)
                        if extracted.isEmpty { localOrphans.append(url) }
                        else { localItems.append(contentsOf: extracted) }
                    }
                    return (localItems, localOrphans)
                }
            }
            var allItems: [FontItem] = []
            var allOrphans: [URL] = []
            for await partial in group {
                allItems.append(contentsOf: partial.items)
                allOrphans.append(contentsOf: partial.orphans)
            }
            return Result(items: allItems, orphanURLs: allOrphans)
        }
    }

    private static func collectFiles(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for rawRoot in roots {
            // If the root is a `.rightfontlibrary` package, transparently
            // descend into its `fonts/` subdirectory instead — that's where
            // the actual font files live, and the rest of the package is
            // metadata we consume separately.
            let root = RightFontImporter.isLibrary(rawRoot)
                ? RightFontImporter.fontsRoot(in: rawRoot)
                : rawRoot

            guard let it = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in it {
                if supportedExt.contains(url.pathExtension.lowercased()) {
                    files.append(url)
                }
            }
        }
        return files
    }

    /// Enumerates every font currently known to Core Text — including those
    /// registered by OTHER font managers (RightFont, FontBase, Typeface,
    /// Adobe CC's font daemon) via CTFontManager `.session` or `.user`
    /// scope. Filesystem walks miss those because the files can live
    /// outside our scan paths.
    ///
    /// We de-dupe against any items we already have by absolute file URL,
    /// so calling this alongside `scanParallel` doesn't produce duplicates.
    static func scanAvailableInSystem(excluding knownURLs: Set<URL>) -> [FontItem] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descs = CTFontCollectionCreateMatchingFontDescriptors(collection)
                as? [CTFontDescriptor] else { return [] }
        var items: [FontItem] = []
        items.reserveCapacity(descs.count)
        for desc in descs {
            guard let url = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute) as? URL
            else { continue }
            let std = url.standardizedFileURL
            if knownURLs.contains(std) { continue }
            let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]))
            let size = Int64((attrs?.fileSize) ?? 0)
            let created = attrs?.creationDate ?? Date()
            if let item = buildItem(from: desc, url: url, fileSize: size, dateAdded: created) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Adobe Fonts local cache

    /// The path where Adobe CC's font-sync daemon stages Adobe-Fonts-synced
    /// files locally. If the user has an active Adobe subscription with
    /// Adobe Fonts enabled, fonts they've activated will be readable here.
    /// The `.r` subfolder contains the actual TTF/OTF files (numerically
    /// named). Returns nil if the directory doesn't exist.
    static var adobeFontsCacheURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(
            "Library/Application Support/Adobe/CoreSync/plugins/livetype/.r",
            isDirectory: true
        )
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? path : nil
    }

    /// A single file may contain multiple faces (TTC/OTC). Expand into one FontItem per face.
    private static func extract(from url: URL) -> [FontItem] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]))
        let size = Int64((attrs?.fileSize) ?? 0)
        let created = attrs?.creationDate ?? Date()
        var out: [FontItem] = []
        for desc in descriptors {
            if let item = buildItem(from: desc, url: url, fileSize: size, dateAdded: created) {
                out.append(item)
            }
        }
        return out
    }

    private static func buildItem(from desc: CTFontDescriptor, url: URL, fileSize: Int64, dateAdded: Date) -> FontItem? {
        let font = CTFontCreateWithFontDescriptor(desc, 14, nil)
        let psName = CTFontCopyPostScriptName(font) as String
        let family = (CTFontCopyName(font, kCTFontFamilyNameKey) as String?) ?? "Unknown"
        let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
        let display = (CTFontCopyName(font, kCTFontFullNameKey) as String?) ?? "\(family) \(style)"

        let traits = CTFontGetSymbolicTraits(font)
        let isItalic = traits.contains(.italicTrait)
        let isBold = traits.contains(.boldTrait)
        let isMono = traits.contains(.monoSpaceTrait)

        let traitsDict = (CTFontCopyTraits(font) as NSDictionary?) ?? [:]
        let weight = (traitsDict[kCTFontWeightTrait] as? Double) ?? 0
        let width = (traitsDict[kCTFontWidthTrait] as? Double) ?? 0
        let slant = (traitsDict[kCTFontSlantTrait] as? Double) ?? 0

        let format = detectFormat(url: url, traits: traits)
        let glyphCount = CTFontGetGlyphCount(font)
        let panose = PanoseReader.read(font: font)
        let axes = VariationAxisReader.read(font: font)
        let foundry = FoundryReader.read(font: font, psName: psName, family: family)

        let (categories, moods) = FontClassifier.classify(
            psName: psName, family: family, style: style,
            traits: traits, weight: weight, slant: slant,
            panose: panose
        )

        let idSource = "\(url.path)::\(psName)"
        let id = SHA.short(idSource)

        return FontItem(
            id: id, fileURL: url, postScriptName: psName,
            familyName: family, styleName: style, displayName: display,
            weight: weight, width: width, slant: slant,
            isItalic: isItalic, isMonospaced: isMono, isBold: isBold,
            format: format, categories: categories, moods: moods,
            glyphCount: glyphCount, fileSize: fileSize, dateAdded: dateAdded,
            panose: panose, variationAxes: axes, foundry: foundry
        )
    }

    private static func detectFormat(url: URL, traits: CTFontSymbolicTraits) -> String {
        switch url.pathExtension.lowercased() {
        case "otf": return "OpenType PostScript"
        case "ttf": return "TrueType"
        case "ttc": return "TrueType Collection"
        case "otc": return "OpenType Collection"
        case "dfont": return "Datafork TrueType"
        case "woff": return "WOFF"
        case "woff2": return "WOFF2"
        default: return "Unknown"
        }
    }
}

enum FoundryReader {
    /// Extracts the type foundry (manufacturer) from the font's name table.
    /// Falls back to vendor ID or PostScript prefix when the manufacturer field is missing.
    static func read(font: CTFont, psName: String, family: String) -> String {
        // Preferred: name ID 8 (Manufacturer Name)
        if let raw = CTFontCopyName(font, kCTFontManufacturerNameKey) as String?,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalise(raw)
        }
        // Fallback 1: OS/2 achVendID (4-byte vendor tag) — useful when manufacturer is blank.
        if let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           data.count >= 62 {
            // achVendID starts at offset 58, 4 bytes, ASCII, often padded with spaces.
            let bytes = (58..<62).map { data[$0] }
            if let tag = String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty, tag != "\u{00}\u{00}\u{00}\u{00}" {
                return vendorTagMap[tag] ?? tag
            }
        }
        // Fallback 2: PostScript-name prefix (e.g. "Adobe-", "Apple-", "Monotype-")
        if let dash = psName.firstIndex(of: "-") {
            let prefix = String(psName[..<dash])
            if prefix.count >= 3 && prefix.count <= 20 { return prefix }
        }
        return "Unknown"
    }

    /// Known 4-byte OS/2 vendor codes → human-readable foundry name.
    /// Not exhaustive; easy to extend as we encounter more.
    private static let vendorTagMap: [String: String] = [
        "ADBE": "Adobe", "APPL": "Apple", "MS":   "Microsoft", "MONO": "Monotype",
        "MT":   "Monotype", "GOOG": "Google", "LINO": "Linotype", "URW": "URW",
        "TYPE": "TypeType", "ITC":  "ITC", "BSTM": "Bitstream", "CTDL": "Cast Type",
        "H&CO": "Hoefler&Co", "HOEF": "Hoefler&Co", "CMRG": "Commercial Type",
        "NONE": "Unknown", "LTYP": "Letterror", "DLTF": "Dalton Maag",
        "PYRS": "Pyrus", "GRIL": "Grilli Type", "HPLX": "Hypeland",
        "KLIM": "Klim Type", "SORK": "Sort Sol", "GEST": "GestaltHaus",
    ]

    private static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trademark / copyright symbols and trailing legal suffixes.
        s = s.replacingOccurrences(of: "®", with: "")
             .replacingOccurrences(of: "™", with: "")
             .replacingOccurrences(of: "©", with: "")
             .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [", Inc.", ", Inc", " Inc.", " Inc", ", Ltd.", ", Ltd",
                        " Ltd.", " Ltd", ", LLC", " LLC", " GmbH", " Co.", " Co",
                        ", Co.", ", Co", " Corporation", " Corp.", " Corp"]
        var changed = true
        while changed {
            changed = false
            for suf in suffixes where s.hasSuffix(suf) {
                s = String(s.dropLast(suf.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return s.isEmpty ? "Unknown" : s
    }
}

enum VariationAxisReader {
    /// Reads OpenType/TrueType variation axes via CTFontCopyVariationAxes.
    /// Returns empty for static fonts.
    static func read(font: CTFont) -> [VariationAxis] {
        guard let raw = CTFontCopyVariationAxes(font) as? [[String: Any]], !raw.isEmpty else {
            return []
        }
        return raw.compactMap { dict -> VariationAxis? in
            guard
                let idNum = dict[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                let minN  = dict[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber,
                let maxN  = dict[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber,
                let defN  = dict[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber
            else { return nil }
            let tag = UInt32(truncating: idNum)
            let name = (dict[kCTFontVariationAxisNameKey as String] as? String) ?? tagToString(tag)
            let hidden = (dict[kCTFontVariationAxisHiddenKey as String] as? NSNumber)?.boolValue ?? false
            let minV = minN.doubleValue, maxV = maxN.doubleValue
            // Some broken fonts emit degenerate ranges; skip them so the slider isn't 0-width.
            guard maxV > minV else { return nil }
            return VariationAxis(
                tag: tag,
                tagString: tagToString(tag),
                name: name,
                minValue: minV,
                maxValue: maxV,
                defaultValue: defN.doubleValue.clamped(minV, maxV),
                isHidden: hidden
            )
        }
    }

    private static func tagToString(_ tag: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((tag >> 24) & 0xFF),
            UInt8((tag >> 16) & 0xFF),
            UInt8((tag >>  8) & 0xFF),
            UInt8( tag        & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) }
}

enum PanoseReader {
    /// Reads the 10-byte PANOSE classification from the OS/2 table, if present.
    static func read(font: CTFont) -> [Int] {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data? else { return [] }
        // OS/2 table: panose begins at offset 32, 10 bytes.
        guard data.count >= 42 else { return [] }
        return (32..<42).map { Int(data[$0]) }
    }
}

/// tiny, dependency-free short-hash for stable IDs.
enum SHA {
    static func short(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* prime
        }
        return String(h, radix: 16)
    }
}
