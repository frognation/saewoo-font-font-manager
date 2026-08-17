import Foundation
import CoreText

/// What a Fork export will and will not carry across.
///
/// Exists because the export *looks* complete — you get a UFO that opens in
/// Glyphs — and you only discover the holes later, after you have started
/// redrawing. Showing this before the user commits is worth more than any of
/// the individual extractors below.
struct ForkFidelity {
    var glyphsInFont = 0
    var glyphsExported = 0

    /// Composite glyphs (accents built from a base + a mark).
    var compositeGlyphs = 0
    /// True when the `glyf` table could be parsed, so composites export as
    /// `<component>` references rather than baked-in outlines. Static TrueType
    /// only: CFF composites live in subroutines, and variable-font masters are
    /// deliberately flattened because `gvar` moves component offsets per
    /// instance and we only read the default `glyf`.
    var compositesPreserved = false

    var kerningPairs = 0
    var kerningSource: KerningSource = .none
    /// GPOS subtables we skipped (contextual, unknown types).
    var gposUnsupportedSubtables = 0

    /// OpenType feature tags present in the font. We cannot regenerate
    /// `features.fea` from compiled GSUB/GPOS, so these are listed to be
    /// honest about what is being left behind.
    var gsubFeatures: [String] = []
    var gposFeatures: [String] = []

    enum KerningSource {
        case none
        /// Legacy `kern` table, format 0 — a flat pair list we can read.
        case kernTable
        /// Modern GPOS, and we managed to read pair positioning out of it.
        case gpos
        /// GPOS present but nothing extractable (contextual-only kerning).
        case gposOnly
    }

    var hasLosses: Bool {
        (compositeGlyphs > 0 && !compositesPreserved) || kerningSource == .gposOnly
            || !gsubFeatures.isEmpty || glyphsExported < glyphsInFont
    }
}

enum UFOFidelity {

    /// Inspects a font without writing anything.
    static func inspect(item: FontItem) -> ForkFidelity {
        var r = ForkFidelity()
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL)
                as? [CTFontDescriptor],
              let desc = descs.first(where: {
                  (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String)
                      == item.postScriptName
              }) ?? descs.first
        else { return r }

        let font = CTFontCreateWithFontDescriptor(desc, 1000, nil)
        r.glyphsInFont = CTFontGetGlyphCount(font)
        // Every glyph is exported now that the walk is by index, not by cmap.
        r.glyphsExported = r.glyphsInFont
        r.compositeGlyphs = countComposites(font: font)
        r.compositesPreserved = !GlyfComponents.read(font: font).isEmpty

        let pairs = KernReader.read(font: font)
        if !pairs.isEmpty {
            r.kerningPairs = pairs.count
            r.kerningSource = .kernTable
        } else if table(font, "GPOS") != nil {
            let g = GPOSKerning.read(font: font)
            if g.pairs.isEmpty {
                r.kerningSource = .gposOnly
            } else {
                r.kerningPairs = g.pairs.count
                r.kerningSource = .gpos
                r.gposUnsupportedSubtables = g.unsupportedSubtables
            }
        }

        r.gsubFeatures = featureTags(font: font, table: "GSUB")
        r.gposFeatures = featureTags(font: font, table: "GPOS")
        return r
    }

    // MARK: - Table helpers

    static func table(_ font: CTFont, _ tag: String) -> Data? {
        var v: UInt32 = 0
        for b in tag.utf8 { v = (v << 8) | UInt32(b) }
        return CTFontCopyTable(font, CTFontTableTag(v), []) as Data?
    }

    private static func u16(_ d: Data, _ o: Int) -> Int {
        guard o + 1 < d.count else { return 0 }
        return Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1])
    }

    /// Counts composite glyphs by walking `loca` + `glyf`. TrueType only —
    /// CFF builds composites out of subroutines and `seac`, which is a
    /// different problem entirely.
    private static func countComposites(font: CTFont) -> Int {
        guard let head = table(font, "head"), head.count >= 52,
              let loca = table(font, "loca"), let glyf = table(font, "glyf")
        else { return 0 }
        let longLoca = u16(head, 50) == 1
        let n = CTFontGetGlyphCount(font)
        var count = 0
        for gid in 0..<n {
            let start: Int, end: Int
            if longLoca {
                guard (gid * 4) + 7 < loca.count else { break }
                start = Int(be32(loca, gid * 4)); end = Int(be32(loca, gid * 4 + 4))
            } else {
                guard (gid * 2) + 3 < loca.count else { break }
                start = u16(loca, gid * 2) * 2; end = u16(loca, gid * 2 + 2) * 2
            }
            guard end > start, start + 1 < glyf.count else { continue }
            // numberOfContours < 0 marks a composite.
            let nc = Int16(bitPattern: UInt16(u16(glyf, start)))
            if nc < 0 { count += 1 }
        }
        return count
    }

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 3 < d.count else { return 0 }
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
    }

    /// Reads the FeatureList of GSUB/GPOS and returns the distinct feature
    /// tags. Cheap, and enough to tell the user what they're losing.
    private static func featureTags(font: CTFont, table tag: String) -> [String] {
        guard let d = table(font, tag), d.count >= 10 else { return [] }
        let featureListOffset = u16(d, 6)
        guard featureListOffset > 0, featureListOffset + 1 < d.count else { return [] }
        let count = u16(d, featureListOffset)
        var tags: Set<String> = []
        for i in 0..<count {
            let rec = featureListOffset + 2 + i * 6
            guard rec + 3 < d.count else { break }
            let s = d.startIndex + rec
            let bytes = [d[s], d[s+1], d[s+2], d[s+3]]
            if let t = String(bytes: bytes, encoding: .ascii) { tags.insert(t) }
        }
        return tags.sorted()
    }
}

/// Legacy `kern` table reader (format 0 only).
///
/// Modern fonts put kerning in GPOS and often ship no `kern` at all, so this
/// returns empty more often than not — which is why `ForkFidelity` reports the
/// source rather than just a number.
enum KernReader {
    struct Pair { let left: CGGlyph; let right: CGGlyph; let value: Int }

    static func read(font: CTFont) -> [Pair] {
        guard let d = UFOFidelity.table(font, "kern"), d.count >= 4 else { return [] }
        func u16(_ o: Int) -> Int {
            guard o + 1 < d.count else { return 0 }
            return Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1])
        }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }

        var out: [Pair] = []
        let nTables = u16(2)
        var off = 4
        for _ in 0..<nTables {
            guard off + 6 <= d.count else { break }
            let length = u16(off + 2)
            let coverage = u16(off + 4)
            let format = (coverage >> 8) & 0xFF
            if format == 0 {
                let nPairs = u16(off + 6)
                var p = off + 14      // skip nPairs/searchRange/entrySelector/rangeShift
                for _ in 0..<nPairs {
                    guard p + 5 < d.count else { break }
                    out.append(Pair(left: CGGlyph(u16(p)),
                                    right: CGGlyph(u16(p + 2)),
                                    value: i16(p + 4)))
                    p += 6
                }
            }
            guard length > 0 else { break }
            off += length
        }
        return out
    }
}
