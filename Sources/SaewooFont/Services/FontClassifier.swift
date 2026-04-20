import Foundation
import CoreText

/// Classifies a font into a high-level category + mood tags using:
///   (1) Core Text symbolic traits
///   (2) PANOSE bytes from OS/2 table
///   (3) Name-based heuristics (family + PS name tokens)
enum FontClassifier {

    static func classify(psName: String,
                         family: String,
                         style: String,
                         traits: CTFontSymbolicTraits,
                         weight: Double,
                         slant: Double,
                         panose: [Int]) -> (FontCategory, [FontMood]) {

        let tokens = tokenize("\(family) \(style) \(psName)")

        let category = categorize(traits: traits, tokens: tokens, panose: panose)
        let moods = moodTags(category: category, tokens: tokens, weight: weight, slant: slant, panose: panose)
        return (category, moods)
    }

    private static func categorize(traits: CTFontSymbolicTraits, tokens: Set<String>, panose: [Int]) -> FontCategory {
        // 1. Core Text symbolic traits + class mask.
        if traits.contains(.monoSpaceTrait) { return .monospace }

        // Class mask lives in the top 4 bits (shifted by kCTFontClassMaskShift = 28).
        let classValue = Int((traits.rawValue >> UInt32(kCTFontClassMaskShift)) & 0xF)
        switch classValue {
        case 1, 2, 3, 4, 5, 7: return .serif      // Old-style/Transitional/Modern/Clarendon/Slab/Freeform serif
        case 8: return .sansSerif
        case 9: return .display                   // Ornamentals
        case 10: return .handwriting              // Scripts
        case 12: return .symbol
        default: break
        }

        // 2. PANOSE family kind (byte 0): 2=Latin Text, 3=Script, 4=Decorative, 5=Pictorial/Symbol
        if panose.count >= 2 {
            switch panose[0] {
            case 3: return .handwriting
            case 4: return .display
            case 5: return .symbol
            case 2:
                // byte 1 = Serif Style. 11=Normal Sans, 12=Obtuse Sans, 13=Perp Sans, 14=Flared, 15=Rounded Sans
                if (11...15).contains(panose[1]) { return .sansSerif }
                if (2...10).contains(panose[1]) { return .serif }
            default: break
            }
        }

        // 3. Name-based fallbacks
        let sansHints: Set<String> = ["sans", "grotesk", "grotesque", "gothic", "neue", "helvetica", "arial", "roboto", "inter", "futura"]
        let serifHints: Set<String> = ["serif", "roman", "times", "georgia", "garamond", "caslon", "bodoni", "didot", "baskerville"]
        let displayHints: Set<String> = ["display", "poster", "deco", "headline", "black", "stencil", "condensed"]
        let scriptHints: Set<String> = ["script", "hand", "brush", "signature", "calligraphy", "italic", "cursive", "written"]
        let monoHints: Set<String> = ["mono", "code", "console", "courier", "terminal"]
        let symbolHints: Set<String> = ["symbol", "icon", "dingbat", "emoji", "ornament", "wingdings"]

        if tokens.isDisjoint(with: monoHints) == false { return .monospace }
        if tokens.isDisjoint(with: symbolHints) == false { return .symbol }
        if tokens.isDisjoint(with: scriptHints) == false { return .handwriting }
        if tokens.isDisjoint(with: sansHints) == false { return .sansSerif }
        if tokens.isDisjoint(with: serifHints) == false { return .serif }
        if tokens.isDisjoint(with: displayHints) == false { return .display }

        return .unknown
    }

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
