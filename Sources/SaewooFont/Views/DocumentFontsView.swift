import AppKit
import SwiftUI

struct DocumentFontsView: View {
    @EnvironmentObject var lib: FontLibrary

    @State private var selectedProjectID: UUID?
    @State private var figmaInput: String = ""
    @State private var figmaToken: String = ""
    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    @State private var lastReport: FontLibrary.DocumentFontImportReport?

    private var projects: [FontCollection] {
        lib.collections
            .filter { $0.kind == .project }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var canImport: Bool {
        selectedProjectID != nil && !isImporting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if projects.isEmpty {
                emptyProjectsState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        targetProjectCard
                        illustratorCard
                        figmaCard
                        if let errorMessage { errorCard(errorMessage) }
                        if let lastReport { reportCard(lastReport) }
                    }
                    .padding(18)
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: ensureSelectedProject)
        .onChange(of: lib.collections) { _ in ensureSelectedProject() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.orange)
                    Text("Document Fonts").font(.title3).bold()
                }
                Text("Pull font usage from an open Illustrator document or a Figma file, match it against this library, and add the matched faces to a Project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680, alignment: .leading)
            }
            Spacer()
            if isImporting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
    }

    private var emptyProjectsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Create a Project First").font(.title3).bold()
            Text("Document fonts are imported into Projects so the set can be toggled on and off from the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                createProject()
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var targetProjectCard: some View {
        card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target Project").font(.headline)
                    Text("Matched font faces will be merged into this project without removing existing fonts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $selectedProjectID) {
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 240)
                Button {
                    createProject()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var illustratorCard: some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "a.square.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Illustrator").font(.headline)
                    Text("Reads every text frame in the front Illustrator document through Adobe's ExtendScript DOM. macOS may ask for Automation permission the first time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        runIllustratorImport()
                    } label: {
                        Label("Import from Open Illustrator Document",
                              systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImport)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var figmaCard: some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "f.cursive.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.purple)
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Figma").font(.headline)
                    Text("Figma does not expose the currently open canvas through a local macOS API. Copy the current Figma file link and use a personal access token; the token is only kept in this window state and is not saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Figma file URL or file key", text: $figmaInput)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Figma personal access token", text: $figmaToken)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            runFigmaImport()
                        } label: {
                            Label("Import from Figma File",
                                  systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canImport || figmaInput.trimmed.isEmpty || figmaToken.trimmed.isEmpty)

                        Button {
                            if let paste = NSPasteboard.general.string(forType: .string) {
                                figmaInput = paste
                            }
                        } label: {
                            Label("Paste Link", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func reportCard(_ report: FontLibrary.DocumentFontImportReport) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Import").font(.headline)
                        Text("\(report.sourceName) -> \(report.projectName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let projectID = selectedProjectID {
                            lib.sidebarSelection = .collection(projectID)
                        }
                    } label: {
                        Label("Open Project", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    stat("Document fonts", "\(report.requestedCount)", .blue)
                    stat("Matched faces", "\(report.matchedFaceCount)", .green)
                    stat("Added", "\(report.addedCount)", .accentColor)
                    stat("Already there", "\(report.alreadyPresentCount)", .secondary)
                    stat("Missing", "\(report.missingCount)", report.missingCount == 0 ? .secondary : .orange)
                }

                if !report.missingReferences.isEmpty {
                    DisclosureGroup("Missing in Library (\(report.missingCount))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(report.missingReferences.prefix(40))) { ref in
                                Text(ref.displayName)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            if report.missingReferences.count > 40 {
                                Text("+ \(report.missingReferences.count - 40) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Activate/sync these fonts, rescan the library, then import again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 100, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private func ensureSelectedProject() {
        if let selectedProjectID,
           projects.contains(where: { $0.id == selectedProjectID }) {
            return
        }
        if let target = lib.documentFontImportTargetProjectID,
           projects.contains(where: { $0.id == target }) {
            selectedProjectID = target
            lib.documentFontImportTargetProjectID = nil
            return
        }
        selectedProjectID = projects.first?.id
    }

    private func createProject() {
        Task { @MainActor in
            if let result = await NewCollectionPrompt.show(kind: .project) {
                selectedProjectID = lib.addCollection(name: result.name,
                                                      kind: .project,
                                                      colorHex: result.color)
                lib.sidebarSelection = .tool(.documentFonts)
            }
        }
    }

    private func runIllustratorImport() {
        guard let projectID = selectedProjectID else {
            errorMessage = "Choose or create a target Project first."
            return
        }
        runImport({
            try await DocumentFontImporter.scanIllustratorActiveDocument()
        }, into: projectID)
    }

    private func runFigmaImport() {
        guard let projectID = selectedProjectID else {
            errorMessage = "Choose or create a target Project first."
            return
        }
        let input = figmaInput
        let token = figmaToken
        runImport({
            try await DocumentFontImporter.scanFigmaFile(fileInput: input, token: token)
        }, into: projectID)
    }

    private func runImport(_ scan: @escaping () async throws -> DocumentFontScan,
                           into projectID: UUID) {
        Task { @MainActor in
            isImporting = true
            errorMessage = nil
            defer { isImporting = false }

            do {
                let scan = try await scan()
                guard let report = lib.importDocumentFonts(
                    scan,
                    intoProject: projectID,
                    selectProjectAfterImport: false
                ) else {
                    errorMessage = "The selected Project no longer exists."
                    return
                }
                lastReport = report
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
