import Foundation
import CoreText

/// Classifies a font into one or more category tags + a set of mood tags.
///
/// Categories are now tag-like: a font can be **Serif + Monospace** (e.g.
/// Courier), or **Sans-Serif + Display** (e.g. an ultra-black poster sans),
/// or **Sans-Serif + Monospace** (e.g. Menlo). Monospace, Display and Symbol
/// are each added as additional tags when they apply — they don't replace
/// the base shape class.
enum FontClassifier {

    static func classify(psName: String,
                         family: String,
                         style: String,
                         traits: CTFontSymbolicTraits,
                         weight: Double,
                         slant: Double,
                         panose: [Int]) -> ([FontCategory], [FontMood]) {

        let tokens = tokenize("\(family) \(style) \(psName)")
        let categories = categorize(traits: traits, tokens: tokens, panose: panose)
        let primary = categories.first(where: {
            $0 != .monospace && $0 != .unknown
        }) ?? categories.first ?? .unknown
        let moods = moodTags(category: primary, tokens: tokens,
                             weight: weight, slant: slant, panose: panose)
        return (categories, moods)
    }

    /// Return all applicable categories for this font. Shape class (serif /
    /// sansSerif / display / handwriting / symbol) adds one tag; monospace
    /// adds an additional orthogonal tag if the traits or name say so.
    private static func categorize(traits: CTFontSymbolicTraits,
                                   tokens: Set<String>,
                                   panose: [Int]) -> [FontCategory] {
        var result: Set<FontCategory> = []

        // Orthogonal: monospace is independent of shape. Add it if traits say
        // so, OR if the name strongly suggests a coding font.
        if traits.contains(.monoSpaceTrait) { result.insert(.monospace) }
        if !tokens.isDisjoint(with: Self.monoHints) { result.insert(.monospace) }

        // Primary shape class from Core Text's stylistic class bits.
        let classValue = Int((traits.rawValue >> UInt32(kCTFontClassMaskShift)) & 0xF)
        switch classValue {
        case 1, 2, 3, 4, 5, 7: result.insert(.serif)
        case 8: result.insert(.sansSerif)
        case 9: result.insert(.display)
        case 10: result.insert(.handwriting)
        case 12: result.insert(.symbol)
        default: break
        }

        // PANOSE fill-in when shape wasn't obvious from traits.
        let hasShape = !result.isDisjoint(with: [.serif, .sansSerif, .display, .handwriting, .symbol])
        if !hasShape, panose.count >= 2 {
            switch panose[0] {
            case 3: result.insert(.handwriting)
            case 4: result.insert(.display)
            case 5: result.insert(.symbol)
            case 2:
                if (11...15).contains(panose[1]) { result.insert(.sansSerif) }
                else if (2...10).contains(panose[1]) { result.insert(.serif) }
            default: break
            }
        }

        // Name-token fill-in when neither traits nor PANOSE nailed a shape.
        let hasShape2 = !result.isDisjoint(with: [.serif, .sansSerif, .display, .handwriting, .symbol])
        if !hasShape2 {
            if !tokens.isDisjoint(with: Self.symbolHints) { result.insert(.symbol) }
            if !tokens.isDisjoint(with: Self.scriptHints) { result.insert(.handwriting) }
            if !tokens.isDisjoint(with: Self.sansHints)   { result.insert(.sansSerif) }
            if !tokens.isDisjoint(with: Self.serifHints)  { result.insert(.serif) }
        }

        // Display is an orthogonal tag too — add when name strongly hints at
        // it, regardless of whether we already picked a shape.
        if !tokens.isDisjoint(with: Self.displayHints) { result.insert(.display) }

        if result.isEmpty { result.insert(.unknown) }
        // Stable order — shape first, then monospace/display, then others.
        let preferred: [FontCategory] = [.serif, .sansSerif, .handwriting, .display, .monospace, .symbol, .unknown]
        return preferred.filter { result.contains($0) }
    }

    private static let sansHints:    Set<String> = ["sans", "grotesk", "grotesque", "gothic", "neue", "helvetica", "arial", "roboto", "inter", "futura"]
    private static let serifHints:   Set<String> = ["serif", "roman", "times", "georgia", "garamond", "caslon", "bodoni", "didot", "baskerville"]
    private static let displayHints: Set<String> = ["display", "poster", "deco", "headline", "black", "stencil", "condensed", "titling"]
    private static let scriptHints:  Set<String> = ["script", "hand", "brush", "signature", "calligraphy", "cursive", "written"]
    private static let monoHints:    Set<String> = ["mono", "code", "console", "courier", "terminal"]
    private static let symbolHints:  Set<String> = ["symbol", "icon", "dingbat", "emoji", "ornament", "wingdings"]

    private static func moodTags(category: FontCategory,
                                 tokens: Set<String>,
                                 weight: Double,
                                 slant: Double,
                                 panose: [Int]) -> [FontMood] {
        var moods: Set<FontMood> = []

        if weight >= 0.5 { moods.insert(.bold) }
        if abs(slant) > 0.02 && category != .handwriting { /* italic is style, not mood */ }

        if tokens.contains(where: { ["thin", "light", "hairline", "minimal", "simple", "clean"].contains($0) }) {
            moods.insert(.minimal)
        }
        if tokens.contains(where: { ["modern", "neue", "grotesk", "futura", "geometric", "neo"].contains($0) }) {
            moods.insert(.modern)
        }
        if tokens.contains(where: { ["elegant", "didot", "bodoni", "garamond", "classic", "refined"].contains($0) }) {
            moods.insert(.elegant)
        }
        if tokens.contains(where: { ["playful", "bubble", "cute", "comic", "round", "kids"].contains($0) }) {
            moods.insert(.playful)
        }
        if tokens.contains(where: { ["mono", "code", "console", "machine", "tech", "pixel", "digital"].contains($0) }) {
            moods.insert(.technical)
        }
        if tokens.contains(where: { ["vintage", "retro", "old", "western", "victorian", "antique"].contains($0) }) {
            moods.insert(.vintage)
        }
        if category == .display || tokens.contains(where: { ["deco", "ornament", "decorative", "fancy", "stencil", "poster"].contains($0) }) {
            moods.insert(.decorative)
        }

        if moods.isEmpty {
            switch category {
            case .serif: moods.insert(.elegant)
            case .sansSerif: moods.insert(.modern)
            case .handwriting: moods.insert(.playful)
            case .monospace: moods.insert(.technical)
            case .display: moods.insert(.decorative)
            default: break
            }
        }

        return Array(moods).sorted(by: { $0.rawValue < $1.rawValue })
    }

    private static func tokenize(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let split = lowered.split(whereSeparator: { !$0.isLetter })
        return Set(split.map(String.init))
    }
}
