import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

/// FontGoggle-style proof sheet for an installed font with three tabs:
/// **Type** (live editable canvas), **Glyphs** (every supported character in a
/// grid), and **Coverage** (Unicode-block heat map). The Type tab exports the
/// rendered canvas as PDF or PNG.
///
/// Source files (.ufo, .glyphs, .glyphspackage, .designspace) are not
/// supported — they need compilation or a dedicated parser out of scope here.
struct ProofSheetView: View {
    @EnvironmentObject var lib: FontLibrary

    enum Tab: String, CaseIterable, Identifiable {
        case type, glyphs, coverage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .type: return "Type"
            case .glyphs: return "Glyphs"
            case .coverage: return "Coverage"
            }
        }
        var icon: String {
            switch self {
            case .type: return "keyboard"
            case .glyphs: return "square.grid.3x3"
            case .coverage: return "chart.bar.xaxis"
            }
        }
    }

    // Shared state across tabs
    @State private var selectedItemID: String? = nil
    @State private var tab: Tab = .type
    @State private var enabledFeatures: Set<String> = []
    @State private var axisValues: [UInt32: Double] = [:]

    // Type-tab state
    @State private var sampleText: String = Self.defaultSampleText
    @State private var fontSize: Double = 64
    @State private var lineHeight: Double = 1.2
    @State private var letterSpacing: Double = 0
    @State private var alignment: NSTextAlignment = .left

    // Glyph-tab state
    @State private var glyphGridSize: Double = 40
    @State private var glyphCache: (fontID: String, chars: [UInt32]) = ("", [])
    @State private var glyphFilter: String = ""

    // Coverage-tab state
    @State private var coverageCache: (fontID: String, rows: [BlockCoverage]) = ("", [])

    // Export
    @StateObject private var canvasHandle = ProofCanvasHandle()
    @State private var exportReport: String? = nil
    @State private var exportError: String? = nil

    private static let defaultSampleText = """
The quick brown fox jumps over the lazy dog.
0 1 2 3 4 5 6 7 8 9 — fi fl ffi ct st — 1/2 1/4 3/4

ABCDEFGHIJKLMNOPQRSTUVWXYZ
abcdefghijklmnopqrstuvwxyz
"""

    private var item: FontItem? {
        if let id = selectedItemID, let m = lib.items.first(where: { $0.id == id }) { return m }
        return lib.items.first
    }

    var body: some View {
        if let item = item {
            VStack(spacing: 0) {
                header(item)
                Divider()
                tabSwitcher
                Divider()
                switch tab {
                case .type:     typeTab(item)
                case .glyphs:   glyphsTab(item)
                case .coverage: coverageTab(item)
                }
            }
            .onChange(of: selectedItemID) { _ in
                axisValues = Dictionary(
                    uniqueKeysWithValues: item.variationAxes.map { ($0.tag, $0.defaultValue) })
                enabledFeatures.removeAll()
                glyphCache = ("", [])
                coverageCache = ("", [])
            }
            .onAppear {
                if axisValues.isEmpty {
                    axisValues = Dictionary(
                        uniqueKeysWithValues: item.variationAxes.map { ($0.tag, $0.defaultValue) })
                }
            }
            .alert("Export failed",
                   isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                   )) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
        } else {
            emptyLibrary
        }
    }

    // MARK: - Header & tab switcher

    private func header(_ item: FontItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "text.word.spacing").foregroundStyle(.pink)
                    Text("Proof Sheet").font(.title3).bold()
                }
                Text("Type into a font, explore every glyph it ships, and see which Unicode blocks it covers. Source files (.ufo, .glyphs) need to be compiled first — open the .otf.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540, alignment: .leading)
            }
            Spacer()
            fontPicker(current: item)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private func fontPicker(current: FontItem) -> some View {
        Menu {
            let favs = lib.items.filter { lib.favorites.contains($0.id) }
            if !favs.isEmpty {
                Section("Favorites") {
                    ForEach(favs) { f in
                        Button(f.displayName) { selectedItemID = f.id }
                    }
                }
            }
            Section("All fonts") {
                ForEach(lib.items) { f in
                    Button(f.displayName) { selectedItemID = f.id }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "textformat").foregroundStyle(.secondary)
                Text(current.displayName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 280)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon)
                        Text(t.label)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(tab == t ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(tab == t ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Type tab

    @ViewBuilder
    private func typeTab(_ item: FontItem) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                ProofCanvas(text: $sampleText,
                            font: currentFont(for: item),
                            lineHeight: lineHeight,
                            letterSpacing: letterSpacing,
                            alignment: alignment,
                            handle: canvasHandle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                canvasControls(item)
                if let rpt = exportReport {
                    banner(rpt, color: .green, icon: "checkmark.circle.fill")
                }
            }
            .frame(minWidth: 420, idealWidth: 760)
            controlsPane(for: item)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
        }
    }

    private func canvasControls(_ item: FontItem) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Slider(value: $fontSize, in: 10...240).frame(width: 130)
                Text("\(Int(fontSize))pt").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down").foregroundStyle(.secondary).help("Line height")
                Slider(value: $lineHeight, in: 0.8...2.4).frame(width: 80)
                Text(String(format: "%.2f", lineHeight)).font(.caption).foregroundStyle(.secondary).frame(width: 36)
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary).help("Letter spacing")
                Slider(value: $letterSpacing, in: -3...10).frame(width: 80)
                Text(String(format: "%.1f", letterSpacing)).font(.caption).foregroundStyle(.secondary).frame(width: 36)
            }
            Picker("", selection: $alignment) {
                Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                Image(systemName: "text.alignright").tag(NSTextAlignment.right)
                Image(systemName: "text.justify").tag(NSTextAlignment.justified)
            }
            .pickerStyle(.segmented).frame(width: 130)
            Spacer()
            Menu {
                Button("Export as PDF…") { export(as: .pdf, fontName: item.displayName) }
                Button("Export as PNG…") { export(as: .png, fontName: item.displayName) }
                Divider()
                Button("Copy as Image") { copyAsImage() }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).controlSize(.small).frame(width: 90)
            Button {
                sampleText = Self.defaultSampleText
                fontSize = 64; lineHeight = 1.2; letterSpacing = 0; alignment = .left
                enabledFeatures.removeAll()
                axisValues = Dictionary(
                    uniqueKeysWithValues: item.variationAxes.map { ($0.tag, $0.defaultValue) })
            } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func controlsPane(for item: FontItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !item.variationAxes.isEmpty {
                    axesSection(item); Divider()
                }
                featureSection
                Divider()
                metadataSection(item)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func axesSection(_ item: FontItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Variable Axes", systemImage: "slider.horizontal.3").font(.headline)
            ForEach(item.variationAxes) { axis in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(axis.name).font(.system(size: 12, weight: .medium))
                        Text(axis.tagString).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        Spacer()
                        Text(formatNum(axisValues[axis.tag] ?? axis.defaultValue))
                            .font(.system(.caption2, design: .monospaced))
                    }
                    Slider(
                        value: Binding(
                            get: { axisValues[axis.tag] ?? axis.defaultValue },
                            set: { axisValues[axis.tag] = $0 }
                        ),
                        in: axis.range
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("OpenType Features", systemImage: "switch.2").font(.headline)
                Spacer()
                Button("Clear all") { enabledFeatures.removeAll() }
                    .font(.caption).buttonStyle(.borderless)
                    .disabled(enabledFeatures.isEmpty)
            }
            Text("Not every font supports every feature — toggling one that's not implemented simply has no effect.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(OpenTypeFeature.groups, id: \.self) { group in
                let features = OpenTypeFeature.all.filter { $0.group == group }
                if !features.isEmpty {
                    Text(group).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(features) { f in featureToggle(f) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func featureToggle(_ f: OpenTypeFeature) -> some View {
        Toggle(isOn: Binding(
            get: { enabledFeatures.contains(f.tag) },
            set: { on in
                if on { enabledFeatures.insert(f.tag) } else { enabledFeatures.remove(f.tag) }
            }
        )) {
            HStack(spacing: 6) {
                Text(f.tag).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Text(f.name).font(.caption)
            }
        }
        .toggleStyle(.checkbox).help(f.description)
    }

    @ViewBuilder
    private func metadataSection(_ item: FontItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Font Info", systemImage: "info.circle").font(.headline).padding(.bottom, 4)
            infoRow("Family", item.familyName)
            infoRow("Style", item.styleName)
            infoRow("PostScript", item.postScriptName, mono: true)
            infoRow("Foundry", item.foundry)
            infoRow("Format", item.format)
            infoRow("Categories", item.categories.map(\.label).joined(separator: ", "))
            infoRow("Glyphs", "\(item.glyphCount)")
            infoRow("File", item.fileURL.lastPathComponent, mono: true)
            infoRow("Size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            if item.isVariable { infoRow("Variable", "\(item.variationAxes.count) axes") }
        }
    }

    @ViewBuilder
    private func infoRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).frame(width: 84, alignment: .leading)
                .foregroundStyle(.secondary).font(.caption)
            Text(value).font(mono ? .system(.caption, design: .monospaced) : .caption).textSelection(.enabled)
        }
    }

    // MARK: - Glyphs tab

    @ViewBuilder
    private func glyphsTab(_ item: FontItem) -> some View {
        let chars = supportedCharacters(for: item)
        let filtered = filteredGlyphs(chars)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(chars.count) supported characters")
                    .font(.caption).bold()
                TextField("Filter (e.g. 'U+00A0' or 'A')", text: $glyphFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size").foregroundStyle(.secondary)
                    Slider(value: $glyphGridSize, in: 24...96).frame(width: 140)
                    Text("\(Int(glyphGridSize))pt").font(.caption).foregroundStyle(.secondary).frame(width: 44)
                }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
                    Text("No matches").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: max(72, CGFloat(glyphGridSize + 24))), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(filtered, id: \.self) { cp in
                            glyphCell(cp: cp, item: item)
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    @ViewBuilder
    private func glyphCell(cp: UInt32, item: FontItem) -> some View {
        let scalar = Unicode.Scalar(cp).map { String(Character($0)) } ?? ""
        VStack(spacing: 4) {
            Text(scalar)
                .font(Font(currentFont(for: item, size: CGFloat(glyphGridSize))))
                .frame(maxWidth: .infinity, minHeight: CGFloat(glyphGridSize + 10))
                .padding(.top, 6)
            Text(String(format: "U+%04X", cp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .help("U+\(String(format: "%04X", cp)) — \(scalar)")
    }

    // MARK: - Coverage tab

    @ViewBuilder
    private func coverageTab(_ item: FontItem) -> some View {
        let rows = coverageRows(for: item)
        let coveredBlocks = rows.filter { $0.count > 0 }.count
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unicode Coverage").font(.headline)
                    Text("\(coveredBlocks) of \(rows.count) blocks with at least one supported character.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in coverageRow(row) }
                }
                .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    @ViewBuilder
    private func coverageRow(_ row: BlockCoverage) -> some View {
        let ratio = row.total == 0 ? 0.0 : Double(row.count) / Double(row.total)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 12, weight: .medium))
                Text(String(format: "U+%04X–U+%04X", row.start, row.end))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 220, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ratio > 0.95 ? Color.green
                              : ratio > 0.5 ? Color.teal
                              : ratio > 0.1 ? Color.orange
                              : Color.secondary.opacity(0.4))
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 10)
            Text("\(row.count) / \(row.total)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ratio > 0 ? .primary : .secondary).bold().frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Font building

    private func currentFont(for item: FontItem, size: CGFloat? = nil) -> NSFont {
        ProofFontFactory.font(
            for: item,
            size: size ?? CGFloat(fontSize),
            features: enabledFeatures,
            axisValues: axisValues
        ) ?? NSFont.systemFont(ofSize: size ?? CGFloat(fontSize))
    }

    // MARK: - Glyph/coverage caches

    private func supportedCharacters(for item: FontItem) -> [UInt32] {
        if glyphCache.fontID == item.id { return glyphCache.chars }
        let chars = ProofGlyphs.supported(for: item)
        DispatchQueue.main.async { self.glyphCache = (item.id, chars) }
        return chars
    }

    private func filteredGlyphs(_ all: [UInt32]) -> [UInt32] {
        let q = glyphFilter.trimmingCharacters(in: .whitespaces).uppercased()
        guard !q.isEmpty else { return all }
        // Match hex codepoint, with or without "U+" prefix.
        if let cp = UInt32(q.replacingOccurrences(of: "U+", with: ""), radix: 16) {
            return all.contains(cp) ? [cp] : []
        }
        // Match character literal.
        if q.count == 1, let scalar = q.unicodeScalars.first {
            let target = UInt32(scalar.value)
            return all.contains(target) ? [target] : []
        }
        return []
    }

    private func coverageRows(for item: FontItem) -> [BlockCoverage] {
        if coverageCache.fontID == item.id { return coverageCache.rows }
        let chars = Set(supportedCharacters(for: item))
        let rows = UnicodeBlocks.all.map { block -> BlockCoverage in
            let total = Int(block.end - block.start) + 1
            let count = (block.start...block.end).reduce(0) { $0 + (chars.contains($1) ? 1 : 0) }
            return BlockCoverage(name: block.name, start: block.start, end: block.end,
                                 count: count, total: total)
        }
        DispatchQueue.main.async { self.coverageCache = (item.id, rows) }
        return rows
    }

    // MARK: - Export

    private enum ExportFormat { case pdf, png }

    private func export(as format: ExportFormat, fontName: String) {
        guard let tv = canvasHandle.textView else { return }
        let panel = NSSavePanel()
        panel.title = format == .pdf ? "Export Proof as PDF" : "Export Proof as PNG"
        panel.nameFieldStringValue = "\(fontName) Proof".replacingOccurrences(of: "/", with: "-")
        panel.allowedContentTypes = [format == .pdf ? UTType.pdf : UTType.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .pdf:
                let data = tv.dataWithPDF(inside: tv.bounds)
                try data.write(to: url)
            case .png:
                let data = try proofPNG(from: tv)
                try data.write(to: url)
            }
            exportReport = "Exported to \(url.lastPathComponent)"
            Task { try? await Task.sleep(nanoseconds: 2_400_000_000)
                await MainActor.run { exportReport = nil }
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func copyAsImage() {
        guard let tv = canvasHandle.textView else { return }
        do {
            let data = try proofPNG(from: tv)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            exportReport = "Copied PNG to clipboard"
            Task { try? await Task.sleep(nanoseconds: 2_400_000_000)
                await MainActor.run { exportReport = nil }
            }
        } catch { exportError = error.localizedDescription }
    }

    private func proofPNG(from tv: NSTextView) throws -> Data {
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else {
            throw NSError(domain: "Proof", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't create bitmap"])
        }
        tv.cacheDisplay(in: tv.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Proof", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't encode PNG"])
        }
        return data
    }

    // MARK: - Misc

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.word.spacing")
                .font(.system(size: 44)).foregroundStyle(.pink)
            Text("No fonts to proof").font(.title3).bold()
            Text("Add a source or scan your library first.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
    }

    private func formatNum(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.01 { return "\(Int(v.rounded()))" }
        return String(format: "%.1f", v)
    }
}

// MARK: - OpenTypeFeature catalogue

struct OpenTypeFeature: Identifiable, Hashable {
    var id: String { tag }
    let tag: String
    let name: String
    let description: String
    let group: String

    static let groups = ["Ligatures", "Case", "Numbers", "Stylistic", "Other"]
    static let all: [OpenTypeFeature] = [
        .init(tag: "liga", name: "Standard Ligatures", description: "fi, fl, ffi, ffl — usually on by default.", group: "Ligatures"),
        .init(tag: "dlig", name: "Discretionary Ligatures", description: "Decorative ligatures (ct, st, ...). Off by default.", group: "Ligatures"),
        .init(tag: "clig", name: "Contextual Ligatures", description: "Ligatures that depend on surrounding letters.", group: "Ligatures"),
        .init(tag: "hlig", name: "Historical Ligatures", description: "Archaic ligatures like long-s (ſ).", group: "Ligatures"),
        .init(tag: "smcp", name: "Small Caps", description: "Replaces lowercase with small-capital forms.", group: "Case"),
        .init(tag: "c2sc", name: "Caps → Small Caps", description: "Scales real uppercase down to small-cap size.", group: "Case"),
        .init(tag: "case", name: "Case-Sensitive Forms", description: "Shifts punctuation to align with all-caps.", group: "Case"),
        .init(tag: "onum", name: "Old-Style Numerals", description: "Numerals with varying heights (3, 5, 7 descend).", group: "Numbers"),
        .init(tag: "lnum", name: "Lining Numerals", description: "Uniform-height numerals, default in most fonts.", group: "Numbers"),
        .init(tag: "pnum", name: "Proportional Numerals", description: "Each numeral has its natural width.", group: "Numbers"),
        .init(tag: "tnum", name: "Tabular Numerals", description: "Fixed-width numerals for columns of figures.", group: "Numbers"),
        .init(tag: "frac", name: "Fractions", description: "1/2 → proper ½, etc.", group: "Numbers"),
        .init(tag: "zero", name: "Slashed Zero", description: "Distinguishes 0 from the letter O.", group: "Numbers"),
        .init(tag: "ordn", name: "Ordinals", description: "2nd, 3rd with superscripted suffix.", group: "Numbers"),
        .init(tag: "sups", name: "Superscript", description: "x² style raised forms.", group: "Numbers"),
        .init(tag: "subs", name: "Subscript", description: "H₂O style lowered forms.", group: "Numbers"),
        .init(tag: "salt", name: "Stylistic Alternates", description: "Alternate letter shapes the designer provided.", group: "Stylistic"),
        .init(tag: "calt", name: "Contextual Alternates", description: "Alternates based on surrounding letters.", group: "Stylistic"),
        .init(tag: "swsh", name: "Swashes", description: "Flourished letters for decorative use.", group: "Stylistic"),
        .init(tag: "titl", name: "Titling", description: "Forms optimized for large display sizes.", group: "Stylistic"),
        .init(tag: "ss01", name: "Stylistic Set 01", description: "Font-specific alternate set 1.", group: "Stylistic"),
        .init(tag: "ss02", name: "Stylistic Set 02", description: "Font-specific alternate set 2.", group: "Stylistic"),
        .init(tag: "ss03", name: "Stylistic Set 03", description: "Font-specific alternate set 3.", group: "Stylistic"),
        .init(tag: "ss04", name: "Stylistic Set 04", description: "Font-specific alternate set 4.", group: "Stylistic"),
        .init(tag: "ss05", name: "Stylistic Set 05", description: "Font-specific alternate set 5.", group: "Stylistic"),
        .init(tag: "ss06", name: "Stylistic Set 06", description: "Font-specific alternate set 6.", group: "Stylistic"),
        .init(tag: "ss07", name: "Stylistic Set 07", description: "Font-specific alternate set 7.", group: "Stylistic"),
        .init(tag: "ss08", name: "Stylistic Set 08", description: "Font-specific alternate set 8.", group: "Stylistic"),
        .init(tag: "kern", name: "Kerning", description: "Pair-wise spacing adjustments. Nearly always on.", group: "Other"),
    ]
}

// MARK: - Glyph discovery

enum ProofGlyphs {
    /// Returns every BMP codepoint this font renders a non-zero glyph for.
    /// Iterates 0x0020..0xFFFD (skipping surrogates) — fast on modern machines.
    static func supported(for item: FontItem) -> [UInt32] {
        guard
            let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL) as? [CTFontDescriptor],
            let desc = descs.first(where: { d in
                (CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String) == item.postScriptName
            }) ?? descs.first
        else { return [] }
        let font = CTFontCreateWithFontDescriptor(desc, 20, nil)
        var out: [UInt32] = []
        out.reserveCapacity(1024)
        var uc: UniChar = 0
        var gid: CGGlyph = 0
        for cp in UInt32(0x0020)...UInt32(0xFFFD) {
            if cp >= 0xD800 && cp <= 0xDFFF { continue }   // skip surrogates
            uc = UniChar(cp)
            CTFontGetGlyphsForCharacters(font, &uc, &gid, 1)
            if gid != 0 { out.append(cp) }
        }
        return out
    }
}

// MARK: - Unicode blocks

struct UnicodeBlock: Identifiable {
    var id: UInt32 { start }
    let name: String
    let start: UInt32
    let end: UInt32
}

struct BlockCoverage: Identifiable {
    var id: UInt32 { start }
    let name: String
    let start: UInt32
    let end: UInt32
    let count: Int
    let total: Int
}

enum UnicodeBlocks {
    /// A curated subset of common Unicode blocks that font libraries care about.
    /// Not exhaustive — aims to cover typical Latin, Greek, Cyrillic, punctuation,
    /// symbol, and CJK ranges without overwhelming the UI.
    static let all: [UnicodeBlock] = [
        .init(name: "Basic Latin",              start: 0x0000, end: 0x007F),
        .init(name: "Latin-1 Supplement",       start: 0x0080, end: 0x00FF),
        .init(name: "Latin Extended-A",         start: 0x0100, end: 0x017F),
        .init(name: "Latin Extended-B",         start: 0x0180, end: 0x024F),
        .init(name: "IPA Extensions",           start: 0x0250, end: 0x02AF),
        .init(name: "Spacing Modifier Letters", start: 0x02B0, end: 0x02FF),
        .init(name: "Combining Diacriticals",   start: 0x0300, end: 0x036F),
        .init(name: "Greek and Coptic",         start: 0x0370, end: 0x03FF),
        .init(name: "Cyrillic",                 start: 0x0400, end: 0x04FF),
        .init(name: "Hebrew",                   start: 0x0590, end: 0x05FF),
        .init(name: "Arabic",                   start: 0x0600, end: 0x06FF),
        .init(name: "Devanagari",               start: 0x0900, end: 0x097F),
        .init(name: "Bengali",                  start: 0x0980, end: 0x09FF),
        .init(name: "Thai",                     start: 0x0E00, end: 0x0E7F),
        .init(name: "Latin Extended Additional",start: 0x1E00, end: 0x1EFF),
        .init(name: "Greek Extended",           start: 0x1F00, end: 0x1FFF),
        .init(name: "General Punctuation",      start: 0x2000, end: 0x206F),
        .init(name: "Superscripts & Subscripts",start: 0x2070, end: 0x209F),
        .init(name: "Currency Symbols",         start: 0x20A0, end: 0x20CF),
        .init(name: "Letterlike Symbols",       start: 0x2100, end: 0x214F),
        .init(name: "Number Forms",             start: 0x2150, end: 0x218F),
        .init(name: "Arrows",                   start: 0x2190, end: 0x21FF),
        .init(name: "Mathematical Operators",   start: 0x2200, end: 0x22FF),
        .init(name: "Box Drawing",              start: 0x2500, end: 0x257F),
        .init(name: "Geometric Shapes",         start: 0x25A0, end: 0x25FF),
        .init(name: "Miscellaneous Symbols",    start: 0x2600, end: 0x26FF),
        .init(name: "Dingbats",                 start: 0x2700, end: 0x27BF),
        .init(name: "CJK Symbols & Punctuation",start: 0x3000, end: 0x303F),
        .init(name: "Hiragana",                 start: 0x3040, end: 0x309F),
        .init(name: "Katakana",                 start: 0x30A0, end: 0x30FF),
        .init(name: "Hangul Syllables",         start: 0xAC00, end: 0xD7AF),
        .init(name: "CJK Unified Ideographs",   start: 0x4E00, end: 0x9FFF),
        .init(name: "Private Use Area",         start: 0xE000, end: 0xF8FF),
        .init(name: "Alphabetic Presentation",  start: 0xFB00, end: 0xFB4F),
    ]
}

// MARK: - Font factory

enum ProofFontFactory {
    static func font(for item: FontItem,
                     size: CGFloat,
                     features: Set<String>,
                     axisValues: [UInt32: Double]) -> NSFont? {
        guard
            let descs = CTFontManagerCreateFontDescriptorsFromURL(item.fileURL as CFURL) as? [CTFontDescriptor],
            let baseDesc = descs.first(where: { d in
                (CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String) == item.postScriptName
            }) ?? descs.first
        else { return nil }

        var attrs: [CFString: Any] = [:]

        if !features.isEmpty {
            let settings: [[CFString: Any]] = features.map { tag in
                [
                    kCTFontOpenTypeFeatureTag: tag as CFString,
                    kCTFontOpenTypeFeatureValue: 1 as CFNumber,
                ]
            }
            attrs[kCTFontFeatureSettingsAttribute] = settings
        }

        if !axisValues.isEmpty {
            var dict: [NSNumber: NSNumber] = [:]
            for (tag, value) in axisValues {
                dict[NSNumber(value: tag)] = NSNumber(value: value)
            }
            attrs[kCTFontVariationAttribute] = dict as CFDictionary
        }

        let desc = attrs.isEmpty
            ? baseDesc
            : CTFontDescriptorCreateCopyWithAttributes(baseDesc, attrs as CFDictionary)
        let ct = CTFontCreateWithFontDescriptor(desc, size, nil)
        return ct as NSFont
    }
}

// MARK: - Canvas + handle

/// Lets the SwiftUI parent reach into the NSTextView for PDF/PNG export.
final class ProofCanvasHandle: ObservableObject {
    weak var textView: NSTextView?
}

struct ProofCanvas: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let lineHeight: Double
    let letterSpacing: Double
    let alignment: NSTextAlignment
    var handle: ProofCanvasHandle? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 20, height: 16)
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.string = text
        applyAttributes(to: tv)
        handle?.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        handle?.textView = tv
        if tv.string != text { tv.string = text }
        applyAttributes(to: tv)
    }

    private func applyAttributes(to tv: NSTextView) {
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = CGFloat(lineHeight)
        ps.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
            .kern: CGFloat(letterSpacing), .paragraphStyle: ps,
        ]
        tv.typingAttributes = attrs
        if let storage = tv.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes(attrs, range: full)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProofCanvas
        init(_ parent: ProofCanvas) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
