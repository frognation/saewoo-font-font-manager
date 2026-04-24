import Foundation
import CoreText

/// A single family from Google Fonts — name, category, and the list of
/// variant keys ("400", "700", "400i", etc.) the family exposes.
struct GoogleFontFamily: Decodable, Identifiable, Hashable {
    var id: String { family }

    let family: String
    let category: String            // "SANS_SERIF" | "SERIF" | "DISPLAY" | "HANDWRITING" | "MONOSPACE"
    let variantKeys: [String]       // sorted e.g. ["100", "300", "400", "400i", "700"]
    let subsets: [String]?
    let popularity: Int?
    let lastModified: String?

    private enum CodingKeys: String, CodingKey {
        case family, category, fonts, subsets, popularity, lastModified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.family = try c.decode(String.self, forKey: .family)
        self.category = (try? c.decode(String.self, forKey: .category)) ?? "SANS_SERIF"
        if let fonts = try? c.decode([String: EmptyJSON].self, forKey: .fonts) {
            self.variantKeys = fonts.keys.sorted()
        } else {
            self.variantKeys = []
        }
        self.subsets = try? c.decode([String].self, forKey: .subsets)
        self.popularity = try? c.decode(Int.self, forKey: .popularity)
        self.lastModified = try? c.decode(String.self, forKey: .lastModified)
    }

    /// Human-friendly category string for UI.
    var niceCategory: String {
        switch category {
        case "SANS_SERIF":   return "Sans Serif"
        case "SERIF":        return "Serif"
        case "DISPLAY":      return "Display"
        case "HANDWRITING":  return "Handwriting"
        case "MONOSPACE":    return "Monospace"
        default:             return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var categoryFilterTag: String { category }
}

/// Discarded-on-purpose decoder for the per-variant dicts we don't need to
/// introspect — we only care that they exist (to count variants).
struct EmptyJSON: Decodable, Hashable {
    init(from decoder: Decoder) throws {}
}

private struct CatalogResponse: Decodable {
    let familyMetadataList: [GoogleFontFamily]
}

/// Fetches the Google Fonts catalog (no API key required) and drives
/// downloads of individual families into a local cache folder that the
/// regular font scanner picks up.
///
/// Flow:
/// 1. `ensureCatalogLoaded()` — fetch `fonts.google.com/metadata/fonts`,
///    cache JSON for 24h to `~/Library/Application Support/SaewooFont/`.
/// 2. `download(family:)` — fetch the CSS2 endpoint for the family, parse
///    gstatic.com URLs from the returned CSS, download every woff2 to
///    `~/Library/Application Support/SaewooFont/GoogleFonts/{family}/`,
///    and register them via CTFontManagerRegisterFontURLs.
/// 3. The next rescan picks the new files up as regular FontItems because
///    the GoogleFonts directory is added to the scan roots.
@MainActor
final class GoogleFontsClient: ObservableObject {
    static let shared = GoogleFontsClient()

    @Published private(set) var catalog: [GoogleFontFamily] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var loadError: String? = nil
    /// Families currently being downloaded — used to disable buttons and
    /// show spinners in the browse view.
    @Published private(set) var downloading: Set<String> = []
    /// Last error per family, keyed by family name. Cleared on retry.
    @Published private(set) var downloadErrors: [String: String] = [:]

    /// Root directory for cached Google Fonts downloads. Added as a scan root
    /// so downloaded fonts show up in the normal library automatically.
    static let downloadsRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SaewooFont/GoogleFonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let catalogURL = URL(string: "https://fonts.google.com/metadata/fonts")!
    private let cacheFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SaewooFont/google_fonts_catalog.json")
    }()
    private let maxCacheAge: TimeInterval = 24 * 60 * 60

    // MARK: - Catalog

    /// Ensures `catalog` is populated. Returns immediately if already loaded;
    /// otherwise loads from disk cache if fresh, or fetches over the network.
    func ensureCatalogLoaded() async {
        if !catalog.isEmpty { return }
        if let cached = loadCachedCatalogIfFresh() {
            self.catalog = sorted(cached)
            return
        }
        await refresh()
    }

    /// Force-refresh from the network, bypassing the 24h cache.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            var req = URLRequest(url: catalogURL)
            req.setValue("SaewooFont/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "GoogleFonts", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected response"])
            }
            // Google's endpoint returns a JSON prefixed with `)]}'\n` (XSSI
            // protection). Strip it before decoding.
            var payload = data
            if data.count > 4,
               let head = String(data: data.prefix(4), encoding: .utf8),
               head == ")]}'" {
                if let nl = data.firstIndex(of: 0x0A) {
                    payload = data.subdata(in: (nl + 1)..<data.count)
                }
            }
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: payload)
            self.catalog = sorted(decoded.familyMetadataList)
            try? payload.write(to: cacheFileURL, options: .atomic)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sorted(_ list: [GoogleFontFamily]) -> [GoogleFontFamily] {
        list.sorted { lhs, rhs in
            (lhs.popularity ?? Int.max) < (rhs.popularity ?? Int.max)
        }
    }

    private func loadCachedCatalogIfFresh() -> [GoogleFontFamily]? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFileURL.path),
            let modDate = attrs[.modificationDate] as? Date,
            Date().timeIntervalSince(modDate) < maxCacheAge,
            let data = try? Data(contentsOf: cacheFileURL),
            let decoded = try? JSONDecoder().decode(CatalogResponse.self, from: data)
        else { return nil }
        return decoded.familyMetadataList
    }

    // MARK: - Download

    /// True if we already have a local folder for this family with at least
    /// one font file in it.
    func isInstalled(family: String) -> Bool {
        let dir = familyDir(family)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return false }
        return !contents.isEmpty
    }

    func installedVariantCount(family: String) -> Int {
        let dir = familyDir(family)
        return (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil).count) ?? 0
    }

    private func familyDir(_ family: String) -> URL {
        Self.downloadsRoot
            .appendingPathComponent(family, isDirectory: true)
    }

    /// Download every variant of the family to the local cache + register it
    /// session-scope with Core Text. Caller should trigger a library rescan
    /// after to have the new files show up in the normal browse views.
    func download(family: GoogleFontFamily) async {
        let name = family.family
        guard !downloading.contains(name) else { return }
        downloading.insert(name)
        downloadErrors[name] = nil
        defer { downloading.remove(name) }

        do {
            let dir = familyDir(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let cssURL = buildCSS2URL(for: family)
            var req = URLRequest(url: cssURL)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let css = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "GoogleFonts", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't fetch CSS for \(name)"])
            }
            let urls = Self.extractFontURLs(from: css)
            guard !urls.isEmpty else {
                throw NSError(domain: "GoogleFonts", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "No downloadable variants found for \(name)"])
            }

            var savedFiles: [URL] = []
            for (index, url) in urls.enumerated() {
                let ext = url.pathExtension.isEmpty ? "woff2" : url.pathExtension
                let dest = dir.appendingPathComponent("\(name)-\(index).\(ext)")
                let (tmp, _) = try await URLSession.shared.download(from: url)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                savedFiles.append(dest)
            }

            // Session-scope register so the new fonts are immediately usable
            // (the scan will pick them up later for persistent tracking).
            if !savedFiles.isEmpty {
                CTFontManagerRegisterFontURLs(
                    savedFiles as CFArray, .session, true) { _, _ in true }
            }
        } catch {
            downloadErrors[name] = error.localizedDescription
        }
    }

    /// Remove the local cache for a family and unregister it from Core Text.
    func uninstall(family: String) {
        let dir = familyDir(family)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil), !files.isEmpty {
            CTFontManagerUnregisterFontURLs(files as CFArray, .session) { _, _ in true }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - CSS2 URL building + parsing

    /// Builds a CSS2 request covering every variant of the family. The endpoint
    /// expects weight/italic encoded as `:ital,wght@0,400;0,700;1,400`.
    private func buildCSS2URL(for family: GoogleFontFamily) -> URL {
        // Encode family name with '+' for spaces.
        let nameParam = family.family.replacingOccurrences(of: " ", with: "+")

        // Map variant strings ("400", "400i", "100", ...) → (italic, weight) pairs.
        var pairs: [(italic: Int, weight: Int)] = []
        for v in family.variantKeys {
            let isItalic = v.hasSuffix("i")
            let weightStr = isItalic ? String(v.dropLast()) : v
            let weight = Int(weightStr) ?? 400
            pairs.append((isItalic ? 1 : 0, weight))
        }
        // If the family has no recognized variants, fall back to Regular.
        if pairs.isEmpty { pairs.append((0, 400)) }
        // Sort: italic asc, then weight asc — CSS2 requires this order.
        pairs.sort { ($0.italic, $0.weight) < ($1.italic, $1.weight) }
        let axisValues = pairs.map { "\($0.italic),\($0.weight)" }.joined(separator: ";")

        let urlString = "https://fonts.googleapis.com/css2?family=\(nameParam):ital,wght@\(axisValues)&display=swap"
        return URL(string: urlString) ?? URL(string: "https://fonts.googleapis.com/css2?family=\(nameParam)")!
    }

    /// Pulls `https://fonts.gstatic.com/...` download URLs from a CSS2 response.
    static func extractFontURLs(from css: String) -> [URL] {
        let pattern = #"url\((https://fonts\.gstatic\.com/[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(css.startIndex..., in: css)
        var urls: [URL] = []
        var seen: Set<URL> = []
        regex.enumerateMatches(in: css, range: range) { match, _, _ in
            guard
                let m = match,
                let r = Range(m.range(at: 1), in: css),
                let url = URL(string: String(css[r])),
                !seen.contains(url)
            else { return }
            seen.insert(url)
            urls.append(url)
        }
        return urls
    }
}
