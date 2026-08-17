import SwiftUI
import AppKit

/// Global rules for which copy of a duplicate survives, plus a live preview of
/// what those rules would do.
///
/// The preview is the point. At 23 644 groups nobody can inspect the outcome by
/// scrolling, so the panel answers the only questions that matter before a
/// destructive click: how many files go, where from, where do the survivors
/// end up, and does this leave anything stranded.
struct KeeperPolicyPanel: View {
    @EnvironmentObject var lib: FontLibrary
    @State private var expanded = true

    /// Read the cached result — never recompute here. SwiftUI evaluates a
    /// computed property several times per body pass, and this one walks
    /// every duplicate group.
    private var preview: KeeperPolicyPreview { lib.policyPreview ?? KeeperPolicyPreview() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    rules.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    outcome.frame(width: 300, alignment: .leading)
                }
                .padding(14)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "slider.horizontal.3").foregroundStyle(Color.accentColor)
                Text("Keep priority").font(.headline)
                Text("어떤 사본을 남길지 전체 기준")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if lib.isPreviewingPolicy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                if preview.hasRisk {
                    Label("확인 필요", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("\(preview.filesDeleted) files · "
                     + ByteCountFormatter.string(fromByteCount: preview.bytesReclaimed, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("규칙 (위쪽이 우선)").font(.caption).foregroundStyle(.secondary)

            ForEach(Array(lib.keeperPolicy.order.enumerated()), id: \.element) { idx, rule in
                ruleRow(rule, index: idx)
            }

            Divider().padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { lib.keeperPolicy.requireReachableKeeper },
                set: { lib.keeperPolicy.requireReachableKeeper = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("읽을 수 없는 사본을 유일본으로 남기지 않기")
                        .font(.caption)
                    Text("연결 안 된 볼륨, 또는 경로만 있고 실제 파일이 없는 클라우드 자리표시자를 걸러냅니다")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Label("시스템 필수 폰트와 SIP 보호 파일은 규칙과 무관하게 항상 보호됩니다",
                  systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: KeeperPolicy.Rule, index: Int) -> some View {
        let on = lib.keeperPolicy.enabled.contains(rule)
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 1) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .disabled(index == lib.keeperPolicy.order.count - 1)
            }
            .font(.caption2).foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { on },
                set: { v in
                    if v { lib.keeperPolicy.enabled.insert(rule) }
                    else { lib.keeperPolicy.enabled.remove(rule) }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.label).font(.caption)
                    Text(rule.detail).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if rule == .preferFolder, on { folderPicker }
                }
            }
            .toggleStyle(.checkbox)
        }
        .opacity(on ? 1 : 0.55)
    }

    private var folderPicker: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { lib.keeperPolicy.preferredFolder ?? "" },
                set: { lib.keeperPolicy.preferredFolder = $0.isEmpty ? nil : $0 }
            )) {
                Text("폴더 선택…").tag("")
                ForEach(lib.visibleDefaultSources + lib.customScanPaths, id: \.self) { u in
                    Text(FontLibrary.label(for: u)).tag(u.standardizedFileURL.path)
                }
            }
            .labelsHidden().frame(maxWidth: 260)
        }
        .padding(.top, 2)
    }

    private func move(_ index: Int, by delta: Int) {
        var order = lib.keeperPolicy.order
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        lib.keeperPolicy.order = order
    }

    // MARK: - Live outcome

    private var outcome: some View {
        let p = preview
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("이 기준으로 하면").font(.caption).foregroundStyle(.secondary)
                if lib.isPreviewingPolicy {
                    Text("계산 중…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(lib.isPreviewingPolicy ? 0.6 : 1)

            row("삭제될 파일", "\(p.filesDeleted)개")
            row("회수 용량",
                ByteCountFormatter.string(fromByteCount: p.bytesReclaimed, countStyle: .file))
            if p.protectedSkipped > 0 {
                row("보호되어 제외", "\(p.protectedSkipped)개", tint: .secondary)
            }

            if p.onlyCopyOffline > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if p.onlyCopyOffline > 0 {
                        Label("\(p.onlyCopyOffline)개 그룹의 유일본이 **지금 오프라인인** 위치에 남습니다",
                              systemImage: "exclamationmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if p.onlyCopyOffline > 0 {
                        Text("읽을 수 없는 사본은 등록에 실패합니다. 해당 볼륨을 연결하거나 클라우드 동기화를 완료한 뒤 다시 스캔하세요.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: false, vertical: true)
            }

            // Neutral facts, not warnings — replication and readability are
            // different things and the user should see both.
            if p.onlyCopyInCloud > 0 {
                row("클라우드에 남음 (복제됨)", "\(p.onlyCopyInCloud)개", tint: .secondary, small: true)
            }
            if p.onlyCopyOnSingleDisk > 0 {
                row("이 디스크에만 남음", "\(p.onlyCopyOnSingleDisk)개", tint: .secondary, small: true)
            }

            if !p.deletionsByLocation.isEmpty {
                Text("삭제 위치").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(p.deletionsByLocation.sorted { $0.value > $1.value }, id: \.key) { k, n in
                    row(k, "\(n)개", small: true)
                }
            }
            if !p.keepersByLocation.isEmpty {
                Text("남는 위치").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(p.keepersByLocation.sorted { $0.value > $1.value }, id: \.key) { k, n in
                    row(k, "\(n)개", small: true)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String,
                     tint: Color = .primary, small: Bool = false) -> some View {
        HStack {
            Text(label).font(small ? .caption2 : .caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(small ? .caption2 : .caption).bold().foregroundStyle(tint)
        }
    }
}
