import SwiftUI
import AppKit

/// Filtered view of Adobe Fonts already synced locally by Creative Cloud.
///
/// There is no public Adobe Fonts API for browsing or downloading — apps can
/// only see fonts the user has activated through CC, which are cached under
/// `~/Library/Application Support/Adobe/CoreSync/plugins/livetype/.r/`. This
/// view pulls just those entries out of the library and presents them with
/// a friendlier header, plus a helpful empty state when CC isn't installed.
struct AdobeFontsView: View {
    @EnvironmentObject var lib: FontLibrary

    private var cacheURL: URL? { FontScanner.adobeFontsCacheURL }

    private var adobeItems: [FontItem] {
        guard let root = cacheURL?.standardizedFileURL.path else { return [] }
        return lib.items
            .filter { $0.fileURL.standardizedFileURL.path.hasPrefix(root) }
            .sorted {
                if $0.familyName.lowercased() == $1.familyName.lowercased() {
                    return $0.styleName < $1.styleName
                }
                return $0.familyName.lowercased() < $1.familyName.lowercased()
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cacheURL == nil {
                creativeCloudMissingState
            } else if adobeItems.isEmpty {
                noActivatedFontsState
            } else {
                listContent
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "a.circle.fill")
                        .foregroundStyle(Color(red: 0.98, green: 0.2, blue: 0.2))
                    Text("Adobe Fonts").font(.title3).bold()
                }
                Text("Fonts synced locally by Creative Cloud's font daemon. Adobe doesn't expose a public API, so browsing the catalog and activating new fonts has to happen inside Creative Cloud — clicking \"Open Creative Cloud\" below takes you there.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let url = cacheURL {
                    Text("\(adobeItems.count) fonts").font(.caption).bold()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Label("Reveal cache", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                Button {
                    openCreativeCloud()
                } label: { Label("Open Creative Cloud", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
    }

    private var creativeCloudMissingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "a.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 0.98, green: 0.2, blue: 0.2).opacity(0.8))
            Text("Creative Cloud not detected").font(.title3).bold()
            Text("Adobe Fonts are synced by the Creative Cloud desktop app to a local cache. That cache doesn't exist on this Mac yet — install CC and sign in with an Adobe subscription to use Adobe Fonts here.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://creativecloud.adobe.com/apps/download/creative-cloud") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Download Creative Cloud", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    if let url = URL(string: "https://fonts.adobe.com") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Browse Adobe Fonts", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noActivatedFontsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No Adobe Fonts activated").font(.title3).bold()
            Text("Creative Cloud is set up, but no fonts have been activated yet. Activate fonts at fonts.adobe.com — they'll appear here after CC syncs them.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                if let url = URL(string: "https://fonts.adobe.com") {
                    NSWorkspace.shared.open(url)
                }
            } label: { Label("Browse Adobe Fonts", systemImage: "safari") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(adobeItems) { item in
                    row(item: item)
                    Divider().opacity(0.3)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func row(item: FontItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(lib.isActive(item) ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.categories.map(\.label).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(item.postScriptName)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }

            Spacer()

            FontPreviewText(item: item, size: 20, text: "Aa Bb 123")
                .frame(maxWidth: 240, alignment: .trailing)
                .lineLimit(1).truncationMode(.tail)

            Button {
                lib.toggleFavorite(item)
            } label: {
                Image(systemName: lib.favorites.contains(item.id) ? "star.fill" : "star")
                    .foregroundStyle(lib.favorites.contains(item.id) ? Color.yellow : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { lib.selectedFontID = item.id }
        .background(lib.selectedFontID == item.id ? Color.accentColor.opacity(0.1) : .clear)
    }

    private func openCreativeCloud() {
        // CC's URL scheme — opens the Fonts tab directly.
        if let url = URL(string: "creativecloud://open/app/fonts") {
            NSWorkspace.shared.open(url)
        }
    }
}
