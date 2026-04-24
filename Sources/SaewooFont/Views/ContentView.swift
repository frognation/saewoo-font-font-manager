import SwiftUI

struct ContentView: View {
    @EnvironmentObject var lib: FontLibrary
    @State private var showInspector = true

    /// Swap the family list for a tool view when a `.tool` or `.cloud` row
    /// is selected.
    @ViewBuilder
    private var mainContent: some View {
        switch lib.sidebarSelection {
        case .tool(.duplicates):  DuplicatesView()
        case .tool(.organize):    OrganizeView()
        case .tool(.proofSheet):  ProofSheetView()
        case .tool(.orphans):     OrphansView()
        case .tool(.missingRefs): MissingRefsView()
        case .tool(.largeFiles):  LargeFilesView()
        case .tool(.fork):        ForkView()
        case .cloud(.google):     GoogleFontsView()
        case .cloud(.adobe):      AdobeFontsView()
        default:                  FontListView()
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240)
        } content: {
            VStack(spacing: 0) {
                if !lib.sidebarSelection.isTool && !lib.sidebarSelection.isCloud {
                    TopToolbar()
                    Divider()
                }
                mainContent
            }
            .frame(minWidth: 520)
        } detail: {
            if showInspector { InspectorView() } else { Text("No selection") }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Group {
                    if lib.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(lib.scanStatus.isEmpty ? " " : lib.scanStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 180, minHeight: 18, alignment: .trailing)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await lib.rescan() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan library")
            }
        }
    }
}

struct TopToolbar: View {
    @EnvironmentObject var lib: FontLibrary
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // Bind to searchInput (instant, cheap) and debounce to searchQuery
            // via updateSearchInput so filtering doesn't fire on every key.
            TextField("Search family, style, postscript…",
                      text: Binding(
                          get: { lib.searchInput },
                          set: { lib.updateSearchInput($0) }
                      ))
                .textFieldStyle(.plain)
            Spacer()
            Slider(value: $lib.previewSize, in: 12...96)
                .frame(width: 120)
                .onChange(of: lib.previewSize) { _ in lib.savePreviewPrefs() }
            Text("\(Int(lib.previewSize))pt")
                .font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            TextField("Preview text", text: $lib.previewText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onChange(of: lib.previewText) { _ in lib.savePreviewPrefs() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
