import Foundation
import CoreText
import CoreGraphics

/// Exports a font as a UFO 3 package — the cross-app source format that both
/// Glyphs.app and RoboFont open natively. Designed to let the user "fork" an
/// existing font: keep the metrics and grid (unitsPerEm, ascender/descender,
/// cap-height, x-height, italic angle, underline) as a starting point, while
/// deliberately omitting license / copyright / trademark fields.
///
/// Three glyph modes let the user decide how much of the original drawing
/// comes along:
///   • `.full`        — every glyph in the default layer (for variants)
///   • `.empty`       — no glyphs; font info only (for starting from zero)
///   • `.background`  — originals on a background layer, default empty
///                      (for tracing / inspired-by new designs)
enum UFOExporter {

    // MARK: - Options

    enum GlyphMode: String, CaseIterable, Identifiable {
        case full, empty, background
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full:       return "Full — copy all outlines to the default layer"
            case .empty:      return "Empty — font info only, no outlines"
            case .background: return "Background — originals on background layer, default empty"
            }
        }
        var shortLabel: String {
            switch self {
            case .full: return "Full glyphs"
            case .empty: return "Empty"
            case .background: return "Background layer"
            }
        }
    }

    struct Options {
        var glyphMode: GlyphMode = .background
        /// Blank familyName / styleName / postscriptFontName so the new file
        /// doesn't carry the original identity. Metrics are still preserved.
        var resetIdentity: Bool = false
    }

    struct Report {
        var outputURL: URL
        var unitsPerEm: Int
        var glyphCount: Int
        var mode: GlyphMode
    }

    /// Report for multi-master / variable-font exports where we produce one
    /// designspace file plus N UFO masters.
    struct DesignspaceReport {
        var outputURL: URL            // the .designspace file
        var ufoURLs: [URL]            // one per master
        var axes: [(tag: String, name: String, min: Double, def: Double, max: Double)]
    }

    enum ExportError: LocalizedError {
        case descriptorUnavailable
        case alreadyExists(URL)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .descriptorUnavailable: return "Couldn't build a font descriptor for this file."
            case .alreadyExists(let u):  return "Output already exists at \(u.path)."
            case .writeFailed(let s):    return "Write failed: \(s)"
            }
        }
    }

    // MARK: - Public API

    static func export(item: FontItem, to targetDir: URL, options: Options) throws -> Report {
        // Create the CTFont at size = unitsPerEm so every metric getter
        // returns em-units directly (no scaling math needed downstream).
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL)
                as? [CTFontDescriptor],
              let desc = descs.first(where: {
                  (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == item.postScriptName
              }) ?? descs.first
        else { throw ExportError.descriptorUnavailable }

        let probe = CTFontCreateWithFontDescriptor(desc, 16, nil)
        let upm   = max(1, Int(CTFontGetUnitsPerEm(probe)))
        let font  = CTFontCreateWithFontDescriptor(desc, CGFloat(upm), nil)

        let fm = FileManager.default
        let fileName = sanitize(item.displayName.isEmpty ? item.postScriptName : item.displayName) + ".ufo"
        let ufo = targetDir.appendingPathComponent(fileName, isDirectory: true)
        if fm.fileExists(atPath: ufo.path) { throw ExportError.alreadyExists(ufo) }
        try fm.createDirectory(at: ufo, withIntermediateDirectories: true)

        try writeMetainfo(to: ufo)
        try writeFontInfo(to: ufo, item: item, font: font, upm: upm, options: options)

        // Composite structure, TrueType only. Empty for CFF and for anything
        // using point-matching placement.
        let comps = GlyfComponents.read(font: font)

        let glyphCount: Int
        switch options.glyphMode {
        case .empty:
            // Glyphs.app requires .notdef + a default layer. Ship a minimal one.
            try writeEmptyLayer(to: ufo, upm: upm)
            try writeLayerContents(to: ufo, layers: [("public.default", "glyphs")])
            glyphCount = 1
        case .full:
            glyphCount = try writeAllGlyphs(to: ufo, layerName: "public.default",
                                            dirName: "glyphs", font: font, upm: upm,
                                            components: comps)
            try writeLayerContents(to: ufo, layers: [("public.default", "glyphs")])
        case .background:
            try writeEmptyLayer(to: ufo, upm: upm)
            glyphCount = try writeAllGlyphs(to: ufo, layerName: "public.background",
                                            dirName: "glyphs.background", font: font, upm: upm,
                                            components: comps)
            try writeLayerContents(to: ufo, layers: [
                ("public.default",    "glyphs"),
                ("public.background", "glyphs.background")
            ])
        }

        if options.glyphMode != .empty { _ = try writeKerning(to: ufo, font: font) }

        return Report(outputURL: ufo, unitsPerEm: upm,
                      glyphCount: glyphCount, mode: options.glyphMode)
    }

    // MARK: - metainfo / fontinfo

    private static func writeMetainfo(to ufo: URL) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>creator</key>
          <string>com.saewoofont.SaewooFont</string>
          <key>formatVersion</key>
          <integer>3</integer>
        </dict>
        </plist>
        """
        try xml.write(to: ufo.appendingPathComponent("metainfo.plist"),
                      atomically: true, encoding: .utf8)
    }

    private static func writeFontInfo(to ufo: URL, item: FontItem, font: CTFont,
                                       upm: Int, options: Options) throws {
        let ascender  =  Int(CTFontGetAscent(font).rounded())
        let descender = -Int(CTFontGetDescent(font).rounded())   // UFO: descender is negative
        let capHeight =  Int(CTFontGetCapHeight(font).rounded())
        let xHeight   =  Int(CTFontGetXHeight(font).rounded())
        let ulPos     =  Int(CTFontGetUnderlinePosition(font).rounded())
        let ulThk     =  Int(CTFontGetUnderlineThickness(font).rounded())
        let italicAngle = readItalicAngle(font: font) ?? (item.isItalic ? -12.0 : 0.0)
        let (vMajor, vMinor) = parseVersion(
            CTFontCopyName(font, kCTFontVersionNameKey) as String? ?? "")

        let familyName = options.resetIdentity ? "" : item.familyName
        let styleName  = options.resetIdentity ? "" : item.styleName
        let psName     = options.resetIdentity ? "" : item.postScriptName

        // Deliberately omitted (user request): copyright, trademark, license,
        // openTypeNameLicense, openTypeNameLicenseURL, openTypeNameDescription.
        var body = ""
        body += entry("familyName",                   string: familyName)
        body += entry("styleName",                    string: styleName)
        body += entry("postscriptFontName",           string: psName)
        body += entry("unitsPerEm",                   integer: upm)
        body += entry("ascender",                     integer: ascender)
        body += entry("descender",                    integer: descender)
        body += entry("capHeight",                    integer: capHeight)
        body += entry("xHeight",                      integer: xHeight)
        body += entry("italicAngle",                  real: italicAngle)
        body += entry("postscriptUnderlinePosition",  integer: ulPos)
        body += entry("postscriptUnderlineThickness", integer: ulThk)
        body += entry("versionMajor",                 integer: vMajor)
        body += entry("versionMinor",                 integer: vMinor)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>\(body)
        </dict>
        </plist>
        """
        try xml.write(to: ufo.appendingPathComponent("fontinfo.plist"),
                      atomically: true, encoding: .utf8)
    }

    // MARK: - Glyph writing

    /// Writes a minimal `glyphs/` layer with only `.notdef`. Used when the
    /// default layer should be empty (empty-mode and background-mode).
    private static func writeEmptyLayer(to ufo: URL, upm: Int) throws {
        let dir = ufo.appendingPathComponent("glyphs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One .notdef glyph so Glyphs.app/RoboFont accept the UFO.
        let notdefGlif = """
        <?xml version="1.0" encoding="UTF-8"?>
        <glyph name=".notdef" format="2">
          <advance width="\(upm / 2)"/>
        </glyph>
        """
        try notdefGlif.write(to: dir.appendingPathComponent("_notdef.glif"),
                             atomically: true, encoding: .utf8)
        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>.notdef</key>
          <string>_notdef.glif</string>
        </dict>
        </plist>
        """
        try contents.write(to: dir.appendingPathComponent("contents.plist"),
                           atomically: true, encoding: .utf8)
    }

    /// Extracts every unicode-mapped glyph from the font and writes it to the
    /// specified layer. Returns the number of glyphs written. Uses the font's
    /// own PostScript glyph names when available (via CGFont), falling back to
    /// `uni{HEX}` for anything unnamed.
    /// - Parameter components: glyph index → composite structure, or nil to
    ///   flatten. Passed nil for variable-font masters on purpose: `gvar`
    ///   shifts component offsets per instance, and this reader only sees the
    ///   default `glyf`, so reusing those offsets would misplace every accent
    ///   in every non-default master. Flattened outlines are at least correct.
    private static func writeAllGlyphs(to ufo: URL, layerName: String, dirName: String,
                                        font: CTFont, upm: Int,
                                        components: [Int: [GlyfComponents.Component]]? = nil
    ) throws -> Int {
        let fm = FileManager.default
        let dir = ufo.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let cgFont = CTFontCopyGraphicsFont(font, nil)
        let charSet = CTFontCopyCharacterSet(font) as CharacterSet

        struct GlyphRecord {
            var name: String
            var unicodes: [UInt32]
            var advance: Int
            var path: CGPath?
        }

        // Glyph index → record, keyed by CGGlyph so we fold duplicate unicodes.
        var byGlyph: [CGGlyph: GlyphRecord] = [:]

        // Pass 1 — unicode coverage only. This walk exists to learn which
        // scalars map to which glyph; it is NOT the list of glyphs to export.
        //
        // It used to be both, and that silently dropped every glyph reachable
        // only through GSUB — stylistic alternates, ligatures, small caps. On
        // a 657-glyph variable font it exported 517, losing 140 of exactly the
        // glyphs a designer forking a typeface would care about.
        var unicodesByGlyph: [CGGlyph: [UInt32]] = [:]
        for plane: UInt32 in 0...16 {
            let start = plane << 16
            let end   = start + 0xFFFF
            for code in start...end {
                guard let scalar = Unicode.Scalar(code),
                      charSet.contains(scalar) else { continue }
                var utf16Pair: [UniChar] = []
                if code <= 0xFFFF {
                    utf16Pair = [UniChar(code)]
                } else {
                    let v = code - 0x10000
                    utf16Pair = [UniChar(0xD800 + (v >> 10)),
                                 UniChar(0xDC00 + (v & 0x3FF))]
                }
                var glyphs = Array<CGGlyph>(repeating: 0, count: utf16Pair.count)
                let ok = CTFontGetGlyphsForCharacters(font, utf16Pair, &glyphs, utf16Pair.count)
                guard ok, let glyph = glyphs.first, glyph != 0 else { continue }

                unicodesByGlyph[glyph, default: []].append(code)
            }
        }

        // Pass 2 — every glyph in the font, by index. `.notdef` is glyph 0, so
        // it comes along for free.
        let totalGlyphs = CTFontGetGlyphCount(font)
        for gid in 0..<totalGlyphs {
            let glyph = CGGlyph(gid)
            let unicodes = unicodesByGlyph[glyph] ?? []
            var adv = CGSize.zero
            var g = glyph
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
            byGlyph[glyph] = GlyphRecord(
                name: preferredName(for: glyph, cgFont: cgFont,
                                    unicode: unicodes.first, gid: gid),
                unicodes: unicodes,
                advance: Int(adv.width.rounded()),
                path: CTFontCreatePathForGlyph(font, glyph, nil)
            )
        }

        // De-duplicate names — UFO filenames must be unique after casefolding.
        var seen = Set<String>()
        var finalRecords: [(glyph: CGGlyph, rec: GlyphRecord)] = []
        for (g, var r) in byGlyph.sorted(by: { $0.key < $1.key }) {
            var base = r.name
            var tries = 0
            while seen.contains(base.lowercased()) {
                tries += 1
                base = "\(r.name)_\(tries)"
            }
            r.name = base
            seen.insert(base.lowercased())
            finalRecords.append((g, r))
        }

        // Components reference other glyphs BY NAME, so the (deduplicated)
        // names have to exist before any glif is written.
        var nameByGid: [Int: String] = [:]
        for (g, r) in finalRecords { nameByGid[Int(g)] = r.name }

        // Write each .glif.
        var contentsMap: [(String, String)] = []
        for (glyph, rec) in finalRecords {
            let fileName = glifFileName(for: rec.name) + ".glif"
            let url = dir.appendingPathComponent(fileName)
            let comps: [GlifComponent] = (components?[Int(glyph)] ?? []).compactMap { c in
                guard let base = nameByGid[c.glyphIndex] else { return nil }
                return GlifComponent(base: base, dx: c.dx, dy: c.dy,
                                     xScale: c.xScale, s01: c.scale01,
                                     s10: c.scale10, yScale: c.yScale)
            }
            let glif = buildGlif(name: rec.name, unicodes: rec.unicodes,
                                 advance: rec.advance,
                                 path: comps.isEmpty ? rec.path : nil,
                                 components: comps,
                                 layerHint: layerName)
            try glif.write(to: url, atomically: true, encoding: .utf8)
            contentsMap.append((rec.name, fileName))
        }

        // contents.plist
        var body = ""
        for (name, file) in contentsMap {
            body += "\n  <key>\(xmlEscape(name))</key>\n  <string>\(xmlEscape(file))</string>"
        }
        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>\(body)
        </dict>
        </plist>
        """
        try contents.write(to: dir.appendingPathComponent("contents.plist"),
                           atomically: true, encoding: .utf8)

        _ = layerName  // (consumed by caller via writeLayerContents)
        lastNameByGid = nameByGid
        return finalRecords.count
    }

    /// Glyph names from the most recent `writeAllGlyphs`, so `writeKerning`
    /// can emit pairs by name. UFO kerning is keyed by glyph NAME, not index,
    /// and the names are only final after deduplication.
    private static var lastNameByGid: [Int: String] = [:]

    /// Writes `kerning.plist` from whichever source has pairs — legacy `kern`
    /// first, then GPOS. Skipped entirely when neither yields anything, since
    /// an empty kerning.plist is just noise in the diff.
    private static func writeKerning(to ufo: URL, font: CTFont) throws -> Int {
        let names = lastNameByGid
        guard !names.isEmpty else { return 0 }

        var flat: [(CGGlyph, CGGlyph, Int)] = KernReader.read(font: font)
            .map { ($0.left, $0.right, $0.value) }
        if flat.isEmpty {
            flat = GPOSKerning.read(font: font).pairs.map { ($0.left, $0.right, $0.value) }
        }
        guard !flat.isEmpty else { return 0 }

        var grouped: [String: [(String, Int)]] = [:]
        for (l, r, v) in flat {
            guard v != 0,
                  let ln = names[Int(l)], let rn = names[Int(r)] else { continue }
            grouped[ln, default: []].append((rn, v))
        }
        guard !grouped.isEmpty else { return 0 }

        var body = ""
        var count = 0
        for (first, seconds) in grouped.sorted(by: { $0.key < $1.key }) {
            body += "\n  <key>\(xmlEscape(first))</key>\n  <dict>"
            for (second, value) in seconds.sorted(by: { $0.0 < $1.0 }) {
                body += "\n    <key>\(xmlEscape(second))</key>\n    <integer>\(value)</integer>"
                count += 1
            }
            body += "\n  </dict>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>\(body)
        </dict>
        </plist>
        """
        try xml.write(to: ufo.appendingPathComponent("kerning.plist"),
                      atomically: true, encoding: .utf8)
        return count
    }

    private static func writeLayerContents(to ufo: URL, layers: [(String, String)]) throws {
        var body = ""
        for (name, dir) in layers {
            body += "\n  <array>\n    <string>\(xmlEscape(name))</string>\n    <string>\(xmlEscape(dir))</string>\n  </array>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>\(body)
        </array>
        </plist>
        """
        try xml.write(to: ufo.appendingPathComponent("layercontents.plist"),
                      atomically: true, encoding: .utf8)
    }

    // MARK: - Glif builder

    struct GlifComponent {
        let base: String
        let dx: Double, dy: Double
        let xScale: Double, s01: Double, s10: Double, yScale: Double
    }

    private static func buildGlif(name: String, unicodes: [UInt32], advance: Int,
                                   path: CGPath?, components: [GlifComponent] = [],
                                   layerHint: String) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <glyph name="\(xmlEscape(name))" format="2">
          <advance width="\(advance)"/>
        """
        for u in unicodes {
            s += "\n  <unicode hex=\"\(String(format: "%04X", u))\"/>"
        }
        if !components.isEmpty {
            // A composite: reference the base glyphs instead of baking their
            // outlines in, so editing "A" still updates "Á À Â Ä".
            s += "\n  <outline>"
            for c in components {
                s += "\n    <component base=\"\(xmlEscape(c.base))\""
                if c.dx != 0 { s += " xOffset=\"\(trimmed(c.dx))\"" }
                if c.dy != 0 { s += " yOffset=\"\(trimmed(c.dy))\"" }
                if c.xScale != 1 { s += " xScale=\"\(trimmed(c.xScale))\"" }
                if c.yScale != 1 { s += " yScale=\"\(trimmed(c.yScale))\"" }
                if c.s01 != 0 { s += " xyScale=\"\(trimmed(c.s01))\"" }
                if c.s10 != 0 { s += " yxScale=\"\(trimmed(c.s10))\"" }
                s += "/>"
            }
            s += "\n  </outline>"
        } else if let p = path, !p.isEmpty {
            s += "\n  <outline>"
            s += pathToGlifContours(p)
            s += "\n  </outline>"
        }
        s += "\n</glyph>\n"
        return s
    }

    /// Whole numbers without a trailing ".0" — glif attributes read better and
    /// diff more cleanly that way.
    private static func trimmed(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.4g", d)
    }

    /// Converts a CGPath into UFO GLIF `<contour>` XML. Handles all CGPath
    /// element types: moveto / lineto / quad / cubic / close. Quadratic
    /// curves become `qcurve`, cubic become `curve` per UFO semantics.
    private static func pathToGlifContours(_ path: CGPath) -> String {
        var contours: [[String]] = [[]]
        var hasOpen: Bool = false

        func flushCloseIfNeeded() {
            if hasOpen { contours.append([]) }
            hasOpen = false
        }

        path.applyWithBlock { elPtr in
            let el = elPtr.pointee
            switch el.type {
            case .moveToPoint:
                flushCloseIfNeeded()
                let p = el.points[0]
                contours[contours.count - 1].append(point(p, type: "move"))
                hasOpen = true
            case .addLineToPoint:
                let p = el.points[0]
                contours[contours.count - 1].append(point(p, type: "line"))
            case .addQuadCurveToPoint:
                // control, end
                let c  = el.points[0]
                let p  = el.points[1]
                contours[contours.count - 1].append(point(c,  type: "offcurve"))
                contours[contours.count - 1].append(point(p,  type: "qcurve"))
            case .addCurveToPoint:
                // control1, control2, end
                let c1 = el.points[0]
                let c2 = el.points[1]
                let p  = el.points[2]
                contours[contours.count - 1].append(point(c1, type: "offcurve"))
                contours[contours.count - 1].append(point(c2, type: "offcurve"))
                contours[contours.count - 1].append(point(p,  type: "curve"))
            case .closeSubpath:
                // UFO closed contours don't repeat the start point; the first
                // point becomes the "last" in display. No-op here besides
                // marking the contour as closed (which is implicit — the
                // presence of curves and the absence of a lone "move" at the
                // end does it). Glyphs/RoboFont both handle this correctly.
                hasOpen = false
            @unknown default:
                break
            }
        }

        var xml = ""
        for c in contours where !c.isEmpty {
            xml += "\n    <contour>"
            for p in c { xml += "\n      \(p)" }
            xml += "\n    </contour>"
        }
        return xml
    }

    private static func point(_ p: CGPoint, type: String) -> String {
        let xs = shortNum(p.x)
        let ys = shortNum(p.y)
        if type == "offcurve" {
            return "<point x=\"\(xs)\" y=\"\(ys)\"/>"
        } else {
            return "<point x=\"\(xs)\" y=\"\(ys)\" type=\"\(type)\"/>"
        }
    }

    private static func shortNum(_ v: CGFloat) -> String {
        // UFO accepts integers and reals. Use integer when exact; otherwise
        // two decimal places, trimmed.
        let rounded = (v * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        } else {
            var s = String(format: "%.2f", Double(rounded))
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
    }

    // MARK: - Name + path helpers

    /// The font's own glyph name where it has one. `unicode` is now optional
    /// because we export unmapped glyphs too, and those have no scalar to name
    /// themselves after — they fall back to their glyph index.
    private static func preferredName(for glyph: CGGlyph, cgFont: CGFont,
                                      unicode: UInt32?, gid: Int) -> String {
        if let cf = cgFont.name(for: glyph) as String?, !cf.isEmpty { return cf }
        return fallbackName(unicode: unicode, gid: gid)
    }

    private static func fallbackName(unicode: UInt32?, gid: Int) -> String {
        guard let u = unicode else { return String(format: "glyph%05d", gid) }
        return u <= 0xFFFF ? String(format: "uni%04X", u) : String(format: "u%04X", u)
    }

    /// UFO requires glyph filenames to be case-insensitive unique on HFS+.
    /// The spec's rule: uppercase letter → prepend `_`. (This is the minimum
    /// for preventing collisions between 'A.glif' and 'a.glif'.)
    private static func glifFileName(for name: String) -> String {
        var out = ""
        for ch in name {
            if ch.isLetter && ch.isUppercase {
                out.append("_")
                out.append(ch)
            } else {
                out.append(ch)
            }
        }
        // Replace filesystem-hostile chars.
        return out.replacingOccurrences(of: "/", with: "_")
                  .replacingOccurrences(of: ":", with: "_")
    }

    private static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|\u{0}")
        return String(name.unicodeScalars.map {
            bad.contains($0) ? "_" : Character($0)
        })
    }

    // MARK: - Plist entry helpers

    private static func entry(_ key: String, string: String) -> String {
        "\n  <key>\(xmlEscape(key))</key>\n  <string>\(xmlEscape(string))</string>"
    }
    private static func entry(_ key: String, integer: Int) -> String {
        "\n  <key>\(xmlEscape(key))</key>\n  <integer>\(integer)</integer>"
    }
    private static func entry(_ key: String, real: Double) -> String {
        "\n  <key>\(xmlEscape(key))</key>\n  <real>\(real)</real>"
    }

    private static func xmlString(_ s: String) -> String { "<string>\(xmlEscape(s))</string>" }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Raw table reads

    /// Reads the `post` table's italicAngle field (16.16 fixed point,
    /// offset 4). Returns nil if the table is missing or malformed.
    private static func readItalicAngle(font: CTFont) -> Double? {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTablePost), [])
                as Data?, data.count >= 8 else { return nil }
        // 16.16 fixed: signed 32-bit integer divided by 65536.
        let raw = Int32(bigEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: Int32.self)
        })
        return Double(raw) / 65536.0
    }

    /// Parse "Version 1.234" or "1.234" → (1, 234). Defaults to (1, 0).
    private static func parseVersion(_ s: String) -> (Int, Int) {
        let cleaned = s.replacingOccurrences(of: "Version", with: "",
                                              options: [.caseInsensitive])
                       .trimmingCharacters(in: .whitespaces)
        let head = cleaned.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? ""
        let parts = head.split(separator: ".")
        let major = Int(parts.first ?? "1") ?? 1
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (major, minor)
    }

    // MARK: - Variable font: named instances via fvar

    /// A single named instance parsed from the `fvar` table.
    struct NamedInstance {
        /// Axis tag → value at this instance (e.g. ["wght": 700, "wdth": 100]).
        var coordinates: [UInt32: Double]
    }

    /// Parses the `fvar` table to enumerate named instances. Returns [] for
    /// non-variable fonts or if the table is missing.
    static func readNamedInstances(item: FontItem) -> [NamedInstance] {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL)
                as? [CTFontDescriptor],
              let desc = descs.first(where: {
                  (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == item.postScriptName
              }) ?? descs.first
        else { return [] }
        let font = CTFontCreateWithFontDescriptor(desc, 16, nil)
        return readNamedInstances(font: font)
    }

    private static func readNamedInstances(font: CTFont) -> [NamedInstance] {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableFvar), [])
                as Data?, data.count >= 16 else { return [] }

        // fvar header: major(2) minor(2) axesArrayOffset(2) reserved(2)
        //              axisCount(2) axisSize(2) instanceCount(2) instanceSize(2)
        let axisCount     = readU16BE(data, at: 8)
        let axisSize      = readU16BE(data, at: 10)
        let instanceCount = readU16BE(data, at: 12)
        let instanceSize  = readU16BE(data, at: 14)

        // Read axis tags in table order (this is the order fvar instances
        // pack their coordinates in).
        var axisTags: [UInt32] = []
        var off = 16
        for _ in 0..<Int(axisCount) {
            axisTags.append(readU32BE(data, at: off))
            off += Int(axisSize)
        }

        var instances: [NamedInstance] = []
        for _ in 0..<Int(instanceCount) {
            var coords: [UInt32: Double] = [:]
            for a in 0..<Int(axisCount) {
                let raw = readI32BE(data, at: off + 4 + a * 4)  // skip subfamilyNameID + flags
                coords[axisTags[a]] = Double(raw) / 65536.0
            }
            instances.append(NamedInstance(coordinates: coords))
            off += Int(instanceSize)
        }
        return instances
    }

    private static func readU16BE(_ d: Data, at o: Int) -> UInt16 {
        UInt16(bigEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) })
    }
    private static func readU32BE(_ d: Data, at o: Int) -> UInt32 {
        UInt32(bigEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) })
    }
    private static func readI32BE(_ d: Data, at o: Int) -> Int32 {
        Int32(bigEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) })
    }

    private static func tagString(_ tag: UInt32) -> String {
        let b0 = UInt8((tag >> 24) & 0xFF)
        let b1 = UInt8((tag >> 16) & 0xFF)
        let b2 = UInt8((tag >>  8) & 0xFF)
        let b3 = UInt8( tag        & 0xFF)
        return String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? "????"
    }

    // MARK: - Designspace export (variable font)

    /// Explodes a variable font into one UFO per named instance + a
    /// `.designspace` file binding them. If the font has no named instances,
    /// we synthesize masters at each axis's min + default + max.
    static func exportDesignspaceFromVariable(
        item: FontItem, to targetDir: URL, options: Options
    ) throws -> DesignspaceReport {
        guard item.isVariable else {
            throw ExportError.writeFailed("This font is not variable — nothing to explode.")
        }
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL)
                as? [CTFontDescriptor],
              let baseDesc = descs.first(where: {
                  (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == item.postScriptName
              }) ?? descs.first
        else { throw ExportError.descriptorUnavailable }

        let probe = CTFontCreateWithFontDescriptor(baseDesc, 16, nil)
        let upm   = max(1, Int(CTFontGetUnitsPerEm(probe)))

        // Figure out which masters to produce.
        var instances = readNamedInstances(font: probe)
        if instances.isEmpty {
            // Synthesize: one master at each of min / default / max per axis,
            // with other axes at their defaults.
            for axis in item.variationAxes {
                for val in [axis.minValue, axis.defaultValue, axis.maxValue] {
                    var coords: [UInt32: Double] = [:]
                    for other in item.variationAxes {
                        coords[other.tag] = (other.tag == axis.tag)
                            ? val : other.defaultValue
                    }
                    instances.append(NamedInstance(coordinates: coords))
                }
            }
        }

        let familyBase = sanitize(item.familyName.isEmpty ? item.postScriptName : item.familyName)
        let dsFolder = targetDir.appendingPathComponent(familyBase + ".designspace-output", isDirectory: true)
        if FileManager.default.fileExists(atPath: dsFolder.path) {
            throw ExportError.alreadyExists(dsFolder)
        }
        try FileManager.default.createDirectory(at: dsFolder, withIntermediateDirectories: true)

        // Write one UFO per instance.
        var ufoURLs: [URL] = []
        var sources: [(filename: String, styleName: String, location: [UInt32: Double])] = []
        for (i, instance) in instances.enumerated() {
            // Apply variation to descriptor.
            var varDict: [NSNumber: NSNumber] = [:]
            for (tag, value) in instance.coordinates {
                varDict[NSNumber(value: tag)] = NSNumber(value: value)
            }
            let instanceDesc = CTFontDescriptorCreateCopyWithAttributes(
                baseDesc,
                [kCTFontVariationAttribute: varDict as CFDictionary] as CFDictionary
            )
            let instanceFont = CTFontCreateWithFontDescriptor(instanceDesc, CGFloat(upm), nil)
            let styleName = (CTFontCopyName(instanceFont, kCTFontStyleNameKey) as String?)
                ?? "Master\(i + 1)"

            let ufoName = "\(familyBase)-\(sanitize(styleName))-\(i).ufo"
            let ufoURL = dsFolder.appendingPathComponent(ufoName, isDirectory: true)
            try FileManager.default.createDirectory(at: ufoURL, withIntermediateDirectories: true)

            // Synthesise a FontItem-ish payload for the instance. We reuse
            // the master item's identity fields but the instance's metrics.
            var instanceItem = item
            instanceItem = FontItem(
                id: item.id + "-i\(i)",
                fileURL: item.fileURL,
                postScriptName: item.postScriptName + "-" + sanitize(styleName),
                familyName: item.familyName,
                styleName: styleName,
                displayName: "\(item.familyName) \(styleName)",
                weight: item.weight, width: item.width, slant: item.slant,
                isItalic: item.isItalic, isMonospaced: item.isMonospaced,
                isBold: item.isBold, format: item.formatKind,
                categories: item.categories, moods: item.moods,
                glyphCount: item.glyphCount, fileSize: item.fileSize,
                dateAdded: item.dateAdded, panose: item.panose,
                variationAxes: [],          // flattened instance: no axes
                foundry: item.foundry
            )

            try writeMetainfo(to: ufoURL)
            try writeFontInfo(to: ufoURL, item: instanceItem, font: instanceFont,
                              upm: upm, options: options)

            switch options.glyphMode {
            case .empty:
                try writeEmptyLayer(to: ufoURL, upm: upm)
                try writeLayerContents(to: ufoURL, layers: [("public.default", "glyphs")])
            case .full:
                _ = try writeAllGlyphs(to: ufoURL, layerName: "public.default",
                                       dirName: "glyphs", font: instanceFont, upm: upm)
                try writeLayerContents(to: ufoURL, layers: [("public.default", "glyphs")])
            case .background:
                try writeEmptyLayer(to: ufoURL, upm: upm)
                _ = try writeAllGlyphs(to: ufoURL, layerName: "public.background",
                                       dirName: "glyphs.background", font: instanceFont, upm: upm)
                try writeLayerContents(to: ufoURL, layers: [
                    ("public.default", "glyphs"),
                    ("public.background", "glyphs.background")
                ])
            }

            ufoURLs.append(ufoURL)
            sources.append((ufoName, styleName, instance.coordinates))
        }

        // Write the .designspace file.
        let axes: [(tag: String, name: String, min: Double, def: Double, max: Double)] =
            item.variationAxes.map { ax in
                (tagString(ax.tag), ax.name, ax.minValue, ax.defaultValue, ax.maxValue)
            }
        let dsURL = dsFolder.appendingPathComponent(familyBase + ".designspace")
        try writeDesignspace(to: dsURL, axes: axes, sources: sources)

        return DesignspaceReport(outputURL: dsURL, ufoURLs: ufoURLs, axes: axes)
    }

    // MARK: - Designspace export (multiple static styles)

    /// Treats a pile of static-style items (one family, multiple weights/widths)
    /// as masters. We infer a single Weight axis from each item's `weight`
    /// trait (CT's -1..1 range is mapped to 100..900 for designspace).
    /// For richer axis handling the user can edit the designspace afterward.
    static func exportDesignspaceFromStatics(
        items: [FontItem], to targetDir: URL, options: Options
    ) throws -> DesignspaceReport {
        guard !items.isEmpty else {
            throw ExportError.writeFailed("No fonts selected.")
        }
        let familyBase = sanitize(items[0].familyName.isEmpty
                                  ? items[0].postScriptName
                                  : items[0].familyName)
        let dsFolder = targetDir.appendingPathComponent(familyBase + ".designspace-output", isDirectory: true)
        if FileManager.default.fileExists(atPath: dsFolder.path) {
            throw ExportError.alreadyExists(dsFolder)
        }
        try FileManager.default.createDirectory(at: dsFolder, withIntermediateDirectories: true)

        var ufoURLs: [URL] = []
        var sources: [(filename: String, styleName: String, location: [UInt32: Double])] = []
        // CT weight trait (-1..1) → designspace weight (100..900). Roughly:
        //   -1 → 100, 0 → 400, +1 → 900.
        func ctWeightToDS(_ w: Double) -> Double {
            let normalized = (w + 1.0) / 2.0                // 0..1
            return 100 + normalized * 800                    // 100..900
        }
        let wghtTag: UInt32 = 0x77676874  // "wght"

        for (i, item) in items.enumerated() {
            guard let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL)
                    as? [CTFontDescriptor],
                  let desc = descs.first(where: {
                      (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == item.postScriptName
                  }) ?? descs.first
            else { continue }
            let probe = CTFontCreateWithFontDescriptor(desc, 16, nil)
            let upm = max(1, Int(CTFontGetUnitsPerEm(probe)))
            let font = CTFontCreateWithFontDescriptor(desc, CGFloat(upm), nil)

            let ufoName = "\(familyBase)-\(sanitize(item.styleName))-\(i).ufo"
            let ufoURL = dsFolder.appendingPathComponent(ufoName, isDirectory: true)
            try FileManager.default.createDirectory(at: ufoURL, withIntermediateDirectories: true)
            try writeMetainfo(to: ufoURL)
            try writeFontInfo(to: ufoURL, item: item, font: font, upm: upm, options: options)

            switch options.glyphMode {
            case .empty:
                try writeEmptyLayer(to: ufoURL, upm: upm)
                try writeLayerContents(to: ufoURL, layers: [("public.default", "glyphs")])
            case .full:
                _ = try writeAllGlyphs(to: ufoURL, layerName: "public.default",
                                       dirName: "glyphs", font: font, upm: upm)
                try writeLayerContents(to: ufoURL, layers: [("public.default", "glyphs")])
            case .background:
                try writeEmptyLayer(to: ufoURL, upm: upm)
                _ = try writeAllGlyphs(to: ufoURL, layerName: "public.background",
                                       dirName: "glyphs.background", font: font, upm: upm)
                try writeLayerContents(to: ufoURL, layers: [
                    ("public.default", "glyphs"),
                    ("public.background", "glyphs.background")
                ])
            }

            ufoURLs.append(ufoURL)
            sources.append((ufoName, item.styleName,
                            [wghtTag: ctWeightToDS(item.weight)]))
        }

        let weights = sources.map { $0.location[wghtTag] ?? 400 }
        let axes: [(tag: String, name: String, min: Double, def: Double, max: Double)] = [
            (tag: "wght", name: "Weight",
             min: weights.min() ?? 100, def: 400, max: weights.max() ?? 900)
        ]
        let dsURL = dsFolder.appendingPathComponent(familyBase + ".designspace")
        try writeDesignspace(to: dsURL, axes: axes, sources: sources)

        return DesignspaceReport(outputURL: dsURL, ufoURLs: ufoURLs, axes: axes)
    }

    // MARK: - Designspace XML writer

    private static func writeDesignspace(
        to url: URL,
        axes: [(tag: String, name: String, min: Double, def: Double, max: Double)],
        sources: [(filename: String, styleName: String, location: [UInt32: Double])]
    ) throws {
        // axis-tag → name lookup for <dimension name="…" xvalue="…"/>.
        let tagToName = Dictionary(uniqueKeysWithValues: axes.map {
            (tagUInt32(from: $0.tag), $0.name)
        })

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <designspace format="4.1">
          <axes>
        """
        for a in axes {
            xml += "\n    <axis tag=\"\(xmlEscape(a.tag))\" name=\"\(xmlEscape(a.name))\""
            xml += " minimum=\"\(shortDouble(a.min))\" maximum=\"\(shortDouble(a.max))\""
            xml += " default=\"\(shortDouble(a.def))\"/>"
        }
        xml += "\n  </axes>\n  <sources>"
        for s in sources {
            xml += "\n    <source filename=\"\(xmlEscape(s.filename))\" name=\"\(xmlEscape(s.styleName))\">"
            xml += "\n      <location>"
            for (tag, value) in s.location.sorted(by: { $0.key < $1.key }) {
                let name = tagToName[tag] ?? tagString(tag)
                xml += "\n        <dimension name=\"\(xmlEscape(name))\" xvalue=\"\(shortDouble(value))\"/>"
            }
            xml += "\n      </location>"
            xml += "\n    </source>"
        }
        xml += "\n  </sources>\n</designspace>\n"
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func tagUInt32(from s: String) -> UInt32 {
        var result: UInt32 = 0
        let bytes = Array(s.utf8.prefix(4))
        for b in bytes { result = (result << 8) | UInt32(b) }
        // Pad if shorter than 4 bytes.
        for _ in bytes.count..<4 { result = (result << 8) | UInt32(0x20) }
        return result
    }

    private static func shortDouble(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
