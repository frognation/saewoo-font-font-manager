import Foundation

/// Named, toggleable group of fonts. Used for Projects and Palettes.
struct FontCollection: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case project, palette }

    var id: UUID
    var name: String
    var kind: Kind
    var colorHex: String          // sidebar accent
    var fontIDs: Set<String>      // FontItem.id values
    var createdAt: Date
    var notes: String             // freeform

    init(id: UUID = UUID(),
         name: String,
         kind: Kind,
         colorHex: String = "#7DD3FC",
         fontIDs: Set<String> = [],
         createdAt: Date = Date(),
         notes: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.colorHex = colorHex
        self.fontIDs = fontIDs
        self.createdAt = createdAt
        self.notes = notes
    }
}

/// A saved snapshot of variation axis values for a specific variable font.
/// Persists alongside favorites/collections so users can recall "Inter @ wght=620, opsz=14" later.
struct VariableInstance: Identifiable, Codable, Hashable {
    var id: UUID
    var baseFontID: String             // FontItem.id of the variable font
    var name: String                   // user-given, e.g. "Inter Editorial"
    var axisValues: [String: Double]   // keyed by tag string ("wght", "opsz", ...)
    var createdAt: Date

    init(id: UUID = UUID(),
         baseFontID: String,
         name: String,
         axisValues: [String: Double],
         createdAt: Date = Date()) {
        self.id = id
        self.baseFontID = baseFontID
        self.name = name
        self.axisValues = axisValues
        self.createdAt = createdAt
    }
}

struct LibraryState: Codable {
    var favorites: Set<String> = []
    var collections: [FontCollection] = []
    var activeFontIDs: Set<String> = []
    var customScanPaths: [URL] = []
    var userText: String = "The quick brown fox jumps over the lazy dog"
    var previewSize: Double = 36
    var variableInstances: [VariableInstance] = []
    /// Default scan-root paths the user has hidden from the sidebar.
    /// Stored as raw path strings so JSON round-trips cleanly across machines.
    var hiddenDefaultSources: Set<String> = []
    /// When true, also enumerate every font currently registered with
    /// Core Text (including those activated by other font managers like
    /// RightFont, FontBase, Typeface, Adobe CC). Default on — users
    /// generally want to see everything that's actually available.
    var includeSystemActive: Bool = true

    private enum CodingKeys: String, CodingKey {
        case favorites, collections, activeFontIDs, customScanPaths
        case userText, previewSize, variableInstances, hiddenDefaultSources
        case includeSystemActive
    }

    init() {}

    init(favorites: Set<String>, collections: [FontCollection],
         activeFontIDs: Set<String>, customScanPaths: [URL],
         userText: String, previewSize: Double,
         variableInstances: [VariableInstance] = [],
         hiddenDefaultSources: Set<String> = [],
         includeSystemActive: Bool = true) {
        self.favorites = favorites
        self.collections = collections
        self.activeFontIDs = activeFontIDs
        self.customScanPaths = customScanPaths
        self.userText = userText
        self.previewSize = previewSize
        self.variableInstances = variableInstances
        self.hiddenDefaultSources = hiddenDefaultSources
        self.includeSystemActive = includeSystemActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.favorites        = (try? c.decode(Set<String>.self,        forKey: .favorites))        ?? []
        self.collections      = (try? c.decode([FontCollection].self,   forKey: .collections))      ?? []
        self.activeFontIDs    = (try? c.decode(Set<String>.self,        forKey: .activeFontIDs))    ?? []
        self.customScanPaths  = (try? c.decode([URL].self,              forKey: .customScanPaths))  ?? []
        self.userText         = (try? c.decode(String.self,             forKey: .userText))         ?? "The quick brown fox jumps over the lazy dog"
        self.previewSize      = (try? c.decode(Double.self,             forKey: .previewSize))      ?? 36
        self.variableInstances = (try? c.decode([VariableInstance].self, forKey: .variableInstances)) ?? []
        self.hiddenDefaultSources = (try? c.decode(Set<String>.self,    forKey: .hiddenDefaultSources)) ?? []
        self.includeSystemActive = (try? c.decode(Bool.self,            forKey: .includeSystemActive)) ?? true
    }
}
