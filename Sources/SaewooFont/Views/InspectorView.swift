import SwiftUI
import AppKit

struct InspectorView: View {
    @EnvironmentObject var lib: FontLibrary

    var body: some View {
        if let id = lib.selectedFontID, let item = lib.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Big preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.displayName).font(.title3).bold()
                        Text(item.postScriptName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        FontPreviewText(item: item, size: 48, text: "Aa Bb Cc 123")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        FontPreviewText(item: item, size: 18, text: lib.previewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        FontPreviewText(item: item, size: 14, text: "abcdefghijklmnopqrstuvwxyz 0123456789")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    HStack {
                        Button {
                            Task { await lib.setActive(item, active: !lib.isActive(item)) }
                        } label: {
                            Label(lib.isActive(item) ? "Deactivate" : "Activate",
                                  systemImage: lib.isActive(item) ? "power.circle.fill" : "power.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(lib.isActive(item) ? .green : .accentColor)

                        Button {
                            lib.toggleFavorite(item)
                        } label: {
                            Label(lib.favorites.contains(item.id) ? "Starred" : "Star",
                                  systemImage: lib.favorites.contains(item.id) ? "star.fill" : "star")
                        }
                        .buttonStyle(.bordered)
                        .tint(lib.favorites.contains(item.id) ? .yellow : .secondary)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                        } label: { Label("Reveal", systemImage: "magnifyingglass") }
                            .buttonStyle(.bordered)
                    }

                    // Metadata grid
                    MetadataGrid(item: item)

                    // Categorization
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Classification").font(.headline)
                        HStack {
                            tag(item.category.label, icon: item.category.icon, color: .accentColor)
                            ForEach(item.moods) { m in
                                tag(m.label, icon: "tag", color: .indigo.opacity(0.7))
                            }
                            Spacer()
                        }
                    }

                    // Collection membership
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Collections").font(.headline)
                        let memberships = lib.collections.filter { $0.fontIDs.contains(item.id) }
                        if memberships.isEmpty {
                            Text("Not in any project or palette yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(memberships) { c in
                            HStack {
                                Circle().fill(Color(hex: c.colorHex) ?? .accentColor).frame(width: 8, height: 8)
                                Text(c.name)
                                Spacer()
                                Button("Remove") {
                                    lib.removeFromCollection(c.id, fontIDs: [item.id])
                                }
                                .font(.caption).buttonStyle(.borderless)
                            }
                        }
                        Menu("Add to…") {
                            ForEach(lib.collections) { c in
                                Button("\(c.kind == .project ? "Project" : "Palette"): \(c.name)") {
                                    lib.addToCollection(c.id, fontIDs: [item.id])
                                }
                            }
                        }.frame(width: 140)
                    }
                }
                .padding(18)
            }
            .frame(minWidth: 320)
            .background(Color(NSColor.windowBackgroundColor))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "textformat").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select a font to inspect").foregroundStyle(.secondary)
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func tag(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

struct MetadataGrid: View {
    let item: FontItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Metadata").font(.headline).padding(.bottom, 4)
            row("Family", item.familyName)
            row("Style", item.styleName)
            row("Format", item.format)
            row("Weight", String(format: "%.2f", item.weight))
            row("Width",  String(format: "%.2f", item.width))
            row("Slant",  String(format: "%.2f", item.slant))
            row("Glyphs", "\(item.glyphCount)")
            row("File Size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            row("Italic", item.isItalic ? "Yes" : "No")
            row("Monospaced", item.isMonospaced ? "Yes" : "No")
            row("Path", item.fileURL.path).lineLimit(2)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary).font(.caption)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}
