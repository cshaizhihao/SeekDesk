import AppKit
import FlutterMacOS
import Foundation
import WebKit

@MainActor
private final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct ForumServiceChecks {
    @MainActor
    static func main() async throws {
        let suite = "cc.seekdesk.qa.forum-bridge." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("No isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = DeskProxyController(defaults: defaults, readVault: { .init(nodes: [], subscriptions: []) },
            saveVault: { _, _ in }, fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        let context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy, fetchFeed: { [] })
        var events: [(String, [String: Any])] = []
        context.event = { domain, payload in events.append((domain, payload as? [String: Any] ?? [:])) }
        let session = context.session
        let topicURL = Forum.home.appendingPathComponent("post-123-1")
        let gate = Gate()
        var readerAttempts = 0
        var inboxAttempts: [String: Int] = [:]
        var profileAttempts = 0
        var optionsAttempts = 0
        var delayReplies = false
        var discoverInbox = false
        var inboxStates: [ObjectIdentifier: ForumAccountReader.State] = [:]
        var markGate: Gate?
        var markSucceeds = true
        var markedTargets: [InboxReadTarget] = []
        let messageStamp = "2026-11-15T12:00:00"
        var requests = NativeForumServices.Requests()
        requests.reader = { topic, state, active, force in
            readerAttempts += 1
            if readerAttempts == 1 { active.observeIdentity(.init(signedIn: true, id: 101, name: "First", floorsPerPage: 10)); return false }
            let thread = ForumThread(title: "Account " + String(active.memberID ?? 0), category: "tech", root: nil,
                replies: [], pages: [], page: 1, replyRestriction: nil)
            return await state.load(topic, session: active, force: true, fetch: { _, session in
                (thread, ForumWebPage(dataStore: session.dataStore))
            })
        }
        requests.inbox = { state, kind, peer, _, _, active in
            inboxAttempts[kind, default: 0] += 1
            if kind == "replies", delayReplies { await gate.wait() }
            if discoverInbox { discoverInbox = false; active.observeIdentity(.init(signedIn: true, id: 303, name: "Third", floorsPerPage: 10)) }
            let identity = ObjectIdentifier(state)
            inboxStates[identity] = state.state
            if kind == "messages" {
                inboxStates[identity] = .conversations([
                    .init(id: 404, name: "Peer 404", preview: "Unread fixture", date: messageStamp, unread: true),
                    .init(id: 405, name: "Peer 405", preview: "Another fixture", date: messageStamp, unread: true)
                ])
            } else if kind == "conversation", let peer {
                inboxStates[identity] = .messages(peer: peer, [])
            }
        }
        requests.inboxState = { inboxStates[ObjectIdentifier($0)] ?? $0.state }
        requests.markRead = { state, target, _ in
            markedTargets.append(target)
            if let markGate { await markGate.wait() }
            guard markSucceeds,
                  let current = inboxStates[ObjectIdentifier(state)],
                  case .conversations(let rows) = current else { return }
            inboxStates[ObjectIdentifier(state)] = .conversations(rows.map { row in
                guard row.readTarget == target else { return row }
                return ForumConversation(id: row.id, name: row.name, preview: row.preview, date: row.date, unread: false)
            })
        }
        requests.profile = { _, active, _ in
            profileAttempts += 1
            if profileAttempts == 1 { active.observeIdentity(.init(signedIn: true, id: 404, name: "Fourth", floorsPerPage: 10)) }
        }
        requests.options = { publisher, active, _ in
            optionsAttempts += 1
            if optionsAttempts == 1 { active.observeIdentity(.init(signedIn: true, id: 505, name: "Fifth", floorsPerPage: 10)) }
            else { publisher.phase = .ready; publisher.categories = [.init(id: "tech", title: "技术")]; publisher.maxRank = 30 }
        }
        let services = NativeForumServices(context: context, requests: requests)
        context.accessChanged = { services.invalidate() }
        func require(_ value: @autoclosure () -> Bool, _ label: String) { if !value() { fatalError(label) } }
        func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
        func args(_ more: [String: Any] = [:]) -> [String: Any] {
            more.merging(["accessRevision": session.accessRevision]) { _, new in new }
        }
        func fails(_ method: String, _ values: [String: Any], _ code: String) async throws {
            do { _ = try await services.handle(method, values); fatalError("Expected \(code) for \(method)") }
            catch let issue as NativeBridgeError { require(issue.code == code, "Wrong failure \(issue.code)") }
        }

        require(context.workspace.openTopicLink(topicURL), "Identity fixture opens its in-memory topic")
        let loaded = map(try await services.handle("reader.load", args(["url": topicURL.absoluteString])))
        require(readerAttempts == 2, "First identity discovery must retry read")
        require(map(loaded["thread"])["title"] as? String == "Account 101", "Current partition reader payload")
        require(loaded["accessRevision"] as? Int == session.accessRevision, "Current revision")
        require(events.contains { $0.0 == "reader" && $0.1["url"] as? String == "" && $0.1["thread"] is NSNull },
                "Identity discovery keeps the empty reader invalidation event")
        require(events.contains {
            $0.0 == "workspace" && ($0.1["tabs"] as? [[String: Any]])?.contains {
                $0["id"] as? String == "123" && $0["title"] as? String == "Account 101"
            } == true
        }, "Identity retry still publishes the current tab title through workspace")
        let identityDocumentEvents = events.filter { $0.0 == "reader" && $0.1["thread"] is [String: Any] }
        let identityEventBytes = identityDocumentEvents.reduce(0) { count, event in
            count + FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope([
                "domain": event.0, "data": event.1, "accessRevision": event.1["accessRevision"] ?? session.accessRevision
            ]).count
        }
        print("MEASURE identity-retry fullDocumentEvents=\(identityDocumentEvents.count) fullDocumentEventBytes=\(identityEventBytes) correlatedMethodBytes=\(FlutterStandardMethodCodec.sharedInstance().encodeSuccessEnvelope(loaded).count)")
        fflush(stdout)
        print("PASS reader discovers identity, synchronously invalidates and retries current account")

        _ = try await services.handle("reader.updateReplyDraft", args(["topicID": "123", "content": "owner101"]))
        let stale = args(["topicID": "123", "content": "must not cross owners"])
        session.observeIdentity(.init(signedIn: true, id: 202, name: "Second", floorsPerPage: 10))
        try await fails("reader.updateReplyDraft", stale, "stale_authorization")
        require(session.drafts["123"] == nil, "Other owner cannot see draft")
        session.observeIdentity(.init(signedIn: true, id: 101, name: "First", floorsPerPage: 10))
        require(session.drafts["123"] == "owner101", "Owner draft restored")
        _ = try await services.handle("discussion.updateDraft", args(["title": "Retained", "category": "tech", "content": "Newer edit", "rank": 0]))
        try await fails("discussion.updateDraft", args(["title": "must not partially write", "rank": -1]), "invalid_rank")
        require(session.newDiscussion.title == "Retained", "Whole draft update validates first")
        print("PASS partitioned drafts and stale write rejection without partial mutations")

        discoverInbox = true
        let inbox = map(try await services.handle("inbox.load", args(["kind": "mentions"])))
        require(inboxAttempts["mentions"] == 2 && inbox["kind"] as? String == "mentions", "Inbox identity retry")
        let profile = map(try await services.handle("profile.load", args(["id": 777])))
        require(profileAttempts == 2 && profile["accessRevision"] as? Int == session.accessRevision, "Profile identity retry")
        let options = map(try await services.handle("discussion.loadOptions", args()))
        require(optionsAttempts == 2 && options["ready"] as? Bool == true, "Options identity retry")
        print("PASS inbox/profile/options survive account discovery without stale payload")

        delayReplies = true
        let slow = Task { @MainActor in try await services.handle("inbox.load", args(["kind": "replies"])) }
        while !gate.entered { await Task.yield() }
        let fast = map(try await services.handle("inbox.load", args(["kind": "messages"])))
        require(fast["kind"] as? String == "messages", "Selected inbox route")
        gate.release()
        do { _ = try await slow.value; fatalError("Old category must not overwrite new category") }
        catch is CancellationError {}
        print("PASS overlapping inbox selections cannot relabel or replace current category")

        for success in [true, false] {
            _ = try await services.handle("inbox.load", args(["kind": "messages"]))
            markSucceeds = success
            let readGate = Gate()
            markGate = readGate
            let reading = Task { @MainActor in
                try await services.handle("inbox.markRead", args(["kind": "messages", "id": 404, "stamp": messageStamp]))
            }
            for _ in 0..<10_000 {
                if readGate.entered { break }
                await Task.yield()
            }
            require(readGate.entered, "Read acknowledgement must reach its memory-only gate")
            let conversation = map(try await services.handle("inbox.load", args(["kind": "conversation", "peer": 404])))
            require(conversation["kind"] as? String == "conversation", "Native selection must switch while acknowledgement is waiting")
            readGate.release()
            let marked = map(try await reading.value)
            require(marked["kind"] as? String == "messages" && marked["peer"] is NSNull,
                    "Read acknowledgement must return its target list, never the selected conversation")
            let rows = marked["items"] as? [[String: Any]] ?? []
            require(rows.count == 2 && rows[0]["unread"] as? Bool == !success && rows[1]["unread"] as? Bool == true,
                    "Success clears only its row; failed acknowledgement must keep unread unchanged")
        }
        require(markedTargets.count == 2 && markedTargets.allSatisfy { $0.category == .messages && $0.id == 404 && $0.stamp == messageStamp },
                "Acknowledgements must keep their exact category, peer and message stamp")
        print("PASS delayed markRead returns the messages list after conversation selection; failure retains unread")

        _ = try await services.handle("inbox.load", args(["kind": "messages"]))
        markSucceeds = true
        let evictionGate = Gate()
        markGate = evictionGate
        let evicted = Task { @MainActor in
            try await services.handle("inbox.markRead", args(["kind": "messages", "id": 404, "stamp": messageStamp]))
        }
        for _ in 0..<10_000 {
            if evictionGate.entered { break }
            await Task.yield()
        }
        require(evictionGate.entered, "Eviction fixture acknowledgement must start")
        for peer in 600...609 {
            _ = try await services.handle("inbox.load", args(["kind": "conversation", "peer": peer]))
        }
        evictionGate.release()
        do { _ = try await evicted.value; fatalError("Evicted list reader must not republish its old state") }
        catch is CancellationError {}
        markGate = nil
        print("PASS an evicted inbox reader cannot overwrite the current account list after acknowledgement")

        services.observeUnread(.init(mentions: 2, replies: 0, messages: 3))
        let firstMentionRevision = services.inboxRevision(for: "mentions")
        let firstMessageRevision = services.inboxRevision(for: "conversation")
        services.observeUnread(.init(mentions: 1, replies: 0, messages: 2))
        services.observeUnread(.init(mentions: 2, replies: 0, messages: 2))
        require(services.inboxRevision(for: "mentions") == firstMentionRevision + 1, "Unread fall and rise must invalidate category continuously")
        require(services.inboxRevision(for: "conversation") == firstMessageRevision, "Unchanged message category isolated")
        print("PASS continuous unread changes invalidate categories independently")

        let isolatedSuite = "cc.seekdesk.qa.reader-offsets." + UUID().uuidString
        let offsetDefaults = UserDefaults(suiteName: isolatedSuite)!
        defer { offsetDefaults.removePersistentDomain(forName: isolatedSuite) }
        var clock = 0.0
        let store = NativeReaderOffsetStore(defaults: offsetDefaults, now: { clock += 1; return Date(timeIntervalSince1970: clock) })
        let guestBody = try NativeReaderOffsetStore.validBodyAnchor(["floor": "0", "dy": -14.5])
        let ownerBody = try NativeReaderOffsetStore.validBodyAnchor(["floor": "12", "dy": 100.0])
        let otherBody = try NativeReaderOffsetStore.validBodyAnchor(["floor": "999999999999", "dy": -100_000_000.0])
        let nextBody = try NativeReaderOffsetStore.validBodyAnchor(["floor": "13", "dy": 100_000_000.0])
        try store.remember(100, bodyAnchor: guestBody, at: topicURL, owner: nil)
        try store.remember(200, bodyAnchor: ownerBody, at: topicURL, owner: 101)
        try store.remember(300, bodyAnchor: otherBody, at: topicURL, owner: 202)
        require(store.offset(at: topicURL, owner: nil) == 100 && store.offset(at: topicURL, owner: 101) == 200, "Guest and account isolation")
        require(store.bodyAnchor(at: topicURL, owner: nil) == guestBody && store.bodyAnchor(at: topicURL, owner: 101) == ownerBody,
                "Body anchors are isolated by owner, including guest and floor zero")
        let pageTwo = Forum.home.appendingPathComponent("post-123-2")
        require(store.offset(at: pageTwo, owner: 101) == 0, "Page offsets separated")
        require(store.bodyAnchor(at: pageTwo, owner: 101) == nil, "Unvisited pages cannot inherit a body anchor")
        try store.remember(400, bodyAnchor: nextBody, at: pageTwo, owner: 101)
        for index in 1...505 { try store.remember(Double(index), at: Forum.home.appendingPathComponent("post-\(index)-1"), owner: 999) }
        store.flush()
        require(store.offset(at: Forum.home.appendingPathComponent("post-1-1"), owner: 999) == 0, "LRU cap evicts oldest")
        require(store.offset(at: Forum.home.appendingPathComponent("post-505-1"), owner: 999) == 505, "LRU latest survives")
        let restored = NativeReaderOffsetStore(defaults: offsetDefaults)
        require(restored.offset(at: topicURL, owner: 101) == 200, "Offsets persist")
        require(restored.bodyAnchor(at: topicURL, owner: 101) == ownerBody && restored.bodyAnchor(at: pageTwo, owner: 101) == nextBody,
                "Body anchors reload independently for each page")
        require(restored.bodyAnchor(at: topicURL, owner: nil) == guestBody && restored.bodyAnchor(at: topicURL, owner: 202) == otherBody,
                "Body anchors survive owner partition reload")
        try restored.remember(401, at: pageTwo, owner: 101)
        restored.flush()
        let clearedReload = NativeReaderOffsetStore(defaults: offsetDefaults)
        require(clearedReload.offset(at: pageTwo, owner: 101) == 401 && clearedReload.bodyAnchor(at: pageTwo, owner: 101) == nil
                && clearedReload.bodyAnchor(at: topicURL, owner: 101) == ownerBody,
                "An offset-only save persistently clears only its page's obsolete body anchor")
        for invalid: Any in [Double.nan, Double.infinity, -1, true, "123", 100_000_001] {
            do { _ = try NativeReaderOffsetStore.validOffset(invalid); fatalError("Invalid offset accepted") }
            catch is NativeBridgeError {}
        }
        let malformedBodies: [Any] = [
            true, "floor-0", ["0", "1"], [:] as [String: Any],
            ["floor": "0"], ["dy": 0], ["floor": 0, "dy": 0],
            ["floor": "", "dy": 0], ["floor": "-1", "dy": 0],
            ["floor": "1.5", "dy": 0], ["floor": "１２", "dy": 0],
            ["floor": " 1", "dy": 0], ["floor": "1\n", "dy": 0],
            ["floor": "1000000000000", "dy": 0], ["floor": "0", "dy": true],
            ["floor": "0", "dy": "12"], ["floor": "0", "dy": NSNull()],
            ["floor": "0", "dy": -100_000_001], ["floor": "0", "dy": 100_000_001]
        ]
        let nonfiniteBodies: [Any] = [Double.nan, Double.infinity, -Double.infinity].map { ["floor": "0", "dy": $0] as [String: Any] }
        for invalid in malformedBodies + nonfiniteBodies {
            do { _ = try NativeReaderOffsetStore.validBodyAnchor(invalid); fatalError("Invalid body anchor accepted") }
            catch let issue as NativeBridgeError { require(issue.code == "invalid_position", "Body anchor failure code") }
        }

        // Use the existing v1 schema and JSON date representation directly:
        // absence or damage of the new optional field must preserve old offsets.
        var storedRows: [[String: Any]] = [["page": topicURL.absoluteString, "offset": 321.0, "updated": 0.0]]
        for (index, invalid) in malformedBodies.enumerated() {
            storedRows.append(["page": Forum.home.appendingPathComponent("post-\(7000 + index)-1").absoluteString,
                               "offset": Double(index + 1), "updated": 1.0, "bodyAnchor": invalid])
        }
        storedRows.append(["page": pageTwo.absoluteString, "offset": 654.0, "updated": 2.0, "bodyAnchor": ownerBody.dictionary])
        offsetDefaults.set(try JSONSerialization.data(withJSONObject: storedRows), forKey: "flutter.readerOffsets.v1.717")
        let recovered = NativeReaderOffsetStore(defaults: offsetDefaults)
        require(recovered.offset(at: topicURL, owner: 717) == 321 && recovered.bodyAnchor(at: topicURL, owner: 717) == nil,
                "Legacy v1 offset-only records remain readable")
        for index in malformedBodies.indices {
            let url = Forum.home.appendingPathComponent("post-\(7000 + index)-1")
            require(recovered.offset(at: url, owner: 717) == Double(index + 1) && recovered.bodyAnchor(at: url, owner: 717) == nil,
                    "Malformed optional body anchor must not drop its offset or the partition")
        }
        require(recovered.offset(at: pageTwo, owner: 717) == 654 && recovered.bodyAnchor(at: pageTwo, owner: 717) == ownerBody,
                "A valid sibling body anchor survives malformed persisted anchors")
        print("PASS bounded owner/guest/page body anchor persistence, legacy reload and corrupt optional field recovery")

        func positionSnapshot() async throws -> [String: Any] {
            map(try await services.handle("reader.load", args(["url": topicURL.absoluteString])))
        }
        _ = try await services.handle("reader.rememberPosition", args(["url": topicURL.absoluteString,
            "offset": 123.0, "bodyAnchor": guestBody.dictionary, "anchor": "floor-9"]))
        let anchoredSnapshot = try await positionSnapshot()
        require(anchoredSnapshot["scrollOffset"] as? Double == 123 && map(anchoredSnapshot["bodyAnchor"])["floor"] as? String == "0"
                && map(anchoredSnapshot["bodyAnchor"])["dy"] as? Double == -14.5 && anchoredSnapshot["anchor"] as? String == "floor-9",
                "Reader snapshots expose independent body and legacy anchors")
        for invalid in malformedBodies + nonfiniteBodies {
            try await fails("reader.rememberPosition", args(["url": topicURL.absoluteString, "offset": 999,
                "bodyAnchor": invalid, "anchor": "floor-10"]), "invalid_position")
        }
        for invalid: Any in [Double.nan, Double.infinity, -1, true, "123", 100_000_001] {
            try await fails("reader.rememberPosition", args(["url": topicURL.absoluteString, "offset": invalid,
                "bodyAnchor": ownerBody.dictionary, "anchor": "floor-10"]), "invalid_position")
        }
        try await fails("reader.rememberPosition", args(["url": topicURL.absoluteString, "offset": 5,
            "bodyAnchor": ownerBody.dictionary, "anchor": ["offset": 5]]), "invalid_anchor")
        var stalePosition = args(["url": topicURL.absoluteString, "offset": 999,
            "bodyAnchor": ownerBody.dictionary, "anchor": "floor-10"])
        stalePosition["accessRevision"] = session.accessRevision - 1
        try await fails("reader.rememberPosition", stalePosition, "stale_authorization")
        for legacyAnchor: Any in [NSNull(), "floor-10"] {
            try await fails("reader.rememberPosition", args(["url": topicURL.absoluteString,
                "bodyAnchor": ownerBody.dictionary, "anchor": legacyAnchor]), "invalid_position")
            try await fails("reader.rememberPosition", args(["url": topicURL.absoluteString,
                "offset": NSNull(), "bodyAnchor": ownerBody.dictionary, "anchor": legacyAnchor]), "invalid_position")
        }
        let afterRejections = try await positionSnapshot()
        require(afterRejections["scrollOffset"] as? Double == 123 && map(afterRejections["bodyAnchor"])["floor"] as? String == "0"
                && map(afterRejections["bodyAnchor"])["dy"] as? Double == -14.5 && session.anchor(at: topicURL) == "floor-9",
                "Any invalid position field must leave the entire previous position unchanged")
        _ = try await services.handle("reader.rememberPosition", args(["url": topicURL.absoluteString, "anchor": "floor-10"]))
        _ = try await services.handle("reader.rememberPosition", args(["url": topicURL.absoluteString,
            "bodyAnchor": NSNull(), "anchor": "floor-11"]))
        let anchorOnly = try await positionSnapshot()
        require(anchorOnly["scrollOffset"] as? Double == 123 && map(anchorOnly["bodyAnchor"])["floor"] as? String == "0"
                && session.anchor(at: topicURL) == "floor-11", "Legacy anchor-only writes preserve offset and body anchor")
        for nullBody in [false, true] {
            _ = try await services.handle("reader.rememberPosition", args(["url": topicURL.absoluteString,
                "offset": 123.0, "bodyAnchor": guestBody.dictionary]))
            var clear: [String: Any] = ["url": topicURL.absoluteString, "offset": 456.0]
            if nullBody { clear["bodyAnchor"] = NSNull() }
            _ = try await services.handle("reader.rememberPosition", args(clear))
            let cleared = try await positionSnapshot()
            require(cleared["scrollOffset"] as? Double == 456 && cleared["bodyAnchor"] == nil
                    && session.anchor(at: topicURL) == "floor-11", "Missing or null bodyAnchor with offset clears stale body geometry only")
        }
        print("PASS reader bridge snapshots, atomic position rejection, anchor-only compatibility and body anchor clearing")

        let stickerMap = map(try await services.handle("stickers.list", args()))
        require(stickerMap["packs"] is [[String: Any]], "NativeClient list data must be inside map")
        require(JSONSerialization.isValidJSONObject(stickerMap), "Sticker map codec safe")
        for invalid: Any in [true, 2.5, Double.infinity] {
            do { _ = try NativeDTO.integer(["n": invalid], "n"); fatalError("Invalid integer accepted") }
            catch is NativeBridgeError {}
        }
        let normalized = map(NativeForumServices.normalizedThread(["root": ["blocks": [["kind": "tabs", "tabs": [["label": "NQ", "blocks": [["kind": "terminal", "text": "\u{001B}[31mRED\u{001B}[0m"]]]]]]]]))
        let root = map(normalized["root"])
        let block = (root["blocks"] as? [[String: Any]])?.first ?? [:]
        let tab = (block["tabs"] as? [[String: Any]])?.first ?? [:]
        let terminal = (tab["blocks"] as? [[String: Any]])?.first ?? [:]
        require(terminal["terminal"] is [[Any]], "Nested ANSI report must carry parsed spans")
        require(JSONSerialization.isValidJSONObject(normalized), "Normalized reports codec safe")
        print("PASS nested ANSI reports use native color parsing at the bridge boundary")
        let listReport: [String: Any] = ["kind": "list", "text": "", "items": [
            ["marker": "•", "blocks": [["kind": "terminal", "text": "\u{001B}[31mRED\u{001B}[0m"]]]
        ]]
        let normalizedList = map(NativeForumServices.normalizedThread(listReport))
        let listItem = (normalizedList["items"] as? [[String: Any]])?.first ?? [:]
        let listTerminal = (listItem["blocks"] as? [[String: Any]])?.first ?? [:]
        require(listTerminal["terminal"] is [[Any]], "List descendants retain terminal spans")
        require(JSONSerialization.isValidJSONObject(normalizedList), "List report remains codec safe")
        print("PASS list descendants use native terminal normalization")

        let currencies = map(try await services.handle("value.currencies", args()))
        require((currencies["items"] as? [[String: String]])?.contains(where: { $0["code"] == "USD" }) == true, "Native currency catalog")
        let sameRate = map(try await services.handle("value.rate", args(["base": "USD", "quote": "USD"])))
        require(sameRate["rate"] as? String == "1", "Same currency requires no network")
        try await fails("value.rate", args(["base": "BAD", "quote": "USD"]), "invalid_currency")
        let future = Date().addingTimeInterval(30 * 86400).timeIntervalSince1970 * 1000
        let values: [String: Any] = ["amount": "100.00", "cycle": 1, "expires": future, "rate": "7.2", "quote": "CNY", "asking": "999"]
        let estimate = map(try await services.handle("value.calculate", args(values)))
        require(estimate["formatted"] is String && estimate["differenceAmount"] is String, "Decimal conversion and asking comparison")
        require(estimate["differenceLabel"] as? String == "高于剩余价值", "Asking difference direction")
        try await fails("value.calculate", args(values.merging(["rate": "0"]) { _, new in new }), "invalid_rate")
        print("PASS currency catalog, no-network same pair and Decimal asking-price comparison")

        services.dispose()
        do { _ = try await services.handle("stickers.list", args()); fatalError("Disposed service accepted work") }
        catch is CancellationError {}
        print("PASS channel map contract, strict integer inputs and disposed lifecycle")
        require(identityDocumentEvents.isEmpty && identityEventBytes == 0,
                "Identity retry must return its full reader document only through the correlated method result")
        print("PASS identity retry preserves empty invalidation and workspace events without duplicating the reader document")
    }
}
