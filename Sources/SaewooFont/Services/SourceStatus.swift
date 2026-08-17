import Foundation

/// Availability of a scan-root URL (a "Source" row in the sidebar).
///
/// Scan roots frequently live on external drives or cloud mounts (Google
/// Drive, Dropbox) that can disappear mid-session without any of our code
/// noticing — the cached `FontItem`s stay in memory, but the folder itself is
/// gone. Without this, a disconnected source kept showing its last-known
/// count and "Reveal in Finder" silently failed.
enum SourceStatus: Equatable {
    /// Directory exists, is readable, and (per the cached item count) holds
    /// at least one font.
    case available
    /// The path does not currently resolve to a directory — unmounted
    /// volume, ejected drive, or a folder the user deleted outside the app.
    case unavailable
    /// Directory exists and is reachable, but the cached scan found no fonts
    /// under it.
    case empty

    /// Convenience for view code that just needs to grey a row out.
    var isOffline: Bool { self == .unavailable }
}

/// Stateless classifier — deliberately has no cache of its own. `FontLibrary`
/// owns the cache (`sourceStatuses`) and decides when to re-run this; this
/// type only answers "what does this one root look like right now".
enum SourceStatusChecker {
    /// Classifies `url` without walking its contents.
    ///
    /// Scan roots can hold tens of thousands of files, and this can be called
    /// from a view body (indirectly, via `FontLibrary.status(for:)`), so it
    /// must stay O(1): `FileManager.fileExists(atPath:isDirectory:)` only
    /// stats the path itself. Distinguishing "empty" from "available" reuses
    /// the font count `FontLibrary` already has cached in `sourceBuckets`
    /// (via `itemCountInSource`) rather than re-reading the directory here.
    ///
    /// - Parameter itemCount: the caller's already-cached font count for this
    ///   root. Never recomputed by this function.
    static func classify(_ url: URL, itemCount: Int) -> SourceStatus {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else { return .unavailable }
        return itemCount > 0 ? .available : .empty
    }
}
