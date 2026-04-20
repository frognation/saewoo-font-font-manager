import Foundation
import CoreText
import AppKit

enum FontScanner {
    static let defaultSearchRoots: [URL] = {
        let fm = FileManager.default
        var roots: [URL] = []
        if let user = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            roots.append(user.appendingPathComponent("Fonts"))
        }
        roots.append(URL(fileURLWithPath: "/Library/Fonts"))
        return roots
    }()

    private static let supportedExt: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2"]

    static func scan(roots: [URL]) -> [FontItem] {
        let fm = FileManager.default
        var files: [URL] = []
        for root in roots {
            guard let it = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in it {
                if supportedExt.contains(url.pathExtension.lowercased()) {
                    files.append(url)
                }
            }
        }

        var items: [FontItem] = []
        items.reserveCapacity(files.count)
        for url in files {
            items.append(contentsOf: extract(from: url))
        }
        return items
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

        let (category, moods) = FontClassifier.classify(
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
            format: format, category: category, moods: moods,
            glyphCount: glyphCount, fileSize: fileSize, dateAdded: dateAdded,
            panose: panose
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
