import Foundation

/// Classifies font files by *where* they live and *how safe they are to delete*.
///
/// Three concerns that must not be conflated:
///
/// 1. **Location** — is the file in `/System/Library/Fonts`, `/Library/Fonts`,
///    `~/Library/Fonts`, or a user-added custom scan folder?
/// 2. **Deletability** — `/System/Library/Fonts` is SIP-protected; the OS blocks
///    writes even with admin rights. `/Library/Fonts` needs admin auth but is
///    deletable. `~/Library/Fonts` and custom folders are freely deletable.
/// 3. **Essentialness** — some fonts (SF Pro, Helvetica, Menlo, Apple Color
///    Emoji, Hiragino, PingFang …) are required for macOS UI rendering. Even
///    when *technically* deletable, removing them breaks menus, web pages,
///    Korean/Japanese/Chinese rendering, emoji in messages, etc.
///
/// The "prefer removing from system folders" strategy needs all three: it
/// targets location (1), only touches deletable paths (2), and always skips
/// essentials (3).
enum SystemFontGuard {

    // MARK: - Location

    enum Location {
        case systemProtected   // /System/Library/Fonts — SIP, never writable
        case systemShared      // /Library/Fonts        — admin-writable
        case userFonts         // ~/Library/Fonts       — freely writable
        case userCustom        // anywhere else the user added as a scan path
    }

    static func location(of url: URL) -> Location {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/System/Library/") { return .systemProtected }
        if path.hasPrefix("/Library/Fonts") { return .systemShared }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/Fonts") { return .userFonts }
        return .userCustom
    }

    /// Whether the file lives under any system-owned font directory. Used as
    /// the "prefer to remove" signal for the system-cleanup strategy.
    static func isInSystemFolder(_ url: URL) -> Bool {
        switch location(of: url) {
        case .systemProtected, .systemShared: return true
        case .userFonts, .userCustom: return false
        }
    }

    /// Whether the file lives in a location the user controls (and can safely
    /// delete without admin prompts).
    static func isInUserFolder(_ url: URL) -> Bool {
        switch location(of: url) {
        case .userFonts, .userCustom: return true
        case .systemProtected, .systemShared: return false
        }
    }

    // MARK: - Deletability

    /// Can this file physically be deleted? `/System/Library/Fonts` is locked
    /// by SIP; Finder/Terminal alike will fail.
    static func isDeletable(_ url: URL) -> Bool {
        location(of: url) != .systemProtected
    }

    // MARK: - Essentialness

    /// Any font whose PostScript or family name matches a known-critical
    /// identifier that macOS or major apps depend on for rendering.
    /// Matching is case-insensitive prefix — "SFPro" matches "SFProDisplay-Bold".
    static func isEssential(postScriptName: String, familyName: String) -> Bool {
        let ps = postScriptName.lowercased()
        let fam = familyName.lowercased()
        // Check both, because some fonts have idiosyncratic PS names.
        for pattern in essentialPatterns {
            if ps.hasPrefix(pattern) || fam.hasPrefix(pattern) { return true }
        }
        // Exact matches for single-word families (Symbol, Keyboard, etc.)
        for exact in essentialExactFamilies {
            if fam == exact { return true }
        }
        return false
    }

    /// Convenience overload for `FontItem` callers.
    static func isEssential(_ item: FontItem) -> Bool {
        isEssential(postScriptName: item.postScriptName, familyName: item.familyName)
    }

    /// Short label explaining why a file is protected — surfaced in the UI.
    static func protectionReason(for item: FontItem) -> String? {
        if location(of: item.fileURL) == .systemProtected {
            return "In /System/Library/Fonts — SIP protected, OS blocks deletion."
        }
        if isEssential(item) {
            return "Essential macOS system font — deleting it breaks UI rendering, menus, or language support."
        }
        return nil
    }

    static func isProtected(_ item: FontItem) -> Bool {
        protectionReason(for: item) != nil
    }

    // MARK: - Essential patterns
    //
    // This list is conservative: it's better to leave a font behind than to
    // brick a user's system menus or emoji rendering. When in doubt, add here.
    //
    // Sources: Apple's macOS Font Book "System" category, the `/System/Library/
    // Fonts` inventory across recent macOS releases, and Apple documentation
    // for language fallback fonts (CJK, Arabic, Thai, Devanagari).

    private static let essentialPatterns: [String] = [
        // Apple system UI typefaces
        "sfpro", "sfcompact", "sfmono", "sfarabic", "sfhebrew",
        "sfns", "newyork",

        // Core Latin fallbacks used throughout UI chrome
        "helvetica",           // Helvetica, Helvetica Neue, Helvetica Neue Desk UI
        "menlo", "monaco", "courier",
        "times", "geneva", "lucida",
        "arial",               // bundled legacy; web rendering falls back to it

        // Emoji / symbol fallbacks
        "apple color emoji", "applesymbols", "zapfdingbats", "symbol",
        "lastresort", "keyboard",

        // CJK — losing these breaks Korean/Japanese/Chinese across the whole OS
        "applesdgothicneo",    // Korean system
        "applegothic",         // Korean legacy
        "hiragino",            // Japanese (Sans/Mincho/Maru)
        "osaka",               // Japanese legacy
        "heiti", "songti", "kaiti", "yuanti",        // Chinese
        "pingfang",            // Chinese system (SC/TC/HK)
        "stheiti", "stsong", "stkaiti",              // Simplified Chinese legacy
        "libiansc", "hannotatesc", "hanzipensc",     // Apple CJK specialties

        // South/Southeast Asian — system language packs
        "devanagari", "gurmukhi", "gujarati", "tamil", "telugu",
        "kannada", "malayalam", "sinhala", "thai", "myanmar",
        "khmer", "lao", "tibetan",

        // RTL and near-Eastern
        "geeza", "alnile", "beirut", "baghdad", "damascus",
        "kefa", "kohinoor", "mshtakan", "muna", "sana",
        "farah", "nadeem", "waseem",

        // Cyrillic/Greek-focused system files
        "plantagenetcherokee",
    ]

    private static let essentialExactFamilies: Set<String> = [
        "symbol", "keyboard", "lastresort",
        "applesymbols", "apple color emoji",
        "noteworthy", "markerfelt",   // legacy handwriting bundled with macOS
    ]
}
