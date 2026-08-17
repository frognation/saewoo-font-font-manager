import Foundation

struct FontItem: Identifiable, Codable, Hashable {
    let id: String                // stable hash of fileURL + postScriptName
    let fileURL: URL
    let postScriptName: String
    let familyName: String
    let styleName: String         // "Regular", "Bold Italic" etc
    /// Only stored when the font's own full name differs from the derived
    /// "Family Style". For the vast majority of faces it matches, so keeping
    /// it nil avoids ~78 000 redundant heap strings.
    private let displayNameOverride: String?
    let weight: Double            // -1..1 (CT weight trait)
    let width: Double             // -1..1
    let slant: Double             // -1..1 (italic → positive)
    let isItalic: Bool
    let isMonospaced: Bool
    let isBold: Bool
    /// One byte instead of a heap-allocated String repeated across the library.
    let formatKind: FontFormat
    let categories: [FontCategory] // tags — a font can be both e.g. serif + monospace
    let moods: [FontMood]         // auto-tagged
    let glyphCount: Int
    let fileSize: Int64
    let dateAdded: Date
    let panose: [UInt8]           // 10 bytes (0-255) or empty
    let variationAxes: [VariationAxis]  // empty for non-variable fonts
    let foundry: String           // normalised type foundry / manufacturer name

    /// "Helvetica Neue Bold". Derived unless the font declared something else.
    var displayName: String { displayNameOverride ?? "\(familyName) \(styleName)" }
    /// Human-readable format, kept as a String for the views that display it.
    var format: String { formatKind.label }

    var familyKey: String { familyName.lowercased() }
    var isVariable: Bool { !variationAxes.isEmpty }
    var foundryKey: String { foundry.lowercased() }

    /// Preferred category for single-label UIs (e.g. list rows). Prefers a
    /// shape class (serif / sansSerif / display / handwriting / symbol) over
    /// an orthogonal property like monospace — "Courier" is a serif that
    /// happens to be monospaced, not a monospace that happens to be serif.
    var primaryCategory: FontCategory {
        let shapes: Set<FontCategory> = [.serif, .sansSerif, .display, .handwriting, .symbol]
        if let shape = categories.first(where: { shapes.contains($0) }) { return shape }
        return categories.first ?? .unknown
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileURL, postScriptName, familyName, styleName, displayName
        case weight, width, slant, isItalic, isMonospaced, isBold
        case format, categories, moods, glyphCount, fileSize, dateAdded, panose
        case variationAxes, foundry
    }

    /// Only used by the decoder to rehydrate pre-multi-category caches.
    private enum LegacyKeys: String, CodingKey { case category }

    init(id: String, fileURL: URL, postScriptName: String, familyName: String,
         styleName: String, displayName: String, weight: Double, width: Double,
         slant: Double, isItalic: Bool, isMonospaced: Bool, isBold: Bool,
         format: FontFormat, categories: [FontCategory], moods: [FontMood],
         glyphCount: Int, fileSize: Int64, dateAdded: Date, panose: [UInt8],
         variationAxes: [VariationAxis] = [], foundry: String = "Unknown") {
        self.id = id; self.fileURL = fileURL
        self.postScriptName = postScriptName; self.familyName = familyName
        self.styleName = styleName
        let derived = "\(familyName) \(styleName)"
        self.displayNameOverride = (displayName == derived) ? nil : displayName
        self.weight = weight; self.width = width; self.slant = slant
        self.isItalic = isItalic; self.isMonospaced = isMonospaced; self.isBold = isBold
        self.formatKind = format; self.categories = categories; self.moods = moods
        self.glyphCount = glyphCount; self.fileSize = fileSize
        self.dateAdded = dateAdded; self.panose = panose
        self.variationAxes = variationAxes
        self.foundry = foundry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.fileURL = try c.decode(URL.self, forKey: .fileURL)
        self.postScriptName = try c.decode(String.self, forKey: .postScriptName)
        let fam = try c.decode(String.self, forKey: .familyName)
        let sty = try c.decode(String.self, forKey: .styleName)
        self.familyName = fam
        self.styleName = sty
        // Older caches always wrote displayName; drop it when it's derivable.
        // `decodeIfPresent`, not `try?` — a caught throw per absent key costs
        // real time across 78 000 items.
        if let dn = try c.decodeIfPresent(String.self, forKey: .displayName) {
            self.displayNameOverride = (dn == "\(fam) \(sty)") ? nil : dn
        } else {
            self.displayNameOverride = nil
        }
        self.weight = try c.decode(Double.self, forKey: .weight)
        self.width = try c.decode(Double.self, forKey: .width)
        self.slant = try c.decode(Double.self, forKey: .slant)
        self.isItalic = try c.decode(Bool.self, forKey: .isItalic)
        self.isMonospaced = try c.decode(Bool.self, forKey: .isMonospaced)
        self.isBold = try c.decode(Bool.self, forKey: .isBold)
        // Accepts both the new short rawValue and the legacy human-readable label.
        let rawFormat = (try c.decodeIfPresent(String.self, forKey: .format)) ?? ""
        self.formatKind = FontFormat(rawValue: rawFormat) ?? FontFormat(legacyLabel: rawFormat)
        // Migration: old caches wrote a single `category`; new caches write `categories`.
        if let arr = try c.decodeIfPresent([FontCategory].self, forKey: .categories) {
            self.categories = arr
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
                .decode(FontCategory.self, forKey: .category)
            self.categories = legacy.map { [$0] } ?? [.unknown]
        }
        self.moods = try c.decode([FontMood].self, forKey: .moods)
        self.glyphCount = try c.decode(Int.self, forKey: .glyphCount)
        self.fileSize = try c.decode(Int64.self, forKey: .fileSize)
        self.dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        self.panose = (try c.decodeIfPresent([UInt8].self, forKey: .panose)) ?? []
        // New fields — tolerate older caches that lack them.
        self.variationAxes = (try c.decodeIfPresent([VariationAxis].self, forKey: .variationAxes)) ?? []
        self.foundry = (try c.decodeIfPresent(String.self, forKey: .foundry)) ?? "Unknown"
    }

    /// Explicit because two stored properties are written under different key
    /// names (`displayNameOverride` → `displayName`, `formatKind` → `format`),
    /// and the override is omitted entirely when it's derivable.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileURL, forKey: .fileURL)
        try c.encode(postScriptName, forKey: .postScriptName)
        try c.encode(familyName, forKey: .familyName)
        try c.encode(styleName, forKey: .styleName)
        try c.encodeIfPresent(displayNameOverride, forKey: .displayName)
        try c.encode(weight, forKey: .weight)
        try c.encode(width, forKey: .width)
        try c.encode(slant, forKey: .slant)
        try c.encode(isItalic, forKey: .isItalic)
        try c.encode(isMonospaced, forKey: .isMonospaced)
        try c.encode(isBold, forKey: .isBold)
        try c.encode(formatKind.rawValue, forKey: .format)
        try c.encode(categories, forKey: .categories)
        try c.encode(moods, forKey: .moods)
        try c.encode(glyphCount, forKey: .glyphCount)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(dateAdded, forKey: .dateAdded)
        try c.encode(panose, forKey: .panose)
        try c.encode(variationAxes, forKey: .variationAxes)
        try c.encode(foundry, forKey: .foundry)
    }
}

/// Font container format. Stored as a one-byte enum rather than a String —
/// the library repeats the same handful of labels across ~78 000 faces.
enum FontFormat: String, Codable, Hashable {
    case openTypePS, trueType, trueTypeCollection, openTypeCollection
    case datafork, woff, woff2, unknown

    var label: String {
        switch self {
        case .openTypePS:         return "OpenType PostScript"
        case .trueType:           return "TrueType"
        case .trueTypeCollection: return "TrueType Collection"
        case .openTypeCollection: return "OpenType Collection"
        case .datafork:           return "Datafork TrueType"
        case .woff:               return "WOFF"
        case .woff2:              return "WOFF2"
        case .unknown:            return "Unknown"
        }
    }

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "otf":   self = .openTypePS
        case "ttf":   self = .trueType
        case "ttc":   self = .trueTypeCollection
        case "otc":   self = .openTypeCollection
        case "dfont": self = .datafork
        case "woff":  self = .woff
        case "woff2": self = .woff2
        default:      self = .unknown
        }
    }

    /// Rehydrates caches written before this was an enum.
    init(legacyLabel: String) {
        switch legacyLabel {
        case "OpenType PostScript":  self = .openTypePS
        case "TrueType":             self = .trueType
        case "TrueType Collection":  self = .trueTypeCollection
        case "OpenType Collection":  self = .openTypeCollection
        case "Datafork TrueType":    self = .datafork
        case "WOFF":                 self = .woff
        case "WOFF2":                self = .woff2
        default:                     self = .unknown
        }
    }
}

/// A single OpenType/TrueType variation axis (e.g. "wght", "wdth", "opsz").
struct VariationAxis: Codable, Hashable, Identifiable {
    var id: UInt32 { tag }
    let tag: UInt32               // raw 4-char code packed into a UInt32
    let tagString: String         // "wght", "wdth", "opsz", "ital", "slnt", ...
    let name: String              // human-readable name from the font
    let minValue: Double
    let maxValue: Double
    let defaultValue: Double
    let isHidden: Bool

    var range: ClosedRange<Double> { minValue...maxValue }
}

enum FontCategory: String, Codable, CaseIterable, Identifiable {
    case serif, sansSerif, display, handwriting, monospace, symbol, unknown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .serif: return "Serif"
        case .sansSerif: return "Sans Serif"
        case .display: return "Display"
        case .handwriting: return "Handwriting"
        case .monospace: return "Monospace"
        case .symbol: return "Symbol"
        case .unknown: return "Uncategorized"
        }
    }
    var icon: String {
        switch self {
        case .serif: return "textformat.abc"
        case .sansSerif: return "textformat"
        case .display: return "textformat.size.larger"
        case .handwriting: return "pencil.and.scribble"
        case .monospace: return "chevron.left.forwardslash.chevron.right"
        case .symbol: return "asterisk"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum FontMood: String, Codable, CaseIterable, Identifiable {
    case elegant, modern, playful, technical, vintage, bold, minimal, decorative
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
