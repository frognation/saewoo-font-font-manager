import SwiftUI
import AppKit

/// Sidebar with a three-tier visual hierarchy:
///
/// 1. **Sources** — every folder being scanned
/// 2. **Library** — all ways to browse the fonts (Overview / Categories /
///    Moods / Foundries / Projects / Palettes)
/// 3. **Tools** — library-maintenance actions
///
/// Each top-level section has a big prominent header with a colored glyph and
/// semibold title. Inside Library, smaller sub-section headers group related
/// browsing filters. Everything collapses independently and the collapse state
/// persists via `@AppStorage`.
struct SidebarView: View {
    @EnvironmentObject var lib: FontLibrary
    @AppStorage("sidebar.collapsedSections") private var collapsedCSV: String = ""

    private var collapsed: Set<String> {
        Set(collapsedCSV.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    private func toggle(_ id: String) {
        var s = collapsed
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        collapsedCSV = s.sorted().joined(separator: ",")
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { lib.sidebarSelection },
            set: { if let v = $0 { lib.sidebarSelection = v } }
        )
    }

    // MARK: - Body

    var body: some View {
        List(selection: selectionBinding) {
            sourcesSection
            librarySection
            toolsSection
        }
        .listStyle(.sidebar)
    }

    // MARK: - Top-level sections

    @ViewBuilder
    private var sourcesSection: some View {
        topSection(id: "sources", title: "Sources",
                   icon: "externaldrive.connected.to.line.below",
                   tint: .blue,
                   trailing: { addFolderButton }) {
            ForEach(lib.displayableDefaultSources, id: \.self) { url in
                sourceRow(url, removable: false)
            }
            ForEach(lib.customScanPaths, id: \.self) { url in
                sourceRow(url, removable: true)
            }
            if hasAutoOrManuallyHidden { hiddenSourcesMenu }
            systemActiveToggleRow
        }
    }

    /// Toggles "include fonts activated by other font managers" (RightFont,
    /// FontBase, Typeface, Adobe CC…). When on, rescan merges every font
    /// CoreText currently knows about, even those whose files live outside
    /// our scan paths.
    private var systemActiveToggleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: lib.includeSystemActive
                  ? "dot.radiowaves.left.and.right"
                  : "dot.radiowaves.left.and.right")
                .font(.system(size: 14))
                .foregroundStyle(lib.includeSystemActive ? .green : .secondary)
                .frame(width: 20)
            Toggle(isOn: Binding(
                get: { lib.includeSystemActive },
                set: { lib.setIncludeSystemActive($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Other managers + Adobe CC")
                        .font(.system(size: 12))
                    Text("RightFont, FontBase, Typeface, …")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 3)
        .help("When on, rescan also enumerates every font CoreText currently knows about — so fonts activated by other managers show up in this library too.")
    }

    @ViewBuilder
    private var librarySection: some View {
        topSection(id: "library", title: "Library",
                   icon: "books.vertical.fill",
                   tint: .accentColor) {
            subSection(id: "lib-overview", title: "Overview") {
                rowLabel(.allFonts, title: "All Fonts",
                         icon: "square.grid.2x2", count: lib.items.count)
                rowLabel(.active, title: "Active",
                         icon: "circle.fill", tint: .green,
                         count: lib.activeFontIDs.count)
                rowLabel(.inactive, title: "Inactive", icon: "circle",
                         count: max(0, lib.items.count - lib.activeFontIDs.count))
                rowLabel(.favorites, title: "Favorites", icon: "star.fill",
                         tint: .yellow, count: lib.favorites.count)
                if lib.variableCount > 0 {
                    rowLabel(.variable, title: "Variable",
                             icon: "slider.horizontal.3", tint: .purple,
                             count: lib.variableCount)
                }
            }
            subSection(id: "lib-categories", title: "Categories") {
                ForEach(lib.categoryCounts, id: \.0) { cat, count in
                    rowLabel(.category(cat), title: cat.label,
                             icon: cat.icon, count: count)
                }
            }
            subSection(id: "lib-moods", title: "Moods") {
                ForEach(lib.moodCounts, id: \.0) { mood, count in
                    rowLabel(.mood(mood), title: mood.label,
                             icon: moodIcon(mood), count: count)
                }
            }
            subSection(id: "lib-foundries", title: "Foundries") {
                ForEach(lib.foundryCounts, id: \.0) { name, count in
                    foundryRow(name: name, count: count)
                }
            }
            subSection(id: "lib-projects", title: "Projects",
                       trailing: { addCollectionButton(.project) }) {
                ForEach(lib.collections.filter { $0.kind == .project }) { c in
                    collectionRow(c)
                }
            }
            subSection(id: "lib-palettes", title: "Palettes",
                       trailing: { addCollectionButton(.palette) }) {
                ForEach(lib.collections.filter { $0.kind == .palette }) { c in
                    collectionRow(c)
                }
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        topSection(id: "tools", title: "Tools",
                   icon: "wrench.and.screwdriver.fill",
                   tint: .pink) {
            rowLabel(.tool(.duplicates),
                     title: ToolKind.duplicates.label,
                     icon: ToolKind.duplicates.icon,
                     tint: ToolKind.duplicates.tint,
                     count: lib.duplicateGroups.count > 0 ? lib.duplicateGroups.count : nil)
            rowLabel(.tool(.organize),
                     title: ToolKind.organize.label,
                     icon: ToolKind.organize.icon,
                     tint: ToolKind.organize.tint)
            rowLabel(.tool(.proofSheet),
                     title: ToolKind.proofSheet.label,
                     icon: ToolKind.proofSheet.icon,
                     tint: ToolKind.proofSheet.tint)
            rowLabel(.tool(.orphans),
                     title: ToolKind.orphans.label,
                     icon: ToolKind.orphans.icon,
                     tint: ToolKind.orphans.tint,
                     count: lib.orphanURLs.count > 0 ? lib.orphanURLs.count : nil)
            rowLabel(.tool(.missingRefs),
                     title: ToolKind.missingRefs.label,
                     icon: ToolKind.missingRefs.icon,
                     tint: ToolKind.missingRefs.tint,
                     count: lib.missingReferences.count > 0 ? lib.missingReferences.count : nil)
            rowLabel(.tool(.largeFiles),
                     title: ToolKind.largeFiles.label,
                     icon: ToolKind.largeFiles.icon,
                     tint: ToolKind.largeFiles.tint)
            rowLabel(.tool(.fork),
                     title: ToolKind.fork.label,
                     icon: ToolKind.fork.icon,
                     tint: ToolKind.fork.tint)
        }
    }

    // MARK: - Section wrappers

    @ViewBuilder
    private func topSection<Trailing: View, Content: View>(
        id: String,
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = isExpanded(id)
        Section {
            if expanded { content() }
        } header: {
            HStack(spacing: 8) {
                Button { toggle(id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(tint)
                            .frame(width: 22)
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                trailing()
            }
            .padding(.vertical, 4)
        }
    }

    /// Lightweight intra-section header — used inside Library to group
    /// Categories / Moods / Foundries / etc. Tappable for expand/collapse.
    @ViewBuilder
    private func subSection<Trailing: View, Content: View>(
        id: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = isExpanded(id)
        HStack(spacing: 4) {
            Button { toggle(id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.top, 8).padding(.bottom, 2)

        if expanded { content() }
    }

    // MARK: - Header trailing buttons

    private var addFolderButton: some View {
        Button { pickFolder() } label: { Image(systemName: "plus") }
            .buttonStyle(.plain).help("Add a folder to scan")
    }

    private func addCollectionButton(_ kind: FontCollection.Kind) -> some View {
        Button {
            // NewCollectionPrompt attaches as an AppKit sheet to the SwiftUI
            // scene's backing window. Sheets are async by nature, hence the
            // await — the caller returns immediately and the completion fires
            // once the user hits Create or Cancel.
            Task { @MainActor in
                if let result = await NewCollectionPrompt.show(kind: kind) {
                    lib.addCollection(name: result.name, kind: kind,
                                      colorHex: result.color)
                }
            }
        } label: { Image(systemName: "plus") }
            .buttonStyle(.plain)
            .help(kind == .project ? "New project" : "New palette")
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowLabel(_ item: SidebarItem, title: String, icon: String,
                          tint: Color = .accentColor, count: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 3)
        .tag(item)
    }

    /// True if any default source is hidden — either explicitly or implicitly (<2 fonts).
    private var hasAutoOrManuallyHidden: Bool {
        if !lib.hiddenDefaultSources.isEmpty { return true }
        return lib.visibleDefaultSources.contains { lib.itemsInSource($0).count < 2 }
    }

    @ViewBuilder
    private func sourceRow(_ url: URL, removable: Bool) -> some View {
        let count = lib.itemsInSource(url).count
        let isRFLibrary = RightFontImporter.isLibrary(url)
        // RightFont libraries get a briefcase icon + purple tint so they
        // stand out from plain folders at a glance.
        let icon = isRFLibrary
            ? "briefcase.fill"
            : (removable ? "folder.badge.plus" : "folder")
        let tint: Color = isRFLibrary ? .purple : .blue
        // Strip the ".rightfontlibrary" suffix from the display label —
        // users don't need to see the extension in the sidebar.
        let label: String = {
            if isRFLibrary { return url.deletingPathExtension().lastPathComponent }
            return removable ? url.lastPathComponent : FontLibrary.label(for: url)
        }()

        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(label).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 3)
        .tag(SidebarItem.source(url))
        .help(url.path)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Activate All in Folder") {
                Task { await lib.setActiveMany(lib.itemsInSource(url), active: true) }
            }
            Button("Deactivate All in Folder") {
                Task { await lib.setActiveMany(lib.itemsInSource(url), active: false) }
            }
            if isRFLibrary {
                Divider()
                Button("Import RightFont Collections as Palettes") {
                    Task { @MainActor in
                        if let report = await lib.importRightFontLibrary(url) {
                            presentImportReport(report)
                        }
                    }
                }
            }
            Divider()
            if removable {
                Button("Remove from Sources", role: .destructive) {
                    lib.removeCustomScanPath(url)
                }
            } else {
                Button("Hide from Sidebar") { lib.hideDefaultSource(url) }
            }
        }
    }

    /// Shows a small success alert summarising what the RightFont import did.
    @MainActor
    private func presentImportReport(_ r: FontLibrary.RightFontImportReport) {
        let alert = NSAlert()
        alert.messageText = "Imported “\(r.libraryName)”"
        alert.informativeText = """
        \(r.paletteCount) palette\(r.paletteCount == 1 ? "" : "s") created.
        \(r.enrichedCount) font\(r.enrichedCount == 1 ? "" : "s") matched to RightFont metadata.
        \(r.starredMatchCount) starred font\(r.starredMatchCount == 1 ? "" : "s") added to Favorites.
        \(r.skippedCount == 0 ? "" : "\(r.skippedCount) empty/unresolved fontlist\(r.skippedCount == 1 ? "" : "s") skipped.")
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var hiddenSourcesMenu: some View {
        let auto = lib.visibleDefaultSources.filter { lib.itemsInSource($0).count < 2 }
        let manual = Array(lib.hiddenDefaultSources).map { URL(fileURLWithPath: $0) }
        let all = (auto + manual).sorted { $0.path < $1.path }

        return Menu {
            ForEach(all, id: \.self) { url in
                Button("Show \(FontLibrary.label(for: url)) — \(url.path)") {
                    if lib.hiddenDefaultSources.contains(url.standardizedFileURL.path) {
                        lib.unhideDefaultSource(url)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text("Hidden sources (\(all.count))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func foundryRow(name: String, count: Int) -> some View {
        let faces = lib.itemsInFoundry(name)
        let allActive = !faces.isEmpty && faces.allSatisfy { lib.isActive($0) }
        let anyActive = faces.contains { lib.isActive($0) }
        HStack(spacing: 10) {
            Image(systemName: "building.2")
                .font(.system(size: 14))
                .foregroundStyle(name == "Unknown" ? Color.secondary : Color.teal)
                .frame(width: 20)
            Text(name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await lib.setActiveMany(faces, active: !allActive) }
            } label: {
                Circle()
                    .fill(allActive ? Color.green : (anyActive ? Color.yellow : Color.secondary.opacity(0.3)))
                    .frame(width: 7, height: 7)
            }
            .buttonStyle(.plain)
            .help(allActive ? "Deactivate all from this foundry" : "Activate all from this foundry")
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 3)
        .tag(SidebarItem.foundry(name))
        .contextMenu {
            Button("Activate All from \(name)") {
                Task { await lib.setActiveMany(faces, active: true) }
            }
            Button("Deactivate All from \(name)") {
                Task { await lib.setActiveMany(faces, active: false) }
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ c: FontCollection) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: c.colorHex) ?? .accentColor).frame(width: 10, height: 10)
                .padding(.leading, 5) // align with icon-centered rows
            Text(c.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await lib.toggleCollectionActive(c) }
            } label: {
                Image(systemName: lib.isCollectionFullyActive(c) ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(lib.isCollectionFullyActive(c) ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(lib.isCollectionFullyActive(c) ? "Deactivate all" : "Activate all")
            Text("\(c.fontIDs.count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .tag(SidebarItem.collection(c.id))
        .contextMenu {
            Button("Activate All") {
                Task { await lib.setActiveMany(lib.items.filter { c.fontIDs.contains($0.id) }, active: true) }
            }
            Button("Deactivate All") {
                Task { await lib.setActiveMany(lib.items.filter { c.fontIDs.contains($0.id) }, active: false) }
            }
            Divider()
            Menu("Change Color") {
                ForEach(["#7DD3FC", "#A78BFA", "#F472B6", "#FB923C",
                         "#FACC15", "#4ADE80", "#22D3EE", "#F87171"], id: \.self) { hex in
                    Button(hex) { lib.setCollectionColor(c.id, hex: hex) }
                }
            }
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
        // Also allow picking `.rightfontlibrary` packages. Packages are files
        // to the Finder, so we flip canChooseFiles on AND ensure packages
        // aren't traversed as if they were folders.
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder or a .rightfontlibrary package to scan"
        panel.message = "You can select a regular folder OR a RightFont library package (.rightfontlibrary)."
        if panel.runModal() == .OK, let url = panel.url {
            // Validate: if it's a file, it must be a .rightfontlibrary — we
            // don't want to accept arbitrary non-folder files.
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let isFolder = exists && isDir.boolValue
            let isLibrary = RightFontImporter.isLibrary(url)
            guard isFolder || isLibrary else {
                let a = NSAlert()
                a.messageText = "Unsupported selection"
                a.informativeText = "Pick a folder or a .rightfontlibrary package."
                a.runModal()
                return
            }
            lib.addCustomScanPath(url)
        }
    }
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
