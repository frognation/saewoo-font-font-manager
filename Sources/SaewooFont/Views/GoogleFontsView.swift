import SwiftUI
import AppKit

/// Browse view for the public Google Fonts catalog. Fetches the catalog with
/// no API key (via `fonts.google.com/metadata/fonts`), caches for 24h, and
/// downloads requested families to a local folder that's part of the scan
/// roots — so a downloaded Google Font shows up in Library / Foundries /
/// Categories like any other font.
struct GoogleFontsView: View {
    @EnvironmentObject var lib: FontLibrary
    @StateObject private var client = GoogleFontsClient.shared

    @State private var searchText: String = ""
    @State private var selectedCategory: String? = nil
    @State private var sortMode: SortMode = .popularity
    @State private var lastAction: String? = nil

    enum SortMode: String, CaseIterable, Identifiable {
        case popularity, name, lastModified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .popularity:   return "Popular"
            case .name:         return "A → Z"
            case .lastModified: return "Recently updated"
            }
        }
    }

    private static let categoryFilters: [(tag: String?, label: String)] = [
        (nil, "All"),
        ("SANS_SERIF", "Sans Serif"),
        ("SERIF", "Serif"),
        ("DISPLAY", "Display"),
        ("HANDWRITING", "Handwriting"),
        ("MONOSPACE", "Monospace"),
    ]

    private var filtered: [GoogleFontFamily] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var list = client.catalog
        if let cat = selectedCategory {
            list = list.filter { $0.category == cat }
        }
        if !q.isEmpty {
            list = list.filter { $0.family.lowercased().contains(q) }
        }
        switch sortMode {
        case .popularity:
            // `list` is already popularity-sorted from the client.
            break
        case .name:
            list.sort { $0.family.lowercased() < $1.family.lowercased() }
        case .lastModified:
            list.sort {
                ($0.lastModified ?? "0000") > ($1.lastModified ?? "0000")
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            content
        }
        .task { await client.ensureCatalogLoaded() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "g.circle.fill").foregroundStyle(.blue)
                    Text("Google Fonts").font(.title3).bold()
                }
                Text("Browse the full Google Fonts catalog (~1,700 families, all open source). Download & Activate registers the font for this login session. Downloaded fonts also appear in your regular Library — so you can favorite, put in Projects, etc.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                if let a = lastAction {
                    Text(a).font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if client.isLoading {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Loading catalog…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(client.catalog.count) families").font(.caption).bold()
                    Button {
                        Task { await client.refresh() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .padding(16)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search families…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .frame(maxWidth: 320)

            Picker("Category", selection: Binding(
                get: { selectedCategory ?? "" },
                set: { selectedCategory = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(Self.categoryFilters, id: \.label) { entry in
                    Text(entry.label).tag(entry.tag ?? "")
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)

            Spacer()

            Picker("Sort", selection: $sortMode) {
                ForEach(SortMode.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if client.isLoading && client.catalog.isEmpty {
            loadingState
        } else if let err = client.loadError, client.catalog.isEmpty {
            errorState(err)
        } else if filtered.isEmpty {
            emptyState
        } else {
            listContent
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Fetching Google Fonts catalog…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(.orange)
            Text("Couldn't load catalog").font(.title3).bold()
            Text(msg).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Try Again") { Task { await client.refresh() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No matches").font(.title3).bold()
            Text("Try a different search or clear the category filter.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { family in
                    row(family: family)
                    Divider().opacity(0.3)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func row(family: GoogleFontFamily) -> some View {
        let installed = client.isInstalled(family: family.family)
        let downloading = client.downloading.contains(family.family)
        let error = client.downloadErrors[family.family]

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(family.family)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    if installed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                HStack(spacing: 10) {
                    Label(family.niceCategory, systemImage: categoryIcon(family.category))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(family.variantKeys.count) variant\(family.variantKeys.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let sub = family.subsets, !sub.isEmpty {
                        Text(sub.prefix(4).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let mod = family.lastModified {
                        Text("updated \(mod)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let err = error {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            rowActions(family: family, installed: installed, downloading: downloading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contextMenu {
            Button("Open in Google Fonts") {
                if let url = URL(string: "https://fonts.google.com/specimen/\(family.family.replacingOccurrences(of: " ", with: "+"))") {
                    NSWorkspace.shared.open(url)
                }
            }
            if installed {
                Button("Remove local copy", role: .destructive) {
                    client.uninstall(family: family.family)
                    Task {
                        await lib.rescan()
                        lastAction = "Removed \(family.family)."
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowActions(family: GoogleFontFamily, installed: Bool, downloading: Bool) -> some View {
        if downloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if installed {
            HStack(spacing: 6) {
                Text("\(client.installedVariantCount(family: family.family)) file\(client.installedVariantCount(family: family.family) == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
                Button {
                    Task {
                        client.uninstall(family: family.family)
                        await lib.rescan()
                        lastAction = "Removed \(family.family)."
                    }
                } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        } else {
            Button {
                Task {
                    await client.download(family: family)
                    await lib.rescan()
                    if client.downloadErrors[family.family] == nil {
                        lastAction = "Installed \(family.family)."
                    }
                }
            } label: {
                Label("Download & Activate", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func categoryIcon(_ cat: String) -> String {
        switch cat {
        case "SANS_SERIF":   return "textformat"
        case "SERIF":        return "textformat.abc"
        case "DISPLAY":      return "textformat.size.larger"
        case "HANDWRITING":  return "pencil.and.scribble"
        case "MONOSPACE":    return "chevron.left.forwardslash.chevron.right"
        default:             return "questionmark"
        }
    }
}
