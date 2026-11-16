import AppKit
import SwiftUI

/// Mount in the sidebar background. The saved preference remains the only source of restored width.
struct NativeSidebarWidth: NSViewRepresentable {
    let preferredWidth: CGFloat
    let range: ClosedRange<CGFloat>
    let active: Bool
    let onUserResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.configure(preferredWidth: preferredWidth, range: range, active: active, onUserResize: onUserResize)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.invalidate() }

    final class ObserverView: NSView {
        private weak var split: NSSplitView?
        private weak var observedWindow: NSWindow?
        private var monitor: Any?
        private var preferredWidth: CGFloat = 0
        private var allowedRange: ClosedRange<CGFloat> = 1...1
        private var active = false
        private var onUserResize: ((CGFloat) -> Void)?
        private var needsRestore = true
        private var reconcileQueued = false
        private var applyingWidth = false
        private var invalidated = false
        private var drag: DividerDrag?

        private struct DividerDrag {
            let id = UUID()
            let originalWidth: CGFloat
            let splitSize: NSSize
            var changed = false
            var finishQueued = false
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(preferredWidth: CGFloat, range: ClosedRange<CGFloat>, active: Bool,
                       onUserResize: @escaping (CGFloat) -> Void) {
            guard !invalidated else { return }
            let valid = preferredWidth.isFinite && range.lowerBound.isFinite && range.upperBound.isFinite && range.lowerBound > 0
            let enabled = active && valid
            if self.preferredWidth != preferredWidth || allowedRange != range || self.active != enabled {
                needsRestore = true
            }
            self.preferredWidth = preferredWidth
            allowedRange = range
            self.active = enabled
            self.onUserResize = onUserResize
            if !enabled { drag = nil }
            queueReconcile()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            queueReconcile()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsRestore = true
            queueReconcile()
        }

        override func layout() {
            super.layout()
            if split == nil && window != nil { queueReconcile() }
        }

        private func queueReconcile() {
            guard !invalidated, !reconcileQueued else { return }
            reconcileQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalidated else { return }
                self.reconcileQueued = false
                self.reconcile()
            }
        }

        private func owningSplit() -> NSSplitView? {
            guard window != nil else { return nil }
            var ancestor = superview
            while let view = ancestor {
                if let candidate = view as? NSSplitView, candidate.isVertical,
                   candidate.arrangedSubviews.count >= 2,
                   let first = candidate.arrangedSubviews.first, isDescendant(of: first) {
                    return candidate
                }
                ancestor = view.superview
            }
            return nil
        }

        private func reconcile() {
            let candidate = owningSplit()
            if split !== candidate || observedWindow !== window {
                detach()
                split = candidate
                observedWindow = candidate?.window
                needsRestore = true
                if let candidate {
                    NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)),
                        name: NSSplitView.didResizeSubviewsNotification, object: candidate)
                    if let observedWindow {
                        NotificationCenter.default.addObserver(self, selector: #selector(windowFinishedResizing(_:)),
                            name: NSWindow.didEndLiveResizeNotification, object: observedWindow)
                    }
                    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                        self?.observe(event)
                        return event
                    }
                }
            }
            guard needsRestore, active, drag == nil, let split, let first = split.arrangedSubviews.first,
                  let window = split.window, !window.inLiveResize else { return }
            needsRestore = false
            applyingWidth = true
            defer { applyingWidth = false }
            split.layoutSubtreeIfNeeded()
            let width = min(allowedRange.upperBound, max(allowedRange.lowerBound, preferredWidth))
            if split.isSubviewCollapsed(first) || abs(first.frame.width - width) > 0.5 {
                split.setPosition(first.frame.minX + width, ofDividerAt: 0)
            }
        }

        @objc private func windowFinishedResizing(_ notification: Notification) { queueReconcile() }

        private func observe(_ event: NSEvent) {
            guard !invalidated, active, !applyingWidth, let split, event.window === split.window else { return }
            switch event.type {
            case .leftMouseDown:
                drag = nil
                guard split.window?.inLiveResize != true, split.arrangedSubviews.count >= 2,
                      !split.isSubviewCollapsed(split.arrangedSubviews[0]) else { return }
                let first = split.arrangedSubviews[0], next = split.arrangedSubviews[1]
                let divider = NSRect(x: first.frame.maxX, y: split.bounds.minY,
                    width: max(split.dividerThickness, next.frame.minX - first.frame.maxX), height: split.bounds.height)
                let point = split.convert(event.locationInWindow, from: nil)
                guard divider.insetBy(dx: -6, dy: 0).contains(point) else { return }
                drag = DividerDrag(originalWidth: first.frame.width, splitSize: split.bounds.size)
                // A pending initial/layout restoration must not fight the user's drag.
                needsRestore = false
            case .leftMouseUp:
                queueDragFinish()
            default: break
            }
        }

        @objc private func splitResized(_ notification: Notification) {
            guard !applyingWidth, active, let split, var current = drag else { return }
            guard split.window?.inLiveResize != true, split.bounds.size == current.splitSize else {
                drag = nil
                return
            }
            current.changed = true
            drag = current
            // Native divider tracking may consume mouse-up before a local monitor sees it.
            // Default-mode work runs after the AppKit event-tracking loop has completed.
            queueDragFinish()
        }

        private func queueDragFinish() {
            guard var current = drag, !current.finishQueued else { return }
            current.finishQueued = true
            drag = current
            let id = current.id
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                self?.finishDragIfReleased(id: id)
            }
        }

        private func finishDragIfReleased(id: UUID) {
            guard !invalidated, var current = drag, current.id == id else { return }
            current.finishQueued = false
            drag = current
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            drag = nil
            guard current.changed, active, !applyingWidth, let split,
                  split.window?.inLiveResize != true, split.bounds.size == current.splitSize,
                  let first = split.arrangedSubviews.first, !split.isSubviewCollapsed(first),
                  first.frame.width.isFinite, allowedRange.contains(first.frame.width),
                  abs(first.frame.width - current.originalWidth) >= 0.5 else { return }
            onUserResize?(first.frame.width)
        }

        private func detach() {
            NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: nil)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            split = nil
            observedWindow = nil
            drag = nil
        }

        func invalidate() {
            invalidated = true
            onUserResize = nil
            detach()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
