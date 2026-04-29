import CoreServices
import Foundation

/// Watches scan roots for filesystem changes and asks the library to rescan.
/// FSEvents is recursive, so a single source folder also covers nested folders.
final class FontSourceWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var onChange: (() -> Void)?

    deinit {
        stop()
    }

    func start(roots: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange

        let paths = Self.watchablePaths(for: roots)
        guard paths != watchedPaths else { return }

        stop()
        watchedPaths = paths

        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPaths = []
    }

    private func handleChange() {
        onChange?()
    }

    private static func watchablePaths(for roots: [URL]) -> [String] {
        var seen: Set<String> = []
        return roots.compactMap { rawRoot in
            let root = RightFontImporter.isLibrary(rawRoot)
                ? RightFontImporter.fontsRoot(in: rawRoot)
                : rawRoot
            let standardized = root.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
                  isDir.boolValue,
                  seen.insert(standardized.path).inserted
            else {
                return nil
            }
            return standardized.path
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FontSourceWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleChange()
    }
}
