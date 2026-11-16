import AppKit
import FlutterMacOS

/// A presentation channel only. Files stay in the native one-shot store;
/// capture/upload still use the authorization-checked native service channel.
@MainActor
final class NativeComposerDropBridge {
    static let channelName = "cc.seekdesk/composer.drop.v1"
    private var channel: FlutterMethodChannel?
    private let send: ([String: Any]) -> Void
    private let store: NativeComposerDropStore
    private let authorization: () -> ForumSession.Authorization?
    private let available: () -> Bool
    private let overlay: NativeComposerDropView
    private var hovering: NativeComposerDropStore.Target?
    private var lastPoint = CGPoint.zero
    private var disposed = false

    convenience init(controller: FlutterViewController, store: NativeComposerDropStore,
         authorization: @escaping () -> ForumSession.Authorization?, available: @escaping () -> Bool) {
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: controller.engine.binaryMessenger)
        // The controller's root is an unflipped wrapper in the pinned engine.
        // Match macOS desktop_drop: register inside the actual Flutter render
        // view supplied by the public registrar, not as its sibling. The root
        // is only a fallback for a detached/headless controller without a view.
        let hostView = controller.registrar(forPlugin: "SeekDeskComposerDrop").view ?? controller.view
        self.init(hostView: hostView, store: store, authorization: authorization, available: available,
                  send: { channel.invokeMethod("drag", arguments: $0) })
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self, !self.disposed else { result(nil); return }
                guard call.method == "updateTarget" else { result(FlutterMethodNotImplemented); return }
                guard let args = call.arguments as? [String: Any], let authorization = self.authorization() else {
                    result(["accepted": false]); return
                }
                let previous = self.store.target
                let accepted = self.store.update(args, authorization: authorization)
                if accepted && previous != self.store.target { self.leave() }
                result(["accepted": accepted, "targetRevision": self.store.targetRevision])
            }
        }
    }

    /// Separating AppKit delivery from channel transport allows real destination
    /// callbacks to be exercised with a private drag pasteboard and no engine.
    init(hostView: NSView, store: NativeComposerDropStore,
         authorization: @escaping () -> ForumSession.Authorization?, available: @escaping () -> Bool,
         send: @escaping ([String: Any]) -> Void) {
        self.store = store
        self.authorization = authorization
        self.available = available
        self.send = send
        overlay = NativeComposerDropView(frame: hostView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.bridge = self
        hostView.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    func dispose() {
        guard !disposed else { return }
        leave()
        disposed = true
        channel?.setMethodCallHandler(nil)
        channel = nil
        overlay.bridge = nil
        overlay.unregisterDraggedTypes()
        overlay.removeFromSuperview()
        store.invalidate()
    }

    private func target(_ sender: NSDraggingInfo) -> (NativeComposerDropStore.Target, CGPoint)? {
        guard !disposed, available(), overlay.window?.attachedSheet == nil,
              let authorization = authorization(), sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.pasteboardItems?.count == 1,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return nil }
        let point = overlay.convert(sender.draggingLocation, from: nil)
        guard overlay.bounds.contains(point), let target = store.target(at: point, authorization: authorization) else { return nil }
        return (target, point)
    }

    fileprivate func hover(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (target, point) = target(sender) else { leave(); return [] }
        lastPoint = point
        if hovering != target {
            leave()
            hovering = target
            send(target.event("enter", point: point))
        } else {
            send(target.event("update", point: point))
        }
        return .copy
    }

    fileprivate func canAccept(_ sender: NSDraggingInfo) -> Bool { target(sender) != nil }

    fileprivate func perform(_ sender: NSDraggingInfo) -> Bool {
        guard let (target, point) = target(sender), let authorization = authorization(),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1 else { leave(); return false }
        do {
            let token = try store.offer(urls[0], target: target, authorization: authorization)
            hovering = nil
            lastPoint = point
            send(target.event("drop", point: point, token: token))
            return true
        } catch { leave(); return false }
    }

    fileprivate func leave() {
        guard let previous = hovering else { return }
        hovering = nil
        send(previous.event("exit", point: lastPoint))
    }
}

/// Uses the same registered, pointer-transparent overlay pattern as macOS
/// desktop_drop's NativeDropTarget (MixinNetwork/flutter-plugins). Normal hit
/// testing stays with Flutter so clicks, scrolling and selection pass through;
/// AppKit drag destination callbacks are handled by this registered view.
@MainActor
final class NativeComposerDropView: NSView {
    fileprivate weak var bridge: NativeComposerDropBridge?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { bridge?.hover(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { bridge?.hover(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { bridge?.leave() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { bridge?.canAccept(sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { bridge?.perform(sender) ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) { bridge?.leave() }
}
