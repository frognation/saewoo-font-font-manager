import SwiftUI
import AppKit

/// How to pick the "winner" from each duplicate group when bulk-selecting extras.
enum KeepStrategy: String, CaseIterable, Identifiable {
    case composite   // favorited > active > user-folder > newest
    case newest      // latest dateAdded
    case userFolder  // anything inside ~/Library/Fonts wins
    case largest     // biggest file size (often most feature-complete)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .composite:  return "Smart — keep favorite/active/newest"
        case .newest:     return "Keep the newest"
        case .userFolder: return "Keep the one in ~/Library/Fonts"
        case .largest:    return "Keep the largest file"
        }
    }
    var shortLabel: String {
        switch self {
        case .composite:  return "Smart"
        case .newest:     return "Newest"
        case .userFolder: return "User folder"
        case .largest:    return "Largest"
        }
    }
    var explanation: String {
        switch self {
        case .composite:
            return "Keeps the one that's favorited > active > in your user Fonts folder > newest. Best default for most people."
        case .newest:
            return "Keeps whichever file was added most recently. Good after bulk updates from a foundry."
        case .userFolder:
            return "Keeps the copy inside ~/Library/Fonts over any system or vendor-installed copies."
        case .largest:
            return "Keeps the bigger file — usually the one with more OpenType features or language coverage."
        }
    }
}

struct DuplicatesView: View {
    @EnvironmentObject var lib: FontLibrary

    @State private var strategy: KeepStrategy = .composite
    @State private var selection: Set<String> = []
    @State private var pendingBatch: [FontItem] = []
    @State private var deleteError: String? = nil
    @State private var lastDeleteReport: String? = nil

    var body: some View {
        let groups = lib.duplicateGroups
        VStack(spacing: 0) {
            header(groupCount: groups.count,
                   fileCount: groups.reduce(0) { $0 + $1.items.count })
            if !groups.isEmpty {
                Divider()
                actionBar(groups: groups)
            }
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.name) { group in
                            DuplicateGroupRow(group: group,
                                              winner: winner(in: group.items),
                                              selection: $selection)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .confirmationDialog(
            "Move \(pendingBatch.count) file\(pendingBatch.count == 1 ? "" : "s") to Trash?",
            isPresented: Binding(
                get: { !pendingBatch.isEmpty },
                set: { if !$0 { pendingBatch = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                let batch = pendingBatch
                pendingBatch = []
                Task { await performBatchDelete(batch) }
            }
            Button("Cancel", role: .cancel) { pendingBatch = [] }
        } message: {
            Text("This moves every selected file to Trash — reversible from Finder. Active/favorite/collection references are cleaned up automatically.")
        }
        .alert("Some deletions failed",
               isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
               )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func header(groupCount: Int, fileCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("Duplicate PostScript Names").font(.title3).bold()
                }
                Text("Files sharing the same PostScript name. The OS picks one and ignores the rest — the extras waste disk space and cause \"wrong glyphs\" bugs. Choose a Keep strategy, then Delete Extras to purge.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report = lastDeleteReport {
                    Text(report).font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            if groupCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(groupCount) group\(groupCount == 1 ? "" : "s")")
                        .font(.caption).bold()
                    Text("\(fileCount) files · \(totalExtras()) extras")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder
    private func actionBar(groups: [(name: String, items: [FontItem])]) -> some View {
        HStack(spacing: 10) {
            // Strategy menu
            Menu {
                ForEach(KeepStrategy.allCases) { s in
                    Button { strategy = s } label: {
                        if strategy == s {
                            Label(s.label, systemImage: "checkmark")
                        } else {
                            Text(s.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "crown")
                    Text("Keep: \(strategy.shortLabel)")
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 190)
            .help(strategy.explanation)

            Text(strategy.explanation)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)
                .layoutPriority(0)

            Spacer()

            Button {
                selectAllExtras(groups: groups)
            } label: {
                Label("Select Extras (\(allExtrasCount(groups)))", systemImage: "checkmark.circle")
            }
            .disabled(allExtrasCount(groups) == 0)

            Button {
                selection.removeAll()
            } label: { Text("Clear") }
                .disabled(selection.isEmpty)

            Button(role: .destructive) {
                pendingBatch = groups.flatMap { $0.items }.filter { selection.contains($0.id) }
            } label: {
                Label("Delete \(selection.count) Selected",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .environment(\.duplicatesSelection, $selection)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("No duplicates").font(.title3).bold()
            Text("Every font in your library has a unique PostScript name. Nothing to clean up.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Logic

    private func winner(in group: [FontItem]) -> FontItem {
        switch strategy {
        case .newest:
            return group.max { $0.dateAdded < $1.dateAdded } ?? group[0]
        case .largest:
            return group.max { $0.fileSize < $1.fileSize } ?? group[0]
        case .userFolder:
            if let u = group.first(where: { $0.fileURL.path.contains("/Library/Fonts") &&
                                            $0.fileURL.path.hasPrefix(NSHomeDirectory()) }) { return u }
            // fall through to newest as tiebreaker
            return group.max { $0.dateAdded < $1.dateAdded } ?? group[0]
        case .composite:
            // favorited > active > user-folder > newest
            if let fav = group.first(where: { lib.favorites.contains($0.id) }) { return fav }
            if let act = group.first(where: { lib.isActive($0) }) { return act }
            if let u = group.first(where: { $0.fileURL.path.contains("/Library/Fonts") &&
                                            $0.fileURL.path.hasPrefix(NSHomeDirectory()) }) { return u }
            return group.max { $0.dateAdded < $1.dateAdded } ?? group[0]
        }
    }

    private func selectAllExtras(groups: [(name: String, items: [FontItem])]) {
        var ids: Set<String> = []
        for group in groups {
            let keeper = winner(in: group.items)
            for item in group.items where item.id != keeper.id {
                ids.insert(item.id)
            }
        }
        selection = ids
    }

    private func allExtrasCount(_ groups: [(name: String, items: [FontItem])]) -> Int {
        groups.reduce(0) { $0 + max(0, $1.items.count - 1) }
    }

    private func totalExtras() -> Int {
        allExtrasCount(lib.duplicateGroups)
    }

    private func performBatchDelete(_ items: [FontItem]) async {
        var deleted = 0
        var errors: [String] = []
        for item in items {
            do {
                try await lib.deleteFontFile(item)
                deleted += 1
            } catch {
                errors.append("\(item.fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        selection.removeAll()
        lastDeleteReport = "Moved \(deleted) file\(deleted == 1 ? "" : "s") to Trash."
        if !errors.isEmpty {
            deleteError = errors.joined(separator: "\n")
        }
    }
}

/// Environment passthrough so every row can mutate the same selection set
/// without each taking a binding as a parameter.
private struct DuplicatesSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<Set<String>> = .constant([])
}
extension EnvironmentValues {
    var duplicatesSelection: Binding<Set<String>> {
        get { self[DuplicatesSelectionKey.self] }
        set { self[DuplicatesSelectionKey.self] = newValue }
    }
}

/// One duplicate group — the PS-name header plus every file claiming that name.
private struct DuplicateGroupRow: View {
    @EnvironmentObject var lib: FontLibrary
    let group: (name: String, items: [FontItem])
    let winner: FontItem
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(group.name)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                Text("\(group.items.count) files")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)

            // Files
            ForEach(group.items) { item in
                DuplicateFileRow(item: item,
                                 isWinner: item.id == winner.id,
                                 selection: $selection)
            }
        }
        .padding(.bottom, 8)
    }
}

/// One file row within a duplicate group — checkbox, path, metadata, actions.
private struct DuplicateFileRow: View {
    @EnvironmentObject var lib: FontLibrary
    let item: FontItem
    let isWinner: Bool
    @Binding var selection: Set<String>

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Checkbox (winners can't be checked via the standard box — too easy to misclick)
            Toggle("", isOn: Binding(
                get: { selection.contains(item.id) },
                set: { on in
                    if on { selection.insert(item.id) }
                    else  { selection.remove(item.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            // Winner crown OR active dot
            if isWinner {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.yellow)
                    .help("Keep — picked by current strategy")
            } else {
                Circle()
                    .fill(lib.isActive(item) ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.fileURL.lastPathComponent)
                        .font(.system(.body, design: .default).weight(.medium))
                        .lineLimit(1)
                    if lib.favorites.contains(item.id) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow).font(.caption)
                    }
                }
                Text(item.fileURL.deletingLastPathComponent().path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    Label(item.familyName + " · " + item.styleName, systemImage: "textformat")
                        .font(.caption2).foregroundStyle(.secondary)
                    Label(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
                          systemImage: "internaldrive")
                        .font(.caption2).foregroundStyle(.secondary)
                    Label(item.foundry, systemImage: "building.2")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(
            isWinner
                ? Color.yellow.opacity(0.06)
                : (selection.contains(item.id) ? Color.red.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { lib.selectedFontID = item.id }
    }
}
