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

struct LibraryState: Codable {
    var favorites: Set<String> = []
    var collections: [FontCollection] = []
    var activeFontIDs: Set<String> = []
    var customScanPaths: [URL] = []
    var userText: String = "The quick brown fox jumps over the lazy dog"
    var previewSize: Double = 36
}
