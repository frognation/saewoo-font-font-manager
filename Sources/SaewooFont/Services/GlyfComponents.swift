import Foundation
import CoreText

/// Reads composite glyph structure straight out of the TrueType `glyf` table.
///
/// Core Text only ever hands back flattened outlines
/// (`CTFontCreatePathForGlyph`), so without this every accented glyph exports
/// as loose contours. On a typical text face that is most of the font — 406 of
/// 657 glyphs in the reference variable font — and it destroys the thing that
/// makes a UFO editable: fix "A" and every "Á À Â Ä Å" should follow. Flattened,
/// they don't, and the designer has to redraw each one.
enum GlyfComponents {

    struct Component {
        let glyphIndex: Int
        let dx: Double
        let dy: Double
        /// 2×2 transform. Identity for the common accent case.
        let xScale: Double, scale01: Double, scale10: Double, yScale: Double

        var isIdentityTransform: Bool {
            xScale == 1 && yScale == 1 && scale01 == 0 && scale10 == 0
        }
    }

    // Composite glyph flags, per the OpenType spec.
    private static let ARG_1_AND_2_ARE_WORDS: UInt16 = 0x0001
    private static let ARGS_ARE_XY_VALUES: UInt16    = 0x0002
    private static let WE_HAVE_A_SCALE: UInt16       = 0x0008
    private static let MORE_COMPONENTS: UInt16       = 0x0020
    private static let X_AND_Y_SCALE: UInt16         = 0x0040
    private static let TWO_BY_TWO: UInt16            = 0x0080

    /// glyph index → its components, for composites only.
    ///
    /// `upmScale` converts from the font's design units into whatever UPM the
    /// caller is writing, which matters because the exporter creates its CTFont
    /// at `unitsPerEm` and the `glyf` offsets are already in design units.
    static func read(font: CTFont) -> [Int: [Component]] {
        guard let head = UFOFidelity.table(font, "head"), head.count >= 52,
              let loca = UFOFidelity.table(font, "loca"),
              let glyf = UFOFidelity.table(font, "glyf")
        else { return [:] }

        let longLoca = be16(head, 50) == 1
        let n = CTFontGetGlyphCount(font)
        var out: [Int: [Component]] = [:]

        for gid in 0..<n {
            let start: Int, end: Int
            if longLoca {
                guard gid * 4 + 7 < loca.count else { break }
                start = Int(be32(loca, gid * 4)); end = Int(be32(loca, gid * 4 + 4))
            } else {
                guard gid * 2 + 3 < loca.count else { break }
                start = be16(loca, gid * 2) * 2; end = be16(loca, gid * 2 + 2) * 2
            }
            guard end > start, start + 9 < glyf.count else { continue }
            let numberOfContours = Int16(bitPattern: UInt16(be16(glyf, start)))
            guard numberOfContours < 0 else { continue }   // not a composite

            var comps: [Component] = []
            var p = start + 10          // skip numberOfContours + bbox
            var more = true
            while more, p + 3 < glyf.count {
                let flags = UInt16(be16(glyf, p))
                let glyphIndex = be16(glyf, p + 2)
                p += 4

                var a1 = 0, a2 = 0
                if flags & ARG_1_AND_2_ARE_WORDS != 0 {
                    guard p + 3 < glyf.count else { break }
                    a1 = Int(Int16(bitPattern: UInt16(be16(glyf, p))))
                    a2 = Int(Int16(bitPattern: UInt16(be16(glyf, p + 2))))
                    p += 4
                } else {
                    guard p + 1 < glyf.count else { break }
                    a1 = Int(Int8(bitPattern: glyf[glyf.startIndex + p]))
                    a2 = Int(Int8(bitPattern: glyf[glyf.startIndex + p + 1]))
                    p += 2
                }

                var xs = 1.0, s01 = 0.0, s10 = 0.0, ys = 1.0
                if flags & WE_HAVE_A_SCALE != 0 {
                    xs = f2dot14(glyf, p); ys = xs; p += 2
                } else if flags & X_AND_Y_SCALE != 0 {
                    xs = f2dot14(glyf, p); ys = f2dot14(glyf, p + 2); p += 4
                } else if flags & TWO_BY_TWO != 0 {
                    xs  = f2dot14(glyf, p);     s01 = f2dot14(glyf, p + 2)
                    s10 = f2dot14(glyf, p + 4); ys  = f2dot14(glyf, p + 6)
                    p += 8
                }

                // Point-matching placement (ARGS_ARE_XY_VALUES clear) can't be
                // expressed as a UFO offset; skip the whole glyph rather than
                // silently misplace it.
                guard flags & ARGS_ARE_XY_VALUES != 0 else { comps.removeAll(); break }

                comps.append(Component(glyphIndex: glyphIndex,
                                       dx: Double(a1), dy: Double(a2),
                                       xScale: xs, scale01: s01, scale10: s10, yScale: ys))
                more = flags & MORE_COMPONENTS != 0
            }
            if !comps.isEmpty { out[gid] = comps }
        }
        return out
    }

    // MARK: - Primitives

    private static func be16(_ d: Data, _ o: Int) -> Int {
        guard o + 1 < d.count else { return 0 }
        let i = d.startIndex + o
        return Int(d[i]) << 8 | Int(d[i + 1])
    }
    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 3 < d.count else { return 0 }
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
    }
    /// F2Dot14 fixed-point, as used for component scales.
    private static func f2dot14(_ d: Data, _ o: Int) -> Double {
        Double(Int16(bitPattern: UInt16(be16(d, o)))) / 16384.0
    }
}
