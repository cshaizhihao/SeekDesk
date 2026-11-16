import AppKit
import SwiftUI

enum DeskTextSize {
    static let listKey = "workspace.listTextSize"
    static let bodyKey = "workspace.readerTextSize"
    static let authorScaleKey = "workspace.floorAuthorScale"
    static let boardKey = "workspace.boardTextSize"
    static let rankingKey = "workspace.rankingTextSize"
    static let listDefault = 15.0
    static let bodyDefault = 15.0
    static let authorScaleDefault = 100.0
    static let boardDefault = 13.0
    static let rankingDefault = 12.0
    static let listRange = 12.0...24.0
    static let bodyRange = 13.0...24.0
    static let authorScaleRange = 80.0...160.0
    static let sidebarRange = 11.0...22.0
}

enum DeskReadingDensity: String, CaseIterable, Identifiable {
    case compact, comfortable
    static let preference = "workspace.readingDensity"
    var id: String { rawValue }
    var title: String { self == .compact ? "紧凑" : "舒适" }
    var rowPadding: CGFloat { self == .compact ? 8 : 12 }
    var floorSpacing: CGFloat { self == .compact ? 19 : 27 }
    var readingWidth: CGFloat { self == .compact ? 960 : 860 }
}

struct DeskPalette: Equatable {
    let dark: Bool
    var readingSize = DeskTextSize.bodyDefault

    var accent: Color { tone(0x0066CC, 0x69B4FF) }
    var publish: Color { tone(0x18754A, 0x19794D) }
    var unread: Color { tone(0xC12838, 0xFF656D) }
    var featured: Color { tone(0x91600A, 0xEBC476) }
    var readingRestriction: Color { tone(0x8C4250, 0xEBA8B5) }
    var chrome: Color { Color(nsColor: .windowBackgroundColor) }
    var sidebar: Color { Color(nsColor: .windowBackgroundColor) }
    var list: Color { Color(nsColor: .controlBackgroundColor) }
    var reader: Color { Color(nsColor: .textBackgroundColor) }
    var readerWash: Color { tone(0xF7FAFE, 0x181F28) }
    var line: Color { Color(nsColor: .separatorColor).opacity(0.6) }
    var surface: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.45) }
    var selection: Color { tone(0xE5EFFC, 0x24384F) }

    func rankingInk(_ position: Int) -> Color {
        switch position {
        case 1: tone(0xC4312D, 0xFF8179)
        case 2: tone(0xB85813, 0xFFAD66)
        case 3: tone(0x8A6600, 0xE3C65B)
        default: .secondary
        }
    }

    func categoryInk(_ category: String) -> Color {
        switch category {
        case "trade": tone(0x775322, 0xEFC78A)
        case "review": tone(0x236B61, 0x82D5C7)
        case "tech", "dev": tone(0x355DAC, 0x9EBFFF)
        case "carpool": tone(0x6952A0, 0xC5B2F2)
        case "expose": tone(0x9B4652, 0xE9A2AE)
        default: .secondary
        }
    }

    private func tone(_ light: UInt32, _ dark: UInt32) -> Color {
        let rgb = self.dark ? dark : light
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

enum DeskMotion {
    static let feedback = Animation.easeOut(duration: 0.10)
    static let selection = Animation.smooth(duration: 0.18, extraBounce: 0)
    static let reader = Animation.easeOut(duration: 0.16)
    static let pane = Animation.smooth(duration: 0.24, extraBounce: 0)
    static let image = Animation.smooth(duration: 0.22, extraBounce: 0)
}

struct DeskArrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var state = Entrance()

    func body(content: Content) -> some View {
        content.opacity(state.visible || reduceMotion ? 1 : 0.76)
            .onAppear { withAnimation(reduceMotion ? nil : DeskMotion.reader) { state.visible = true } }
    }

    @MainActor private final class Entrance: ObservableObject { @Published var visible = false }
}

struct DeskRefreshLabel: View {
    let title: String
    let loading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                DeskIcon("arrow.clockwise", size: 14).opacity(loading ? 0 : 1)
                if loading { ProgressView().controlSize(.mini).scaleEffect(0.77) }
            }
            .frame(width: 14, height: 14)
            .animation(reduceMotion ? nil : DeskMotion.feedback, value: loading)
            Text(title)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7).frame(height: 27)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(loading ? "正在刷新" : "")
    }
}

struct DeskButtonStyle: ButtonStyle {
    var compresses = false
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, compresses: compresses)
    }

    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let compresses: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @StateObject private var pointer = Pointer()

        var body: some View {
            let highlight = configuration.isPressed ? (compresses ? 0.14 : 0.10) : pointer.isHovering ? 0.054 : 0
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isEnabled ? highlight : 0))
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .animation(reduceMotion ? nil : DeskMotion.feedback, value: highlight)
                }
                // Keep glyphs at their laid-out size; pressed feedback belongs to the surface.
                .opacity(isEnabled ? 1 : 0.48)
                .contentShape(Rectangle())
                .onHover { if pointer.isHovering != $0 { pointer.isHovering = $0 } }
                .animation(reduceMotion ? nil : DeskMotion.feedback, value: configuration.isPressed)
        }
    }

    @MainActor private final class Pointer: ObservableObject { @Published var isHovering = false }
}

struct CategoryBadge: View {
    let category: String
    let emphasized: Bool
    let palette: DeskPalette
    var fontSize: CGFloat = 10

    var body: some View {
        let ink = emphasized ? palette.accent : palette.categoryInk(category)
        Text(Board.title(for: category)).font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(ink.opacity(palette.dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 5))
    }
}

@MainActor
final class CopyFeedback: ObservableObject {
    @Published private(set) var didCopy = false
    private var reset: Task<Void, Never>?

    func write(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.absoluteString, forType: .string) else { return }
        didCopy = true
        reset?.cancel()
        reset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { self?.didCopy = false }
        }
    }
}

struct ForumAvatar: View {
    let url: URL?
    let size: CGFloat
    let palette: DeskPalette
    @StateObject private var state = AvatarState()

    var body: some View {
        Group {
            if let url, let image = state.url == url ? state.image : ForumImageRequest.cached(url, kind: .avatar) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
            else {
                DeskIcon("person.fill", size: size * 0.38).font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: size, height: size)
        .background(palette.selection)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url, state.url != url || state.image == nil,
                  let image = try? await ForumImageRequest.fetch(url, kind: .avatar),
                  !Task.isCancelled else { return }
            state.url = url
            state.image = image
        }
    }

    @MainActor private final class AvatarState: ObservableObject {
        @Published var image: CGImage?
        var url: URL?
    }
}
