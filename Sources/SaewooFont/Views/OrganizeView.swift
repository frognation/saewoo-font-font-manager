import SwiftUI
import AppKit

/// The Organize tool — bulk move + rule-based sorting of font files between folders.
///
/// Two modes:
/// - **Move**: pick source + destination, filter which fonts to move.
///   Typical use: "Empty out `/Library/Fonts` to a managed archive folder but
///   keep Apple system essentials."
/// - **Sort**: group files in a source folder into auto-created subfolders by
///   category / foundry / weight. Typical use: "I dumped 800 fonts in a
///   flat folder — organize them."
///
/// All operations are **non-destructive in the OS sense** — we `moveItem` which
/// keeps the file on disk at a new path, and we patch in-memory FontItems so
/// favorites / activation state survive the move.
struct OrganizeView: View {
    @EnvironmentObject var lib: FontLibrary

    enum Mode: String, CaseIterable, Identifiable {
        case move, sort
        var id: String { rawValue }
        var label: String {
            switch self {
            case .move: return "Move"
            case .sort: return "Sort into subfolders"
            }
        }
        var icon: String {
            switch self {
            case .move: return "arrow.right.to.line"
            case .sort: return "square.grid.3x3.folder.badge.plus"
            }
        }
    }

    enum GroupBy: String, CaseIterable, Identifiable {
        case category, foundry, weightBucket, mood
        var id: String { rawValue }
        var label: String {
            switch self {
            case .category:     return "Category (Serif / Sans / ...)"
            case .foundry:      return "Foundry"
            case .weightBucket: return "Weight (Light / Regular / Bold / ...)"
            case .mood:         return "Mood"
            }
        }
        var shortLabel: String {
            switch self {
            case .category:     return "Category"
            case .foundry:      return "Foundry"
            case .weightBucket: return "Weight"
            case .mood:         return "Mood"
            }
        }
    }

    enum FilterKind: String, CaseIterable, Identifiable {
        case all, variable, category, foundry, mood, inactive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:       return "All fonts"
            case .variable:  return "Variable fonts only"
            case .category:  return "By category"
            case .foundry:   return "By foundry"
            case .mood:      return "By mood"
            case .inactive:  return "Only inactive"
            }
        }
    }

    @State private var mode: Mode = .move
    @State private var sourceURL: URL? = nil
    @State private var destURL: URL? = nil
    @State private var filter: FilterKind = .all
    @State private var filterCategory: FontCategory = .sansSerif
    @State private var filterFoundry: String = ""
    @State private var filterMood: FontMood = .modern
    @State private var groupBy: GroupBy = .category
    @State private var skipSystemEssentials: Bool = true
    @State private var skipActive: Bool = false
    @State private var selectedIDs: Set<String> = []
    @State private var running: Bool = false
    @State private var lastReport: String? = nil
    @State private var lastError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeSwitcher
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderPickers
                    Divider()
                    if mode == .move { moveFilters } else { sortControls }
                    Divider()
                    previewList
                    if let err = lastError {
                        banner(err, color: .red, icon: "exclamationmark.triangle.fill")
                    }
                    if let rpt = lastReport {
                        banner(rpt, color: .green, icon: "checkmark.circle.fill")
                    }
                }
                .padding(16)
            }
            Divider()
            actionBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape").foregroundStyle(.teal)
                    Text("Organize").font(.title3).bold()
                }
                Text("Bulk-move font files between folders or auto-sort them into subfolders by category / foundry / weight / mood. Use it to keep `~/Library/Fonts` and `/Library/Fonts` lean — move rarely-used fonts to an archive folder you scan on demand. Apple system essentials are skipped by default.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { m in
                Button { mode = m; refreshSelection() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.icon)
                        Text(m.label)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(mode == m ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(mode == m ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Folder pickers

    private var folderPickers: some View {
        HStack(spacing: 12) {
            folderPickerBox("Source", url: $sourceURL, placeholder: "Pick a folder to read fonts from")
                .onChange(of: sourceURL) { _ in refreshSelection() }
            Image(systemName: mode == .sort ? "square.grid.2x2" : "arrow.right")
                .foregroundStyle(.secondary)
            folderPickerBox("Destination",
                            url: $destURL,
                            placeholder: mode == .sort
                                ? "Subfolders are created inside this folder"
                                : "Where to move fonts to")
        }
    }

    @ViewBuilder
    private func folderPickerBox(_ label: String, url: Binding<URL?>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button {
                pickFolder(assignTo: url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    if let u = url.wrappedValue {
                        Text(u.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        Text(placeholder).foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    if url.wrappedValue != nil {
                        Button {
                            url.wrappedValue = nil
                            refreshSelection()
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Move mode filters

    private var moveFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter").font(.headline)
            Picker("Which fonts?", selection: $filter) {
                ForEach(FilterKind.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: filter) { _ in refreshSelection() }

            switch filter {
            case .category:
                Picker("Category", selection: $filterCategory) {
                    ForEach(FontCategory.allCases) { c in Text(c.label).tag(c) }
                }
                .onChange(of: filterCategory) { _ in refreshSelection() }
            case .foundry:
                TextField("Foundry name (e.g. Monotype, Adobe)", text: $filterFoundry)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: filterFoundry) { _ in refreshSelection() }
            case .mood:
                Picker("Mood", selection: $filterMood) {
                    ForEach(FontMood.allCases) { m in Text(m.label).tag(m) }
                }
                .onChange(of: filterMood) { _ in refreshSelection() }
            default:
                EmptyView()
            }

            safetyToggles
        }
    }

    private var sortControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Group by").font(.headline)
            Picker("Group by", selection: $groupBy) {
                ForEach(GroupBy.allCases) { g in Text(g.label).tag(g) }
            }
            .pickerStyle(.segmented)
            .onChange(of: groupBy) { _ in refreshSelection() }

            Text("Fonts in the source folder will be moved into subfolders named by \(groupBy.shortLabel). Anything matching the filter below is included.").font(.caption).foregroundStyle(.secondary)

            Picker("Which fonts?", selection: $filter) {
                ForEach([FilterKind.all, .variable, .inactive]) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: filter) { _ in refreshSelection() }

            safetyToggles
        }
    }

    private var safetyToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $skipSystemEssentials) {
                Label("Skip Apple system essentials", systemImage: "lock.shield")
                    .font(.callout)
            }
            .onChange(of: skipSystemEssentials) { _ in refreshSelection() }
            Text("Helvetica, Menlo, PingFang, SF families and other fonts macOS relies on are left alone. Strongly recommended.")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle(isOn: $skipActive) {
                Label("Skip currently active fonts", systemImage: "power.circle")
                    .font(.callout)
            }
            .onChange(of: skipActive) { _ in refreshSelection() }
            Text("If you're using a font right now (showing in your font menus), skip it. Moves won't break anything — the manager re-links after — but this gives you peace of mind.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview list

    private var preview: [FontItem] { filteredItems() }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preview").font(.headline)
                Text("\(preview.count) file\(preview.count == 1 ? "" : "s") · \(selectedIDs.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { selectedIDs = Set(preview.map { $0.id }) }
                    .disabled(preview.isEmpty)
                Button("Clear") { selectedIDs.removeAll() }
                    .disabled(selectedIDs.isEmpty)
            }
            if preview.isEmpty {
                Text(sourceURL == nil
                     ? "Pick a source folder to see what would move."
                     : "Nothing matches the current filter.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 24).frame(maxWidth: .infinity)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(preview) { item in
                        previewRow(item)
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    @ViewBuilder
    private func previewRow(_ item: FontItem) -> some View {
        let isEssential = FontLibrary.isSystemEssential(item)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selectedIDs.contains(item.id) },
                set: { on in
                    if on { selectedIDs.insert(item.id) }
                    else  { selectedIDs.remove(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isEssential && skipSystemEssentials)

            if isEssential {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                    .help("System-essential — default: skip")
            } else {
                Circle()
                    .fill(lib.isActive(item) ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.fileURL.lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if mode == .sort {
                Text("→ \(subfolderFor(item))")
                    .font(.caption2).foregroundStyle(.teal)
            }
            Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selectedIDs.contains(item.id)
                    ? Color.accentColor.opacity(0.08)
                    : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            if running {
                ProgressView().controlSize(.small)
                Text("Moving files…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(actionHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await execute() }
            } label: {
                Label(mode == .move
                      ? "Move \(selectedIDs.count) to Destination"
                      : "Sort \(selectedIDs.count) into Subfolders",
                      systemImage: mode.icon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExecute)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var actionHint: String {
        if sourceURL == nil { return "Pick a source folder first." }
        if destURL == nil { return mode == .sort
                            ? "Pick a destination folder where subfolders will be created."
                            : "Pick a destination folder." }
        if selectedIDs.isEmpty { return "No files selected." }
        return "Ready — \(selectedIDs.count) file\(selectedIDs.count == 1 ? "" : "s") will move."
    }

    private var canExecute: Bool {
        !running && sourceURL != nil && destURL != nil && !selectedIDs.isEmpty
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(color).textSelection(.enabled)
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Logic

    private func filteredItems() -> [FontItem] {
        guard let src = sourceURL else { return [] }
        let srcPath = src.standardizedFileURL.path
        let base = lib.items.filter { $0.fileURL.standardizedFileURL.path.hasPrefix(srcPath) }
        return base.filter { item in
            if skipSystemEssentials, FontLibrary.isSystemEssential(item) { return false }
            if skipActive, lib.isActive(item) { return false }
            switch filter {
            case .all:       return true
            case .variable:  return item.isVariable
            case .category:  return item.categories.contains(filterCategory)
            case .foundry:
                let q = filterFoundry.trimmingCharacters(in: .whitespaces).lowercased()
                return q.isEmpty ? true : item.foundry.lowercased().contains(q)
            case .mood:      return item.moods.contains(filterMood)
            case .inactive:  return !lib.isActive(item)
            }
        }
    }

    private func refreshSelection() {
        // By default, pre-check everything matching the filter (minus essentials).
        selectedIDs = Set(filteredItems().map { $0.id })
    }

    private func subfolderFor(_ item: FontItem) -> String {
        switch groupBy {
        case .category:     return item.primaryCategory.label
        case .foundry:      return item.foundry
        case .weightBucket: return weightBucket(item.weight)
        case .mood:         return item.moods.first?.label ?? "Unclassified"
        }
    }

    private func weightBucket(_ w: Double) -> String {
        // CT weight trait ranges roughly -1..1. Map to coarse buckets.
        switch w {
        case ..<(-0.6):  return "Thin"
        case ..<(-0.3):  return "Light"
        case ..<(0.1):   return "Regular"
        case ..<(0.3):   return "Medium"
        case ..<(0.5):   return "Semibold"
        case ..<(0.7):   return "Bold"
        default:         return "Black"
        }
    }

    private func execute() async {
        running = true
        lastError = nil
        lastReport = nil
        defer { running = false }

        let toMove = filteredItems().filter { selectedIDs.contains($0.id) }
        guard let dest = destURL else { return }

        var moved = 0
        var errors: [String] = []

        for item in toMove {
            let target: URL
            if mode == .sort {
                let sub = dest.appendingPathComponent(subfolderFor(item), isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: sub, withIntermediateDirectories: true)
                } catch {
                    errors.append("Couldn't create \(sub.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                target = sub
            } else {
                target = dest
            }
            do {
                try await lib.moveFontFile(item, to: target)
                moved += 1
            } catch {
                errors.append("\(item.fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        selectedIDs.removeAll()
        lastReport = "Moved \(moved) file\(moved == 1 ? "" : "s")."
        if !errors.isEmpty {
            lastError = errors.joined(separator: "\n")
        }
    }

    private func pickFolder(assignTo url: Binding<URL?>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url {
            url.wrappedValue = u
        }
    }
}
