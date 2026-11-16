import AppKit
import SwiftUI

/// Observes the native viewport without publishing scroll ticks or issuing scroll commands.
@MainActor
final class ReaderScrollTracker: NSObject, ObservableObject {
    private var currentAnchor: String?
    /// A lifecycle read must include any layout change still waiting for a coalesced sample.
    var observedAnchor: String? {
        if geometryDirty { flush() }
        return currentAnchor
    }
    var onAnchorChanged: ((String?) -> Void)? {
        willSet { if newValue == nil { flush() } }
    }

    private struct Registration {
        weak var view: ReaderScrollAnchor.AnchorView?
        weak var scroll: NSScrollView?
        let id: String
    }
    private struct Geometry {
        let id: String
        let top: CGFloat
        let bottom: CGFloat
        var maximumBottom: CGFloat
    }
    private struct WeakView { weak var view: NSView? }
    private var anchors: [ObjectIdentifier: Registration] = [:]
    private var geometry: [Geometry] = []
    private var layoutViews: [ObjectIdentifier: WeakView] = [:]
    private weak var scrollView: NSScrollView?
    private weak var clipView: NSClipView?
    private weak var documentView: NSView?
    private weak var trackedWindow: NSWindow?
    private var geometryDirty = true
    private var sampleTimer: Timer?
    private var sampling = false
    #if READER_SCROLL_BENCHMARK
    private(set) var benchmarkSamples = 0
    private(set) var benchmarkGeometryBuilds = 0
    private(set) var benchmarkAnchorVisits = 0
    func resetBenchmarkCounters() { benchmarkSamples = 0; benchmarkGeometryBuilds = 0; benchmarkAnchorVisits = 0 }
    #endif

    override init() {
        super.init()
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleFlush(_:)), name: name, object: nil)
        }
    }

    fileprivate func register(_ view: ReaderScrollAnchor.AnchorView, id: String) {
        let key = ObjectIdentifier(view)
        guard let scroll = view.enclosingScrollView, let window = view.window,
              let document = scroll.documentView, view.isDescendant(of: document) else {
            anchors[key] = Registration(view: view, scroll: nil, id: id)
            invalidateGeometry()
            removeUnusedRoute()
            return
        }
        if let previous = anchors[key], previous.id == id, previous.scroll === scroll,
           scrollView === scroll, documentView === document, trackedWindow === window { return }
        let knownRoute = anchors.values.contains { $0.scroll === scroll && $0.view != nil }
        anchors[key] = Registration(view: view, scroll: scroll, id: id)
        // Updating a still-mounted outgoing view must not steal observation from its replacement.
        if knownRoute, let current = scrollView, current !== scroll { return }
        if scrollView !== scroll || documentView !== document || trackedWindow !== window {
            flush()
            detachRoute()
            scrollView = scroll
            clipView = scroll.contentView
            documentView = document
            trackedWindow = window
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleFlush(_:)),
                name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleFlush(_:)),
                name: NSWindow.willCloseNotification, object: window)
            report(nil)
        }
        invalidateGeometry()
    }

    fileprivate func unregister(_ view: ReaderScrollAnchor.AnchorView) {
        anchors.removeValue(forKey: ObjectIdentifier(view))
        invalidateGeometry()
        removeUnusedRoute()
    }

    fileprivate func anchorFrameChanged(_ view: ReaderScrollAnchor.AnchorView) {
        guard anchors[ObjectIdentifier(view)] != nil else { return }
        invalidateGeometry()
    }

    @objc private func viewportChanged(_ notification: Notification) {
        // Pure scrolling does one coordinate conversion and a cached binary lookup. No anchor walk,
        // ancestor checks, frame measurements, temporary candidate arrays or layout calls occur here.
        if geometryDirty { scheduleSample() }
        else { sample() }
    }

    @objc private func layoutChanged(_ notification: Notification) { invalidateGeometry() }
    @objc private func lifecycleFlush(_ notification: Notification) { flush() }

    private func invalidateGeometry() {
        geometryDirty = true
        scheduleSample()
    }

    private func scheduleSample() {
        guard sampleTimer == nil, scrollView != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        sampleTimer = timer
        // Common modes also service the final pending layout during native scroll tracking.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Resample after an explicit restoration or reattachment, without changing native scroll bounds.
    func refresh() { flush() }

    private func flush() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        guard !sampling else { return }
        sample()
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        defer { sampling = false }
        #if READER_SCROLL_BENCHMARK
        benchmarkSamples += 1
        #endif
        guard let scroll = scrollView, let clip = clipView, let document = documentView,
              let window = trackedWindow, scroll.window === window,
              scroll.contentView === clip, scroll.documentView === document else {
            detachRoute()
            report(nil)
            return
        }
        if geometryDirty { rebuildGeometry(scroll: scroll, document: document, window: window) }
        let viewport = document.convert(clip.bounds, from: clip)
        guard viewport.width > 0, viewport.height > 0 else { return }
        let top = document.isFlipped ? viewport.minY : document.bounds.maxY - viewport.maxY
        let threshold = top + 0.5
        var low = 0, high = geometry.count
        while low < high {
            let middle = (low + high) / 2
            if geometry[middle].top <= threshold { low = middle + 1 }
            else { high = middle }
        }
        if low > 0 {
            let preceding = low - 1
            var index = preceding
            // Prefix maxima handle overlapping transitions without scanning ordinary disjoint floors.
            while index >= 0 && geometry[index].maximumBottom > threshold {
                if geometry[index].bottom > threshold { report(geometry[index].id); return }
                index -= 1
            }
            report(geometry[preceding].id)
        } else {
            report(geometry.first?.id)
        }
    }

    private func rebuildGeometry(scroll: NSScrollView, document: NSView, window: NSWindow) {
        geometryDirty = false
        #if READER_SCROLL_BENCHMARK
        benchmarkGeometryBuilds += 1
        #endif
        anchors = anchors.filter { $0.value.view != nil }
        geometry.removeAll(keepingCapacity: true)
        var measuredViews: [ObjectIdentifier: WeakView] = [ObjectIdentifier(document): WeakView(view: document)]
        for registration in anchors.values {
            #if READER_SCROLL_BENCHMARK
            benchmarkAnchorVisits += 1
            #endif
            guard let view = registration.view, registration.scroll === scroll, view.window === window,
                  view.enclosingScrollView === scroll, view.isDescendant(of: document) else { continue }
            // Observe hosting ancestors as well: a floor can move while its background's local frame
            // stays unchanged. These notifications only invalidate once; they never perform layout.
            var ancestor: NSView? = view
            while let candidate = ancestor, candidate !== document {
                measuredViews[ObjectIdentifier(candidate)] = WeakView(view: candidate)
                ancestor = candidate.superview
            }
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            let frame = view.convert(view.bounds, to: document)
            guard frame.width > 0, frame.height > 0, frame.minY.isFinite, frame.maxY.isFinite else { continue }
            let start = document.isFlipped ? frame.minY : document.bounds.maxY - frame.maxY
            geometry.append(Geometry(id: registration.id, top: start, bottom: start + frame.height, maximumBottom: start + frame.height))
        }
        geometry.sort { $0.top == $1.top ? $0.id < $1.id : $0.top < $1.top }
        var maximum = -CGFloat.infinity
        for index in geometry.indices {
            maximum = max(maximum, geometry[index].bottom)
            geometry[index].maximumBottom = maximum
        }
        for (key, previous) in layoutViews where measuredViews[key]?.view !== previous.view {
            guard let view = previous.view else { continue }
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: view)
        }
        for (key, next) in measuredViews where layoutViews[key]?.view !== next.view {
            guard let view = next.view else { continue }
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged(_:)),
                name: NSView.frameDidChangeNotification, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: view)
        }
        layoutViews = measuredViews
    }

    private func report(_ id: String?) {
        guard currentAnchor != id else { return }
        currentAnchor = id
        onAnchorChanged?(id)
    }

    private func removeUnusedRoute() {
        guard let scroll = scrollView, let window = trackedWindow else { return }
        let stillMounted = anchors.values.contains { registration in
            guard let view = registration.view else { return false }
            return registration.scroll === scroll && view.window === window
        }
        if !stillMounted { detachRoute(); report(nil) }
    }

    private func detachRoute() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
        geometry.removeAll(keepingCapacity: true)
        layoutViews.removeAll(keepingCapacity: true)
        geometryDirty = true
        scrollView = nil
        clipView = nil
        documentView = nil
        trackedWindow = nil
    }

    /// Removes observers and pending registrations when the owning reader is discarded.
    func invalidate() {
        flush()
        onAnchorChanged = nil
        anchors.removeAll()
        detachRoute()
        currentAnchor = nil
    }

    deinit {
        sampleTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

/// Mount as the background of a complete header or floor, after its final frame/padding.
struct ReaderScrollAnchor: NSViewRepresentable {
    let id: String
    let tracker: ReaderScrollTracker

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.configure(id: id, tracker: tracker) }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.detach() }

    final class AnchorView: NSView {
        private weak var tracker: ReaderScrollTracker?
        private var anchorID = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(id: String, tracker: ReaderScrollTracker) {
            if self.tracker !== tracker || anchorID != id { self.tracker?.unregister(self) }
            self.tracker = tracker
            anchorID = id
            tracker.register(self, id: id)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            registerIfMounted()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerIfMounted()
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { tracker?.anchorFrameChanged(self) }
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            let changed = frame.origin != newOrigin
            super.setFrameOrigin(newOrigin)
            if changed { tracker?.anchorFrameChanged(self) }
        }

        private func registerIfMounted() {
            if window != nil, superview != nil { tracker?.register(self, id: anchorID) }
            else { tracker?.unregister(self) }
        }

        func detach() {
            tracker?.unregister(self)
            tracker = nil
        }
    }
}
