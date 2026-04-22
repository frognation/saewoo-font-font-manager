import SwiftUI
import AppKit

/// Lists files the scanner found in your sources that Core Text couldn't parse —
/// usually truncated downloads, corrupted files, or exotic formats the OS doesn't
/// understand. They waste disk space and produce nothing visible in macOS.
struct OrphansView: View {
    @EnvironmentObject var lib: FontLibrary

    @State private var selection: Set<URL> = []
    @State private var pendingDelete: [URL] = []
    @State private var deleteError: String? = nil
    @State private var report: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if lib.orphanURLs.isEmpty {
                emptyState
            } else {
                actionBar
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
            Text("Reversible from Finder's Trash.")
        }
        .alert("Some files couldn't be trashed",
               isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
               )) {
            Button("OK") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.ellipsis").foregroundStyle(.gray)
                    Text("Orphan Files").font(.title3).bold()
                }
                Text("Files with a font extension (.ttf / .otf / .ttc / ...) that the OS couldn't parse. Usually corrupted downloads, half-finished copies, or formats macOS doesn't understand. They invisibly take up space in your sources — clean them out.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report { Text(report).font(.caption).foregroundStyle(.green) }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("\(lib.orphanURLs.count) file\(lib.orphanURLs.count == 1 ? "" : "s")")
                    .font(.caption).bold()
                Text(totalSizeLabel()).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var actionBar: some View {
        HStack {
            Button("Select All") { selection = Set(lib.orphanURLs) }
                .disabled(lib.orphanURLs.isEmpty)
            Button("Clear") { selection.removeAll() }
                .disabled(selection.isEmpty)
            Spacer()
            Button(role: .destructive) {
                pendingDelete = lib.orphanURLs.filter { selection.contains($0) }
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
                ForEach(lib.orphanURLs, id: \.self) { url in
                    row(url: url)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func row(url: URL) -> some View {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(url) },
                set: { on in
                    if on { selection.insert(url) } else { selection.remove(url) }
                }
            )).toggleStyle(.checkbox).labelsHidden()

            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(.body, design: .default).weight(.medium))
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")

            Button {
                pendingDelete = [url]
            } label: { Image(systemName: "trash").foregroundStyle(.red) }
                .buttonStyle(.borderless).help("Move to Trash")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selection.contains(url) ? Color.red.opacity(0.08) : Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("No orphans").font(.title3).bold()
            Text("Every font file in your scanned sources parses cleanly.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func totalSizeLabel() -> String {
        let total = lib.orphanURLs.reduce(Int64(0)) { acc, url in
            acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file) + " total"
    }

    private func trashBatch(_ urls: [URL]) async {
        var ok = 0
        var errors: [String] = []
        for url in urls {
            do { try await lib.trashOrphan(url); ok += 1 }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        selection.removeAll()
        report = "Moved \(ok) file\(ok == 1 ? "" : "s") to Trash."
        if !errors.isEmpty { deleteError = errors.joined(separator: "\n") }
    }
}
