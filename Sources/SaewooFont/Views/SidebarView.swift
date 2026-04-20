import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var lib: FontLibrary
    @State private var showAddCollection: (FontCollection.Kind)? = nil
    @State private var collectionName: String = ""

    var body: some View {
        List(selection: Binding(
            get: { lib.sidebarSelection },
            set: { if let v = $0 { lib.sidebarSelection = v } }
        )) {
            Section("Library") {
                rowLabel(.allFonts, title: "All Fonts", icon: "square.grid.2x2", count: lib.items.count)
                rowLabel(.active, title: "Active", icon: "circle.fill", tint: .green, count: lib.activeFontIDs.count)
                rowLabel(.inactive, title: "Inactive", icon: "circle", count: max(0, lib.items.count - lib.activeFontIDs.count))
                rowLabel(.favorites, title: "Favorites", icon: "star.fill", tint: .yellow, count: lib.favorites.count)
            }

            Section("Categories") {
                ForEach(lib.categoryCounts, id: \.0) { cat, count in
                    rowLabel(.category(cat), title: cat.label, icon: cat.icon, count: count)
                }
            }

            Section("Moods") {
                ForEach(lib.moodCounts, id: \.0) { mood, count in
                    rowLabel(.mood(mood), title: mood.label, icon: moodIcon(mood), count: count)
                }
            }

            Section {
                ForEach(lib.collections.filter { $0.kind == .project }) { c in
                    collectionRow(c)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { showAddCollection = .project; collectionName = "" } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).help("New project")
                }
            }

            Section {
                ForEach(lib.collections.filter { $0.kind == .palette }) { c in
                    collectionRow(c)
                }
            } header: {
                HStack {
                    Text("Palettes")
                    Spacer()
                    Button { showAddCollection = .palette; collectionName = "" } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).help("New palette")
                }
            }

            Section("Sources") {
                ForEach(FontScanner.defaultSearchRoots, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "folder")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                ForEach(lib.customScanPaths, id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent, systemImage: "folder.badge.plus")
                            .font(.caption)
                        Spacer()
                        Button { lib.removeCustomScanPath(url) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                    }
                }
                Button {
                    pickFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus.circle").font(.caption)
                }.buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .sheet(item: Binding(get: {
            showAddCollection.map { IdentifiedKind(kind: $0) }
        }, set: { _ in showAddCollection = nil })) { wrap in
            AddCollectionSheet(kind: wrap.kind) { name, color in
                lib.addCollection(name: name, kind: wrap.kind, colorHex: color)
                showAddCollection = nil
            } cancel: { showAddCollection = nil }
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func rowLabel(_ item: SidebarItem, title: String, icon: String, tint: Color = .accentColor, count: Int? = nil) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Spacer()
            if let count, count > 0 {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .tag(item)
    }

    @ViewBuilder
    private func collectionRow(_ c: FontCollection) -> some View {
        HStack {
            Circle().fill(Color(hex: c.colorHex) ?? .accentColor).frame(width: 8, height: 8)
            Text(c.name).lineLimit(1)
            Spacer()
            // Batch toggle: one tap activates/deactivates the whole collection.
            Button {
                Task { await lib.toggleCollectionActive(c) }
            } label: {
                Image(systemName: lib.isCollectionFullyActive(c) ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(lib.isCollectionFullyActive(c) ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(lib.isCollectionFullyActive(c) ? "Deactivate all" : "Activate all")

            Text("\(c.fontIDs.count)").font(.caption2).foregroundStyle(.secondary)
        }
        .tag(SidebarItem.collection(c.id))
        .contextMenu {
            Button("Activate All") { Task { await lib.setActiveMany(lib.items.filter { c.fontIDs.contains($0.id) }, active: true) } }
            Button("Deactivate All") { Task { await lib.setActiveMany(lib.items.filter { c.fontIDs.contains($0.id) }, active: false) } }
            Divider()
            Button("Delete \(c.kind == .project ? "Project" : "Palette")", role: .destructive) {
                lib.deleteCollection(c.id)
            }
        }
    }

    private func moodIcon(_ m: FontMood) -> String {
        switch m {
        case .elegant: return "sparkles"
        case .modern: return "circle.grid.cross"
        case .playful: return "face.smiling"
        case .technical: return "gearshape"
        case .vintage: return "hourglass"
        case .bold: return "bold"
        case .minimal: return "minus"
        case .decorative: return "leaf"
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder to scan for fonts"
        if panel.runModal() == .OK, let url = panel.url {
            lib.addCustomScanPath(url)
        }
    }
}

private struct IdentifiedKind: Identifiable {
    let kind: FontCollection.Kind
    var id: String { kind.rawValue }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue:  Double(v & 0xFF) / 255.0
        )
    }
}
