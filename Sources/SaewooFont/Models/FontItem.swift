import Foundation

struct FontItem: Identifiable, Codable, Hashable {
    let id: String                // stable hash of fileURL + postScriptName
    let fileURL: URL
    let postScriptName: String
    let familyName: String
    let styleName: String         // "Regular", "Bold Italic" etc
    let displayName: String       // "Helvetica Neue Bold"
    let weight: Double            // -1..1 (CT weight trait)
    let width: Double             // -1..1
    let slant: Double             // -1..1 (italic → positive)
    let isItalic: Bool
    let isMonospaced: Bool
    let isBold: Bool
    let format: String            // "OpenType PostScript", "TrueType", ...
    let categories: [FontCategory] // tags — a font can be both e.g. serif + monospace
    let moods: [FontMood]         // auto-tagged
    let glyphCount: Int
    let fileSize: Int64
    let dateAdded: Date
    let panose: [Int]             // 10 bytes (0-255) or empty
    let variationAxes: [VariationAxis]  // empty for non-variable fonts
    let foundry: String           // normalised type foundry / manufacturer name

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
         format: String, categories: [FontCategory], moods: [FontMood],
         glyphCount: Int, fileSize: Int64, dateAdded: Date, panose: [Int],
         variationAxes: [VariationAxis] = [], foundry: String = "Unknown") {
        self.id = id; self.fileURL = fileURL
        self.postScriptName = postScriptName; self.familyName = familyName
        self.styleName = styleName; self.displayName = displayName
        self.weight = weight; self.width = width; self.slant = slant
        self.isItalic = isItalic; self.isMonospaced = isMonospaced; self.isBold = isBold
        self.format = format; self.categories = categories; self.moods = moods
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
        self.familyName = try c.decode(String.self, forKey: .familyName)
        self.styleName = try c.decode(String.self, forKey: .styleName)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.weight = try c.decode(Double.self, forKey: .weight)
        self.width = try c.decode(Double.self, forKey: .width)
        self.slant = try c.decode(Double.self, forKey: .slant)
        self.isItalic = try c.decode(Bool.self, forKey: .isItalic)
        self.isMonospaced = try c.decode(Bool.self, forKey: .isMonospaced)
        self.isBold = try c.decode(Bool.self, forKey: .isBold)
        self.format = try c.decode(String.self, forKey: .format)
        // Migration: old caches wrote a single `category`; new caches write `categories`.
        if let arr = try? c.decode([FontCategory].self, forKey: .categories) {
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
        self.panose = try c.decode([Int].self, forKey: .panose)
        // New fields — tolerate older caches that lack them.
        self.variationAxes = (try? c.decode([VariationAxis].self, forKey: .variationAxes)) ?? []
        self.foundry = (try? c.decode(String.self, forKey: .foundry)) ?? "Unknown"
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
