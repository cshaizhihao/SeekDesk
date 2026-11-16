import Foundation
import WebKit

// Root can compile this file against the frozen pre-Round33 bridge with this
// flag. These two adapters reproduce its original startup listing await and
// absent recovery shutdown, without introducing a test-only production hook.
// The first test must then fail after identity confirmation clears the list.
#if SEEKDESK_LISTING_RECOVERY_BASELINE
extension SeekDeskBridgeContext {
    func bootstrapListing() async { await workspace.refresh() }
    func stopListingRecovery() {}
}
#endif

@MainActor
private final class RecoveryGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecoveryFixture {
    struct Read {
        let url: URL
        let revision: Int
        let owner: Int?
    }
    let suite = "cc.seekdesk.qa.listing-recovery." + UUID().uuidString
    let defaults: UserDefaults
    private(set) var context: SeekDeskBridgeContext!
    private(set) var reads: [Read] = []
    private(set) var feedReads = 0
    private(set) var feedCompletions = 0
    private(set) var peopleReads = 0
    var gates: [Int: RecoveryGate] = [:]
    var feedGates: [Int: RecoveryGate] = [:]
    var failures: Set<Int> = []
    var cancellations: Set<Int> = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let proxy = DeskProxyController(defaults: defaults,
            readVault: { .init(nodes: [], subscriptions: []) }, saveVault: { _, _ in },
            fetchSubscription: { _ in throw CancellationError() }, measureNode: { _ in 1 })
        context = SeekDeskBridgeContext(defaults: defaults, dataStore: .nonPersistent(), proxy: proxy,
            fetchFeed: { [weak self] in
                guard let self else { throw CancellationError() }
                self.feedReads += 1
                let number = self.feedReads
                // Deliberately ignore cancellation while gated: Workspace
                // must reject a late fallback response after account changes.
                if let gate = self.feedGates[number] { await gate.wait() }
                self.feedCompletions += 1
                return [Self.post(id: "799", title: "Public RSS fixture", category: "daily")]
            }, fetchPage: { [weak self] url in
                guard let self else { throw CancellationError() }
                let number = self.reads.count + 1
                let read = Read(url: url, revision: self.context.session.accessRevision,
                    owner: self.context.session.memberID)
                self.reads.append(read)
                if let gate = self.gates[number] { await gate.wait() }
                if self.failures.contains(number) { throw ForumPageError.network }
                if self.cancellations.contains(number) { throw CancellationError() }
                let owner = read.owner ?? 0
                let category = url.path.contains("/tech") ? "tech" : "daily"
                return .init(posts: [
                    Self.post(id: "777", title: "Owner \(owner) read \(number)", category: category),
                    Self.post(id: "778", title: "Background owner \(owner) read \(number)", category: category)
                ], next: nil)
            }, fetchPeople: { [weak self] _ in
                self?.peopleReads += 1
                return []
            })
    }

    static func post(id: String, title: String, category: String) -> FeedPost {
        FeedPost(id: id, url: Forum.home.appendingPathComponent("post-\(id)-1"),
            title: title, author: "Local fixture", category: category, published: nil,
            summary: "Isolated local fixture", authorID: 101)
    }

    func identify(_ owner: Int) {
        context.session.observeIdentity(.init(signedIn: true, id: owner,
            name: "Fixture \(owner)", floorsPerPage: 20))
    }

    func finish() {
        context.stopListingRecovery()
        for gate in gates.values { gate.release() }
        for gate in feedGates.values { gate.release() }
        defaults.removePersistentDomain(forName: suite)
    }
}

@main
struct ListingRecoveryChecks {
    @MainActor
    private static func require(_ value: @autoclosure () -> Bool, _ label: String) {
        if !value() { fatalError(label) }
    }

    @MainActor
    private static func settle() async {
        for _ in 0..<80 { await Task.yield() }
    }

    @MainActor
    private static func until(_ label: String, _ predicate: () -> Bool) async {
        for _ in 0..<4000 {
            if predicate() { return }
            await Task.yield()
        }
        fatalError(label)
    }

    @MainActor
    static func main() async {
        await completedStartupThenIdentity()
        await identityDuringStartup()
        await signedOutConfirmation()
        await coalescedIdentityChanges()
        await lateRecoveryCannotCrossIdentity()
        await currentBoardAndOrder()
        await navigationWhileRecovering()
        await readyAndInflightAreNotDuplicated()
        await cancelledManualReadIsRecovered()
        await searchesAreNeverReplayed()
        await failureDoesNotLoop()
        await lateFallbackCannotCrossIdentity()
        await disposeCancelsQueuedAndInflight()
        print("PASS all native listing recovery checks")
    }

    @MainActor
    private static func completedStartupThenIdentity() async {
        let fixture = RecoveryFixture()
        defer { fixture.finish() }
        let context = fixture.context!, workspace = context.workspace
        await context.bootstrapListing()
        require(workspace.hasForumPage && fixture.reads.count == 1, "Initial listing must load before identity is known")
        require(workspace.openTopicLink(Forum.home.appendingPathComponent("post-777-1")), "Open local reader navigation")
        require(workspace.openTopicInBackground(Forum.home.appendingPathComponent("post-778-1")), "Open local background tab")
        let urls = workspace.session.topics.map(\.url)
        let selection = workspace.session.selection
        fixture.identify(101)
        require(!workspace.hasForumPage, "Identity invalidation must still clear the old listing synchronously")
        await until("Identity confirmation after startup stranded the list on RSS", { workspace.hasForumPage })
        await settle()
        require(fixture.reads.count == 2 && fixture.reads.last?.owner == 101, "One current-account recovery must follow startup")
        require(workspace.posts.first?.title == "Owner 101 read 2", "Recovery must publish only current-account rows")
        require(workspace.session.topics.map(\.url) == urls && workspace.session.selection == selection && workspace.showReader,
            "Recovering listings must preserve tab order, URLs, selection and reader presentation")
        require(workspace.session.topics.last?.label == "Background owner 101 read 2",
            "A newly authorized listing should refill a matching unselected tab title")
        require(fixture.feedReads == 0 && fixture.peopleReads == 0 && !context.session.dataStore.isPersistent,
            "Successful isolated recovery must not fetch RSS, people, cookies or real forum content")
        print("PASS completed startup identity invalidation recovers listing and matching background title")
    }

    @MainActor
    private static func identityDuringStartup() async {
        let fixture = RecoveryFixture(), gate = RecoveryGate()
        defer { fixture.finish() }
        fixture.gates[1] = gate
        let initial = Task { @MainActor in await fixture.context.bootstrapListing() }
        await until("Initial request did not enter", { gate.entered })
        fixture.identify(101)
        await until("Concurrent reader identity did not recover listing", { fixture.context.workspace.hasForumPage })
        gate.release()
        await initial.value
        await settle()
        require(fixture.reads.count == 2 && fixture.context.workspace.posts.first?.title == "Owner 101 read 2",
            "Late initial listing must not replace the recovered current identity")
        print("PASS identity discovered during an in-flight initial listing rejects its stale result")
    }

    @MainActor
    private static func signedOutConfirmation() async {
        let fixture = RecoveryFixture()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        fixture.context.session.observeAccount(false)
        await until("Signed-out confirmation stranded the public listing", { fixture.context.workspace.hasForumPage })
        await settle()
        require(fixture.reads.count == 2 && fixture.reads.last?.owner == nil && !fixture.context.session.canCompose,
            "Signed-out confirmation recovers only the normal public listing without granting account capabilities")
        print("PASS initial signed-out confirmation recovers the public listing")
    }

    @MainActor
    private static func coalescedIdentityChanges() async {
        let fixture = RecoveryFixture()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        fixture.identify(101)
        fixture.identify(202)
        fixture.identify(202)
        await until("Coalesced recovery never completed", { fixture.context.workspace.hasForumPage })
        await settle()
        require(fixture.reads.count == 2 && fixture.reads.last?.owner == 202,
            "Synchronous revision changes must coalesce to one latest-identity read")
        fixture.identify(202)
        await settle()
        require(fixture.reads.count == 2, "Observing an unchanged identity must not refresh a ready listing")
        print("PASS repeated identity confirmation and queued revisions do not duplicate requests")
    }

    @MainActor
    private static func lateRecoveryCannotCrossIdentity() async {
        let fixture = RecoveryFixture(), gate = RecoveryGate()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        fixture.gates[2] = gate
        fixture.identify(101)
        await until("First recovery did not enter", { gate.entered })
        fixture.identify(202)
        await until("New revision did not recover while old request was suspended", { fixture.context.workspace.hasForumPage })
        gate.release()
        await settle()
        require(fixture.reads.count == 3 && fixture.context.workspace.posts.first?.title == "Owner 202 read 3",
            "A late cancelled recovery cannot overwrite the latest account")
        require(fixture.reads[1].revision < fixture.reads[2].revision, "Requests must belong to distinct access revisions")
        print("PASS in-flight recovery is replaced and guarded when identity changes again")
    }

    @MainActor
    private static func currentBoardAndOrder() async {
        let fixture = RecoveryFixture()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        fixture.identify(101)
        let tech = Board.sections.first { $0.id == "tech" }!
        fixture.context.workspace.choose(tech)
        fixture.context.workspace.chooseFeedOrder(.replies)
        await until("Current board was not recovered", { fixture.context.workspace.hasForumPage })
        require(fixture.reads.count == 2 && fixture.reads.last?.url == tech.latestURL(order: .replies),
            "Queued recovery must use current board/order, not startup home")
        print("PASS queued recovery follows current board and sort order")
    }

    @MainActor
    private static func navigationWhileRecovering() async {
        let fixture = RecoveryFixture(), gate = RecoveryGate()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        fixture.gates[2] = gate
        fixture.identify(101)
        await until("Home recovery did not enter", { gate.entered })
        _ = try! await fixture.context.selectBoard("tech")
        gate.release()
        await settle()
        let tech = Board.sections.first { $0.id == "tech" }!
        require(fixture.reads.count == 3 && fixture.context.workspace.board == tech && fixture.context.workspace.hasForumPage,
            "Explicit board load during recovery must not get a duplicate follow-up")
        require(fixture.reads.last?.url == tech.latestURL(order: .topics), "Board request must remain the user's new target")

        let moved = RecoveryFixture(), oldBoard = RecoveryGate()
        defer { moved.finish() }
        await moved.context.bootstrapListing()
        moved.gates[2] = oldBoard
        moved.identify(101)
        await until("Recovery did not enter before board changed", { oldBoard.entered })
        moved.context.workspace.choose(tech)
        oldBoard.release()
        await until("Recovery forgot the new current board", { moved.context.workspace.hasForumPage })
        await settle()
        require(moved.reads.count == 3 && moved.reads.last?.url == tech.latestURL(order: .topics),
            "When navigation has no competing read, recovery must resolve the current board after its old request")
        print("PASS board navigation during recovery keeps its own ready listing without duplicate reads")
    }

    @MainActor
    private static func readyAndInflightAreNotDuplicated() async {
        let ready = RecoveryFixture()
        defer { ready.finish() }
        await ready.context.bootstrapListing()
        ready.identify(101)
        await ready.context.workspace.refresh()
        await settle()
        require(ready.reads.count == 2 && ready.context.workspace.hasForumPage,
            "A manual refresh that already completed must satisfy queued recovery")

        let inflight = RecoveryFixture(), gate = RecoveryGate()
        defer { inflight.finish() }
        inflight.identify(101)
        await inflight.context.workspace.refresh()
        inflight.context.workspace.invalidateForumAccess()
        inflight.gates[2] = gate
        let manual = Task { @MainActor in await inflight.context.workspace.refresh() }
        await until("Manual current-revision request did not start", { gate.entered })
        // Exercise the coordinator after the competing request has definitely
        // entered, independently of the actor executor's task scheduling order.
        let recovery = NativeListingRecovery(workspace: inflight.context.workspace, session: inflight.context.session)
        defer { recovery.dispose() }
        recovery.invalidate()
        recovery.invalidate()
        await settle()
        require(inflight.reads.count == 2, "Recovery must wait for a current in-flight request")
        gate.release()
        await manual.value
        await settle()
        require(inflight.reads.count == 2 && inflight.context.workspace.hasForumPage,
            "Successful in-flight manual read must finish recovery without a second read")
        print("PASS ready and in-flight manual reads satisfy recovery without duplication")
    }

    @MainActor
    private static func cancelledManualReadIsRecovered() async {
        let fixture = RecoveryFixture(), gate = RecoveryGate()
        defer { fixture.finish() }
        fixture.identify(101)
        await fixture.context.workspace.refresh()
        fixture.context.workspace.invalidateForumAccess()
        fixture.gates[2] = gate
        let manual = Task { @MainActor in await fixture.context.workspace.refresh() }
        await until("Manual request did not enter", { gate.entered })
        let recovery = NativeListingRecovery(workspace: fixture.context.workspace, session: fixture.context.session)
        defer { recovery.dispose() }
        recovery.invalidate()
        await settle()
        manual.cancel()
        gate.release()
        await manual.value
        await until("Cancelled manual read lost pending recovery", { fixture.context.workspace.hasForumPage })
        await settle()
        require(fixture.reads.count == 3 && fixture.context.workspace.posts.first?.title == "Owner 101 read 3",
            "A cancelled in-flight read must leave one pending recovery, not a retry loop")
        print("PASS cancellation of a current manual read does not strand the invalidated listing")
    }

    @MainActor
    private static func searchesAreNeverReplayed() async {
        let fixture = RecoveryFixture()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        let workspace = fixture.context.workspace
        workspace.searchText = "Old query"
        workspace.searchKind = .posts
        workspace.search()
        await workspace.refresh()
        require(fixture.reads.count == 2, "The old query fixture must have been explicitly requested")
        fixture.identify(101)
        await until("Search invalidation did not restore the board", { workspace.hasForumPage })
        require(workspace.query.isEmpty && fixture.reads.count == 3 && fixture.reads.last?.url == Board.home.latestURL(order: .topics),
            "Identity invalidation may recover its board but must never replay the previous query")

        fixture.identify(202)
        workspace.searchText = "New query"
        workspace.searchKind = .posts
        workspace.search()
        await settle()
        require(fixture.reads.count == 3 && workspace.query == "New query" && fixture.peopleReads == 0,
            "A newly submitted search owns its request; recovery must not trigger it")
        workspace.clearSearch()
        await settle()
        require(fixture.reads.count == 3, "Revoked recovery must not revive after the new search is cleared")

        let gate = RecoveryGate()
        fixture.gates[4] = gate
        fixture.identify(303)
        await until("Recovery did not enter before search", { gate.entered })
        workspace.searchText = "Search while recovering"
        workspace.searchKind = .posts
        workspace.search()
        await settle()
        gate.release()
        await settle()
        require(fixture.reads.count == 4 && !workspace.hasForumPage && workspace.query == "Search while recovering",
            "A new search cancels an owned in-flight listing and prevents its late publication")
        print("PASS previous and newly submitted searches are never replayed by recovery")
    }

    @MainActor
    private static func failureDoesNotLoop() async {
        let fixture = RecoveryFixture()
        defer { fixture.finish() }
        await fixture.context.bootstrapListing()
        fixture.failures.insert(2)
        fixture.identify(101)
        await until("Expected recovery failure was not exposed", { fixture.context.workspace.failedToRefresh })
        await settle()
        require(fixture.reads.count == 2 && fixture.feedReads == 1 && !fixture.context.workspace.hasForumPage,
            "Recovery failure must preserve normal fallback/error behavior without recurring requests")
        require(fixture.context.workspace.posts.first?.title == "Public RSS fixture",
            "An intermediate primary-page error must not cancel the recovery's pending RSS fallback")

        let cancelled = RecoveryFixture()
        defer { cancelled.finish() }
        await cancelled.context.bootstrapListing()
        cancelled.cancellations.insert(2)
        cancelled.identify(101)
        await until("Recovery cancellation fixture was not requested", { cancelled.reads.count == 2 })
        await settle()
        require(cancelled.reads.count == 2 && cancelled.feedReads == 0,
            "A bare cancellation from the recovery transport must not create an unbounded retry loop")
        print("PASS recovery errors and bare cancellation retain one-attempt behavior")
    }

    @MainActor
    private static func lateFallbackCannotCrossIdentity() async {
        let fixture = RecoveryFixture(), oldFeed = RecoveryGate()
        defer { fixture.finish() }
        let context = fixture.context!, workspace = context.workspace
        await context.bootstrapListing()
        require(fixture.feedReads == 0 && fixture.defaults.data(forKey: "latestFeed.v1") == nil,
            "Successful initial listing must leave the isolated RSS cache empty")
        fixture.failures.insert(2)
        fixture.feedGates[1] = oldFeed
        fixture.identify(101)
        await until("Old-account recovery did not enter RSS fallback", { oldFeed.entered })
        let oldRevision = context.session.accessRevision
        require(fixture.reads.count == 2 && fixture.reads.last?.owner == 101 &&
                fixture.feedReads == 1 && fixture.feedCompletions == 0 &&
                workspace.isLoading && workspace.failedToRefresh && !workspace.hasForumPage,
            "The old recovery must remain suspended inside fallback after its primary-page failure")

        fixture.identify(202)
        require(context.session.accessRevision > oldRevision && !workspace.hasForumPage,
            "Changing identity during RSS fallback must synchronously invalidate the old access")
        await until("New account waited on the suspended old RSS fallback", { workspace.hasForumPage })
        require(fixture.reads.count == 3 && fixture.reads.last?.owner == 202 &&
                workspace.posts.first?.title == "Owner 202 read 3" &&
                fixture.feedCompletions == 0,
            "One new-account listing must finish independently before the old RSS response is released")

        oldFeed.release()
        await until("The late RSS fake transport never returned", { fixture.feedCompletions == 1 })
        await settle()
        require(workspace.hasForumPage && !workspace.isLoading && !workspace.failedToRefresh &&
                workspace.posts.first?.title == "Owner 202 read 3" &&
                fixture.reads.count == 3 && fixture.feedReads == 1 && fixture.peopleReads == 0,
            "The old RSS completion must not overwrite the current listing, restore its error or schedule another read")
        require(fixture.defaults.data(forKey: "latestFeed.v1") == nil,
            "A cancelled previous-revision RSS response must not be persisted under the current session")

        // A ready home listing can mask a stale in-memory feed. Inspect an
        // uncached board without fetching so that a leaked fallback is visible.
        workspace.choose(Board.sections.first { $0.id == "tech" }!)
        require(!workspace.hasForumPage && workspace.posts.isEmpty,
            "Late old-account RSS must not become the fallback of an uncached current board")
        workspace.choose(.home)
        await settle()
        require(workspace.hasForumPage && workspace.posts.first?.title == "Owner 202 read 3" &&
                fixture.reads.count == 3 && fixture.feedReads == 1,
            "Inspecting fallback state must preserve the new-account home cache without reviving recovery")
        print("PASS an account change during RSS fallback rejects its late response and preserves the current listing")
    }

    @MainActor
    private static func disposeCancelsQueuedAndInflight() async {
        let queued = RecoveryFixture()
        defer { queued.finish() }
        await queued.context.bootstrapListing()
        queued.identify(101)
        queued.context.stopListingRecovery()
        await settle()
        require(queued.reads.count == 1 && !queued.context.workspace.hasForumPage,
            "Shutdown must cancel queued recovery before it makes a request")

        let inflight = RecoveryFixture(), gate = RecoveryGate()
        defer { inflight.finish() }
        await inflight.context.bootstrapListing()
        inflight.gates[2] = gate
        inflight.identify(101)
        await until("Recovery did not enter before shutdown", { gate.entered })
        inflight.context.stopListingRecovery()
        gate.release()
        await settle()
        require(!inflight.context.workspace.hasForumPage && inflight.reads.count == 2,
            "Shutdown must cancel a suspended recovery before its response can publish")
        inflight.identify(202)
        await settle()
        require(inflight.reads.count == 2, "Disposed recovery must not observe later identity changes")

        let cancelledStart = RecoveryFixture()
        defer { cancelledStart.finish() }
        let startup = Task { @MainActor in await cancelledStart.context.bootstrapListing() }
        startup.cancel()
        await startup.value
        cancelledStart.identify(101)
        await settle()
        require(cancelledStart.reads.isEmpty, "An already-cancelled startup must not arm recovery or fetch a listing")
        print("PASS shutdown cancels pending and in-flight recovery and detaches observers")
    }
}
