import SwiftUI

extension View {
    func deskGlass<S: Shape>(in shape: S, solid: Color, interactive: Bool = false) -> some View {
        modifier(DeskGlassSurface(shape: shape, solid: solid, interactive: interactive))
    }

    func deskGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(DeskGlassButtonStyle(prominent: prominent))
    }
}

/// Keep related chrome in one native glass rendering group. Content lists and
/// document surfaces stay outside the group to avoid extra compositing layers.
struct DeskGlassGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A single moving glass selection. Animate only the small control, never its
/// destination document or native text editor.
struct DeskGlassPicker<Value: Hashable, Label: View>: View {
    let values: [Value]
    @Binding var selection: Value
    let tint: Color
    let solid: Color
    var vertical = false
    var compact = false
    var controlHeight: CGFloat = 34
    @ViewBuilder let label: (Value, Bool) -> Label
    @Namespace private var namespace
    @StateObject private var geometry = DeskGlassPickerGeometry<Value>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selectedFrame = geometry.frames[selection] ?? .zero
        let motionReduced = reduceMotion
        let isVertical = vertical
        let selectionFill = solid
        let visible = values.contains(selection)
        Group {
            let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) :
                AnyLayout(HStackLayout(spacing: 4))
            layout {
                ForEach(values, id: \.self) { value in
                    let selected = selection == value
                    Button {
                        guard selection != value else { return }
                        selection = value
                    } label: {
                        label(value, selected)
                            .foregroundStyle(selected ? tint : Color.secondary)
                            .padding(.horizontal, compact ? 8 : vertical ? 11 : 14)
                            .frame(maxWidth: vertical ? .infinity : nil, alignment: vertical ? .leading : .center)
                            .frame(height: compact ? min(28, controlHeight) : controlHeight)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(DeskChoiceButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(namespace))
                    } action: { frame in
                        geometry.update(frame, for: value, initialCount: values.count)
                    }
                }
            }
            .coordinateSpace(name: namespace)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: selection) { content, stretch in
                content.modifier(DeskGlassMovingSelection(frame: selectedFrame,
                                                         stretch: motionReduced ? 0 : stretch,
                                                         vertical: isVertical, solid: selectionFill, visible: visible))
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.12)
                CubicKeyframe(-0.12, duration: 0.18)
                CubicKeyframe(0, duration: 0.12)
            }
            .animation(reduceMotion || !geometry.ready || !visible || selectedFrame.isEmpty ? nil : .spring(duration: 0.42, bounce: 0.16),
                       value: selection)
            .transaction(value: selection) { transaction in
                if selectedFrame.isEmpty || !visible || (geometry.selection.map({ !values.contains($0) }) ?? true) {
                    transaction.disablesAnimations = true
                }
            }
            .onChange(of: selection, initial: true) { _, value in geometry.selection = value }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A navigation column shares one moving selection without changing the layout,
/// scroll views or actions of its rows. Frames update only when row layout changes.
struct DeskGlassSelectionGroup<Content: View>: View {
    let selection: String?
    let solid: Color
    var vertical = true
    @ViewBuilder let content: () -> Content
    @StateObject private var geometry = DeskGlassNavigationGeometry()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let target = selection.flatMap { geometry.frames[$0] } ?? .zero
        let motionReduced = reduceMotion
        let selectionFill = solid
        let visible = selection != nil
        let isVertical = vertical
        Group {
            content()
                .environment(\.deskGlassNavigationGeometry, geometry)
                .coordinateSpace(name: geometry.space)
                .keyframeAnimator(initialValue: CGFloat.zero, trigger: selection) { content, stretch in
                    content.modifier(DeskGlassMovingSelection(frame: target, stretch: motionReduced ? 0 : stretch,
                                                             vertical: isVertical, solid: selectionFill, visible: visible))
                } keyframes: { _ in
                    CubicKeyframe(1, duration: 0.12)
                    CubicKeyframe(-0.12, duration: 0.18)
                    CubicKeyframe(0, duration: 0.12)
                }
                .animation(reduceMotion || !geometry.ready || !visible || target.isEmpty ? nil : .spring(duration: 0.42, bounce: 0.16),
                           value: selection)
                .transaction(value: selection) { transaction in
                    if target.isEmpty || geometry.selection == nil || selection == nil { transaction.disablesAnimations = true }
                }
                .onChange(of: selection, initial: true) { _, value in geometry.selection = value }
        }
    }
}

extension View {
    func deskGlassSelectionItem(_ id: String, selected: Bool) -> some View {
        modifier(DeskGlassNavigationItem(id: id, selected: selected))
    }
}

private struct DeskGlassNavigationItem: ViewModifier {
    let id: String
    let selected: Bool
    @Environment(\.deskGlassNavigationGeometry) private var geometry

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            if let geometry { return proxy.frame(in: .named(geometry.space)) }
            return .zero
        } action: { frame in
            geometry?.update(frame, for: id)
        }
    }
}

@MainActor private final class DeskGlassNavigationGeometry: ObservableObject {
    let space = UUID()
    @Published private(set) var frames: [String: CGRect] = [:]
    @Published private(set) var ready = false
    var selection: String?

    func update(_ frame: CGRect, for id: String) {
        guard !frame.isEmpty, frames[id] != frame else { return }
        frames[id] = frame
        if !ready {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.ready = true
            }
        }
    }
}

private struct DeskGlassNavigationGeometryKey: EnvironmentKey {
    static let defaultValue: DeskGlassNavigationGeometry? = nil
}

private extension EnvironmentValues {
    var deskGlassNavigationGeometry: DeskGlassNavigationGeometry? {
        get { self[DeskGlassNavigationGeometryKey.self] }
        set { self[DeskGlassNavigationGeometryKey.self] = newValue }
    }
}

@MainActor private final class DeskGlassPickerGeometry<Value: Hashable>: ObservableObject {
    @Published private(set) var frames: [Value: CGRect] = [:]
    @Published private(set) var ready = false
    var selection: Value?

    func update(_ frame: CGRect, for value: Value, initialCount: Int) {
        guard !frame.isEmpty, frames[value] != frame else { return }
        frames[value] = frame
        if !ready, frames.count >= initialCount {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.ready = true
            }
        }
    }
}

/// Keep one native glass surface alive and interpolate its actual geometry.
/// Explicit presentation coordinates avoid relying on insertion transitions
/// between different buttons. Only the selection background hosts glass: putting
/// the entire group inside a row-sized glass silhouette can hide its other labels.
/// Keep the foreground outside GlassEffectContainer as well: a container hoists
/// background glass above sibling labels, making the selected text refract/blur.
private struct DeskGlassMovingSelection: AnimatableModifier {
    var frame: CGRect
    let stretch: CGFloat
    let vertical: Bool
    let solid: Color
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(frame.origin.x, frame.origin.y), AnimatablePair(frame.width, frame.height)) }
        set {
            frame = CGRect(x: newValue.first.first, y: newValue.first.second,
                           width: newValue.second.first, height: newValue.second.second)
        }
    }

    func body(content: Content) -> some View {
        let bounds = presentationFrame
        return content.background(alignment: .topLeading) {
            Group {
                if #available(macOS 26.0, *) {
                    Color.clear
                        .frame(width: max(0, bounds.width), height: max(0, bounds.height))
                        .background {
                            if reduceTransparency { Capsule().fill(solid) }
                        }
                        .glassEffect(reduceTransparency ? .identity : .regular, in: Capsule())
                } else {
                    Capsule()
                        .fill(reduceTransparency ? AnyShapeStyle(solid) : AnyShapeStyle(.regularMaterial))
                        .frame(width: max(0, bounds.width), height: max(0, bounds.height))
                }
            }
            .offset(x: bounds.minX, y: bounds.minY)
            .opacity(visible && !frame.isEmpty ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var presentationFrame: CGRect {
        guard !reduceMotion else { return frame }
        let expansion = 10 * stretch
        let width = vertical ? frame.width * (1 - 0.035 * stretch) : frame.width + expansion
        let height = vertical ? frame.height + expansion : frame.height * (1 - 0.035 * stretch)
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }
}

private struct DeskChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Feedback(configuration: configuration) }

    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        @StateObject private var pointer = Pointer()
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.12), value: configuration.isPressed)
                .overlay {
                    Capsule().fill(.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.10 : pointer.hovering ? 0.05 : 0))
                        .allowsHitTesting(false)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pointer.hovering)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
                }
                .onHover { if pointer.hovering != $0 { pointer.hovering = $0 } }
        }
    }
    @MainActor private final class Pointer: ObservableObject { @Published var hovering = false }
}

private struct DeskGlassButtonStyle: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

private struct DeskGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let solid: Color
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Attach glass to its foreground, so the compositor excludes labels
            // from refraction. Change the material value rather than branching
            // around content when Reduce Transparency changes during editing.
            content
                .background {
                    if reduceTransparency {
                        shape.fill(solid).overlay { shape.strokeBorderFallback }
                    }
                }
                .glassEffect(reduceTransparency ? .identity : .regular.interactive(interactive && !reduceMotion), in: shape)
        } else {
            content.background {
                shape.fill(reduceTransparency ? AnyShapeStyle(solid) : AnyShapeStyle(.regularMaterial))
                    .overlay { shape.strokeBorderFallback }
            }
        }
    }
}

private extension Shape {
    var strokeBorderFallback: some View { stroke(.primary.opacity(0.09), lineWidth: 1) }
}
