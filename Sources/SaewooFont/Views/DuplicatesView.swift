import SwiftUI
import AppKit

/// Byte-identical file cleanup.
///
/// The previous version of this screen grouped by PostScript name and offered
/// to delete the "extras". On the reference library that was actively unsafe:
/// only ~66 % of same-name groups were actually the same font, so a third of
/// every deletion was a different typeface that merely reused the name. Worse,
/// it counted faces but deleted files — and one file here holds 252 faces, so
/// removing a single "extra" could take 251 unrelated ones with it.
///
/// This version only ever offers files whose contents hash identically. That
/// makes deletion lossless by construction: every face in a removed file still
/// exists, byte for byte, in the copy that is kept.
struct DuplicatesView: View {
    @EnvironmentObject var lib: FontLibrary

    /// Group digest → the copy the user wants to keep.
    @State private var keepers: [String: URL] = [:]
    /// Group digests excluded from the purge.
    @State private var excluded: Set<String> = []
    @State private var confirming = false
    @State private var report: FontLibrary.DuplicateDeletionReport?

    private var groups: [DuplicateScanner.Group] { lib.contentDuplicates }

    private func keeper(for g: DuplicateScanner.Group) -> URL {
        keepers[g.digest] ?? lib.recommendedKeeper(in: g)
    }

    private var pending: [(group: DuplicateScanner.Group, keeper: URL)] {
        groups.filter { !excluded.contains($0.digest) }
              .map { ($0, keeper(for: $0)) }
    }

    private var reclaimable: Int64 {
        pending.reduce(0) { $0 + $1.group.size * Int64($1.group.paths.count - 1) }
    }
    private var deletableCount: Int {
        pending.reduce(0) { $0 + $1.group.paths.count - 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if lib.isScanningDuplicates {
                scanning
            } else if groups.isEmpty {
                idle
            } else {
                actionBar
                Divider()
                list
            }
        }
        .confirmationDialog(
            "Move \(deletableCount) identical file\(deletableCount == 1 ? "" : "s") to Trash?",
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) {
                let batch = pending
                Task { report = await lib.deleteDuplicates(batch) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Every file listed is byte-for-byte identical to the copy being kept, \
            so nothing is lost — each removed face still exists in the keeper. \
            Files go to the Trash, and a manifest of deleted → kept paths is saved. \
            Favorites and projects are re-pointed at the surviving copy automatically.
            """)
        }
        .alert("Cleanup finished", isPresented: Binding(
            get: { report != nil }, set: { if !$0 { report = nil } })
        ) {
            Button("OK") { report = nil }
        } message: {
            if let r = report { Text(summary(r)) }
        }
    }

    private func summary(_ r: FontLibrary.DuplicateDeletionReport) -> String {
        var s = "\(r.filesDeleted) files moved to Trash · "
        s += ByteCountFormatter.string(fromByteCount: r.bytesReclaimed, countStyle: .file)
        s += " reclaimed.\n\(r.referencesRemapped) favorite/project references re-pointed at the kept copy."
        if !r.skipped.isEmpty { s += "\n\nSkipped:\n" + r.skipped.prefix(5).joined(separator: "\n") }
        if !r.errors.isEmpty  { s += "\n\nFailed:\n"  + r.errors.prefix(5).joined(separator: "\n") }
        return s
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("Identical Files").font(.title3).bold()
                }
                Text("""
                Finds files whose contents are byte-for-byte identical, so removing \
                the extras cannot lose a font. Fonts that merely share a PostScript \
                name are deliberately NOT listed here — those are usually different \
                typefaces reusing a name, and deleting them loses real data.
                """)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !groups.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(groups.count) groups").font(.caption).bold()
                    Text(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)
                         + " reclaimable")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let p = lib.duplicateScanProgress {
                Text(p.stage).font(.callout)
                if p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .frame(width: 320)
                    Text("\(p.done) / \(p.total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Only files that share a size are read, and only their first and last 16 KB unless those match.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idle: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 42)).foregroundStyle(.secondary)
            Text("No scan yet").font(.title3).bold()
            Text("Comparing contents means reading the files, so it runs on demand.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Scan for identical files") {
                Task { await lib.scanContentDuplicates() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Rescan") { Task { await lib.scanContentDuplicates() } }
            Text("Click any copy to make it the one that's kept.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { excluded.removeAll() }
                .disabled(excluded.isEmpty)
            Button("Deselect All") { excluded = Set(groups.map { $0.digest }) }
                .disabled(excluded.count == groups.count)
            Button(role: .destructive) { confirming = true } label: {
                Label("Delete \(deletableCount) Extra Copies", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(deletableCount == 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var list: some View {
        List {
            ForEach(groups) { g in
                DuplicateGroupRow(group: g,
                                  keeper: keeper(for: g),
                                  included: !excluded.contains(g.digest),
                                  setKeeper: { keepers[g.digest] = $0 },
                                  toggleIncluded: {
                                      if excluded.contains(g.digest) { excluded.remove(g.digest) }
                                      else { excluded.insert(g.digest) }
                                  })
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
    }
}

private struct DuplicateGroupRow: View {
    @EnvironmentObject var lib: FontLibrary
    let group: DuplicateScanner.Group
    let keeper: URL
    let included: Bool
    let setKeeper: (URL) -> Void
    let toggleIncluded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { included }, set: { _ in toggleIncluded() }))
                    .labelsHidden().toggleStyle(.checkbox)
                Text("\(group.paths.count) identical copies")
                    .font(.system(size: 12, weight: .medium))
                Text(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Text("frees " + ByteCountFormatter.string(
                        fromByteCount: group.size * Int64(group.paths.count - 1), countStyle: .file))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)

            ForEach(group.paths, id: \.self) { url in
                fileRow(url)
            }
        }
        .padding(.bottom, 8)
        .opacity(included ? 1 : 0.45)
    }

    @ViewBuilder
    private func fileRow(_ url: URL) -> some View {
        let isKeeper = url == keeper
        let faces = lib.itemsAtPath(url)
        let isProtected = faces.contains { SystemFontGuard.isProtected($0) }
        HStack(spacing: 10) {
            Image(systemName: isKeeper ? "crown.fill" : "trash")
                .foregroundStyle(isKeeper ? Color.yellow : Color.red.opacity(0.7))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if faces.count > 1 {
                        Text("\(faces.count) faces").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                    }
                    if FontLibrary.isCloudSynced(url) {
                        Label("Cloud", systemImage: "cloud")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if isProtected {
                        Label("Protected", systemImage: "lock.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(url.deletingLastPathComponent().path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !isKeeper {
                Button("Keep this one") { setKeeper(url) }
                    .font(.caption)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(isKeeper ? Color.yellow.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { setKeeper(url) }
    }
}
