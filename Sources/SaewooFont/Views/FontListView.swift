import SwiftUI
import AppKit

/// How a click should change the selection, derived from the modifier keys
/// held at the moment of the tap.
///
/// SwiftUI's `onTapGesture` doesn't hand us the originating event, so we read
/// `NSEvent.modifierFlags` — the current keyboard state — which is accurate at
/// the instant the gesture fires.
enum ClickIntent {
    case replace   // plain click
    case toggle    // ⌘
    case extend    // ⇧

    static var current: ClickIntent {
        let f = NSEvent.modifierFlags
        if f.contains(.command) { return .toggle }
        if f.contains(.shift)   { return .extend }
        return .replace
    }
}

struct FontListView: View {
    @EnvironmentObject var lib: FontLibrary
    @EnvironmentObject var sel: SelectionModel
    @State private var expandedFamilies: Set<String> = []

    /// The on-screen row order, flattened. ⇧-click ranges are meaningless
    /// unless they follow exactly what the user sees, so expanded families
    /// contribute their faces here in display order.
    private func visibleOrder(_ groups: [FontFamilyGroup]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(groups.count)
        for g in groups {
            guard let primary = g.faces.first else { continue }
            out.append(primary.id)
            if expandedFamilies.contains(g.key) {
                for f in g.faces where f.id != primary.id { out.append(f.id) }
            }
        }
        return out
    }

    var body: some View {
        let groups = lib.familyGroups
        let order = visibleOrder(groups)
        VStack(spacing: 0) {
            if sel.count > 1 { selectionBar }
            // `List` (NSTableView-backed) recycles rows. The previous
            // ScrollView+LazyVStack realized a row on first scroll-past and
            // never released it, so scrolling 4 000+ families grew memory
            // monotonically.
            List {
                ForEach(groups) { group in
                    FamilyGroupRow(group: group,
                                   expanded: expandedFamilies.contains(group.key),
                                   visibleOrder: order,
                                   toggleExpand: {
                                       if expandedFamilies.contains(group.key) {
                                           expandedFamilies.remove(group.key)
                                       } else {
                                           expandedFamilies.insert(group.key)
                                       }
                                   })
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
        }
        .background(Color(NSColor.textBackgroundColor))
        .onCopyCommand { [] }   // keeps the responder chain alive for shortcuts
        .background(
            // Invisible buttons purely to register ⌘A / Esc with the menu system.
            Group {
                Button("") { sel.selectAll(order) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("") { sel.clear() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0).frame(width: 0, height: 0)
        )
    }

    /// Appears only for a multi-row selection, so the bulk actions are visible
    /// rather than hidden behind a right-click.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(sel.count) selected")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                let items = sel.selectedItems(in: lib.items)
                Task { await lib.setActiveMany(items, active: true) }
            } label: { Label("Activate", systemImage: "power.circle.fill") }
            Button {
                let items = sel.selectedItems(in: lib.items)
                Task { await lib.setActiveMany(items, active: false) }
            } label: { Label("Deactivate", systemImage: "power.circle") }
            Menu("Add to Project") {
                if lib.collections.isEmpty { Text("No projects").foregroundStyle(.secondary) }
                ForEach(lib.collections) { p in
                    Button(p.name) {
                        lib.addToCollection(p.id, fontIDs: Array(sel.selectedIDs))
                    }
                }
            }
            .frame(width: 150)
            Button("Clear") { sel.clear() }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12))
    }
}

struct FamilyGroupRow: View {
    @EnvironmentObject var lib: FontLibrary
    @EnvironmentObject var sel: SelectionModel
    @EnvironmentObject var preview: PreviewSettings
    let group: FontFamilyGroup
    let expanded: Bool
    let visibleOrder: [String]
    let toggleExpand: () -> Void

    /// Routes a row tap through the modifier keys.
    private func handleClick(_ id: String) {
        switch ClickIntent.current {
        case .replace: sel.select(id)
        case .toggle:  sel.toggle(id)
        case .extend:  sel.extend(to: id, visibleOrder: visibleOrder)
        }
    }

    /// What a context-menu action should apply to. Right-clicking inside an
    /// existing multi-selection acts on the whole selection — right-clicking a
    /// row outside it acts on just that row, which is the macOS convention.
    private func actionTargets(for rowItems: [FontItem]) -> [FontItem] {
        if sel.count > 1, rowItems.contains(where: { sel.isSelected($0.id) }) {
            return sel.selectedItems(in: lib.items)
        }
        return rowItems
    }

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

                FontPreviewText(item: primary, size: preview.size, text: preview.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                starButton(for: primary)

                Text(primary.categories.map(\.label).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 160, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { handleClick(primary.id) }
            .background(sel.isSelected(primary.id) ? Color.accentColor.opacity(0.18) : Color.clear)
            .contextMenu { rowContextMenu(items: actionTargets(for: group.faces)) }

            if expanded {
                ForEach(group.faces) { face in
                    FaceRow(item: face, onClick: { handleClick(face.id) })
                        .padding(.leading, 44)
                        .contextMenu { rowContextMenu(items: actionTargets(for: [face])) }
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
        let n = items.count
        let suffix = n > 1 ? " (\(n))" : ""
        Button("Activate" + suffix) { Task { await lib.setActiveMany(items, active: true) } }
        Button("Deactivate" + suffix) { Task { await lib.setActiveMany(items, active: false) } }
        Divider()
        Menu("Add to Project") {
            if lib.collections.isEmpty { Text("No projects").foregroundStyle(.secondary) }
            ForEach(lib.collections) { p in
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
    @EnvironmentObject var sel: SelectionModel
    @EnvironmentObject var preview: PreviewSettings
    let item: FontItem
    let onClick: () -> Void

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

            FontPreviewText(item: item, size: preview.size * 0.85, text: preview.text)
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
        .background(sel.isSelected(item.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture { onClick() }
    }
}

/// Renders preview text using the font at `item.fileURL`. Loads Core Text ad-hoc
/// so we can preview even when the font isn't session-activated. Cached by URL+size.
struct FontPreviewText: View {
    let item: FontItem
    let size: Double
    let text: String
    /// Optional variation axis overrides, keyed by axis tag. Pass `nil` for default instance.
    var variations: [UInt32: Double]? = nil

    var body: some View {
        Text(AttributedString(attributedString(text: text, item: item, size: size)))
            .truncationMode(.tail)
    }

    private func attributedString(text: String, item: FontItem, size: Double) -> NSAttributedString {
        let font = FontPreviewCache.shared.font(for: item, size: CGFloat(size), variations: variations)
                ?? NSFont.systemFont(ofSize: CGFloat(size))
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
    }
}

final class FontPreviewCache {
    static let shared = FontPreviewCache()

    /// NSCache gives us automatic LRU-ish eviction once we exceed `countLimit`,
    /// and is thread-safe. Sized to comfortably cover a scrolled-through list
    /// on a large library — at 1000 it thrashed against 4 000+ families.
    private let cache: NSCache<NSString, NSFont> = {
        let c = NSCache<NSString, NSFont>()
        c.countLimit = 4000
        return c
    }()

    /// Boxes an *optional* descriptor so failures are negative-cached too —
    /// otherwise an unreadable face re-parses from disk on every render.
    private final class DescriptorBox {
        let descriptor: CTFontDescriptor?
        init(_ d: CTFontDescriptor?) { descriptor = d }
    }

    /// Descriptors keyed by file+face, independent of size.
    ///
    /// This is the important one. Inactive fonts miss the `NSFont(name:)` fast
    /// path, so the old code re-ran `CTFontManagerCreateFontDescriptorsFromURL`
    /// — a synchronous disk read and parse, inside a SwiftUI body — on every
    /// cache miss. Dragging the preview-size slider changed the cache key, so
    /// each tick re-parsed every visible font file.
    private let descriptors: NSCache<NSString, DescriptorBox> = {
        let c = NSCache<NSString, DescriptorBox>()
        c.countLimit = 4000
        return c
    }()

    private func descriptor(for item: FontItem) -> CTFontDescriptor? {
        let key = "\(item.fileURL.path)::\(item.postScriptName)" as NSString
        if let box = descriptors.object(forKey: key) { return box.descriptor }
        let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL) as? [CTFontDescriptor]
        let found = descs?.first(where: { d in
            (CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String) == item.postScriptName
        }) ?? descs?.first
        descriptors.setObject(DescriptorBox(found), forKey: key)
        return found
    }

    func font(for item: FontItem, size: CGFloat, variations: [UInt32: Double]? = nil) -> NSFont? {
        let varKey = variations.map { dict in
            dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined(separator: ",")
        } ?? ""
        // Quantize size so nearly-identical slider values (e.g. 36.0 vs 36.0000001)
        // hit the same cache entry.
        let qsize = (size * 10).rounded() / 10
        let key = "\(item.postScriptName)::\(qsize)::\(varKey)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // Non-variation path: try PS name (fast) first.
        if variations == nil, let f = NSFont(name: item.postScriptName, size: size) {
            cache.setObject(f, forKey: key)
            return f
        }

        // Variation path (or fallback): descriptor comes from the size-independent
        // cache, so a size change never re-reads the file.
        guard var desc = descriptor(for: item) else { return nil }
        if let v = variations, !v.isEmpty {
            var dict: [NSNumber: NSNumber] = [:]
            for (tag, value) in v {
                dict[NSNumber(value: tag)] = NSNumber(value: value)
            }
            let attrs = [kCTFontVariationAttribute: dict as CFDictionary] as CFDictionary
            desc = CTFontDescriptorCreateCopyWithAttributes(desc, attrs)
        }
        let ct = CTFontCreateWithFontDescriptor(desc, size, nil)
        let ns = ct as NSFont
        cache.setObject(ns, forKey: key)
        return ns
    }
}
