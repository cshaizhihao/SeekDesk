import SwiftUI

struct RulingsView: View {
    let name: String
    @ObservedObject var session: ForumSession
    let palette: DeskPalette
    let openTopic: (URL) -> Bool
    @StateObject private var records = Records()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 20)).foregroundStyle(palette.accent)
                    .frame(width: 44, height: 44)
                    .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("管理记录").font(.system(size: 21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(name).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { session.presentation = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(DeskButtonStyle()).controlSize(.large)
            }
            .padding(14)
            .deskGlass(in: RoundedRectangle(cornerRadius: 18), solid: palette.chrome)
            switch records.phase {
            case .loading:
                ProgressView("正在查询…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    DeskLabel("无法查询管理记录", systemImage: "doc.text.magnifyingglass", size: 32)
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { records.retry += 1 }.deskGlassButtonStyle()
                }
            case .ready(let rows) where rows.isEmpty:
                ContentUnavailableView {
                    DeskLabel("NS Seek 暂无此用户的记录", systemImage: "checkmark.shield", size: 32)
                }
            case .ready(let rows):
                List(rows) { row in record(row).listRowBackground(Color.clear) }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .background(palette.list, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                if rows.count == RulingClient.limit {
                    Text("显示最近 \(RulingClient.limit) 条记录").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("数据来源")
                Link("NS Seek 社区查询服务", destination: URL(string: "https://github.com/theslugger/ns-seek")!)
                Spacer()
                Text("北京时间")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .deskGlass(in: RoundedRectangle(cornerRadius: 12), solid: palette.chrome)
        }
        .padding(20).frame(width: 580, height: 440)
        .background(palette.chrome)
        .task(id: records.retry) { await records.load(name) }
    }

    private func record(_ row: RulingRecord) -> some View {
        let (title, icon, color): (String, String, Color) = switch row.kind {
        case .punish: ("处罚", "exclamationmark.shield", palette.unread)
        case .reward: ("奖励", "gift.fill", palette.categoryInk("review"))
        case .management: ("管理", "shield.fill", palette.accent)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DeskLabel(title, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(color)
                Text("#\(row.id.formatted(.number.grouping(.never)))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let url = row.postURL {
                    Button { if openTopic(url) { session.presentation = nil } } label: {
                        DeskLabel("打开原帖", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let reason = row.reason, !reason.isEmpty {
                Text(reason).font(.callout).textSelection(.enabled)
            }
            if let actions = row.beijingActions, !actions.isEmpty {
                Text(actions).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
    }

    @MainActor private final class Records: ObservableObject {
        enum Phase { case loading, ready([RulingRecord]), failed(String) }
        @Published var phase: Phase = .loading
        @Published var retry = 0

        func load(_ name: String) async {
            phase = .loading
            do {
                let rows = try await RulingClient.shared.lookup(name)
                if !Task.isCancelled { phase = .ready(rows) }
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? RulingClient.LookupError)?.errorDescription
                phase = .failed(message ?? "NS Seek 查询服务暂时无法连接。")
            }
        }
    }
}
