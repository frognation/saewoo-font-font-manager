import SwiftUI
import AppKit

/// Disk-space audit: the N heaviest font files in your library, with bulk
/// trash. Big CJK families, Monotype megatons, and old manual backup copies
/// rise to the top. Multi-select + Trash to reclaim space.
struct LargeFilesView: View {
    @EnvironmentObject var lib: FontLibrary

    @State private var topN: Int = 50
    @State private var selection: Set<String> = []
    @State private var pendingDelete: [FontItem] = []
    @State private var deleteError: String? = nil
    @State private var report: String? = nil

    private var topItems: [FontItem] {
        let sorted = lib.itemsByFileSize
        return Array(sorted.prefix(topN))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if lib.items.isEmpty {
                empty
            } else {
                controls
                Divider()
                list
            }
        }
        .confirmationDialog(
            "Move \(pendingDelete.count) file\(pendingDelete.count == 1 ? "" : "s") to Trash?",
            isPresented: Binding(
                get: { !pendingDelete.isEmpty },
                set: { if !$0 { pendingDelete = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                let batch = pendingDelete
                pendingDelete = []
                Task { await trashBatch(batch) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Reversible from Finder's Trash. Active / favorite / collection references are scrubbed automatically.")
        }
        .alert("Some files couldn't be trashed",
               isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
               )) {
            Button("OK") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down.circle").foregroundStyle(.blue)
                    Text("Largest Files").font(.title3).bold()
                }
                Text("Biggest font files first — handy for quickly reclaiming disk space. CJK typefaces and fully-featured variable fonts tend to dominate. Multi-select and Trash.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report { Text(report).font(.caption).foregroundStyle(.green) }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(totalLabel()).font(.caption).bold()
                Text("\(lib.items.count) files total").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var controls: some View {
        HStack {
            Text("Show top").font(.caption).foregroundStyle(.secondary)
            Picker("Top N", selection: $topN) {
                ForEach([10, 25, 50, 100, 250], id: \.self) { Text("\($0)").tag($0) }
                Text("All").tag(Int.max)
            }
            .pickerStyle(.segmented).frame(width: 280)

            Spacer()

            Button("Select All") { selection = Set(topItems.map { $0.id }) }
                .disabled(topItems.isEmpty)
            Button("Clear") { selection.removeAll() }
                .disabled(selection.isEmpty)
            Button(role: .destructive) {
                pendingDelete = topItems.filter { selection.contains($0.id) }
            } label: {
                Label("Trash \(selection.count) Selected", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(topItems.enumerated()), id: \.element.id) { idx, item in
                    row(rank: idx + 1, item: item)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func row(rank: Int, item: FontItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(item.id) },
                set: { on in
                    if on { selection.insert(item.id) } else { selection.remove(item.id) }
                }
            )).toggleStyle(.checkbox).labelsHidden()

            Text("#\(rank)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            Circle()
                .fill(lib.isActive(item) ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(.body, design: .default).weight(.medium))
                        .lineLimit(1)
                    if lib.favorites.contains(item.id) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                    }
                    if FontLibrary.isSystemEssential(item) {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.orange).font(.caption)
                            .help("System-essential font — deleting may affect macOS")
                    }
                }
                HStack(spacing: 10) {
                    Label(item.foundry, systemImage: "building.2")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(item.fileURL.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                .font(.system(.caption, design: .monospaced)).bold()
                .frame(width: 84, alignment: .trailing)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)

            Button {
                pendingDelete = [item]
            } label: { Image(systemName: "trash").foregroundStyle(.red) }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selection.contains(item.id) ? Color.red.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { lib.selectedFontID = item.id }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Library is empty").font(.title3).bold()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func totalLabel() -> String {
        let total = lib.items.reduce(Int64(0)) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func trashBatch(_ items: [FontItem]) async {
        var ok = 0
        var errors: [String] = []
        for item in items {
            do { try await lib.deleteFontFile(item); ok += 1 }
            catch { errors.append("\(item.fileURL.lastPathComponent): \(error.localizedDescription)") }
        }
        selection.removeAll()
        report = "Moved \(ok) file\(ok == 1 ? "" : "s") to Trash."
        if !errors.isEmpty { deleteError = errors.joined(separator: "\n") }
    }
}
