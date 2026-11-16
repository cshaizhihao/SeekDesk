import SwiftUI
import UserNotifications

struct PluginCenterView: View {
    let palette: DeskPalette
    let returnTitle: String
    let returnToForum: () -> Void
    let showHot: () -> Void
    let openTopic: (URL) -> Bool
    @ObservedObject var session: ForumSession
    @ObservedObject var attendance: AttendanceState
    @EnvironmentObject private var extensions: DeskExtensions
    @StateObject private var selection = Selection()

    var body: some View {
        VStack(spacing: 0) {
            PluginGlassGroup {
                HStack(spacing: 13) {
                    if selection.item != nil {
                        navigationButton("返回扩展中心") { selection.item = nil }
                    }
                    Text(selection.item == nil ? "扩展中心" : "扩展详情")
                        .font(.system(size: selection.item == nil ? 23 : 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    navigationButton(returnTitle, action: returnToForum)
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            }
            if let item = selection.item {
                detail(item).id(item).modifier(DeskArrival())
            } else {
                catalog.modifier(DeskArrival())
            }
        }
        .background(palette.readerWash)
    }

    private var catalog: some View {
        let installed = DeskExtension.allCases.filter { extensions.installed.contains($0) }
        let available = DeskExtension.allCases.filter { !extensions.installed.contains($0) }
        return VStack(spacing: 0) {
            HStack {
                DeskGlassPicker(values: [Catalog.installed, .all], selection: $selection.catalog,
                                tint: palette.accent, solid: palette.selection) { category, selected in
                    Text(category == .installed ? "已安装 \(installed.count)" : "全部扩展 \(DeskExtension.allCases.count)")
                        .font(.system(size: 13, weight: .semibold))
                }
                .accessibilityIdentifier("extension-category")
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 20)
            if selection.catalog == .installed && installed.isEmpty {
                ContentUnavailableView {
                    DeskLabel("还没有已安装的扩展", systemImage: "puzzlepiece.extension", size: 32)
                } actions: {
                    Button("浏览全部扩展") { selection.catalog = .all }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    PluginGlassGroup {
                        VStack(alignment: .leading, spacing: 24) {
                            if selection.catalog == .all && !available.isEmpty {
                                catalogSection("未安装", items: available)
                            }
                            if !installed.isEmpty {
                                catalogSection("已安装", items: installed)
                            }
                        }
                    }
                    .frame(maxWidth: 1000, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 28)
                }
            }
        }
    }

    private func catalogSection(_ title: String, items: [DeskExtension]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 310), spacing: 16)], spacing: 16) {
                ForEach(items) { item in card(item) }
            }
        }
    }

    private func card(_ item: DeskExtension) -> some View {
        PluginCatalogCard(title: item.title, subtitle: cardSubtitle(item), symbol: item.icon,
                          installed: extensions.installed.contains(item), active: extensions.active(item), palette: palette) {
            selection.item = item
        }
    }

    private func navigationButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeskLabel(title, systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).frame(height: 30)
        }
        .deskGlassButtonStyle()
    }

    private func cardSubtitle(_ item: DeskExtension) -> String {
        switch item {
        case .hot: "原作者 · @小号"
        case .rulings: "原项目 @slugger · 时区修正 @sss1231"
        default: item.description
        }
    }

    private func detail(_ item: DeskExtension) -> some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    VStack(alignment: .leading, spacing: 20) {
                        detailIdentity(item)
                        if item == .proxy && extensions.installed.contains(item) {
                            DeskProxySettingsView(available: extensions.active(.proxy), palette: palette)
                        } else {
                            let wide = geometry.size.width >= 850 && extensions.installed.contains(item)
                            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20)) :
                                AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                            layout {
                                detailSettings(item).frame(maxWidth: .infinity)
                                if extensions.installed.contains(item) {
                                    detailGuide(item).frame(width: wide ? 280 : nil)
                                }
                            }
                        }
                        if extensions.installed.contains(item) { removalRow(item) }
                    }
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if item == .keywords { extensions.acknowledgeHits() } }
    }

    private func detailIdentity(_ item: DeskExtension) -> some View {
        let installed = extensions.installed.contains(item)
        let active = extensions.active(item)
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 18) {
                DeskIcon(item.icon, size: 30).font(.system(size: 30, weight: .medium))
                    .foregroundStyle(palette.accent).frame(width: 68, height: 68)
                    .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.system(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.description).font(.system(size: 13)).foregroundStyle(.secondary)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Label(installed ? (active ? "已启用" : "已停用") : "尚未安装",
                      systemImage: active ? "checkmark.circle.fill" : installed ? "pause.circle" : "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? palette.categoryInk("review") : .secondary)
                Spacer()
                if installed {
                    Toggle("启用扩展", isOn: Binding(get: { extensions.active(item) }, set: { extensions.setEnabled(item, $0) }))
                        .toggleStyle(.switch).tint(palette.accent).font(.system(size: 12, weight: .medium))
                } else {
                    Button { extensions.install(item) } label: { Label("安装扩展", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent)
                }
            }
        }
        .padding(26).frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 24), solid: palette.list)
    }

    private func detailSettings(_ item: DeskExtension) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if extensions.installed.contains(item) {
                PluginDetailSection(settingsTitle(item), symbol: settingsSymbol(item), palette: palette) {
                    controls(item)
                }
            } else {
                PluginDetailSection("功能预览", symbol: "sparkles", palette: palette) {
                    guideRows(item)
                    Label("安装后可在这里管理扩展。", systemImage: "plus.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if item == .hot || item == .rulings {
                PluginDetailSection("来源与致谢", symbol: "heart", palette: palette) {
                    if item == .hot {
                        sourceLink("原作者 @小号", subtitle: "NodeSeek 社区", url: "https://www.nodeseek.com/space/10539")
                        Divider()
                        sourceLink("原热榜项目", subtitle: "Greasy Fork", url: "https://greasyfork.org/scripts/560065")
                    } else {
                        sourceLink("原脚本 · @slugger", subtitle: "sluggerbox · Greasy Fork", url: "https://greasyfork.org/scripts/567915")
                        Divider()
                        sourceLink("NS Seek 后端", subtitle: "@slugger · GitHub", url: "https://github.com/theslugger/ns-seek")
                        Divider()
                        sourceLink("北京时间修正", subtitle: "@sss1231 · NodeSeek", url: "https://www.nodeseek.com/post-870735-1")
                    }
                }
            }
        }
    }

    private func detailGuide(_ item: DeskExtension) -> some View {
        PluginDetailSection("使用方式", symbol: "lightbulb", palette: palette) {
            guideRows(item)
        }
    }

    @ViewBuilder private func guideRows(_ item: DeskExtension) -> some View {
        switch item {
        case .hot:
            guide("sidebar.left", "侧栏随时查看", "展开侧栏热榜，直接打开感兴趣的帖子。")
            guide("clock", "切换时间范围", "实时、日榜和周榜分别查看近期与持续热门的讨论。")
        case .attendance:
            guide("calendar", "北京时间零点", "SeekDesk 运行时自动执行当天签到。")
            guide("moon", "恢复后补签", "电脑休眠或应用退出后，重新运行会补签当天。")
        case .office:
            guide("keyboard", "快捷切换", "按设定的 ⌘⇧ 快捷键进入或退出办公视图。")
            guide("rectangle.on.rectangle", "保留阅读状态", "恢复窗口后继续浏览之前的帖子。")
        case .value:
            guide("rectangle.topthird.inset.filled", "帖子右上角", "打开交易帖子，点击「估价」填写价格与到期时间。")
            guide("arrow.left.arrow.right", "对比交易价格", "按剩余时间估值，也可以换算币种。")
        case .block:
            guide("person.crop.circle.badge.minus", "从作者菜单屏蔽", "在帖主或楼层作者旁打开菜单，选择屏蔽用户。")
            guide("eye", "随时恢复", "可在原楼层临时展开，也可在这里解除屏蔽。")
        case .authorOnly:
            guide("person.text.rectangle", "聚焦楼主更新", "在帖子楼层标题旁开启「只看楼主」。")
            guide("text.bubble", "返回完整讨论", "关闭开关，即可继续查看其他人的回复。")
        case .keywords:
            guide("text.magnifyingglass", "组合关键词", "日本+VPS 表示两个词都出现；用逗号添加另一组规则。")
            guide("bell", "应用内与系统通知", "命中后显示应用内提示，也可开启 macOS 通知。")
        case .rulings:
            guide("shield.lefthalf.filled", "从作者旁查询", "点击「管理记录查询」查看公开社区记录。")
            guide("clock", "北京时间", "查询结果统一显示为北京时间。")
        case .proxy:
            guide("link", "导入节点或订阅", "粘贴分享链接或订阅地址，选择自己的节点。")
            guide("network", "仅代理 SeekDesk", "开启后只影响本应用的连接，其他 App 保持原有网络。")
        }
    }

    private func guide(_ symbol: String, _ title: String, _ detail: String) -> some View {
        PluginGuideRow(symbol: symbol, title: title, detail: detail, palette: palette)
    }

    private func sourceLink(_ title: String, subtitle: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.accent)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func removalRow(_ item: DeskExtension) -> some View {
        HStack {
            Text("不再需要这个扩展？").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("移除扩展", role: .destructive) { extensions.remove(item) }.buttonStyle(.borderless)
        }.padding(.horizontal, 8).padding(.top, 2)
    }

    private func settingsTitle(_ item: DeskExtension) -> String {
        switch item {
        case .hot: "浏览热榜"
        case .attendance: "自动签到"
        case .office: "办公视图与快捷键"
        case .value: "估价工具"
        case .block: "已屏蔽用户"
        case .authorOnly: "阅读筛选"
        case .keywords: "监控规则与通知"
        case .rulings: "公开记录查询"
        case .proxy: "连接设置"
        }
    }

    private func settingsSymbol(_ item: DeskExtension) -> String {
        switch item {
        case .hot: "flame"
        case .block: "person.2"
        case .value: "plus.forwardslash.minus"
        case .keywords: "bell.badge"
        default: "slider.horizontal.3"
        }
    }

    @ViewBuilder private func controls(_ item: DeskExtension) -> some View {
        switch item {
        case .proxy:
            DeskProxySettingsView(available: extensions.active(.proxy), palette: palette)
        case .attendance:
            VStack(alignment: .leading, spacing: 12) {
                Text("签到方式").font(.callout)
                DeskGlassPicker(values: ForumAttendanceMode.allCases, selection: $extensions.attendanceMode,
                                tint: palette.accent, solid: palette.selection, compact: true) { mode, _ in
                    Text(mode.title).font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("签到方式")
                Toggle("每天 00:00 自动签到", isOn: $extensions.autoAttendance).toggleStyle(.switch)
                    .disabled(!extensions.active(.attendance))
                Text("按北京时间签到。电脑休眠或应用退出时，恢复运行后会补签当天。")
                    .font(.caption).foregroundStyle(.secondary)
                if extensions.active(.attendance) && extensions.autoAttendance {
                    if let profile = session.ownProfile {
                        DeskLabel(attendance.status(for: profile.id), systemImage: "calendar")
                            .font(.callout).foregroundStyle(palette.accent)
                        if attendance.needsVerification(for: profile.id) {
                            Button("打开 NodeSeek 验证") { session.verify(Forum.home) }
                        }
                    } else if session.account == .signedOut {
                        Button("登录 NodeSeek", action: session.signIn)
                    } else {
                        Text("正在确认 NodeSeek 登录状态…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        case .hot:
            VStack(alignment: .leading, spacing: 18) {
                Text("发现社区里正在热议的帖子。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    ForEach([("实时", "当下热议"), ("日榜", "今天热门"), ("周榜", "本周精选")], id: \.0) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.0).font(.system(size: 15, weight: .semibold))
                            Text(entry.1).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(16).background(palette.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                Button(action: showHot) { Label("打开热榜", systemImage: "flame") }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent)
                    .disabled(!extensions.active(.hot))
            }
        case .office:
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("工作表标题").font(.system(size: 12, weight: .medium))
                    TextField("工作计划", text: $extensions.officeTitle).textFieldStyle(.roundedBorder).controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("工具栏按钮名称").font(.system(size: 12, weight: .medium))
                    TextField("切换办公视图", text: $extensions.officeButton).textFieldStyle(.roundedBorder).controlSize(.large)
                }
                HStack {
                    Picker("⌘⇧ 快捷键", selection: $extensions.officeKey) {
                        ForEach(["7", "8", "9", "0"], id: \.self) { Text($0).tag($0) }
                    }.fixedSize()
                    Spacer()
                    Button("切换办公视图") { extensions.officePresented = true }
                        .buttonStyle(.bordered).disabled(!extensions.active(.office))
                }
            }
        case .value:
            VStack(alignment: .leading, spacing: 9) {
                Text("启用后，打开任意帖子即可在顶部点「估价」。")
                    .font(.callout).foregroundStyle(.secondary)
                RemainingValueButton(palette: palette, title: "试算")
                    .disabled(!extensions.active(.value))
            }
        case .block:
            if extensions.blocked.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.slash").font(.system(size: 27, weight: .light)).foregroundStyle(palette.accent)
                    Text("还没有屏蔽用户").font(.system(size: 14, weight: .medium))
                    Text("从帖子作者旁的菜单添加，屏蔽名单会显示在这里。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 18).frame(maxWidth: .infinity)
            } else {
                ForEach(extensions.blocked) { entry in
                    HStack {
                        Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        Button("解除屏蔽") { extensions.unblock(entry) }
                    }.padding(12).background(palette.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        case .authorOnly:
            guide("line.3.horizontal.decrease", "筛选作者正文与回复", "启用后，帖子内会提供「只看楼主」开关。每篇讨论可按需要切换。")
        case .rulings:
            guide("person.text.rectangle", "查询社区公开记录", "在帖子作者旁点「管理记录查询」，即可打开查询面板。")
            Divider()
            Label("NS Seek 社区服务仅接收被查询的公开用户名。", systemImage: "hand.raised")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .keywords:
            VStack(alignment: .leading, spacing: 16) {
                Text("关键词规则").font(.system(size: 12, weight: .medium))
                TextField("关键词规则，例如 日本+VPS，测评", text: $selection.watchInput).textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityLabel("关键词规则")
                    .onSubmit(saveWatchSettings)
                Text("逗号分隔的规则满足任意一组即可。用 + 连接的词必须出现在同一篇帖子的标题或 RSS 摘要里，顺序不限。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("最多 25 组，例如：日本+VPS，测评。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("备注（可选）", text: $selection.watchNoteInput).textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(saveWatchSettings)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(watchStatus).font(.caption).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 8)
                        saveWatchButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(watchStatus).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        saveWatchButton
                    }
                }
                Divider().padding(.vertical, 2)
                Toggle("发送 macOS 通知", isOn: Binding(get: { extensions.watchSystemNotifications },
                                                        set: extensions.setWatchSystemNotifications))
                    .toggleStyle(.switch)
                    .disabled(!extensions.active(.keywords))
                if extensions.watchSystemNotifications && extensions.watchNotificationAccess == .denied {
                    Text("请在系统设置的「通知」中允许 SeekDesk 发送通知。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("SeekDesk 运行时每 10 秒在后台检查 RSS，命中会显示应用内提示。开启此选项后，也会发送 macOS 通知。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(extensions.hits) { hit in
                    Button { _ = openTopic(hit.post.url) } label: {
                        DeskLabel(hit.post.title, systemImage: "arrow.up.right").lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(palette.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            .onAppear {
                selection.watchInput = extensions.watchWords
                selection.watchNoteInput = extensions.watchNote
            }
            .task { await extensions.refreshWatchNotificationAccess() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await extensions.refreshWatchNotificationAccess() }
            }
        }
    }

    private func saveWatchSettings() {
        extensions.watchNote = selection.watchNoteInput
        extensions.watchWords = selection.watchInput
    }

    private var saveWatchButton: some View {
        Button("保存监控设置", action: saveWatchSettings)
            .buttonStyle(.borderedProminent).tint(palette.accent).fixedSize()
    }

    private var watchStatus: String {
        if !extensions.active(.keywords) { return "监控已关闭" }
        if extensions.watchFailed { return "RSS 暂时无法连接，稍后自动重试" }
        if extensions.watchTerms.isEmpty { return "添加关键词后开始监控" }
        if let time = extensions.lastCheck { return "最近检查 \(time.formatted(date: .omitted, time: .standard))" }
        return "正在检查新帖…"
    }

    private enum Catalog: Hashable { case installed, all }

    @MainActor private final class Selection: ObservableObject {
        @Published var item: DeskExtension?
        @Published var catalog = Catalog.installed
        @Published var watchInput = ""
        @Published var watchNoteInput = ""
    }
}
