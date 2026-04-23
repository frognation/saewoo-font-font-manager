import SwiftUI
import AppKit

/// "Fork" tool — extracts font info + (optionally) glyph outlines from one or
/// more fonts to produce a UFO or Designspace that Glyphs.app / RoboFont can
/// open directly. Licence / copyright / trademark fields are always stripped;
/// metrics (unitsPerEm, ascender, descender, cap-height, x-height, italic
/// angle, underline) are always preserved.
struct ForkView: View {
    @EnvironmentObject var lib: FontLibrary

    // MARK: - Source mode

    enum SourceMode: String, CaseIterable, Identifiable {
        case selected       // just the inspector's selected font
        case family         // every face sharing the selected font's family
        case currentList    // the current sidebar list (filter/collection/etc.)
        var id: String { rawValue }
        var label: String {
            switch self {
            case .selected:    return "Selected font only"
            case .family:      return "All styles in selected font's family"
            case .currentList: return "Current list in main pane"
            }
        }
    }

    // MARK: - State

    @State private var sourceMode: SourceMode = .selected
    @State private var glyphMode: UFOExporter.GlyphMode = .background
    @State private var resetIdentity: Bool = false
    @State private var outputDir: URL = defaultOutputDir()

    @State private var lastStatus: String? = nil
    @State private var lastError: String? = nil
    @State private var isWorking: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                sourceSection
                detectionCard
                glyphModeSection
                identitySection
                outputSection
                exportButton
                if let s = lastStatus {
                    Text(s).font(.caption).foregroundStyle(.green)
                        .textSelection(.enabled)
                }
                if let e = lastError {
                    Text(e).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.mint)
                Text("Fork").font(.title3).bold()
            }
            Text("Turn existing fonts into a fresh UFO or Designspace source you can open in Glyphs.app or RoboFont. License, copyright and trademark fields are always stripped. Grid, cap-height, x-height, italic angle, underline and similar metrics are preserved.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source").font(.headline)
            Picker("", selection: $sourceMode) {
                ForEach(SourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var detectionCard: some View {
        let items = resolvedItems()
        let scenario = scenarioFor(items: items)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: scenario.icon).foregroundStyle(scenario.tint)
                Text(scenario.title).font(.subheadline).bold()
            }
            Text(scenario.summary)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private var glyphModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glyph handling").font(.headline)
            ForEach(UFOExporter.GlyphMode.allCases) { m in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        glyphMode = m
                    } label: {
                        Image(systemName: glyphMode == m
                              ? "largecircle.fill.circle"
                              : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(glyphMode == m ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.shortLabel).font(.callout)
                        Text(m.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { glyphMode = m }
            }
        }
    }

    private var identitySection: some View {
        Toggle(isOn: $resetIdentity) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reset identity fields").font(.callout)
                Text("Blank familyName, styleName and postscriptFontName in the output — useful when starting an entirely new design. Metrics are preserved either way.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output location").font(.headline)
            HStack {
                Text(outputDir.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                Button("Choose…") { pickOutputDir() }
            }
        }
    }

    private var exportButton: some View {
        let items = resolvedItems()
        return HStack {
            Spacer()
            Button {
                Task { await performExport() }
            } label: {
                HStack(spacing: 6) {
                    if isWorking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.and.arrow.up") }
                    Text(isWorking ? "Exporting…" : "Export")
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(items.isEmpty || isWorking)
        }
    }

    // MARK: - Resolving source

    private func resolvedItems() -> [FontItem] {
        switch sourceMode {
        case .selected:
            if let id = lib.selectedFontID,
               let item = lib.items.first(where: { $0.id == id }) {
                return [item]
            }
            return []
        case .family:
            guard let id = lib.selectedFontID,
                  let seed = lib.items.first(where: { $0.id == id })
            else { return [] }
            return lib.items
                .filter { $0.familyKey == seed.familyKey }
                .sorted { $0.weight < $1.weight }
        case .currentList:
            return lib.currentItems()
        }
    }

    private struct Scenario {
        var title: String
        var summary: String
        var icon: String
        var tint: Color
        var kind: Kind
        enum Kind { case none, singleUFO, variableDesignspace, staticDesignspace }
    }

    private func scenarioFor(items: [FontItem]) -> Scenario {
        if items.isEmpty {
            return Scenario(
                title: "Nothing to fork",
                summary: "Select a font in the main list (or pick a family / current list option) to begin.",
                icon: "questionmark.circle",
                tint: .secondary,
                kind: .none
            )
        }
        if items.count == 1, let item = items.first {
            if item.isVariable {
                let instances = UFOExporter.readNamedInstances(item: item)
                let n = instances.isEmpty ? max(1, item.variationAxes.count * 3) : instances.count
                return Scenario(
                    title: "Variable font → Designspace (\(n) master\(n == 1 ? "" : "s"))",
                    summary: "\(item.displayName) has \(item.variationAxes.count) axis\(item.variationAxes.count == 1 ? "" : "es"). \(instances.isEmpty ? "No named instances found — we'll synthesise masters at each axis's min/default/max." : "Each named instance becomes one UFO master.")",
                    icon: "slider.horizontal.3",
                    tint: .purple,
                    kind: .variableDesignspace
                )
            } else {
                return Scenario(
                    title: "Single static font → UFO",
                    summary: "Produces one \(item.displayName).ufo.",
                    icon: "doc",
                    tint: .mint,
                    kind: .singleUFO
                )
            }
        }
        // Multiple items
        let variableCount = items.filter { $0.isVariable }.count
        if variableCount > 0 && items.count == variableCount {
            return Scenario(
                title: "Multiple variable fonts → Designspace",
                summary: "Named instances from each variable source will be combined into a single designspace. Axes are taken from the first font.",
                icon: "slider.horizontal.3",
                tint: .purple,
                kind: .variableDesignspace
            )
        }
        return Scenario(
            title: "Multiple styles → Designspace (\(items.count) masters)",
            summary: "Each style becomes a UFO master. A Weight axis is inferred from each style's weight trait (100…900). You can edit the designspace after opening it.",
            icon: "square.stack.3d.up",
            tint: .teal,
            kind: .staticDesignspace
        )
    }

    // MARK: - Export

    private func performExport() async {
        let items = resolvedItems()
        let scenario = scenarioFor(items: items)
        let options = UFOExporter.Options(glyphMode: glyphMode, resetIdentity: resetIdentity)

        lastStatus = nil
        lastError = nil
        isWorking = true
        defer { isWorking = false }

        // Capture values into locals so the detached task closure doesn't
        // have to reach back into MainActor-isolated @State vars.
        let outDir = outputDir
        let capturedItems = items

        do {
            switch scenario.kind {
            case .none:
                lastError = "No source selected."
                return
            case .singleUFO:
                let r = try await Task.detached(priority: .userInitiated) { () throws -> UFOExporter.Report in
                    try UFOExporter.export(item: capturedItems[0], to: outDir, options: options)
                }.value
                lastStatus = "Exported \(r.outputURL.lastPathComponent) · \(r.glyphCount) glyph\(r.glyphCount == 1 ? "" : "s") · UPM \(r.unitsPerEm)"
                NSWorkspace.shared.activateFileViewerSelecting([r.outputURL])
            case .variableDesignspace:
                let r = try await Task.detached(priority: .userInitiated) { () throws -> UFOExporter.DesignspaceReport in
                    try UFOExporter.exportDesignspaceFromVariable(
                        item: capturedItems[0], to: outDir, options: options)
                }.value
                lastStatus = "Exported \(r.outputURL.lastPathComponent) with \(r.ufoURLs.count) master\(r.ufoURLs.count == 1 ? "" : "s") · Axes: \(axisDescription(r.axes))"
                NSWorkspace.shared.activateFileViewerSelecting([r.outputURL])
            case .staticDesignspace:
                let r = try await Task.detached(priority: .userInitiated) { () throws -> UFOExporter.DesignspaceReport in
                    try UFOExporter.exportDesignspaceFromStatics(
                        items: capturedItems, to: outDir, options: options)
                }.value
                lastStatus = "Exported \(r.outputURL.lastPathComponent) with \(r.ufoURLs.count) master\(r.ufoURLs.count == 1 ? "" : "s") · Axes: \(axisDescription(r.axes))"
                NSWorkspace.shared.activateFileViewerSelecting([r.outputURL])
            }
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func axisDescription(_ axes: [(tag: String, name: String, min: Double, def: Double, max: Double)]) -> String {
        axes.map { "\($0.tag) (\(shortNum($0.min))…\(shortNum($0.max)))" }.joined(separator: ", ")
    }

    private func shortNum(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    // MARK: - Output dir picker

    private func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = outputDir
        panel.title = "Choose output folder"
        if panel.runModal() == .OK, let u = panel.url {
            outputDir = u
        }
    }

    private static func defaultOutputDir() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
