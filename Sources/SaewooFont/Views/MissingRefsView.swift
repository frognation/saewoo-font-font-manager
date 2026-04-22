import SwiftUI

/// Shows library references (favorites, projects, palettes, variable instances)
/// that point at FontItem IDs which no longer exist — i.e. the underlying font
/// file was deleted, moved outside all scan paths, or had its path change in
/// a way that regenerated its ID. Typically happens after manual cleanup in
/// Finder or a Dropbox/Drive sync move. Non-destructive to files.
struct MissingRefsView: View {
    @EnvironmentObject var lib: FontLibrary
    @State private var report: String? = nil

    var body: some View {
        let missing = lib.missingReferences
        VStack(spacing: 0) {
            header(count: missing.count)
            Divider()
            if missing.isEmpty {
                emptyState
            } else {
                actionBar(count: missing.count)
                Divider()
                list(missing: missing)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus").foregroundStyle(.indigo)
                    Text("Missing References").font(.title3).bold()
                }
                Text("Favorites, Projects, Palettes, and saved Variable Instances that reference a font that's no longer in your library. They don't hurt anything but they clutter counts and can confuse toggling behaviour. Clean up to remove the dangling IDs — your files are untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report { Text(report).font(.caption).foregroundStyle(.green) }
            }
            Spacer()
            Text("\(count) dangling ref\(count == 1 ? "" : "s")")
                .font(.caption).bold()
        }
        .padding(16)
    }

    private func actionBar(count: Int) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                lib.cleanupMissingReferences()
                report = "Removed \(count) dangling reference\(count == 1 ? "" : "s")."
            } label: {
                Label("Clean Up (\(count))", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private func list(missing: [FontLibrary.MissingReference]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(missing) { ref in
                    row(ref: ref)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    @ViewBuilder
    private func row(ref: FontLibrary.MissingReference) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(ref.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ForEach(ref.locations, id: \.self) { loc in
                        Text(loc)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.indigo)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("No dangling references").font(.title3).bold()
            Text("Every favorite, project member, and saved instance points at a font that still exists.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
