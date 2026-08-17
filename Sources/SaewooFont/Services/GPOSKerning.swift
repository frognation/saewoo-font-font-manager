import Foundation
import CoreText

/// Extracts pair kerning from the compiled `GPOS` table.
///
/// `KernReader` (in `UFOFidelity.swift`) only understands the legacy `kern`
/// table, format 0. Almost every font shipped in the last decade puts its
/// kerning in GPOS instead — often with no `kern` table at all — so without
/// this, exported UFOs are unkerned and the designer doesn't find out until
/// text starts colliding. This reader walks just enough of GPOS to recover
/// horizontal pair kerning: the `kern` feature's Pair Adjustment (LookupType
/// 2) subtables, both the flat PairPos and class-based formats, unwrapped
/// through Extension Positioning (LookupType 9) where needed.
///
/// What this deliberately does NOT attempt: contextual/chained kerning
/// (LookupTypes 7/8), device-table hinting deltas, vertical kerning, RTL
/// cursive attachment, or anything that isn't a plain XAdvance bump between
/// two glyphs. Those are layout-engine territory; flattening them into a
/// static pair list would be either wrong or impossible. Subtables we can't
/// handle are counted in `unsupportedSubtables` rather than silently eaten,
/// so callers can at least report that something was left behind.
enum GPOSKerning {

    struct Pair {
        let left: CGGlyph
        let right: CGGlyph
        let value: Int
    }

    /// Extracted pairs, plus what could not be represented.
    struct Result {
        var pairs: [Pair] = []
        /// How many of `pairs` came from expanding a class-pair matrix
        /// (PairPos format 2) rather than an explicit glyph pair (format 1).
        var classPairsExpanded: Int = 0
        /// Subtables we saw but skipped: unhandled lookup types, unhandled
        /// PairPos formats, unhandled Extension targets, or the point at
        /// which the pair budget below was exhausted.
        var unsupportedSubtables: Int = 0
    }

    /// Hard ceiling on expanded pairs. A malformed or adversarial class
    /// matrix (large class1Count × class2Count, all cells populated) could
    /// otherwise expand to hundreds of millions of pairs; this keeps memory
    /// bounded and the caller informed via `unsupportedSubtables`.
    private static let maxPairs = 200_000

    static func read(font: CTFont) -> Result {
        let builder = Builder()
        guard let d = UFOFidelity.table(font, "GPOS"), d.count >= 10 else { return builder.result }

        // Header is version(4) + scriptListOffset(2) + featureListOffset(2)
        // + lookupListOffset(2). Version 1.1 appends a featureVariationsOffset
        // (u32) we don't read — it comes after everything we need, so the
        // 1.0 vs 1.1 distinction doesn't change any of the offsets below.
        let featureListOffset = u16(d, 6)
        let lookupListOffset = u16(d, 8)
        guard featureListOffset > 0, featureListOffset + 1 < d.count,
              lookupListOffset > 0, lookupListOffset + 1 < d.count
        else { return builder.result }

        let kernLookupIndices = kernFeatureLookupIndices(d, featureListOffset)
        guard !kernLookupIndices.isEmpty else { return builder.result }

        let lookupCount = u16(d, lookupListOffset)
        for lookupIndex in kernLookupIndices {
            if builder.capHit { break }
            guard lookupIndex >= 0, lookupIndex < lookupCount else { continue }
            let lo = lookupListOffset + 2 + lookupIndex * 2
            guard lo + 1 < d.count else { continue }
            let lookupOffsetRel = u16(d, lo)
            guard lookupOffsetRel > 0 else { continue }
            let lookupTableOffset = lookupListOffset + lookupOffsetRel
            guard lookupTableOffset + 5 < d.count else { continue }

            let lookupType = u16(d, lookupTableOffset)
            let subTableCount = u16(d, lookupTableOffset + 4)

            for si in 0..<subTableCount {
                if builder.capHit { break }
                let so = lookupTableOffset + 6 + si * 2
                guard so + 1 < d.count else { break }
                let subOffsetRel = u16(d, so)
                guard subOffsetRel > 0 else { continue }
                let subAbs = lookupTableOffset + subOffsetRel

                switch lookupType {
                case 2:
                    parsePairAdjustment(d, subAbs, builder)
                case 9:
                    parseExtension(d, subAbs, builder)
                default:
                    builder.result.unsupportedSubtables += 1
                }
            }
        }

        if builder.capHit { builder.result.unsupportedSubtables += 1 }
        return builder.result
    }

    // MARK: - FeatureList

    /// Collects the LookupList indices referenced by every `kern` feature.
    /// (There can be more than one FeatureRecord tagged `kern` — one per
    /// script/language — so we gather across all of them.)
    private static func kernFeatureLookupIndices(_ d: Data, _ featureListOffset: Int) -> [Int] {
        var indices: [Int] = []
        let featureCount = u16(d, featureListOffset)
        for i in 0..<featureCount {
            let rec = featureListOffset + 2 + i * 6
            guard rec + 5 < d.count else { break }
            let s = d.startIndex + rec
            guard s + 3 < d.endIndex else { break }
            let tag = String(bytes: [d[s], d[s + 1], d[s + 2], d[s + 3]], encoding: .ascii)
            guard tag == "kern" else { continue }

            let featureOffsetRel = u16(d, rec + 4)
            guard featureOffsetRel > 0 else { continue }
            let featureTableOffset = featureListOffset + featureOffsetRel
            guard featureTableOffset + 3 < d.count else { continue }

            let lookupIndexCount = u16(d, featureTableOffset + 2)
            for li in 0..<lookupIndexCount {
                let o = featureTableOffset + 4 + li * 2
                guard o + 1 < d.count else { break }
                indices.append(u16(d, o))
            }
        }
        return indices
    }

    // MARK: - LookupType 9 (Extension Positioning)

    private static func parseExtension(_ d: Data, _ offset: Int, _ builder: Builder) {
        guard offset >= 0, offset + 7 < d.count else { return }
        let extensionLookupType = u16(d, offset + 2)
        guard extensionLookupType == 2 else {
            builder.result.unsupportedSubtables += 1
            return
        }
        let extensionOffset = u32(d, offset + 4)
        guard extensionOffset > 0 else { return }
        let extAbs = offset + Int(extensionOffset)
        guard extAbs >= 0, extAbs < d.count else { return }
        parsePairAdjustment(d, extAbs, builder)
    }

    // MARK: - LookupType 2 (Pair Adjustment)

    private static func parsePairAdjustment(_ d: Data, _ offset: Int, _ builder: Builder) {
        guard offset >= 0, offset + 1 < d.count else { return }
        switch u16(d, offset) {
        case 1: parsePairPosFormat1(d, offset, builder)
        case 2: parsePairPosFormat2(d, offset, builder)
        default: builder.result.unsupportedSubtables += 1
        }
    }

    /// Format 1: an explicit glyph-pair list, one PairSet per coverage glyph.
    private static func parsePairPosFormat1(_ d: Data, _ offset: Int, _ builder: Builder) {
        guard offset + 9 < d.count else { return }
        let coverageOffsetRel = u16(d, offset + 2)
        let valueFormat1 = u16(d, offset + 4)
        let valueFormat2 = u16(d, offset + 6)
        let pairSetCount = u16(d, offset + 8)
        guard coverageOffsetRel > 0 else { return }

        let coverage = parseCoverageIndexed(d, offset + coverageOffsetRel)
        let len1 = valueRecordLength(valueFormat1)
        let len2 = valueRecordLength(valueFormat2)

        for i in 0..<pairSetCount {
            if builder.capHit { return }
            let offOff = offset + 10 + i * 2
            guard offOff + 1 < d.count else { break }
            let pairSetOffsetRel = u16(d, offOff)
            guard pairSetOffsetRel > 0 else { continue }
            guard let leftGlyph = coverage[i] else { continue }

            let pairSetAbs = offset + pairSetOffsetRel
            guard pairSetAbs + 1 < d.count else { continue }
            let pairValueCount = u16(d, pairSetAbs)

            var p = pairSetAbs + 2
            for _ in 0..<pairValueCount {
                guard p + 1 < d.count else { break }
                let rightGlyph = u16(d, p)
                p += 2
                guard p + len1 <= d.count else { break }
                let xAdv = xAdvance(d, p, format: valueFormat1)
                p += len1
                // Value2 (the second glyph's own adjustment) is skipped, not
                // read — we only export horizontal advances between a pair,
                // and skipping the wrong byte count here would desync every
                // PairValueRecord after it.
                guard p + len2 <= d.count else { break }
                p += len2

                if !builder.add(leftGlyph, rightGlyph, xAdv) { return }
            }
        }
    }

    /// Format 2: a class1 × class2 matrix of values, expanded into concrete
    /// glyph pairs. Class 0 is the implicit "everything not otherwise
    /// listed" bucket. On the left side that's well defined — it's every
    /// coverage glyph absent from ClassDef1 — so we include it. On the right
    /// side "everything else" means every glyph in the font, which is not
    /// enumerable from this table alone and would be an enormous, mostly
    /// meaningless expansion; we only expand right-side classes that
    /// ClassDef2 explicitly lists glyphs for.
    private static func parsePairPosFormat2(_ d: Data, _ offset: Int, _ builder: Builder) {
        guard offset + 15 < d.count else { return }
        let coverageOffsetRel = u16(d, offset + 2)
        let valueFormat1 = u16(d, offset + 4)
        let classDef1OffsetRel = u16(d, offset + 8)
        let classDef2OffsetRel = u16(d, offset + 10)
        let class1Count = u16(d, offset + 12)
        let class2Count = u16(d, offset + 14)
        guard coverageOffsetRel > 0, classDef1OffsetRel > 0, classDef2OffsetRel > 0,
              class1Count > 0, class2Count > 0
        else { return }

        let coverageGlyphs = parseCoverageGlyphSet(d, offset + coverageOffsetRel)
        guard !coverageGlyphs.isEmpty else { return }
        let classDef1 = parseClassDef(d, offset + classDef1OffsetRel)
        let classDef2 = parseClassDef(d, offset + classDef2OffsetRel)

        var class1Glyphs: [Int: [Int]] = [:]
        for g in coverageGlyphs {
            let c = classDef1[g] ?? 0
            guard c < class1Count else { continue }
            class1Glyphs[c, default: []].append(g)
        }
        var class2Glyphs: [Int: [Int]] = [:]
        for (g, c) in classDef2 {
            guard c < class2Count else { continue }
            class2Glyphs[c, default: []].append(g)
        }
        guard !class1Glyphs.isEmpty, !class2Glyphs.isEmpty else { return }

        // Walk only classes that actually have glyphs, keyed rather than
        // 0..<count — class1Count/class2Count are u16 and a malformed font
        // could set both near 65535, which would make a dense 0..<count×
        // 0..<count walk billions of cells even though almost all are empty.
        let usedClass1 = class1Glyphs.keys.sorted()
        let usedClass2 = class2Glyphs.keys.sorted()
        guard usedClass1.count * usedClass2.count <= 4_000_000 else {
            builder.result.unsupportedSubtables += 1
            return
        }

        let len1 = valueRecordLength(valueFormat1)
        let len2 = valueRecordLength(u16(d, offset + 6))
        let recordSize = len1 + len2
        guard recordSize > 0 else { return }
        let arrayStart = offset + 16

        for c1 in usedClass1 {
            if builder.capHit { return }
            guard let leftGlyphs = class1Glyphs[c1] else { continue }
            for c2 in usedClass2 {
                if builder.capHit { return }
                guard let rightGlyphs = class2Glyphs[c2] else { continue }

                let recordOffset = arrayStart + (c1 * class2Count + c2) * recordSize
                guard recordOffset >= 0, recordOffset + len1 <= d.count else { continue }
                let xAdv = xAdvance(d, recordOffset, format: valueFormat1)
                guard xAdv != 0 else { continue }

                for l in leftGlyphs {
                    for r in rightGlyphs {
                        let before = builder.result.pairs.count
                        if !builder.add(l, r, xAdv) { return }
                        if builder.result.pairs.count > before { builder.result.classPairsExpanded += 1 }
                    }
                }
            }
        }
    }

    // MARK: - Coverage

    /// Format 1 (glyph list) and format 2 (glyph ranges), keyed by coverage
    /// index — required for PairPos format 1, where PairSet i pairs with
    /// coverage glyph i.
    private static func parseCoverageIndexed(_ d: Data, _ offset: Int) -> [Int: Int] {
        guard offset > 0, offset + 1 < d.count else { return [:] }
        var out: [Int: Int] = [:]
        switch u16(d, offset) {
        case 1:
            let count = min(u16(d, offset + 2), maxCoverageEntries)
            for i in 0..<count {
                let o = offset + 4 + i * 2
                guard o + 1 < d.count else { break }
                out[i] = u16(d, o)
            }
        case 2:
            let rangeCount = min(u16(d, offset + 2), maxCoverageEntries)
            for i in 0..<rangeCount {
                let o = offset + 4 + i * 6
                guard o + 5 < d.count else { break }
                let startGlyph = u16(d, o)
                let endGlyph = u16(d, o + 2)
                let startCoverageIndex = u16(d, o + 4)
                guard endGlyph >= startGlyph else { continue }
                let len = min(endGlyph - startGlyph + 1, maxCoverageEntries)
                for k in 0..<len { out[startCoverageIndex + k] = startGlyph + k }
            }
        default:
            break
        }
        return out
    }

    /// Same tables, but just the glyph set — order doesn't matter for
    /// PairPos format 2, which only needs "is this glyph covered".
    private static func parseCoverageGlyphSet(_ d: Data, _ offset: Int) -> [Int] {
        guard offset > 0, offset + 1 < d.count else { return [] }
        var out: [Int] = []
        switch u16(d, offset) {
        case 1:
            let count = min(u16(d, offset + 2), maxCoverageEntries)
            for i in 0..<count {
                let o = offset + 4 + i * 2
                guard o + 1 < d.count else { break }
                out.append(u16(d, o))
            }
        case 2:
            let rangeCount = min(u16(d, offset + 2), maxCoverageEntries)
            for i in 0..<rangeCount {
                let o = offset + 4 + i * 6
                guard o + 5 < d.count else { break }
                let startGlyph = u16(d, o)
                let endGlyph = u16(d, o + 2)
                guard endGlyph >= startGlyph else { continue }
                let len = min(endGlyph - startGlyph + 1, maxCoverageEntries)
                for k in 0..<len { out.append(startGlyph + k) }
            }
        default:
            break
        }
        return out
    }

    // MARK: - ClassDef

    /// Format 1 (contiguous glyph range, one class per slot) and format 2
    /// (explicit class ranges). Glyphs absent from the returned map are
    /// class 0 by definition — callers decide whether that matters for
    /// their side of the pair.
    private static func parseClassDef(_ d: Data, _ offset: Int) -> [Int: Int] {
        guard offset > 0, offset + 1 < d.count else { return [:] }
        var out: [Int: Int] = [:]
        switch u16(d, offset) {
        case 1:
            guard offset + 5 < d.count else { return [:] }
            let startGlyph = u16(d, offset + 2)
            let count = min(u16(d, offset + 4), maxCoverageEntries)
            for i in 0..<count {
                let o = offset + 6 + i * 2
                guard o + 1 < d.count else { break }
                out[startGlyph + i] = u16(d, o)
            }
        case 2:
            guard offset + 3 < d.count else { return [:] }
            let rangeCount = min(u16(d, offset + 2), maxCoverageEntries)
            for i in 0..<rangeCount {
                let o = offset + 4 + i * 6
                guard o + 5 < d.count else { break }
                let startGlyph = u16(d, o)
                let endGlyph = u16(d, o + 2)
                let classValue = u16(d, o + 4)
                guard endGlyph >= startGlyph else { continue }
                let len = min(endGlyph - startGlyph + 1, maxCoverageEntries)
                for k in 0..<len { out[startGlyph + k] = classValue }
            }
        default:
            break
        }
        return out
    }

    private static let maxCoverageEntries = 100_000

    // MARK: - ValueRecord

    private static let fmtXPlacement = 0x0001
    private static let fmtYPlacement = 0x0002
    private static let fmtXAdvance   = 0x0004

    /// Total byte length of a ValueRecord for a given format bitmask — 2
    /// bytes per set bit, regardless of which fields they are. Get this
    /// wrong and every read after the record is garbage.
    private static func valueRecordLength(_ format: Int) -> Int {
        var n = 0, f = format & 0xFF
        while f != 0 { n += f & 1; f >>= 1 }
        return n * 2
    }

    /// XAdvance is the third field when present, after XPlacement and
    /// YPlacement (in that fixed bit order), so its byte offset within the
    /// record depends on which earlier fields are also set. We only ever
    /// want XAdvance (horizontal kerning); everything else in the record is
    /// skipped by `valueRecordLength`, never read.
    private static func xAdvance(_ d: Data, _ offset: Int, format: Int) -> Int {
        guard format & fmtXAdvance != 0 else { return 0 }
        var skip = 0
        if format & fmtXPlacement != 0 { skip += 2 }
        if format & fmtYPlacement != 0 { skip += 2 }
        return i16(d, offset + skip)
    }

    // MARK: - Accumulator

    /// Mutable parse state threaded through the recursive subtable walk:
    /// the pairs found so far, dedup so the first lookup to claim a pair
    /// wins, and the point at which we stop because `maxPairs` was hit.
    private final class Builder {
        var result = Result()
        private var seen = Set<Int64>()
        private(set) var capHit = false

        /// Returns false once the pair budget is exhausted, telling callers
        /// to unwind rather than keep scanning bytes that will never be kept.
        func add(_ left: Int, _ right: Int, _ value: Int) -> Bool {
            guard value != 0 else { return true }
            guard left >= 0, left <= 0xFFFF, right >= 0, right <= 0xFFFF else { return true }
            guard result.pairs.count < GPOSKerning.maxPairs else {
                capHit = true
                return false
            }
            let key = (Int64(left) << 32) | Int64(right)
            guard seen.insert(key).inserted else { return true }
            result.pairs.append(Pair(left: CGGlyph(left), right: CGGlyph(right), value: value))
            return true
        }
    }

    // MARK: - Primitives

    private static func u16(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 1 < d.count else { return 0 }
        let i = d.startIndex + o
        return Int(d[i]) << 8 | Int(d[i + 1])
    }
    private static func i16(_ d: Data, _ o: Int) -> Int {
        Int(Int16(bitPattern: UInt16(u16(d, o))))
    }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 3 < d.count else { return 0 }
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}
