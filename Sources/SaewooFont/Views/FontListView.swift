import SwiftUI
import AppKit

struct FontListView: View {
    @EnvironmentObject var lib: FontLibrary
    @State private var expandedFamilies: Set<String> = []

    var body: some View {
        let groups = lib.familyGroups
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    FamilyGroupRow(group: group,
                                   expanded: expandedFamilies.contains(group.key),
                                   toggleExpand: {
                                       if expandedFamilies.contains(group.key) {
                                           expandedFamilies.remove(group.key)
                                       } else {
                                           expandedFamilies.insert(group.key)
                                       }
                                   })
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct FamilyGroupRow: View {
    @EnvironmentObject var lib: FontLibrary
    let group: FontFamilyGroup
    let expanded: Bool
    let toggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let primary = group.faces.first ?? group.faces[0]
            HStack(spacing: 10) {
                Button(action: toggleExpand) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }.buttonStyle(.plain)

                activationDot(for: group)

                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 200, alignment: .leading)

                Text("\(group.faces.count) style\(group.faces.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)

                FontPreviewText(item: primary, size: lib.previewSize, text: lib.previewText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                starButton(for: primary)

                Text(primary.category.label)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                lib.selectedFontID = primary.id
            }
            .background(lib.selectedFontID == primary.id ? Color.accentColor.opacity(0.12) : Color.clear)
            .contextMenu { rowContextMenu(items: group.faces) }

            if expanded {
                ForEach(group.faces) { face in
                    FaceRow(item: face)
                        .padding(.leading, 44)
                        .contextMenu { rowContextMenu(items: [face]) }
                }
            }
        }
    }

    @ViewBuilder
    private func activationDot(for group: FontFamilyGroup) -> some View {
        let allActive = group.faces.allSatisfy { lib.isActive($0) }
        let anyActive = group.faces.contains { lib.isActive($0) }
        let color: Color = allActive ? .green : (anyActive ? .yellow : .secondary.opacity(0.35))
        Button {
            Task { await lib.setActiveMany(group.faces, active: !allActive) }
        } label: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .help(allActive ? "Deactivate family" : "Activate family")
    }

    @ViewBuilder
    private func starButton(for item: FontItem) -> some View {
        Button {
            lib.toggleFavorite(item)
        } label: {
            Image(systemName: lib.favorites.contains(item.id) ? "star.fill" : "star")
                .foregroundStyle(lib.favorites.contains(item.id) ? Color.yellow : Color.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowContextMenu(items: [FontItem]) -> some View {
        Button("Activate") { Task { await lib.setActiveMany(items, active: true) } }
        Button("Deactivate") { Task { await lib.setActiveMany(items, active: false) } }
        Divider()
        Menu("Add to Project") {
            let projects = lib.collections.filter { $0.kind == .project }
            if projects.isEmpty { Text("No projects").foregroundStyle(.secondary) }
            ForEach(projects) { p in
                Button(p.name) { lib.addToCollection(p.id, fontIDs: items.map { $0.id }) }
            }
        }
        Menu("Add to Palette") {
            let palettes = lib.collections.filter { $0.kind == .palette }
            if palettes.isEmpty { Text("No palettes").foregroundStyle(.secondary) }
            ForEach(palettes) { p in
                Button(p.name) { lib.addToCollection(p.id, fontIDs: items.map { $0.id }) }
            }
        }
        Divider()
        Button("Show File in Finder") {
            if let first = items.first {
                NSWorkspace.shared.activateFileViewerSelecting([first.fileURL])
            }
        }
    }
}

struct FaceRow: View {
    @EnvironmentObject var lib: FontLibrary
    let item: FontItem

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await lib.setActive(item, active: !lib.isActive(item)) }
            } label: {
                Image(systemName: lib.isActive(item) ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(lib.isActive(item) ? Color.green : Color.secondary)
            }.buttonStyle(.plain)

            Text(item.styleName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            FontPreviewText(item: item, size: lib.previewSize * 0.85, text: lib.previewText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                lib.toggleFavorite(item)
            } label: {
                Image(systemName: lib.favorites.contains(item.id) ? "star.fill" : "star")
                    .foregroundStyle(lib.favorites.contains(item.id) ? Color.yellow : Color.secondary.opacity(0.5))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(lib.selectedFontID == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .onTapGesture { lib.selectedFontID = item.id }
    }
}

/// Renders preview text using the font at `item.fileURL`. Loads Core Text ad-hoc
/// so we can preview even when the font isn't session-activated. Cached by URL+size.
struct FontPreviewText: View {
    let item: FontItem
    let size: Double
    let text: String

    var body: some View {
        Text(AttributedString(attributedString(text: text, item: item, size: size)))
            .truncationMode(.tail)
    }

    private func attributedString(text: String, item: FontItem, size: Double) -> NSAttributedString {
        let font = FontPreviewCache.shared.font(for: item, size: CGFloat(size))
                ?? NSFont.systemFont(ofSize: CGFloat(size))
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
    }
}

final class FontPreviewCache {
    static let shared = FontPreviewCache()
    private var cache: [String: NSFont] = [:]
    func font(for item: FontItem, size: CGFloat) -> NSFont? {
        let key = "\(item.postScriptName)::\(size)"
        if let cached = cache[key] { return cached }
        // Try by PS name first (works if activated or if it's a system font).
        if let f = NSFont(name: item.postScriptName, size: size) {
            cache[key] = f
            return f
        }
        // Fallback: create a Core Text font straight from the URL (preview without activation).
        let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL) as? [CTFontDescriptor]
        if let desc = descs?.first(where: { d in
            (CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String) == item.postScriptName
        }) ?? descs?.first {
            let ct = CTFontCreateWithFontDescriptor(desc, size, nil)
            let ns = ct as NSFont
            cache[key] = ns
            return ns
        }
        return nil
    }
}
