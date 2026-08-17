import Foundation
import CryptoKit

/// Finds font files whose **contents** are byte-identical.
///
/// This replaces the old PostScript-name grouping for anything destructive.
/// Sharing a PostScript name says almost nothing about whether two files are
/// interchangeable: on the reference library only ~66 % of same-name groups
/// were actually the same font, so a third of every "extra" offered for
/// deletion was a different typeface — a different version, a different weight
/// set, a different language cut — that happened to reuse the name.
///
/// Byte-identity has the property we actually need: if two files are identical,
/// deleting one loses *nothing*, because every face inside it still exists in
/// the copy we keep. That holds even for TTC bundles and variable fonts, which
/// is what made the name-based tool so dangerous — it counted faces but deleted
/// whole files, and one file in this library holds 252 faces.
enum DuplicateScanner {

    /// A set of two or more files with identical contents.
    struct Group: Identifiable {
        var id: String { digest }
        let digest: String
        let size: Int64
        /// Every path holding this exact content. Always 2+.
        let paths: [URL]
    }

    struct Progress {
        var stage: String
        var done: Int
        var total: Int
    }

    /// Two-stage compare so we don't read 8.9 GB to answer this.
    ///
    /// 1. Bucket by file size — free, comes from the cached `FontItem`s, and
    ///    different sizes can never be identical.
    /// 2. Within a size bucket, hash the first and last 16 KB. Font files
    ///    differ early (header/name table) and late (checksums), so this
    ///    eliminates nearly everything for ~32 KB of reads per file.
    /// 3. Only for files that still collide, hash the whole thing.
    static func scan(
        files: [(url: URL, size: Int64)],
        progress: @Sendable @escaping (Progress) -> Void
    ) async -> [Group] {

        // Stage 1 — size buckets.
        var bySize: [Int64: [URL]] = [:]
        for f in files where f.size > 0 { bySize[f.size, default: []].append(f.url) }
        let candidates = bySize.filter { $0.value.count > 1 }
        let stage2Count = candidates.reduce(0) { $0 + $1.value.count }
        progress(Progress(stage: "Comparing file sizes", done: files.count, total: files.count))

        // Stage 2 — partial hashes, in parallel.
        let partial = await hashAll(
            candidates.flatMap { size, urls in urls.map { ($0, size) } },
            full: false, stage: "Reading file headers",
            total: stage2Count, progress: progress
        )
        var byPartial: [String: [(URL, Int64)]] = [:]
        for (url, size, digest) in partial { byPartial[digest, default: []].append((url, size)) }
        let stage3 = byPartial.values.filter { $0.count > 1 }.flatMap { $0 }

        // Stage 3 — full hashes for whatever survived.
        let full = await hashAll(
            stage3, full: true, stage: "Verifying contents",
            total: stage3.count, progress: progress
        )
        var byFull: [String: (size: Int64, urls: [URL])] = [:]
        for (url, size, digest) in full {
            byFull[digest, default: (size, [])].urls.append(url)
        }

        return byFull
            .filter { $0.value.urls.count > 1 }
            .map { Group(digest: $0.key, size: $0.value.size,
                         paths: $0.value.urls.sorted { $0.path < $1.path }) }
            .sorted { ($0.size * Int64($0.paths.count - 1)) > ($1.size * Int64($1.paths.count - 1)) }
    }

    /// Hashes `input` in parallel using GCD rather than a `TaskGroup`.
    ///
    /// This is deliberate. With `withTaskGroup` the scan made no progress at
    /// all when driven from a context that isn't a running `NSApplication` —
    /// the cooperative pool never got scheduled and one core span for ten
    /// minutes. `concurrentPerform` owns its own threads, so the same code runs
    /// identically whether it's called from the app, a CLI, or a test, and the
    /// caller just waits on one continuation.
    private static func hashAll(
        _ input: [(URL, Int64)],
        full: Bool,
        stage: String,
        total: Int,
        progress: @Sendable @escaping (Progress) -> Void
    ) async -> [(URL, Int64, String)] {
        guard !input.isEmpty else { return [] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let cores = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
                let chunkSize = max(1, (input.count + cores - 1) / cores)
                let chunkCount = (input.count + chunkSize - 1) / chunkSize
                let lock = NSLock()
                var all: [(URL, Int64, String)] = []
                all.reserveCapacity(input.count)
                var done = 0

                DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                    let lo = c * chunkSize
                    let hi = min(lo + chunkSize, input.count)
                    guard lo < hi else { return }
                    var out: [(URL, Int64, String)] = []
                    out.reserveCapacity(hi - lo)
                    for i in lo..<hi {
                        let (url, size) = input[i]
                        if let d = full ? fullDigest(url) : partialDigest(url, size: size) {
                            out.append((url, size, d))
                        }
                    }
                    lock.lock()
                    all.append(contentsOf: out)
                    done += hi - lo
                    let snapshot = done
                    lock.unlock()
                    progress(Progress(stage: stage, done: min(snapshot, total), total: total))
                }
                progress(Progress(stage: stage, done: total, total: total))
                cont.resume(returning: all)
            }
        }
    }

    private static let window = 16 * 1024

    /// Head + tail sample. Size is folded in so two files can't collide across
    /// size buckets when the partial digests are merged.
    private static func partialDigest(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(data: Data($0)) }
        guard let head = try? h.read(upToCount: window) else { return nil }
        hasher.update(data: head)
        if size > Int64(window) {
            let tailOffset = UInt64(max(0, size - Int64(window)))
            if (try? h.seek(toOffset: tailOffset)) != nil,
               let tail = try? h.read(upToCount: window) {
                hasher.update(data: tail)
            }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func fullDigest(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}

