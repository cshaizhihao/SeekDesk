import SwiftUI

struct DeskProxySettingsView: View {
    let available: Bool
    let palette: DeskPalette
    @ObservedObject private var proxy = DeskProxyController.shared
    @StateObject private var selection = ProxySettingsSelection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var stateColor: Color {
        proxy.issue != nil ? .orange : proxy.running ? palette.categoryInk("review") : proxy.starting ? palette.accent : .secondary
    }
    private var stateTitle: String {
        if !available { return "扩展已停用" }
        if !proxy.enabled { return "代理未开启" }
        if proxy.starting { return "正在连接" }
        return proxy.running ? "代理已就绪" : "连接未建立"
    }
    private var stateDetail: String {
        if !available { return "启用扩展后，可以使用自己的节点访问 NodeSeek。" }
        if !proxy.enabled { return "SeekDesk 正在使用当前网络。" }
        return proxy.running ? "仅供 SeekDesk 使用，可检测 NodeSeek 连通性。" : proxy.status
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            connection
            subscriptions
            nodes
            preferences
            HStack(spacing: 8) {
                Text("Xray-core 26.11.9").foregroundStyle(.secondary)
                Text("MPL-2.0").foregroundStyle(.secondary)
                Spacer()
                Link("内核与源代码", destination: URL(string: "https://github.com/XTLS/Xray-core/tree/v26.11.9")!)
            }.font(.system(size: 11)).padding(.horizontal, 4).padding(.top, 2)
        }
        .task { proxy.loadNodes() }
        .sheet(item: $selection.editor) { entry in ProxyNodeEditor(node: entry.node, proxy: proxy, palette: palette) }
        .alert("删除这个节点？", isPresented: Binding(get: { selection.deleting != nil }, set: { if !$0 { selection.deleting = nil } })) {
            Button("取消", role: .cancel) { selection.deleting = nil }
            Button("删除", role: .destructive) { if let node = selection.deleting { proxy.remove(node.id) }; selection.deleting = nil }
        } message: { Text("删除后需要重新导入链接。删除当前节点时，开启的代理将尝试使用剩余节点；没有节点时保持断开。") }
        .alert("删除这个订阅？", isPresented: Binding(get: { selection.deletingSubscription != nil }, set: { if !$0 { selection.deletingSubscription = nil } })) {
            Button("取消", role: .cancel) { selection.deletingSubscription = nil }
            Button("删除订阅及节点", role: .destructive) {
                if let source = selection.deletingSubscription { proxy.removeSubscription(source.id) }
                selection.deletingSubscription = nil
            }
        } message: { Text("将一并移除该订阅导入的节点。其他节点和订阅会保留。") }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(stateColor.opacity(0.12))
                    if proxy.starting { ProgressView().controlSize(.small) }
                    else { Image(systemName: proxy.running ? "checkmark.shield" : "network").font(.system(size: 23, weight: .medium)).foregroundStyle(stateColor) }
                }.frame(width: 54, height: 54).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(stateTitle).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(stateDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("开启专用代理", isOn: Binding(get: { proxy.enabled }, set: { proxy.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).disabled(!available).tint(palette.accent)
            }
            HStack(spacing: 12) {
                Circle().fill(stateColor).frame(width: 7, height: 7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前节点").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(proxy.selected?.name ?? "尚未选择节点")
                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Label("仅此应用", systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent).fixedSize()
            }
            .padding(14)
            .background(palette.accent.opacity(palette.dark ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 12))
            if let issue = proxy.issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(palette.dark ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if proxy.enabled {
                HStack(spacing: 10) {
                    Button { Task { await proxy.checkConnection() } } label: {
                        Label(proxy.checking ? "正在检测…" : "检测连通性", systemImage: "waveform.path.ecg")
                    }.buttonStyle(.bordered).disabled(!available || !proxy.running || proxy.checking)
                    Button { proxy.reconnect() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).disabled(!available || proxy.starting)
                }.controlSize(.regular)
            }
            if let result = proxy.checkResult {
                Label(result, systemImage: "waveform.path.ecg")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), solid: palette.list, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private var filteredNodes: [DeskProxyNode] {
        proxy.nodes.filter {
            selection.search.isEmpty || ($0.name + " " + $0.host + " " + $0.protocolName).localizedCaseInsensitiveContains(selection.search)
        }
    }
    private var nodes: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sectionTitle("我的节点", symbol: "network", count: proxy.nodes.count)
                    if !proxy.nodes.isEmpty { addButton }
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("我的节点", symbol: "network", count: proxy.nodes.count)
                    if !proxy.nodes.isEmpty { addButton }
                }
            }
            if proxy.nodes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 29, weight: .light)).foregroundStyle(palette.accent)
                        .frame(width: 64, height: 64)
                        .background(palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                        .padding(.bottom, 4).accessibilityHidden(true)
                    Text("添加你的第一个节点").font(.system(size: 14, weight: .semibold))
                    Text("添加订阅，或批量粘贴节点分享链接。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    addButton.padding(.top, 8)
                }.padding(.horizontal, 16).padding(.vertical, 20).frame(maxWidth: .infinity)
            } else {
                if proxy.nodes.count > 8 || !selection.search.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索节点名称、服务器或协议", text: $selection.search).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("搜索节点名称、服务器或协议")
                        if !selection.search.isEmpty {
                            Button("清空") { selection.search = "" }.buttonStyle(.borderless)
                        }
                    }
                }
                if filteredNodes.isEmpty {
                    Text("没有匹配的节点").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.vertical, 12).frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredNodes) { node in nodeRow(node) }
                    }
                }
            }
        }
        .modifier(ProxySettingsPanel(palette: palette))
    }
    @ViewBuilder private var subscriptions: some View {
        if !proxy.subscriptions.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("我的订阅", symbol: "link", count: proxy.subscriptions.count)
                ForEach(proxy.subscriptions) { source in
                    HStack(spacing: 12) {
                        Image(systemName: "link").font(.system(size: 16, weight: .medium)).foregroundStyle(palette.accent)
                            .frame(width: 34, height: 34)
                            .background(palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text("\(proxy.nodes.filter { $0.subscriptionID == source.id }.count) 个节点" + (source.updatedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if proxy.updatingSubscriptions.contains(source.id) { ProgressView().controlSize(.small) }
                        Button { Task { await proxy.refreshSubscription(source.id) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.bordered).controlSize(.regular)
                            .help("更新订阅").accessibilityLabel("更新 " + source.name)
                            .disabled(!available || proxy.updatingSubscriptions.contains(source.id))
                        Button { selection.deletingSubscription = source } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered).controlSize(.regular)
                            .help("删除订阅").accessibilityLabel("删除订阅 " + source.name).disabled(!available)
                    }
                    .padding(14).background(palette.chrome, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .modifier(ProxySettingsPanel(palette: palette))
        }
        if let message = proxy.importMessage {
            Label(message, systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .deskGlass(in: RoundedRectangle(cornerRadius: 12), solid: palette.list)
        }
    }
    private var addButton: some View {
        Button { selection.editor = ProxyNodeEditorRequest(node: nil) } label: { Label("添加节点 / 订阅", systemImage: "plus") }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!available)
    }
    private func nodeRow(_ node: DeskProxyNode) -> some View {
        let selected = proxy.selectedID == node.id
        return HStack(spacing: 12) {
            Button { proxy.select(node.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(selected ? palette.accent : .secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                        Text(node.host + ":" + String(node.port)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let source = proxy.subscriptions.first(where: { $0.id == node.subscriptionID }) {
                            Text(source.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(node.protocolName).font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? palette.accent : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(selected ? palette.accent.opacity(0.1) : palette.surface, in: Capsule()).fixedSize()
                }.padding(.vertical, 16).padding(.leading, 16).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!available).accessibilityLabel("选择 " + node.name).accessibilityAddTraits(selected ? .isSelected : [])
            latencyButton(node)
            Menu {
                Button("编辑节点") { selection.editor = ProxyNodeEditorRequest(node: node) }
                Button("删除节点", role: .destructive) { selection.deleting = node }
            } label: { Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 28, height: 30) }
                .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 12).disabled(!available).accessibilityLabel(node.name + "的操作")
        }
        .background(selected ? palette.selection : palette.chrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? palette.accent.opacity(0.5) : Color.primary.opacity(contrast == .increased ? 0.35 : 0))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : DeskMotion.selection, value: selected)
    }
    private func latencyButton(_ node: DeskProxyNode) -> some View {
        let result = proxy.nodeLatencies[node.id]
        let measuring = result == .measuring
        return Button { proxy.measureLatency(node.id) } label: {
            HStack(spacing: 5) {
                if measuring {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "bolt.fill").font(.system(size: 12, weight: .medium))
                }
                if case .success(let milliseconds) = result {
                    Text("\(milliseconds) ms").monospacedDigit()
                } else if result == .failed {
                    Text("未连通")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(result == .failed ? Color.secondary : palette.accent)
            .frame(minWidth: 18, minHeight: 22)
        }
        .buttonStyle(.bordered).controlSize(.regular).fixedSize()
        .disabled(!available || measuring || !proxy.canMeasureMoreNodes)
        .help(measuring ? "正在检测…" : "检测节点延迟")
        .accessibilityLabel("检测 " + node.name + " 的延迟")
        .accessibilityValue(measuring ? "正在检测" : latencyDescription(result))
    }
    private func latencyDescription(_ result: DeskProxyLatency?) -> String {
        switch result {
        case .success(let milliseconds): "\(milliseconds) 毫秒"
        case .failed: "未连通"
        default: "尚未检测"
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("连接偏好", symbol: "slider.horizontal.3")
            Toggle(isOn: $proxy.startWithApp) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("启动时恢复代理").font(.system(size: 13, weight: .medium))
                    Text("下次打开 SeekDesk 时，恢复上次已开启的连接。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).controlSize(.regular).disabled(!available)
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 17)).foregroundStyle(palette.accent)
                    .padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("仅在 SeekDesk 内生效").font(.system(size: 12, weight: .medium))
                    Text("节点凭据及订阅地址仅存于本机钥匙串。系统代理和其他 App 不受影响；连接失败时保持断开。")
                    Text("切换节点会中断当前请求，账号和草稿会保留。浏览器中打开的链接使用浏览器自身的网络设置。")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
        }.modifier(ProxySettingsPanel(palette: palette))
    }

    private func sectionTitle(_ title: String, symbol: String, count: Int? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let count {
                Text(String(count)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(palette.surface, in: Capsule())
                    .accessibilityLabel("\(count) 项")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ProxySettingsPanel: ViewModifier {
    let palette: DeskPalette
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .deskGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), solid: palette.list)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct ProxyNodeEditor: View {
    let node: DeskProxyNode?
    @ObservedObject var proxy: DeskProxyController
    let palette: DeskPalette
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ProxyNodeEditorForm()
    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.system(size: 22)).foregroundStyle(palette.accent)
                    .frame(width: 44, height: 44).background(palette.selection, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(node == nil ? "添加节点或订阅" : "编辑代理节点").font(.system(size: 19, weight: .semibold))
                    Text("导入后选择节点，再开启 SeekDesk 专用代理。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if node == nil {
                ScrollView(.horizontal) {
                    DeskGlassPicker(values: [false, true], selection: $form.subscriptionMode,
                                    tint: palette.accent, solid: palette.selection, compact: true) { subscription, _ in
                        Text(subscription ? "订阅链接" : "节点链接 / 批量导入")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .disabled(form.fetching)
                    .accessibilityLabel("导入方式")
                }
                .scrollIndicators(.hidden)
                .frame(height: 34)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(form.subscriptionMode ? "订阅地址" : "节点链接").font(.system(size: 12, weight: .medium))
                Group {
                    if form.subscriptionMode {
                        TextField("https://example.com/subscribe", text: $form.link)
                            .textFieldStyle(.plain).autocorrectionDisabled().font(.system(size: 12)).frame(height: 18)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                    } else {
                        ZStack(alignment: .topLeading) {
                            if form.link.isEmpty {
                                Text("粘贴节点链接、Base64 列表或 Clash YAML")
                                    .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 1)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                            TextEditor(text: $form.link).scrollContentBackground(.hidden).autocorrectionDisabled()
                                .frame(height: 44)
                        }.font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 8)
                    }
                }.background(palette.reader, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line).allowsHitTesting(false) }
                    .accessibilityLabel(form.subscriptionMode ? "订阅地址" : "节点链接")
                Text(form.subscriptionMode ? "支持 Base64 / 明文列表及 Clash YAML / JSON。通过当前网络获取，可在导入后手动更新；不导入远程规则或脚本。" : "支持 VLESS、VMess、SS、Trojan、Hysteria2（含 Salamander）、SOCKS5、HTTP/HTTPS。TUIC / SSR 暂不支持。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(form.subscriptionMode ? "订阅名称" : "节点名称").font(.system(size: 12, weight: .medium))
                    Text("可选").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                TextField(form.subscriptionMode ? "例如：我的订阅" : "单个节点可自定义；批量时保留原名称", text: $form.name).textFieldStyle(.plain).padding(.horizontal, 11).padding(.vertical, 9)
                    .background(palette.reader, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line).allowsHitTesting(false) }
            }
            if let result = form.result {
                VStack(alignment: .leading, spacing: 7) {
                    Text(result.summary).font(.system(size: 12, weight: .semibold))
                    ForEach(Array(result.nodes.prefix(4).enumerated()), id: \.offset) { _, node in
                        Text(node.protocolName + " · " + node.name).font(.system(size: 11)).lineLimit(1)
                    }
                    if result.nodes.count > 4 { Text("还有 \(result.nodes.count - 4) 个节点").font(.system(size: 11)).foregroundStyle(.secondary) }
                    ForEach(Array(result.skipped.prefix(2).enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.reader, in: RoundedRectangle(cornerRadius: 8))
            }
            if let issue = form.issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
            HStack {
                Label("仅保存在本机钥匙串", systemImage: "lock").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button(form.fetching ? "正在获取…" : node != nil ? "保存节点" : form.result == nil ? (form.subscriptionMode ? "获取订阅" : "识别节点") : "确认导入") { submit() }
                    .buttonStyle(.borderedProminent).disabled(form.fetching || form.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.controlSize(.regular).padding(.horizontal, 22).padding(.vertical, 16)
        }.frame(width: 550, height: node != nil ? 390 : form.result == nil ? 470 : 560)
        .deskGlass(in: RoundedRectangle(cornerRadius: 20), solid: palette.list)
        .onAppear { form.name = node?.name ?? ""; form.link = node?.link ?? "" }
        .onChange(of: form.link) { _, _ in form.result = nil; form.issue = nil }
        .onChange(of: form.subscriptionMode) { _, _ in form.result = nil; form.issue = nil }
        .onDisappear { form.task?.cancel(); form.link = ""; form.result = nil }
    }

    private func submit() {
        form.issue = nil
        if let node {
            do { try proxy.save(link: form.link, name: form.name, replacing: node.id); dismiss() }
            catch { form.issue = error.localizedDescription }
        } else if var result = form.result {
            do {
                let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !form.subscriptionMode, result.nodes.count == 1, !name.isEmpty { result.nodes[0].name = String(name.prefix(100)) }
                let source: DeskProxySubscription?
                if form.subscriptionMode {
                    let url = try DeskProxySubscriptionFetch.validatedURL(form.link)
                    source = DeskProxySubscription(name: String((name.isEmpty ? (url.host ?? "我的订阅") : name).prefix(100)), url: url.absoluteString, updatedAt: Date())
                } else { source = nil }
                try proxy.importNodes(result, subscription: source)
                dismiss()
            } catch { form.issue = error.localizedDescription }
        } else {
            let input = form.link, isSubscription = form.subscriptionMode
            form.fetching = true
            form.task = Task {
                defer { form.fetching = false }
                do {
                    let result = try await (isSubscription ? DeskProxySubscriptionFetch.fetch(input) : Task.detached { try DeskProxySubscriptionParser.parse(Data(input.utf8)) }.value)
                    guard !Task.isCancelled, form.link == input, form.subscriptionMode == isSubscription else { return }
                    form.result = result
                } catch is CancellationError { }
                catch { if !Task.isCancelled { form.issue = error.localizedDescription } }
            }
        }
    }
}
private struct ProxyNodeEditorRequest: Identifiable { let id = UUID(); let node: DeskProxyNode? }
@MainActor private final class ProxySettingsSelection: ObservableObject {
    @Published var editor: ProxyNodeEditorRequest?
    @Published var deleting: DeskProxyNode?
    @Published var deletingSubscription: DeskProxySubscription?
    @Published var search = ""
}
@MainActor private final class ProxyNodeEditorForm: ObservableObject {
    @Published var name = ""
    @Published var link = ""
    @Published var issue: String?
    @Published var subscriptionMode = false
    @Published var result: DeskProxyImportResult?
    @Published var fetching = false
    var task: Task<Void, Never>?
}
