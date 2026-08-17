import Foundation

/// User-controlled rules for deciding which copy of a duplicate group survives.
///
/// Before this, the keeper was picked by a fixed heuristic and the only way to
/// disagree was to click every group by hand — unworkable at 23 644 groups.
/// The policy is a small ordered rule list: rules earlier in the list outweigh
/// later ones, so "prefer Dropbox" can beat "prefer newest" without either
/// being absolute.
struct KeeperPolicy: Codable, Equatable {

    enum Rule: String, Codable, CaseIterable, Identifiable {
        case preferFolder        // a specific scan root the user nominates
        case preferCloud
        case preferLocal
        case preferUserFonts     // ~/Library/Fonts
        case preferCurated       // favorited / active / in a project
        case preferNewest
        case preferLargest

        var id: String { rawValue }

        var label: String {
            switch self {
            case .preferFolder:  return "Prefer a specific folder"
            case .preferCloud:   return "Prefer cloud-synced copies (Dropbox, Drive)"
            case .preferLocal:   return "Prefer local copies (not cloud-synced)"
            case .preferUserFonts: return "Prefer ~/Library/Fonts"
            case .preferCurated: return "Prefer favorited / active / in a project"
            case .preferNewest:  return "Prefer the newest file"
            case .preferLargest: return "Prefer the largest file"
            }
        }

        var detail: String {
            switch self {
            case .preferFolder:
                return "Keeps whichever copy lives under the folder you pick below."
            case .preferCloud:
                return "Treats the cloud copy as canonical. Replicated across the cloud and your other machines, so more durable than one disk — as long as the folder is fully synced, not online-only."
            case .preferLocal:
                return "Keeps a copy on this Mac only. Always readable, but it lives on one drive with nothing behind it."
            case .preferUserFonts:
                return "Keeps the copy macOS and other apps installed into your user Fonts folder."
            case .preferCurated:
                return "Keeps a copy you've starred, activated, or put in a project, so those references survive."
            case .preferNewest:
                return "Later file date wins. Useful after a foundry re-issue."
            case .preferLargest:
                return "Bigger file wins. Irrelevant here — identical files are the same size — kept as a tie-break for future non-identical matching."
            }
        }
    }

    /// Ordered, highest priority first. Only enabled rules score.
    var order: [Rule]
    var enabled: Set<Rule>
    /// Root path for `.preferFolder`.
    var preferredFolder: String?

    /// Refuse to leave a group's only surviving copy somewhere unreadable —
    /// an unmounted volume, or a cloud placeholder that has a path but no
    /// bytes on disk. Note this is about *usability now*, not durability:
    /// a fully-synced cloud folder is replicated and passes this check.
    var requireReachableKeeper: Bool

    static let `default` = KeeperPolicy(
        order: [.preferCurated, .preferLocal, .preferUserFonts,
                .preferFolder, .preferCloud, .preferNewest, .preferLargest],
        enabled: [.preferCurated, .preferLocal],
        preferredFolder: nil,
        requireReachableKeeper: true
    )

    /// Weight for a rule: earlier in `order` wins decisively over later ones,
    /// so enabling several doesn't produce surprising ties.
    func weight(_ rule: Rule) -> Int {
        guard let i = order.firstIndex(of: rule) else { return 0 }
        return (order.count - i) * 100
    }

    // MARK: - Persistence

    private static let defaultsKey = "duplicates.keeperPolicy"

    static func load() -> KeeperPolicy {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let p = try? JSONDecoder().decode(KeeperPolicy.self, from: data)
        else { return .default }
        // Tolerate rules added in later versions.
        var fixed = p
        for r in Rule.allCases where !fixed.order.contains(r) { fixed.order.append(r) }
        return fixed
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// What a policy would do to the whole scan, computed before anything is deleted.
struct KeeperPolicyPreview {
    var groups = 0
    var filesDeleted = 0
    var bytesReclaimed: Int64 = 0
    /// Groups whose survivor sits in a synced cloud folder. Informational, not
    /// a warning: a full-sync folder is replicated across the cloud and every
    /// other machine, so it is *more* durable than one local disk. The real
    /// hazard is the next field.
    var onlyCopyInCloud = 0
    /// Groups whose survivor can't be read right now — an unmounted volume, or
    /// a cloud placeholder with a path but no bytes. These fail to activate.
    var onlyCopyOffline = 0
    /// Groups whose survivor exists on exactly one physical disk, with no
    /// replication behind it. Fine until that drive dies.
    var onlyCopyOnSingleDisk = 0
    /// Deletions the guard will refuse (system essentials, SIP).
    var protectedSkipped = 0
    /// Where the deletions land, by folder label.
    var deletionsByLocation: [String: Int] = [:]
    /// Where the survivors land.
    var keepersByLocation: [String: Int] = [:]

    var hasRisk: Bool { onlyCopyOffline > 0 }
}
