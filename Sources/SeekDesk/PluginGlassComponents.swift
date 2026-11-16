import SwiftUI

/// Catalog cards are navigation controls. Share their material rendering while
/// keeping the gaps wider than the glass interaction distance.
struct PluginGlassGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        DeskGlassGroup { content }
    }
}

struct PluginCatalogCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let installed: Bool
    let active: Bool
    let palette: DeskPalette
    let action: () -> Void

    private var status: String { installed ? (active ? "已启用" : "已停用") : "未安装" }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    PluginExtensionIcon(symbol: symbol, palette: palette)
                    Spacer(minLength: 0)
                    Label(status, systemImage: active ? "checkmark.circle" : installed ? "pause.circle" : "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(active ? palette.categoryInk("review") : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(active ? palette.categoryInk("review").opacity(0.09) : palette.surface, in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        }
        .buttonStyle(PluginCardButtonStyle(palette: palette))
        .accessibilityLabel(title)
        .accessibilityValue(installed ? "已安装，\(status)" : status)
        .accessibilityHint("打开扩展详情和设置")
    }
}

private struct PluginCardButtonStyle: ButtonStyle {
    let palette: DeskPalette
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, palette: palette)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let palette: DeskPalette
        @StateObject private var pointer = Pointer()
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .deskGlass(in: shape, solid: palette.list, interactive: true)
                .overlay {
                    shape.fill(palette.accent.opacity(configuration.isPressed ? 0.12 : pointer.hovering ? 0.045 : 0))
                        .allowsHitTesting(false)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pointer.hovering)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
                    shape.strokeBorder(pointer.hovering ? palette.accent.opacity(0.48) : .clear, lineWidth: 1)
                        .allowsHitTesting(false)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pointer.hovering)
                }
                .contentShape(shape)
                .onHover { if pointer.hovering != $0 { pointer.hovering = $0 } }
        }
    }
    @MainActor private final class Pointer: ObservableObject { @Published var hovering = false }
}

struct PluginExtensionIcon: View {
    let symbol: String
    let palette: DeskPalette

    var body: some View {
        DeskIcon(symbol, size: 20).font(.system(size: 20, weight: .medium))
            .foregroundStyle(palette.accent)
            .frame(width: 42, height: 42)
            .background(palette.accent.opacity(palette.dark ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

/// Each settings/guide card owns one material. Its rows and buttons remain
/// flat, sharing this surface instead of stacking their own glass layers.
struct PluginDetailSection<Content: View>: View {
    let title: String
    let symbol: String
    let palette: DeskPalette
    private let content: Content

    init(_ title: String, symbol: String, palette: DeskPalette, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: RoundedRectangle(cornerRadius: 18), solid: palette.list)
    }
}

struct PluginGuideRow: View {
    let symbol: String
    let title: String
    let detail: String
    let palette: DeskPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(palette.accent)
                .frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
