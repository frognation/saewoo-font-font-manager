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
    let category: FontCategory    // auto-classified
    let moods: [FontMood]         // auto-tagged
    let glyphCount: Int
    let fileSize: Int64
    let dateAdded: Date
    let panose: [Int]             // 10 bytes (0-255) or empty

    var familyKey: String { familyName.lowercased() }
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
