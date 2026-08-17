import SwiftUI
import AppKit

/// Fork moved out of this app into **Type Forker**, its own repository.
///
/// The exporter was 2 375 lines that touched the rest of the manager in
/// exactly two places, so it was never really part of this app — and the two
/// have different completion bars. A font manager that is 90 % done is useful;
/// a UFO exporter that is 90 % done writes source files that are *silently*
/// wrong, and you find out after you have started redrawing.
///
/// The Tools entry stays so the workflow is still discoverable from the
/// library, but all it does now is hand the selected font to the other app.
struct ForkLauncherView: View {
    @EnvironmentObject var lib: FontLibrary
    @EnvironmentObject var sel: SelectionModel

    @State private var launchError: String?

    /// Where the split-out app lands once it ships.
    private static let appPaths = [
        "/Applications/Type Forker.app",
        NSHomeDirectory() + "/Applications/Type Forker.app",
    ]
    /// Fallback while it is still source-only.
    private static let repoPath =
        NSHomeDirectory() + "/Documents/GitHub/Projects/type-forker"

    private var installedApp: URL? {
        Self.appPaths.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private var selectedFont: FontItem? {
        guard let id = sel.selectedFontID else { return nil }
        return lib.items.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44)).foregroundStyle(.mint)
            Text("Fork moved to Type Forker").font(.title3).bold()
            Text("""
            Turning a compiled font back into editable UFO / Designspace source \
            grew past what belongs in a font manager, so it now lives in its own \
            app. Pick a font here and hand it over.
            """)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            if let f = selectedFont {
                Text(f.displayName)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            } else {
                Text("No font selected — pick one in the library first.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if installedApp != nil {
                Button {
                    launch()
                } label: {
                    Label("Open in Type Forker", systemImage: "arrow.up.forward.app")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent).tint(.mint)
                .disabled(selectedFont == nil)
            } else {
                // Not built yet — say so plainly rather than failing on click.
                VStack(spacing: 8) {
                    Text("Type Forker isn't installed yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reveal the repository") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: Self.repoPath)])
                    }
                    Text(Self.repoPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let e = launchError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func launch() {
        guard let app = installedApp, let font = selectedFont else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([font.fileURL], withApplicationAt: app,
                                configuration: cfg) { _, error in
            if let error {
                Task { @MainActor in launchError = error.localizedDescription }
            }
        }
    }
}
