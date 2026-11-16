import Foundation

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    preconditionFailure("Timed out waiting for a request lifecycle event")
}

private func url(_ path: String) -> URL { URL(string: "https://fixture.invalid/\(path).png")! }

private func fetch(_ path: String, kind: ForumImageRequest.Kind = .post) async throws -> Int {
    let image = try await ForumImageRequest.fetch(url(path), kind: kind)
    return image.width * image.height
}

private actor ControlledOperation {
    private var waiting: [String: CheckedContinuation<Int, Never>] = [:]
    private var starts: [String] = []
    func run(_ id: String) async -> Int {
        starts.append(id)
        return await withCheckedContinuation { waiting[id] = $0 }
    }
    func started(_ id: String) -> Bool { starts.contains(id) }
    func release(_ id: String, value: Int) { waiting.removeValue(forKey: id)?.resume(returning: value) }
}

@main struct ImageRequestChecks {
    static func main() async throws {
        let fixture = imageFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let probe = ImageRequestProbe.shared

        probe.configure(fixture)
        let pixels = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { try await fetch("dedup") } }
            var total = 0
            for try await value in group { total += value }
            return total
        }
        var stats = probe.snapshot()
        expect(stats.downloads == 1 && stats.decodes == 1 && pixels == 8 * 1024, "Identical in-flight images must share download and decode")
        _ = try await fetch("dedup")
        expect(probe.snapshot().downloads == 1, "Warm fetch must remain cached")
        expect(stats.mainThreadDecodes == 0 && stats.referersValid, "Decode must stay off main; request headers preserved")
        print("Passed production fetch: 8 identical images → 1 download / 1 decode (baseline 8 / 8), warm hit unchanged.")

        probe.configure(fixture)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for kind in [ForumImageRequest.Kind.post, .avatar, .original] {
                group.addTask { try await fetch("kinds", kind: kind) }
            }
            for try await value in group { expect(value == 1024, "Wrong kind result") }
        }
        expect(probe.snapshot().downloads == 3, "Same URL with different decode kinds must not merge")
        print("Passed URL + kind separation.")

        probe.configure(fixture)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<12 { group.addTask { try await fetch("bounded-\(index)") } }
            for index in 0..<4 { group.addTask { try await fetch("original-\(index)", kind: .original) } }
            for try await value in group { expect(value == 1024, "Wrong bounded result") }
        }
        stats = probe.snapshot()
        expect(stats.downloads == 16 && stats.peak <= 4 && stats.peakOriginals == 1, "Download/decode pipelines must be bounded; originals serialized")
        print("Passed bounded pipelines: 16 requests, peak downloads=\(stats.peak), peak originals=\(stats.peakOriginals).")

        probe.configure(fixture)
        DecodeRequestProbe.shared.hold()
        let decoding = (0..<6).map { index in Task { try await fetch("decode-limit-\(index)") } }
        try await eventually { DecodeRequestProbe.shared.snapshot().active == 2 }
        try await Task.sleep(for: .milliseconds(25))
        expect(DecodeRequestProbe.shared.snapshot().entered == 2, "Only 2 held decoder operations may enter")
        DecodeRequestProbe.shared.release()
        for task in decoding { _ = try await task.value }
        expect(DecodeRequestProbe.shared.snapshot().peak == 2, "Decode peak must be measured under overlapping work")
        print("Passed real decoder overlap gate: 6 images, peak active decoders=2.")

        probe.configure(fixture)
        DecodeRequestProbe.shared.hold()
        let cancelledDecodes = (0..<2).map { index in Task { try await fetch("cancel-decode-\(index)") } }
        try await eventually { DecodeRequestProbe.shared.snapshot().active == 2 }
        for task in cancelledDecodes { task.cancel() }
        for task in cancelledDecodes {
            do { _ = try await task.value; preconditionFailure("Cancelled decode subscriber succeeded") }
            catch { expect(error is CancellationError, "Decode-stage cancellation must be prompt") }
        }
        let afterDecodeCancel = Task { try await fetch("after-decode-cancel") }
        try await eventually { probe.snapshot().downloads == 3 }
        try await Task.sleep(for: .milliseconds(140))
        expect(DecodeRequestProbe.shared.snapshot().entered == 2, "Cancelled synchronous decoders must retain both slots until exit")
        DecodeRequestProbe.shared.release()
        _ = try await afterDecodeCancel.value
        try await eventually { DecodeRequestProbe.shared.snapshot().active == 0 }
        expect(DecodeRequestProbe.shared.snapshot().peak == 2, "Cancellation must not overcommit decoder slots")
        print("Passed decoder-stage cancellation, retained slots, temporary-file lifetime and queue release.")

        probe.configure(fixture)
        let leaving = Task { try await fetch("one-cancel") }
        try await eventually { probe.snapshot().downloads == 1 }
        let staying = (0..<3).map { _ in Task { try await fetch("one-cancel") } }
        try await Task.sleep(for: .milliseconds(15))
        leaving.cancel()
        do { _ = try await leaving.value; preconditionFailure("Cancelled subscriber succeeded") }
        catch { expect(error is CancellationError, "Subscriber cancellation must be prompt") }
        var remainingPixels = 0
        for task in staying { remainingPixels += try await task.value }
        stats = probe.snapshot()
        expect(remainingPixels == 3 * 1024 && stats.downloads == 1 && stats.cancellations == 0, "One cancellation must not cancel other subscribers")
        print("Passed individual cancellation while all 3 remaining subscribers succeed.")

        probe.configure(fixture)
        let first = Task { try await fetch("all-cancel") }
        try await eventually { probe.snapshot().downloads == 1 }
        let second = Task { try await fetch("all-cancel") }
        try await Task.sleep(for: .milliseconds(15))
        first.cancel(); second.cancel()
        for task in [first, second] {
            do { _ = try await task.value; preconditionFailure("Cancelled subscriber succeeded") }
            catch { expect(error is CancellationError, "Expected cancellation") }
        }
        try await eventually { probe.snapshot().active == 0 }
        expect(probe.snapshot().cancellations == 1, "Last subscriber must cancel the underlying transport")
        _ = try await fetch("all-cancel")
        expect(probe.snapshot().downloads == 2, "Fully cancelled URL must be retryable")
        print("Passed last-subscriber cancellation, transport release and retry.")

        probe.configure(fixture)
        probe.failOnce("/failure.png")
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { do { _ = try await fetch("failure"); return false } catch { return true } }
            }
            var count = 0
            for await failed in group { if failed { count += 1 } }
            return count
        }
        expect(failures == 8 && probe.snapshot().downloads == 1, "Shared failure must reach all subscribers")
        _ = try await fetch("failure")
        expect(probe.snapshot().downloads == 2 && probe.snapshot().decodes == 1, "Failure must not poison future retries")
        print("Passed shared failure and successful retry.")

        probe.configure(fixture)
        _ = try await fetch("original-release", kind: .original)
        ForumImageRequest.releaseOriginal(url("original-release"))
        _ = try await fetch("original-release", kind: .original)
        expect(probe.snapshot().downloads == 2, "Original release must still remove its cached bitmap")
        let cancelledBeforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fetch("dedup")
        }
        do { _ = try await cancelledBeforeStart.value; preconditionFailure("Cancelled warm hit succeeded") }
        catch { expect(error is CancellationError, "A warm hit must honor cancellation") }
        let cancelledCold = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fetch("cancelled-cold")
        }
        do { _ = try await cancelledCold.value; preconditionFailure("Already-cancelled cold fetch succeeded") }
        catch { expect(error is CancellationError, "Cold request must honor existing cancellation") }
        expect(probe.snapshot().downloads == 2, "Already-cancelled cold request must not start a transport")
        print("Passed original-cache release and already-cancelled warm/cold fetches.")

        try await coordinatorLifecycleChecks()
        print("All image request checks passed; local generated PNG and stub transport only, no network/UI/account changes.")
    }

    private static func coordinatorLifecycleChecks() async throws {
        let coordinator = ImageRequestCoordinator<String, Int>(maximumConcurrent: 1)
        let operation = ControlledOperation()
        let old = Task { try await coordinator.value(for: "same") { await operation.run("old") } }
        try await eventually { await operation.started("old") }
        old.cancel()
        do { _ = try await old.value; preconditionFailure("Cancelled old task succeeded") }
        catch { expect(error is CancellationError, "Cancelled task must not wait for an uncooperative operation") }

        // The old operation deliberately ignores cancellation until released.
        let replacement = Task { try await coordinator.value(for: "same") { await operation.run("replacement") } }
        let queued = Task { try await coordinator.value(for: "queued") { await operation.run("queued") } }
        try await Task.sleep(for: .milliseconds(15))
        queued.cancel()
        do { _ = try await queued.value; preconditionFailure("Queued cancelled task succeeded") }
        catch { expect(error is CancellationError, "Queued cancellation must be prompt") }
        let replacementStartedEarly = await operation.started("replacement")
        expect(!replacementStartedEarly, "Cancelled but still-running worker must retain its slot")
        await operation.release("old", value: 1)
        try await eventually { await operation.started("replacement") }
        await operation.release("replacement", value: 2)
        let result = try await replacement.value
        let queuedStarted = await operation.started("queued")
        expect(result == 2 && !queuedStarted, "Old generation must not consume the replacement; queued cancellation must not start work")

        // With a free slot, the replacement runs before the abandoned generation
        // exits. Its completion must not resume/remove the new subscriber.
        let parallel = ImageRequestCoordinator<String, Int>(maximumConcurrent: 2)
        let slowOld = Task { try await parallel.value(for: "same") { await operation.run("slow-old") } }
        try await eventually { await operation.started("slow-old") }
        slowOld.cancel()
        do { _ = try await slowOld.value; preconditionFailure("Cancelled generation succeeded") }
        catch { expect(error is CancellationError, "Expected old-generation cancellation") }
        let new = Task { try await parallel.value(for: "same") { await operation.run("new") } }
        try await eventually { await operation.started("new") }
        await operation.release("slow-old", value: 10)
        // A sentinel runs through the same scheduler to drain its finish queue.
        _ = try await parallel.value(for: "sentinel") { 0 }
        await operation.release("new", value: 20)
        let newResult = try await new.value
        expect(newResult == 20, "An old in-flight completion must not overwrite the new generation")
        print("Passed queued cancellation, retained slot and simultaneous old/new generation isolation.")
    }
}
