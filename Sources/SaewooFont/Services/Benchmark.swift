import Foundation

/// Headless performance harness. Run with:
///
///     swift run SaewooFont --bench
///
/// Measures the hot paths that dominate perceived UI latency on a large
/// library (the reference machine has ~78 000 faces / 4 100 families /
/// 546 foundries). Numbers are printed as a table so before/after runs can
/// be diffed directly. Keep this in sync with what the views actually call —
/// its value is entirely in being an honest proxy for a SwiftUI render.
enum Benchmark {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--bench")
    }

    private static func measure(_ label: String, repeats: Int = 1, _ body: () -> Void) {
        // Warm once so we time steady-state, not first-touch page faults.
        body()
        let start = Date()
        for _ in 0..<repeats { body() }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(repeats)
        let pad = label.padding(toLength: 52, withPad: " ", startingAt: 0)
        print(String(format: "%@ %8.1f ms", pad, ms))
    }

    @MainActor
    static func run() {
        print("\n=== SaewooFont benchmark ===\n")

        var items: [FontItem] = []
        measure("Persistence.loadCachedLibrary (launch decode)") {
            items = Persistence.loadCachedLibrary() ?? []
        }
        guard !items.isEmpty else {
            print("\nNo library cache found. Launch the app once to build one.\n")
            return
        }

        let families = Set(items.map { $0.familyKey }).count
        let foundries = Set(items.map { $0.foundry }).count
        print("\nlibrary: \(items.count) faces · \(families) families · \(foundries) foundries")
        // Steady-state footprint: the library is loaded, nothing else has run
        // yet. Reported before the rest of the harness churns allocations.
        print(String(format: "resident after load: %.1f MB\n", residentMB()))

        let lib = FontLibrary()
        lib.installForBenchmark(items)

        print("-- SidebarView body (runs on EVERY @Published change) --")
        measure("  displayableDefaultSources", repeats: 3) {
            _ = lib.displayableDefaultSources
        }
        measure("  itemCountInSource x1", repeats: 3) {
            _ = lib.itemCountInSource(FontScanner.defaultSearchRoots[0])
        }
        measure("  itemsInFoundry x1 (materializes)", repeats: 3) {
            _ = lib.itemsInFoundry("Apple")
        }
        // Mirrors what SidebarView.sourcesSection actually touches per body
        // evaluation. Keep this in sync with the view or the number lies.
        measure("  full sourcesSection (~9 passes)", repeats: 3) {
            _ = lib.displayableDefaultSources
            for url in lib.displayableDefaultSources { _ = lib.itemCountInSource(url) }
            _ = lib.autoHiddenDefaultSources
            _ = lib.autoHiddenDefaultSources
        }
        measure("  30 visible foundryRows", repeats: 3) {
            for (name, _) in lib.foundryCounts.prefix(30) {
                _ = lib.foundryActivation(name)
            }
        }

        print("\n-- Library derived data --")
        measure("  familyGroups (cold)", repeats: 3) {
            lib.invalidateForBenchmark()
            _ = lib.familyGroups
        }
        measure("  familyGroups (warm/cached)", repeats: 20) {
            _ = lib.familyGroups
        }
        measure("  search commit \"hel\" + regroup") {
            lib.commitSearchForBenchmark("hel")
            _ = lib.familyGroups
            lib.commitSearchForBenchmark("")
            _ = lib.familyGroups
        }
        measure("  categoryCounts+moodCounts+foundryCounts (cold)", repeats: 3) {
            lib.invalidateForBenchmark()
            _ = lib.categoryCounts; _ = lib.moodCounts; _ = lib.foundryCounts
        }
        measure("  duplicateGroups (cold)", repeats: 3) {
            lib.invalidateForBenchmark()
            _ = lib.duplicateGroups
        }

        print("\n-- Mutation cascades --")
        let victim = items[items.count / 2]
        measure("  toggleFavorite -> next sidebar render", repeats: 3) {
            lib.toggleFavorite(victim)
            _ = lib.categoryCounts; _ = lib.moodCounts; _ = lib.foundryCounts
            _ = lib.duplicateGroups; _ = lib.itemsByFileSize; _ = lib.missingReferences
        }

        print("\n-- Persistence --")
        measure("  saveCachedLibrary (blocks delete/move)") {
            Persistence.saveCachedLibrary(items)
        }

        print("\n-- Memory --")
        print(String(format: "  resident                                       %8.1f MB",
                     residentMB()))
        print("")
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024 / 1024
    }
}
