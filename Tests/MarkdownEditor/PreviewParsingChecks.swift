// Compiled with production parser and extracted view task by run-checks.py.
enum Probe {
    final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func waitUntilEntered() -> Bool {
            entered.wait(timeout: .now() + 5) == .success
        }
    }
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var gates: [String: Gate] = [:]
    private static var mainThreadCalls = 0
    private static var active = 0
    private static var maximumActive = 0

    static func gate(_ source: String) -> Gate {
        lock.lock()
        defer { lock.unlock() }
        let gate = Gate()
        gates[source] = gate
        return gate
    }

    static func count(_ source: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[source, default: 0]
    }

    static func parse(_ source: String) -> [MarkdownPreviewDocument.Block] {
        lock.lock()
        counts[source, default: 0] += 1
        active += 1
        maximumActive = max(maximumActive, active)
        if Thread.isMainThread { mainThreadCalls += 1 }
        let gate = gates.removeValue(forKey: source)
        lock.unlock()
        if let gate {
            gate.entered.signal()
            precondition(gate.release.wait(timeout: .now() + 10) == .success, "worker release timed out")
        }
        let result = MarkdownPreviewDocument.blocks(source)
        lock.lock()
        active -= 1
        lock.unlock()
        return result
    }

    static func assertOffMain() {
        lock.lock()
        defer { lock.unlock() }
        precondition(mainThreadCalls == 0, "parser ran on UI thread")
        precondition(maximumActive == 1, "obsolete parses ran concurrently")
    }
}

@main struct PreviewParsingChecks {
    static func entered(_ gate: Probe.Gate) async {
        let result = await Task.detached {
            gate.waitUntilEntered()
        }.value
        precondition(result, "worker never started")
    }

    @MainActor static func main() async throws {
        let fixtures = [
            "", " \n\t", "# 标题\r\n正文 **粗体**\r> 引用",
            "- [x] 已完成\n- [ ] 待完成\n---\n![a](https://fixture.invalid/a(b).png)",
            "| A | B |\n| --- | :---: |\n| a\\|b | c |",
            "```swift\nlet a = 1\n```\n~~~\n```\n~~~",
            "```ansi\n\u{1b}[31m北京电信\u{1b}[0m\n100.0ms\n```",
            ":::: tabs\n::: tab-item NQ\n# 报告\n:::\n::: tab-item TQ\n内容\n:::\n::::",
            "![表情](https://fixture.invalid/x.png) :ac01: `:ac02:` \\![escaped](bad)",
            String(repeating: "![", count: 2000),
            (0..<1500).map { "## 段落 \($0)\n阅读测试 **重点**" }.joined(separator: "\n")
        ]
        for source in fixtures {
            let expected = MarkdownPreviewDocument.blocks(source)
            let actual = try await MarkdownPreviewParsing.blocks(for: source)
            precondition(actual == expected, "async parser changed Markdown semantics")
        }
        print("Passed: 11 fixtures preserve synchronous parser semantics (including ANSI/tabs/CRLF).")

        let small = "cache-revisit-原始内容"
        _ = try await MarkdownPreviewParsing.blocks(for: small)
        _ = try await MarkdownPreviewParsing.blocks(for: small)
        precondition(Probe.count(small) == 1)
        let different = small + " changed"
        let changed = try await MarkdownPreviewParsing.blocks(for: different)
        precondition(changed == MarkdownPreviewDocument.blocks(different))
        let oversized = String(repeating: "long-report", count: 13000)
        _ = try await MarkdownPreviewParsing.blocks(for: oversized)
        _ = try await MarkdownPreviewParsing.blocks(for: oversized)
        precondition(Probe.count(oversized) == 2)
        _ = try await MarkdownPreviewParsing.blocks(for: small)
        precondition(Probe.count(small) == 1, "large report displaced small drafts")
        for i in 0..<4 { _ = try await MarkdownPreviewParsing.blocks(for: "cache-eviction-\(i)") }
        _ = try await MarkdownPreviewParsing.blocks(for: small)
        precondition(Probe.count(small) == 2, "old drafts retained without a count bound")
        print("Passed: full-source cache hits, changed content, eviction, and oversized bypass.")

        let preCancelled = "cancel-before-start"
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MarkdownPreviewParsing.blocks(for: preCancelled)
        }
        do { _ = try await cancelled.value; preconditionFailure("cancelled request succeeded") }
        catch is CancellationError {}
        precondition(Probe.count(preCancelled) == 0)

        let during = "cancel-during-parsing"
        let gate = Probe.gate(during)
        let running = Task { try await MarkdownPreviewParsing.blocks(for: during) }
        await entered(gate)
        running.cancel()
        gate.release.signal()
        do { _ = try await running.value; preconditionFailure("cancelled work returned a value") }
        catch is CancellationError {}
        _ = try await MarkdownPreviewParsing.blocks(for: during)
        precondition(Probe.count(during) == 2, "cancelled parse was retained")
        print("Passed: cancellation before start and during parsing discards the result.")

        let beforeReset = "cache-reset-before"
        _ = try await MarkdownPreviewParsing.blocks(for: beforeReset)
        let duringReset = "cache-reset-in-flight"
        let resetGate = Probe.gate(duringReset)
        let resetTask = Task { try await MarkdownPreviewParsing.blocks(for: duringReset) }
        await entered(resetGate)
        MarkdownPreviewParsing.removeAll()
        resetGate.release.signal()
        _ = try await resetTask.value
        _ = try await MarkdownPreviewParsing.blocks(for: beforeReset)
        _ = try await MarkdownPreviewParsing.blocks(for: duringReset)
        precondition(Probe.count(beforeReset) == 2, "reset retained existing draft")
        precondition(Probe.count(duringReset) == 2, "old worker repopulated cache after reset")
        print("Passed: removeAll clears drafts and rejects pre-reset worker cache insertion.")

        let blocked = "backpressure-active"
        let blockedGate = Probe.gate(blocked)
        let blockedTask = Task { try await MarkdownPreviewParsing.blocks(for: blocked) }
        await entered(blockedGate)
        let queued = (0..<12).map { index in
            Task { try await MarkdownPreviewParsing.blocks(for: "backpressure-queued-\(index)") }
        }
        // Let the requests enter the worker queue while one parse is blocked.
        for _ in 0..<20 { await Task.yield() }
        for task in queued { task.cancel() }
        blockedGate.release.signal()
        _ = try await blockedTask.value
        for (index, task) in queued.enumerated() {
            do { _ = try await task.value; preconditionFailure("cancelled queue request succeeded") }
            catch is CancellationError {}
            precondition(Probe.count("backpressure-queued-\(index)") == 0, "cancelled queued request parsed")
        }
        print("Passed: serialized parsing skips 12 cancelled queued requests.")

        let snapshot = PreviewSnapshot()
        let older = "older unfinished preview"
        let later = "newest preview"
        let oldGate = Probe.gate(older)
        let newGate = Probe.gate(later)
        let oldTask = Task { await update(older, snapshot) }
        await entered(oldGate)
        let newTask = Task { await update(later, snapshot) }
        for _ in 0..<1000 {
            if snapshot.isCurrent(2) { break }
            await Task.yield()
        }
        precondition(snapshot.isCurrent(2), "new view request did not begin")
        oldGate.release.signal()
        await entered(newGate)
        await oldTask.value
        precondition(snapshot.blocks.isEmpty, "old preview published while newer request was waiting")
        newGate.release.signal()
        await newTask.value
        precondition(snapshot.blocks == MarkdownPreviewDocument.blocks(later), "late result replaced newest preview")
        await update("", snapshot)
        precondition(snapshot.blocks.isEmpty, "clearing editor left stale preview")

        let cancelledPreview = "cancelled preview publication"
        let publishGate = Probe.gate(cancelledPreview)
        let publishTask = Task { await update(cancelledPreview, snapshot) }
        await entered(publishGate)
        publishTask.cancel()
        publishGate.release.signal()
        await publishTask.value
        precondition(snapshot.blocks.isEmpty, "cancelled view task published")
        Probe.assertOffMain()
        print("Passed: production view task rejects stale/cancelled results and clears emptied input.")
        print("Passed: all instrumented synchronous parses ran off the main thread; peak concurrency = 1.")
        print("No UI, network, account state, NQ/TQ sizing or version changes; these checks do not measure FPS.")
    }
}
