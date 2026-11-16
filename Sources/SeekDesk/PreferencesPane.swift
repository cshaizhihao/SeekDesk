import AppKit
import SwiftUI

struct PreferencesPane: View {
    enum Category: String, CaseIterable, Identifiable {
        case general, reading, appearance, about
        var id: String { rawValue }
        var title: String {
            switch self { case .general: "通用"; case .reading: "阅读"; case .appearance: "外观"; case .about: "关于" }
        }
        var icon: String {
            switch self { case .general: "gearshape"; case .reading: "text.book.closed"; case .appearance: "paintbrush"; case .about: "info.circle" }
        }
    }

    @ObservedObject var updates: Updates
    let palette: DeskPalette
    let returnTitle: String
    let returnToForum: () -> Void
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(DeskLogo.preference) private var selectedLogo = DeskLogo.cobalt
    @AppStorage("workspace.mistBackdrop") private var readerGradient = true
    @AppStorage("workspace.autoLoadOlder") private var autoLoad = false
    @AppStorage("workspace.autoRefresh") private var autoRefresh = true
    @AppStorage(ReplySendKey.preference) private var replySendKey = ReplySendKey.commandReturn
    @AppStorage(DeskTextSize.bodyKey) private var bodyTextSize = DeskTextSize.bodyDefault
    @AppStorage(DeskTextSize.authorScaleKey) private var authorScale = DeskTextSize.authorScaleDefault
    @AppStorage(DeskTextSize.listKey) private var listTextSize = DeskTextSize.listDefault
    @AppStorage(DeskTextSize.boardKey) private var boardTextSize = DeskTextSize.boardDefault
    @AppStorage(DeskTextSize.rankingKey) private var rankingTextSize = DeskTextSize.rankingDefault
    @AppStorage(ForumReportKind.nq.preference) private var nqReportScale = ForumReportKind.nq.standard
    @AppStorage(ForumReportKind.tq.preference) private var tqReportScale = ForumReportKind.tq.standard
    @AppStorage("workspace.topicColumnWidth") private var listWidth = 340.0
    @AppStorage("workspace.sidebarWidth") private var sidebarWidth = DeskSidebarSizing.standard
    @AppStorage(DeskReadingDensity.preference) private var density = DeskReadingDensity.comfortable
    @StateObject private var selection = Selection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            let layout = compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                navigation(compact: compact)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(selection.category.title).font(.system(size: 24, weight: .semibold)).accessibilityAddTraits(.isHeader)
                            panel(compact: compact)
                        }
                        // Keep the glass surface mounted when changing categories.
                        // Re-identifying it replayed its fade-in and flashed the whole panel.
                        .frame(maxWidth: 690, alignment: .leading).padding(compact ? 16 : 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("preferences-content-top")
                        .transaction(value: selection.category) { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
                    .onChange(of: selection.category) { _, _ in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo("preferences-content-top", anchor: .top)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.readerWash)
    }

    private func navigation(compact: Bool) -> some View {
        Group {
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack {
                    Button(action: returnToForum) { DeskLabel(returnTitle, systemImage: "chevron.left") }
                        .buttonStyle(DeskButtonStyle())
                    if compact {
                        Spacer()
                        Text("设置").font(.system(size: 18, weight: .semibold))
                    }
                }
                if !compact { Text("设置").font(.system(size: 22, weight: .bold)).padding(.vertical, 8) }
                DeskGlassPicker(values: Category.allCases, selection: $selection.category,
                                tint: palette.accent, solid: palette.selection, vertical: !compact,
                                compact: compact) { category, _ in
                    DeskLabel(category.title, systemImage: category.icon)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                }
                if !compact { Spacer() }
            }
            .padding(compact ? 12 : 15).frame(width: compact ? nil : 155)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background(palette.chrome.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(10)
    }

    @ViewBuilder private func panel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selection.category {
            case .general:
                Text("发送帖子回复").font(.callout)
                DeskGlassPicker(values: ReplySendKey.allCases, selection: $replySendKey,
                                tint: palette.accent, solid: palette.selection, compact: true) { key, _ in
                    Text(key.title).font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("发送帖子回复")
                Text(replySendKey == .returnKey ? "按 Shift + Return 换行。" : "按 Return 换行。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("自动刷新首页", isOn: $autoRefresh)
                    .help("浏览首页时每分钟检查一次。")
                if let updater = updates.controller?.updater {
                    Toggle("自动检查应用更新", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }))
                    Button("检查更新…", action: updates.check).buttonStyle(.bordered).disabled(!updates.canCheck)
                } else {
                    LabeledContent("应用更新") {
                        Link("前往 GitHub 检查更新", destination: AppInformation.releases)
                    }
                }
            case .reading:
                Text("阅读布局").font(.callout)
                DeskGlassPicker(values: DeskReadingDensity.allCases, selection: $density,
                                tint: palette.accent, solid: palette.selection, compact: true) { density, _ in
                    Text(density.title).font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("阅读布局")
                Text("舒适布局增加列表与楼层留白，并控制正文行宽；字号仍可独立调整。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                textSizeControl("帖子列表字号", size: $listTextSize, range: DeskTextSize.listRange,
                                standard: DeskTextSize.listDefault) {
                    TopicListRowLabel(title: "分享一次晚高峰的三网线路实测", author: "示例用户", time: "刚刚",
                                      category: "review", avatarURL: nil, titleSize: listTextSize, palette: palette)
                }
                Divider()
                readerSizeControls
                Divider()
                sizeSlider("NQ 报告宽度", size: $nqReportScale, range: ForumReportKind.nq.range,
                           standard: ForumReportKind.nq.standard, step: 5, unit: "%")
                Text("默认 100%，保持阅读宽度，长报告按原比例向下展开。")
                    .font(.caption).foregroundStyle(.secondary)
                sizeSlider("TQ 报告缩放", size: $tqReportScale, range: ForumReportKind.tq.range,
                           standard: ForumReportKind.tq.standard, step: 5, unit: "%")
                Text("默认 100%。NQ 和 TQ 的缩放分别记忆，也可直接使用报告上方的按钮调整。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                textSizeControl("侧栏热榜字号", size: $rankingTextSize, range: DeskTextSize.sidebarRange,
                                standard: DeskTextSize.rankingDefault) {
                    SidebarRankLabel(position: 1, title: "分享一次晚高峰的三网线路实测", size: rankingTextSize, palette: palette)
                }
                Divider()
                textSizeControl("论坛版块字号", size: $boardTextSize, range: DeskTextSize.sidebarRange,
                                standard: DeskTextSize.boardDefault) {
                    DeskLabel("技术交流", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: boardTextSize, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(maxWidth: .infinity, minHeight: max(34, boardTextSize + 17), alignment: .leading)
                }
                Divider()
                Toggle("滚动到底部时自动加载更早的帖子", isOn: $autoLoad)
                Text("关闭时，可以用列表底部的按钮手动加载。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复默认帖子栏宽度") { listWidth = 340 }.buttonStyle(.bordered)
            case .appearance:
                Text("外观模式").font(.callout)
                DeskGlassPicker(values: ["system", "light", "dark"], selection: $appearance,
                                tint: palette.accent, solid: palette.selection, compact: true) { mode, _ in
                    Text(mode == "system" ? "跟随系统" : mode == "light" ? "白天" : "黑夜")
                        .font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("外观模式")
                Divider()
                logoPicker
                Divider()
                Toggle("阅读区顶部渐变", isOn: $readerGradient)
                    .help("帖子顶部使用与外观模式相配的淡渐变。")
                sizeSlider("侧栏宽度", size: $sidebarWidth,
                           range: Double(DeskSidebarSizing.range.lowerBound)...Double(DeskSidebarSizing.range.upperBound),
                           standard: DeskSidebarSizing.standard, step: 4)
            case .about:
                about
            }
        }
        .toggleStyle(.switch)
        .padding(compact ? 16 : 22).frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18), solid: palette.list)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                if let icon = selectedLogo.dockImage ?? NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon).resizable().scaledToFit()
                        .frame(width: 76, height: 76).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("SeekDesk").font(.system(size: 26, weight: .bold))
                    Text(AppInformation.versionDescription).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text("在 Mac 上，舒服地逛 NodeSeek。").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("开发者", value: "@cshaizhihao")
                LabeledContent("开源许可") {
                    Link("GNU GPL v3.0", destination: AppInformation.license)
                }
                LabeledContent("支持平台", value: "macOS 14 及以上 · Apple Silicon")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { projectLinks }
                VStack(alignment: .leading, spacing: 10) { projectLinks }
            }
            .buttonStyle(.bordered)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("第三方客户端声明").font(.headline).accessibilityAddTraits(.isHeader)
                Text(.init(AppInformation.disclaimer))
                    .font(.callout).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("致谢").font(.headline).accessibilityAddTraits(.isHeader)
                Text("感谢 NodeSeek 社区、Sparkle、NodeImage，以及热榜和 NS Seek 等社区项目。友情链接可从主侧栏查看。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("第三方许可与项目致谢", destination: AppInformation.acknowledgements).font(.callout)
            }
        }
        .tint(palette.accent)
    }

    @ViewBuilder private var projectLinks: some View {
        Link(destination: AppInformation.website) { DeskLabel("官方网站", systemImage: "globe") }
        Link(destination: AppInformation.repository) { DeskLabel("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
        Link(destination: AppInformation.issues) { DeskLabel("问题反馈", systemImage: "bubble.left") }
    }

    private var logoPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("顶栏 Logo 与 Dock 图标").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(DeskLogo.allCases, id: \.self) { logo in
                    let selected = logo == selectedLogo
                    let shape = RoundedRectangle(cornerRadius: 9)
                    Button {
                        selectedLogo = logo
                    } label: {
                        VStack(spacing: 3) {
                            DeskWordmark(logo: logo, dark: palette.dark, height: 34)
                                .accessibilityHidden(true)
                            HStack(spacing: 5) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? palette.accent : Color.secondary)
                                Text(logo.title)
                            }
                            .font(.callout.weight(.medium))
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(selected ? palette.selection : palette.reader, in: shape)
                        .overlay { shape.strokeBorder(selected ? palette.accent : palette.line).allowsHitTesting(false) }
                        .contentShape(shape)
                    }
                    .buttonStyle(DeskButtonStyle())
                    .accessibilityLabel(logo.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: 550)
        }
    }

    private var readerSizeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sizeSlider("帖子正文字号", size: $bodyTextSize, range: DeskTextSize.bodyRange, standard: DeskTextSize.bodyDefault)
            sizeSlider("帖子作者栏缩放", size: $authorScale, range: DeskTextSize.authorScaleRange,
                       standard: DeskTextSize.authorScaleDefault, step: 5, unit: "%")
            sizePreview {
                VStack(alignment: .leading, spacing: 12) {
                    FloorAuthorHeader(author: "示例用户", avatarURL: nil, rank: 6, tags: ["楼主", "管理"],
                                      date: "2026-07-21 21:03:36", number: "0", isRoot: true,
                                      scale: CGFloat(authorScale / 100), palette: palette, openProfile: nil) {
                        EmptyView()
                    }
                    ForumBlocksView(blocks: [
                        ForumBlock(kind: "text", text: "这是晚高峰的实测记录。电信和联通的延迟比较稳定，移动偶尔出现波动。", url: nil, tabs: nil, rows: nil, terminal: nil)
                    ], palette: DeskPalette(dark: palette.dark, readingSize: bodyTextSize))
                }
                .padding(.horizontal, 11).padding(.vertical, 10)
            }
        }
    }

    private func textSizeControl<Preview: View>(_ title: String, size: Binding<Double>, range: ClosedRange<Double>,
                                               standard: Double, @ViewBuilder preview: () -> Preview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sizeSlider(title, size: size, range: range, standard: standard)
            sizePreview(preview)
        }
    }

    private func sizeSlider(_ title: String, size: Binding<Double>, range: ClosedRange<Double>,
                            standard: Double, step: Double = 1, unit: String = " 点") -> some View {
        let value = "\(Int(size.wrappedValue))\(unit)"
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize()
                    Spacer(minLength: 8)
                    sizeValue(value, title: title, size: size, standard: standard)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    HStack {
                        sizeValue(value, title: title, size: size, standard: standard)
                        Spacer(minLength: 0)
                    }
                }
            }
            Slider(value: size, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }

    @ViewBuilder private func sizeValue(_ value: String, title: String, size: Binding<Double>, standard: Double) -> some View {
        Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        Button("恢复默认") { size.wrappedValue = standard }
            .buttonStyle(.borderless).foregroundStyle(palette.accent)
            .accessibilityLabel("恢复默认\(title)").fixedSize()
    }

    private func sizePreview<Preview: View>(@ViewBuilder _ preview: () -> Preview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("预览").font(.caption).foregroundStyle(.secondary)
            preview()
                .background(palette.reader, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line).allowsHitTesting(false) }
        }
    }

    @MainActor private final class Selection: ObservableObject { @Published var category = Category.general }
}

