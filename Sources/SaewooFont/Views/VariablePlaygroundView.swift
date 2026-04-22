import SwiftUI
import AppKit

/// Live-editable playground for a single variable font. One slider per axis,
/// snapshot-save as a VariableInstance, and one-click copy of CSS / Core Text
/// variation strings for handoff to code or other apps.
struct VariablePlaygroundView: View {
    @EnvironmentObject var lib: FontLibrary
    @Environment(\.dismiss) var dismiss

    let item: FontItem

    @State private var values: [UInt32: Double] = [:]
    @State private var previewSize: Double = 72
    @State private var sampleText: String = "Aa Bb Cc 123"
    @State private var instanceName: String = ""
    @State private var saveFieldFocused: Bool = false
    @State private var lastCopied: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview
            Divider()
            axisPanel
            Divider()
            savedInstancesStrip
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 600, idealHeight: 680)
        .onAppear(perform: resetToDefaults)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Variable Axis Playground").font(.title3).bold()
                Text("\(item.displayName) — \(item.variationAxes.count) axis\(item.variationAxes.count == 1 ? "" : "es")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                resetToDefaults()
            } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.bordered)

            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Sample text", text: $sampleText)
                .textFieldStyle(.roundedBorder)

            ScrollView(.horizontal, showsIndicators: false) {
                FontPreviewText(item: item, size: previewSize, text: sampleText.isEmpty ? "Aa" : sampleText,
                                variations: values)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
            }
            .frame(minHeight: max(96, CGFloat(previewSize) * 1.5))
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Slider(value: $previewSize, in: 18...160)
                Text("\(Int(previewSize))pt")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Axes

    private var axisPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(item.variationAxes) { axis in
                    axisRow(axis)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder
    private func axisRow(_ axis: VariationAxis) -> some View {
        let current = values[axis.tag] ?? axis.defaultValue
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(axis.name).font(.system(size: 12, weight: .medium))
                    Text(axis.tagString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    if axis.isHidden {
                        Text("hidden").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text("\(formatNum(axis.minValue)) – \(formatNum(axis.maxValue))  ·  default \(formatNum(axis.defaultValue))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)

            Slider(
                value: Binding(
                    get: { values[axis.tag] ?? axis.defaultValue },
                    set: { values[axis.tag] = $0 }
                ),
                in: axis.range
            )

            Text(formatNum(current))
                .font(.system(.body, design: .monospaced))
                .frame(width: 72, alignment: .trailing)

            Button {
                values[axis.tag] = axis.defaultValue
            } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .buttonStyle(.plain)
                .help("Reset to default")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Saved instances

    private var savedInstancesStrip: some View {
        let saved = lib.instances(for: item)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved instances").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saved.isEmpty {
                    Text("none yet").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(saved) { inst in
                            instanceChip(inst)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder
    private func instanceChip(_ inst: VariableInstance) -> some View {
        HStack(spacing: 6) {
            Button {
                loadInstance(inst)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(inst.name).font(.caption).bold()
                    Text(summary(inst)).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Load these axis values")

            Button {
                lib.deleteVariableInstance(inst.id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete instance")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    private func summary(_ inst: VariableInstance) -> String {
        inst.axisValues.keys.sorted().prefix(4).map { tag in
            "\(tag):\(formatNum(inst.axisValues[tag] ?? 0))"
        }.joined(separator: " ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Name this instance (e.g. \"Editorial Bold\")", text: $instanceName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Button {
                saveCurrent()
            } label: {
                Label("Save Instance", systemImage: "bookmark.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(instanceName.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)

            Spacer()

            Menu {
                Button("Copy CSS — font-variation-settings") {
                    copy(cssVariationSettings(), label: "CSS")
                }
                Button("Copy Core Text attribute literal") {
                    copy(coreTextLiteral(), label: "Core Text")
                }
                Button("Copy JSON") {
                    copy(jsonLiteral(), label: "JSON")
                }
            } label: {
                Label("Copy…", systemImage: "doc.on.doc")
            }
            .frame(width: 120)

            if let last = lastCopied {
                Text("Copied \(last)")
                    .font(.caption).foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Actions

    private func resetToDefaults() {
        values = Dictionary(uniqueKeysWithValues: item.variationAxes.map { ($0.tag, $0.defaultValue) })
    }

    private func loadInstance(_ inst: VariableInstance) {
        // Map string tags back onto UInt32 tags defined by the current font.
        var next: [UInt32: Double] = [:]
        for axis in item.variationAxes {
            if let v = inst.axisValues[axis.tagString] {
                next[axis.tag] = clamp(v, axis)
            } else {
                next[axis.tag] = axis.defaultValue
            }
        }
        values = next
        instanceName = inst.name
    }

    private func saveCurrent() {
        var payload: [String: Double] = [:]
        for axis in item.variationAxes {
            payload[axis.tagString] = values[axis.tag] ?? axis.defaultValue
        }
        lib.saveVariableInstance(base: item, name: instanceName, axisValues: payload)
        instanceName = ""
    }

    private func copy(_ text: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation { lastCopied = label }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run { withAnimation { self.lastCopied = nil } }
        }
    }

    private func cssVariationSettings() -> String {
        let parts = item.variationAxes.map { axis -> String in
            let v = values[axis.tag] ?? axis.defaultValue
            return "\"\(axis.tagString)\" \(formatNum(v))"
        }
        return "font-variation-settings: \(parts.joined(separator: ", "));"
    }

    private func coreTextLiteral() -> String {
        // A `[NSNumber: NSNumber]` literal keyed by the 4-byte tag packed into a UInt32.
        let parts = item.variationAxes.map { axis -> String in
            let v = values[axis.tag] ?? axis.defaultValue
            return "  /* \(axis.tagString) */ NSNumber(value: UInt32(0x\(String(axis.tag, radix: 16)))): NSNumber(value: \(formatNum(v)))"
        }
        return "let variation: [NSNumber: NSNumber] = [\n\(parts.joined(separator: ",\n"))\n]"
    }

    private func jsonLiteral() -> String {
        var dict: [String: Double] = [:]
        for axis in item.variationAxes {
            dict[axis.tagString] = values[axis.tag] ?? axis.defaultValue
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? enc.encode(dict)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    private func formatNum(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.01 { return "\(Int(v.rounded()))" }
        return String(format: "%.2f", v)
    }

    private func clamp(_ v: Double, _ axis: VariationAxis) -> Double {
        min(max(v, axis.minValue), axis.maxValue)
    }
}
