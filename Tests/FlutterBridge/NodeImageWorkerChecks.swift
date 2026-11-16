import Foundation
import Security

private enum WorkerFailure: Error { case expected }

private final class WorkerProbe: @unchecked Sendable {
    struct Snapshot {
        var queued: [String] = []
        var started: [String] = []
        var completed: [String] = []
        var active = 0, maximumActive = 0
        var allOffMain = true
    }

    private let condition = NSCondition()
    private var held: Set<String>
    private var state = Snapshot()

    init(held: Set<String> = []) { self.held = held }

    func queued(_ name: String) {
        condition.lock(); defer { condition.unlock() }
        state.queued.append(name)
    }

    func perform(_ name: String, failing: Bool = false) throws -> String {
        let offMain = !Thread.isMainThread
        precondition(offMain, "The worker must never execute synchronous backend work on the main thread")
        condition.lock()
        state.allOffMain = state.allOffMain && offMain
        state.started.append(name)
        state.active += 1
        state.maximumActive = max(state.maximumActive, state.active)
        while held.contains(name) { condition.wait() }
        state.completed.append(name)
        state.active -= 1
        condition.unlock()
        if failing { throw WorkerFailure.expected }
        return "value:" + name
    }

    func release(_ name: String) {
        condition.lock(); defer { condition.unlock() }
        held.remove(name)
        condition.broadcast()
    }

    func snapshot() -> Snapshot {
        condition.lock(); defer { condition.unlock() }
        return state
    }
}

@main
struct NodeImageWorkerChecks {
    @MainActor
    static func main() async throws {
        @MainActor
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        @MainActor
        func until(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<2_000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            fatalError(message)
        }
        @MainActor
        func cancelled(_ operation: () async throws -> String) async throws {
            do {
                _ = try await operation()
                fatalError("Expected cancellation")
            } catch is CancellationError {}
        }

        do {
            let worker = NodeImageWorker(label: "cc.seekdesk.qa.node-image-worker.responsive")
            let probe = WorkerProbe(held: ["slow"])
            defer { probe.release("slow") }
            var settled = false
            let pending = Task { @MainActor in
                defer { settled = true }
                return try await worker.run { try probe.perform("slow") }
            }
            try await until("The injected operation did not start") { probe.snapshot().started == ["slow"] }
            let ping = Task { @MainActor in 42 }
            let response = await ping.value
            require(response == 42 && !settled && probe.snapshot().completed.isEmpty,
                    "MainActor work remains responsive while the actual synchronous operation is held")
            probe.release("slow")
            let value = try await pending.value
            require(value == "value:slow" && settled, "Successful backend values are returned after completion")
            do {
                _ = try await worker.run { try probe.perform("failure", failing: true) }
                fatalError("Expected the original backend error")
            } catch WorkerFailure.expected {}
            let observed = probe.snapshot()
            require(observed.allOffMain && observed.completed == ["slow", "failure"],
                    "Success and failure both execute off-main and complete exactly once")
            print("PASS worker runs synchronous success and failure off-main while MainActor remains responsive")
        }

        do {
            let worker = NodeImageWorker(label: "cc.seekdesk.qa.node-image-worker.ordering")
            let probe = WorkerProbe(held: ["first", "second"])
            defer { probe.release("first"); probe.release("second") }
            let first = Task { @MainActor in
                try await worker.run(onQueued: { probe.queued("first") }) { try probe.perform("first") }
            }
            try await until("The first serialized operation did not start") { probe.snapshot().started == ["first"] }
            let second = Task { @MainActor in
                try await worker.run(onQueued: { probe.queued("second") }) { try probe.perform("second") }
            }
            try await until("The second operation was not queued") { probe.snapshot().queued.contains("second") }
            let third = Task { @MainActor in
                try await worker.run(onQueued: { probe.queued("third") }) { try probe.perform("third") }
            }
            try await until("The third operation was not queued") { probe.snapshot().queued.contains("third") }
            require(probe.snapshot().started == ["first"], "Queued operations cannot enter the backend concurrently")
            probe.release("first")
            try await until("The second serialized operation did not start") {
                probe.snapshot().started == ["first", "second"]
            }
            require(probe.snapshot().completed == ["first"], "The third backend waits for the second backend to finish")
            probe.release("second")
            let values = try await [first.value, second.value, third.value]
            let observed = probe.snapshot()
            require(values == ["value:first", "value:second", "value:third"] &&
                    observed.completed == ["first", "second", "third"] &&
                    observed.maximumActive == 1 && observed.active == 0 && observed.allOffMain,
                    "A single worker preserves submission order and never overlaps synchronous operations")
            print("PASS serial worker preserves established submission order with no overlapping backends")
        }

        do {
            let worker = NodeImageWorker(label: "cc.seekdesk.qa.node-image-worker.cancelled-entry")
            let probe = WorkerProbe()
            let pending = Task { @MainActor in
                try await worker.run(onQueued: { probe.queued("cancelled") }) { try probe.perform("cancelled") }
            }
            pending.cancel()
            try await cancelled { try await pending.value }
            let observed = probe.snapshot()
            require(observed.queued.isEmpty && observed.started.isEmpty && observed.completed.isEmpty,
                    "An already-cancelled caller never submits or executes backend work")
            print("PASS cancellation at entry skips both queue submission and backend execution")
        }

        do {
            let worker = NodeImageWorker(label: "cc.seekdesk.qa.node-image-worker.queued-cancellation")
            let probe = WorkerProbe(held: ["blocker"])
            defer { probe.release("blocker") }
            let blocker = Task { @MainActor in try await worker.run { try probe.perform("blocker") } }
            try await until("The queue blocker did not start") { probe.snapshot().started == ["blocker"] }
            var settled = false
            let pending = Task { @MainActor in
                defer { settled = true }
                return try await worker.run(onQueued: { probe.queued("cancelled") }) { try probe.perform("cancelled") }
            }
            try await until("The cancellable operation was not actually queued") {
                probe.snapshot().queued.contains("cancelled")
            }
            pending.cancel()
            try await until("Queued cancellation incorrectly waited for the blocked backend") { settled }
            try await cancelled { try await pending.value }
            require(probe.snapshot().started == ["blocker"] && probe.snapshot().completed.isEmpty,
                    "Queued cancellation settles without running its backend or ending the active operation")
            let tail = Task { @MainActor in
                try await worker.run(onQueued: { probe.queued("tail") }) { try probe.perform("tail") }
            }
            try await until("The queue tail was not submitted") { probe.snapshot().queued.contains("tail") }
            probe.release("blocker")
            _ = try await blocker.value
            _ = try await tail.value
            let observed = probe.snapshot()
            require(observed.started == ["blocker", "tail"] && observed.completed == ["blocker", "tail"] &&
                    observed.maximumActive == 1,
                    "Draining the queue skips cancelled work and still executes later authorized work")
            print("PASS cancellation of confirmed queued work returns promptly and skips its backend when the queue drains")
        }

        for failing in [false, true] {
            let worker = NodeImageWorker(label: "cc.seekdesk.qa.node-image-worker.started-cancellation")
            let probe = WorkerProbe(held: ["running"])
            defer { probe.release("running") }
            var settled = false
            let pending = Task { @MainActor in
                defer { settled = true }
                return try await worker.run { try probe.perform("running", failing: failing) }
            }
            try await until("The cancellable backend did not start") { probe.snapshot().started == ["running"] }
            pending.cancel()
            let tail = Task { @MainActor in
                try await worker.run(onQueued: { probe.queued("tail") }) { try probe.perform("tail") }
            }
            try await until("The tail behind a cancelled active operation was not submitted") {
                probe.snapshot().queued.contains("tail")
            }
            // Give an incorrectly early cancellation continuation time to settle
            // while the injected backend remains deterministically blocked.
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(1))
                require(!settled && probe.snapshot().completed.isEmpty && probe.snapshot().started == ["running"],
                        "Cancellation after start must keep awaiting the actual backend and preserve serial ownership")
            }
            probe.release("running")
            try await cancelled { try await pending.value }
            let tailValue = try await tail.value
            let observed = probe.snapshot()
            require(settled && tailValue == "value:tail" && observed.completed == ["running", "tail"] &&
                    observed.maximumActive == 1 && observed.allOffMain,
                    "The real backend finishes before CancellationError wins over its success or failure")
            print("PASS cancellation during started \(failing ? "failure" : "success") waits for real completion before releasing its caller")
        }

        do {
            let probe = WorkerProbe(held: ["credential"])
            defer { probe.release("credential") }
            let pending = Task { @MainActor in
                try await NodeImageWorker.shared.run { try probe.perform("credential") }
            }
            try await until("The shared credential worker did not start") { probe.snapshot().started == ["credential"] }
            var statusSettled = false
            let status = Task { @MainActor in
                defer { statusSettled = true }
                return try await NodeImageKey.configured(matching: { _ in
                    precondition(!Thread.isMainThread, "Status matching must stay off-main")
                    probe.queued("status-matched")
                    return errSecSuccess
                })
            }
            try await until("Nonsecret status was queued behind the authenticated credential worker") { statusSettled }
            let configured = try await status.value
            require(configured && probe.snapshot().queued.contains("status-matched") && probe.snapshot().completed.isEmpty,
                    "The status worker can finish while the shared credential worker is still blocked")
            probe.release("credential")
            _ = try await pending.value
            print("PASS nonsecret status uses its own worker and remains responsive while the credential worker is held")
        }
    }
}
