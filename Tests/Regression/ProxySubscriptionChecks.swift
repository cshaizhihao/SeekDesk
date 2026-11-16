import Foundation

// Controller connectivity is deliberately never invoked in these offline persistence tests.
enum Forum {
    static func contains(_ url: URL) -> Bool { url.host == "www.nodeseek.com" }
}

@main struct ProxySubscriptionChecks {
    @MainActor static func main() async throws {
        try batchAndSelection()
        try matching()
        try persistenceFailures()
        try await refreshes()
        try await staleRefreshes()
        try await latencyResults()
        try await latencyConcurrency()
        try await latencyNodeChanges()
        try await latencySubscriptionChanges()
        try await latencyExtensionDisable()
        print("Passed offline subscription controller checks without user Keychain access, network requests, or proxy startup.")
    }

    @MainActor static func batchAndSelection() throws {
        let harness = Harness()
        defer { harness.clean() }
        let first = try node("first", "First")
        let second = try node("second", "Second")
        let result = try DeskProxySubscriptionParser.parse(Data((first.link + "\n" + first.link + "\n" + second.link).utf8))
        precondition(result.nodes.count == 2 && result.duplicates == 1)
        try harness.controller.importNodes(result, subscription: nil)
        precondition(harness.controller.nodes.count == 2)
        let firstID = harness.controller.nodes[0].id
        let secondID = harness.controller.nodes[1].id
        precondition(harness.controller.selectedID == firstID)
        var duplicate = first
        duplicate.name = "Another label"
        duplicate.id = UUID()
        do { try harness.controller.importNodes(.init(nodes: [duplicate]), subscription: nil); preconditionFailure("Duplicate import accepted") }
        catch is DeskProxyError {}
        precondition(harness.controller.nodes.count == 2 && harness.store.writes == 1)
        harness.controller.select(secondID)
        precondition(harness.defaults.string(forKey: "proxy.selected") == secondID.uuidString)
        let restored = harness.newController()
        restored.loadNodes()
        precondition(restored.selectedID == secondID && restored.nodes == harness.controller.nodes)
        harness.controller.remove(secondID)
        precondition(harness.controller.selectedID == firstID)
        harness.controller.remove(firstID)
        precondition(harness.controller.nodes.isEmpty && harness.controller.selectedID == nil)
        let badID = UUID()
        harness.defaults.set(badID.uuidString, forKey: "proxy.selected")
        harness.store.state.nodes = [first]
        let repaired = harness.newController()
        repaired.loadNodes()
        precondition(repaired.selectedID == first.id && harness.defaults.string(forKey: "proxy.selected") == first.id.uuidString)
        print("Passed batch identity deduplication, selected-node persistence, restart restore and deleted-selection repair.")
    }

    @MainActor static func matching() throws {
        let source = subscription("source")
        let a = try node("a", "Same name")
        let b = try node("b", "Same name")
        var renamedA = a
        renamedA.id = UUID(); renamedA.name = "Renamed"
        let merged = DeskProxyController.mergedSubscriptionNodes(old: [a], imported: [b, renamedA], sourceID: source.id)
        precondition(merged[0].id != a.id && merged[1].id == a.id, "Name fallback stole an unchanged endpoint ID")
        precondition(merged.allSatisfy { $0.subscriptionID == source.id })
        let changed = try node("replacement", "Same name")
        let unique = DeskProxyController.mergedSubscriptionNodes(old: [a], imported: [changed], sourceID: source.id)
        precondition(unique[0].id == a.id)
        let ambiguous = DeskProxyController.mergedSubscriptionNodes(old: [a, b], imported: [changed], sourceID: source.id)
        precondition(ambiguous[0].id != a.id && ambiguous[0].id != b.id)
        print("Passed subscription stable identities, rename/reorder and exact-endpoint matching before name fallback.")
    }

    @MainActor static func persistenceFailures() throws {
        let harness = Harness()
        defer { harness.clean() }
        let original = try node("original", "Original")
        try harness.controller.importNodes(.init(nodes: [original]), subscription: nil)
        let source = subscription("failing")
        let next = try node("next", "Next")
        let before = harness.store.state
        harness.store.failWrite = true
        do { try harness.controller.importNodes(.init(nodes: [next]), subscription: source); preconditionFailure("Vault failure was ignored") }
        catch is DeskProxyError {}
        precondition(harness.controller.nodes == before.nodes && harness.controller.subscriptions == before.subscriptions)
        precondition(harness.controller.selectedID == original.id)
        do { try harness.controller.save(link: next.link, name: "New", replacing: original.id); preconditionFailure("Edit ignored vault failure") }
        catch is DeskProxyError {}
        harness.controller.remove(original.id)
        precondition(harness.controller.nodes == before.nodes && harness.controller.selectedID == original.id)
        precondition(harness.controller.issue != nil)
        let failedRead = Harness()
        defer { failedRead.clean() }
        failedRead.store.failRead = true
        do { try failedRead.controller.importNodes(.init(nodes: [next]), subscription: nil); preconditionFailure("Import overwrote an unreadable vault") }
        catch is DeskProxyError {}
        failedRead.controller.removeSubscription(source.id)
        precondition(failedRead.store.writes == 0 && failedRead.controller.nodes.isEmpty)
        print("Passed failed-vault atomicity, failed-edit/removal preservation and unreadable-vault protection.")
    }

    @MainActor static func refreshes() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let source = subscription("refresh")
        let other = subscription("other")
        let a = try node("a", "A"), b = try node("b", "B"), c = try node("c", "C")
        try harness.controller.importNodes(.init(nodes: [a, b]), subscription: source)
        try harness.controller.importNodes(.init(nodes: [c]), subscription: other)
        harness.controller.select(b.id)
        var renamedB = b
        renamedB.id = UUID(); renamedB.name = "B renamed"
        let changedA = try node("new-a", "A")
        harness.fetcher.result = .success(.init(nodes: [renamedB, changedA]))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.controller.nodes.map(\.id) == [b.id, a.id, c.id])
        precondition(harness.controller.selectedID == b.id)
        precondition(harness.controller.nodes[0].name == "B renamed")
        precondition(harness.controller.subscriptions[0].updatedAt != nil)
        precondition(harness.controller.subscriptions[1] == other)
        let state = harness.store.state
        harness.fetcher.result = .failure(DeskProxyError.invalid("Fixture failure"))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.store.state.nodes == state.nodes && harness.controller.nodes == state.nodes)
        precondition(harness.controller.subscriptions == state.subscriptions)
        precondition(harness.controller.importMessage?.contains("保留原有节点") == true)
        harness.store.failWrite = true
        harness.fetcher.result = .success(.init(nodes: [c]))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.controller.nodes == state.nodes && harness.controller.subscriptions == state.subscriptions)
        harness.store.failWrite = false
        harness.fetcher.result = .success(.init(nodes: [changedA]))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.controller.selectedID == a.id && harness.controller.nodes.map(\.id) == [a.id, c.id])
        harness.controller.removeSubscription(source.id)
        precondition(harness.controller.nodes.map(\.id) == [c.id] && harness.controller.selectedID == c.id)
        precondition(harness.controller.subscriptions == [other])
        print("Passed refresh identity/order preservation, selection fallback, stale-node removal, failure retention and subscription isolation.")
    }

    @MainActor static func staleRefreshes() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let source = subscription("pending")
        let original = try node("old", "Old"), replacement = try node("replacement", "Replacement")
        try harness.controller.importNodes(.init(nodes: [original]), subscription: source)
        harness.fetcher.suspended = true
        let first = Task { await harness.controller.refreshSubscription(source.id) }
        await harness.fetcher.waitUntilStarted()
        precondition(harness.controller.updatingSubscriptions.contains(source.id))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.fetcher.calls == 1, "Duplicate refresh ran concurrently")
        try harness.controller.save(link: original.link, name: "Local edit", replacing: original.id)
        harness.fetcher.finish(.success(.init(nodes: [replacement])))
        await first.value
        precondition(harness.controller.nodes.first?.name == "Local edit" && harness.controller.nodes.first?.id == original.id)
        precondition(harness.controller.importMessage?.contains("保留你的修改") == true)
        precondition(harness.controller.updatingSubscriptions.isEmpty)
        let cancelled = Task { await harness.controller.refreshSubscription(source.id) }
        await harness.fetcher.waitUntilStarted()
        cancelled.cancel()
        harness.fetcher.finish(.success(.init(nodes: [replacement])))
        await cancelled.value
        precondition(harness.controller.nodes.first?.id == original.id)
        let deleted = Task { await harness.controller.refreshSubscription(source.id) }
        await harness.fetcher.waitUntilStarted()
        harness.controller.removeSubscription(source.id)
        harness.fetcher.finish(.success(.init(nodes: [replacement])))
        await deleted.value
        precondition(harness.controller.nodes.isEmpty && harness.controller.subscriptions.isEmpty && harness.controller.selectedID == nil)
        precondition(harness.controller.updatingSubscriptions.isEmpty)
        print("Passed duplicate-refresh suppression, local-edit conflict preservation, cancellation and delete-during-fetch without resurrection.")
    }

    @MainActor static func latencyResults() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let original = try node("latency", "Latency")
        try harness.controller.importNodes(.init(nodes: [original]), subscription: nil)
        let selection = harness.controller.selectedID
        let writes = harness.store.writes
        let unknown = UUID()
        harness.controller.measureLatency(unknown)
        precondition(harness.controller.nodeLatencies[unknown] == nil)
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(1)
        precondition(harness.controller.nodeLatencies[original.id] == .measuring)
        harness.controller.measureLatency(original.id)
        await drainTasks()
        precondition(harness.probe.calls.count == 1, "Repeated clicks started a second measurement for the same node")
        harness.probe.finish(0, .success(83))
        await waitUntil("Successful probe did not publish its latency") { harness.controller.nodeLatencies[original.id] == .success(83) }
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(2)
        precondition(harness.controller.nodeLatencies[original.id] == .measuring)
        harness.probe.finish(1, .failure(DeskProxyError.invalid("Fixture probe failure")))
        await waitUntil("Failed probe did not publish a failed state") { harness.controller.nodeLatencies[original.id] == .failed }
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(3)
        harness.probe.finish(2, .success(41))
        await waitUntil("A retry did not replace the failed result") { harness.controller.nodeLatencies[original.id] == .success(41) }
        precondition(harness.controller.selectedID == selection && !harness.controller.enabled)
        precondition(harness.store.writes == writes, "Latency measurement changed persisted node data")
        print("Passed node-latency success, failure, retry, duplicate-click suppression and selection/persistence isolation.")
    }

    @MainActor static func latencyConcurrency() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let nodes = try (0..<6).map { try node("limited-\($0)", "Limited \($0)") }
        try harness.controller.importNodes(.init(nodes: nodes), subscription: nil)
        for entry in nodes { harness.controller.measureLatency(entry.id) }
        await harness.probe.waitForCalls(4)
        await drainTasks()
        precondition(harness.probe.calls.count == 4 && harness.probe.peakActive == 4)
        precondition(nodes.prefix(4).allSatisfy { harness.controller.nodeLatencies[$0.id] == .measuring })
        precondition(nodes.suffix(2).allSatisfy { harness.controller.nodeLatencies[$0.id] == nil }, "A refused probe changed the node's status")
        harness.probe.finish(0, .success(10))
        await waitUntil("Finished measurement did not release its concurrency slot") { harness.controller.nodeLatencies[nodes[0].id] == .success(10) }
        harness.controller.measureLatency(nodes[4].id)
        await harness.probe.waitForCalls(5)
        harness.controller.measureLatency(nodes[5].id)
        await drainTasks()
        precondition(harness.probe.calls.count == 5 && harness.probe.peakActive == 4)
        precondition(harness.controller.nodeLatencies[nodes[5].id] == nil)
        for index in 1..<5 { harness.probe.finish(index, .success(20 + index)) }
        await waitUntil("Completed measurements retained a running state") { !harness.controller.nodeLatencies.values.contains(.measuring) }

        // A canceled operation deliberately ignores cancellation until its gate is released.
        // Its late result must neither overwrite nor remove a newer measurement with the same ID.
        harness.controller.measureLatency(nodes[0].id)
        await harness.probe.waitForCalls(6)
        harness.controller.cancelNodeMeasurements()
        await harness.probe.waitForCancellation(5)
        precondition(harness.controller.nodeLatencies[nodes[0].id] != .measuring)
        harness.controller.measureLatency(nodes[0].id)
        await harness.probe.waitForCalls(7)
        harness.probe.finish(5, .success(999))
        await waitUntil("Canceled fixture did not return") { harness.probe.returned.contains(5) }
        await drainTasks()
        precondition(harness.controller.nodeLatencies[nodes[0].id] == .measuring, "A canceled result overwrote a newer measurement")
        harness.probe.finish(6, .success(12))
        await waitUntil("New measurement was lost after stale completion") { harness.controller.nodeLatencies[nodes[0].id] == .success(12) }
        print("Passed four-probe concurrency limit, rejected-click stability, released slots and cancellation without late-result races.")
    }

    @MainActor static func latencyNodeChanges() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let original = try node("original-latency", "Original latency")
        let replacement = try node("replacement-latency", "Replacement latency")
        try harness.controller.importNodes(.init(nodes: [original]), subscription: nil)
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(1)
        try harness.controller.save(link: replacement.link, name: replacement.name, replacing: original.id)
        await harness.probe.waitForCancellation(0)
        precondition(harness.controller.nodeLatencies[original.id] == nil)
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(2)
        precondition(harness.probe.calls[1].node.identity == replacement.identity)
        harness.probe.finish(0, .success(1))
        await waitUntil("Old edited-node measurement did not return") { harness.probe.returned.contains(0) }
        await drainTasks()
        precondition(harness.controller.nodeLatencies[original.id] == .measuring)
        harness.probe.finish(1, .success(72))
        await waitUntil("Replacement endpoint's result was discarded") { harness.controller.nodeLatencies[original.id] == .success(72) }

        try harness.controller.save(link: replacement.link, name: "Renamed only", replacing: original.id)
        precondition(harness.controller.nodeLatencies[original.id] == .success(72), "A name-only edit discarded a valid measurement")
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(3)
        try harness.controller.save(link: replacement.link, name: "Renamed during probe", replacing: original.id)
        await drainTasks()
        precondition(!harness.probe.cancelled.contains(2) && harness.controller.nodeLatencies[original.id] == .measuring)
        harness.probe.finish(2, .success(69))
        await waitUntil("Name-only edit invalidated an unchanged endpoint's result") { harness.controller.nodeLatencies[original.id] == .success(69) }

        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(4)
        harness.controller.remove(original.id)
        await harness.probe.waitForCancellation(3)
        precondition(harness.controller.nodeLatencies[original.id] == nil)
        harness.probe.finish(3, .failure(DeskProxyError.invalid("Late deleted-node failure")))
        await waitUntil("Deleted-node fixture did not return") { harness.probe.returned.contains(3) }
        await drainTasks()
        precondition(harness.controller.nodes.isEmpty && harness.controller.nodeLatencies[original.id] == nil)
        print("Passed latency invalidation on endpoint edits/deletion, late-result rejection and preservation across name-only edits.")
    }

    @MainActor static func latencySubscriptionChanges() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let source = subscription("measured-source")
        let original = try node("measured-old", "Stable name")
        let replacement = try node("measured-new", "Stable name")
        try harness.controller.importNodes(.init(nodes: [original]), subscription: source)
        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(1)
        harness.fetcher.result = .success(.init(nodes: [replacement]))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.controller.nodes[0].id == original.id && harness.controller.nodes[0].identity == replacement.identity)
        await harness.probe.waitForCancellation(0)
        precondition(harness.controller.nodeLatencies[original.id] == nil)
        harness.probe.finish(0, .success(2))
        await waitUntil("Old subscription endpoint probe did not return") { harness.probe.returned.contains(0) }
        await drainTasks()
        precondition(harness.controller.nodeLatencies[original.id] == nil)

        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(2)
        harness.probe.finish(1, .success(56))
        await waitUntil("Refreshed endpoint's probe did not complete") { harness.controller.nodeLatencies[original.id] == .success(56) }
        var renamed = replacement
        renamed.id = UUID(); renamed.name = "Subscription rename"
        harness.fetcher.result = .success(.init(nodes: [renamed]))
        await harness.controller.refreshSubscription(source.id)
        precondition(harness.controller.nodes[0].id == original.id && harness.controller.nodeLatencies[original.id] == .success(56))

        harness.controller.measureLatency(original.id)
        await harness.probe.waitForCalls(3)
        harness.controller.removeSubscription(source.id)
        await harness.probe.waitForCancellation(2)
        harness.probe.finish(2, .success(3))
        await waitUntil("Removed subscription's fixture did not return") { harness.probe.returned.contains(2) }
        await drainTasks()
        precondition(harness.controller.nodes.isEmpty && harness.controller.nodeLatencies.isEmpty)
        print("Passed latency cancellation for refreshed/removed subscription nodes and preservation of unchanged endpoints.")
    }

    @MainActor static func latencyExtensionDisable() async throws {
        let harness = Harness()
        defer { harness.clean() }
        let completed = try node("completed-before-disable", "Completed")
        let pending = try node("pending-at-disable", "Pending")
        try harness.controller.importNodes(.init(nodes: [completed, pending]), subscription: nil)
        harness.controller.measureLatency(completed.id)
        await harness.probe.waitForCalls(1)
        harness.probe.finish(0, .success(37))
        await waitUntil("Completed fixture did not publish before extension disable") { harness.controller.nodeLatencies[completed.id] == .success(37) }
        harness.controller.measureLatency(pending.id)
        await harness.probe.waitForCalls(2)
        // The main app proxy is already off: disabling the extension must still stop probes.
        precondition(!harness.controller.enabled)
        harness.controller.setAvailable(false)
        await harness.probe.waitForCancellation(1)
        precondition(harness.controller.nodeLatencies[pending.id] == nil)
        precondition(harness.controller.nodeLatencies[completed.id] == .success(37))
        precondition(harness.controller.canMeasureMoreNodes && !harness.controller.enabled)
        harness.probe.finish(1, .success(999))
        await waitUntil("Disabled extension's fixture did not return") { harness.probe.returned.contains(1) }
        await drainTasks()
        precondition(harness.controller.nodeLatencies[pending.id] == nil, "Disabling the extension allowed a late measurement to reappear")
        print("Passed extension-disable cancellation while the main proxy was already off, preserving completed results and rejecting late results.")
    }

    @MainActor static func waitUntil(_ message: String, condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), message)
    }

    @MainActor static func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    static func node(_ host: String, _ name: String) throws -> DeskProxyNode {
        let label = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        return try DeskProxyNode.parse("trojan://fixture-password@\(host).example.invalid:443?security=tls#\(label)")
    }
    static func subscription(_ name: String) -> DeskProxySubscription {
        DeskProxySubscription(name: name, url: "https://\(name).example.invalid/sub?token=fixture")
    }
}

@MainActor private final class Harness {
    let suite = "SeekDesk.ProxySubscriptionTests." + UUID().uuidString
    let defaults: UserDefaults
    let store = MemoryVault()
    let fetcher = FetchFixture()
    let probe = ProbeFixture()
    lazy var controller = newController()
    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }
    func newController() -> DeskProxyController {
        DeskProxyController(defaults: defaults, readVault: { [store] in
            if store.failRead { throw DeskProxyError.keychain }
            return store.state
        }, saveVault: { [store] nodes, subscriptions in
            if store.failWrite { throw DeskProxyError.keychain }
            store.writes += 1
            store.state = .init(nodes: nodes, subscriptions: subscriptions)
        }, fetchSubscription: { [fetcher] _ in try await fetcher.fetch() },
           measureNode: { [probe] node in try await probe.measure(node) })
    }
    func clean() {
        controller.cancelNodeMeasurements()
        probe.releasePending()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor private final class MemoryVault {
    var state = DeskProxyVault.State(nodes: [], subscriptions: [])
    var failRead = false
    var failWrite = false
    var writes = 0
}

@MainActor private final class FetchFixture {
    var calls = 0
    var suspended = false
    var result: Result<DeskProxyImportResult, Error> = .failure(DeskProxyError.invalid("Unexpected fixture fetch"))
    private var pending: CheckedContinuation<Result<DeskProxyImportResult, Error>, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func fetch() async throws -> DeskProxyImportResult {
        calls += 1
        guard suspended else { return try result.get() }
        let value = await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
        return try value.get()
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value: Result<DeskProxyImportResult, Error>) {
        let completion = pending
        pending = nil
        precondition(completion != nil)
        completion?.resume(returning: value)
    }
}

@MainActor private final class ProbeFixture {
    struct Call { let node: DeskProxyNode }
    private(set) var calls: [Call] = []
    private(set) var cancelled = Set<Int>()
    private(set) var returned = Set<Int>()
    private(set) var peakActive = 0
    private var active = 0
    private var pending: [Int: CheckedContinuation<Result<Int, Error>, Never>] = [:]

    func measure(_ node: DeskProxyNode) async throws -> Int {
        let index = calls.count
        calls.append(Call(node: node))
        active += 1
        peakActive = max(peakActive, active)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { pending[index] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelled.insert(index) }
        }
        active -= 1
        returned.insert(index)
        // Ignore cancellation to model a transport that delivers a completion after it was stopped.
        return try result.get()
    }

    func waitForCalls(_ count: Int) async {
        await ProxySubscriptionChecks.waitUntil("Expected \(count) node probes, received \(calls.count)") { self.calls.count >= count }
    }

    func waitForCancellation(_ index: Int) async {
        await ProxySubscriptionChecks.waitUntil("Node probe \(index) was not canceled") { self.cancelled.contains(index) }
    }

    func finish(_ index: Int, _ value: Result<Int, Error>) {
        guard let continuation = pending.removeValue(forKey: index) else { preconditionFailure("Missing probe gate \(index)") }
        continuation.resume(returning: value)
    }

    func releasePending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: .failure(CancellationError())) }
    }
}
