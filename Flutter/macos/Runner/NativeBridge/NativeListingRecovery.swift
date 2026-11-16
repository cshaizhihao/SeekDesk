import Combine
import Foundation

/// Replaces the access-revision task formerly supplied by WorkspaceView.
/// An invalidation grants one recovery attempt for the *current* listing, not
/// a timer or a general auto-refresh policy. Existing Workspace guards remain
/// responsible for rejecting responses from an earlier account revision.
@MainActor
final class NativeListingRecovery {
    private weak var workspace: Workspace?
    private weak var session: ForumSession?
    private var pendingRevision: Int?
    private var generation = 0
    private var observation: AnyCancellable?
    private var evaluation: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var disposed = false

    init(workspace: Workspace, session: ForumSession) {
        self.workspace = workspace
        self.session = session
    }

    func invalidate() {
        guard !disposed, let workspace, let session else { return }
        if pendingRevision == session.accessRevision {
            scheduleEvaluation()
            return
        }
        cancelPending()
        pendingRevision = session.accessRevision
        // objectWillChange is delivered before a mutation. Queue evaluation
        // on the main actor so the complete new state is inspected once, after
        // both invalidation and any synchronous navigation have settled.
        observation = workspace.objectWillChange.sink { [weak self] in
            self?.scheduleEvaluation()
        }
        scheduleEvaluation()
    }

    func dispose() {
        disposed = true
        cancelPending()
    }

    private func cancelPending() {
        generation += 1
        pendingRevision = nil
        observation = nil
        evaluation?.cancel()
        evaluation = nil
        refresh?.cancel()
        refresh = nil
    }

    private func scheduleEvaluation() {
        guard !disposed, pendingRevision != nil, evaluation == nil else { return }
        let token = generation
        evaluation = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.evaluation = nil
            self.evaluate(token)
        }
    }

    private func evaluate(_ token: Int) {
        guard !disposed, generation == token, let workspace, let session,
              let pendingRevision else { return }
        guard session.accessRevision == pendingRevision else {
            cancelPending()
            return
        }
        // A search submitted after invalidation belongs to its explicit caller.
        // Never replay the old query, refresh a new one, or retry an error loop.
        guard workspace.query.isEmpty, !workspace.isSearchingForum else {
            cancelPending()
            return
        }
        // Our own request may already have set a primary-page error and still
        // be awaiting the normal RSS fallback. Let it finish that whole flow;
        // observing the intermediate error must not cancel its fallback.
        guard refresh == nil else { return }
        guard !workspace.hasForumPage, !workspace.failedToRefresh else {
            cancelPending()
            return
        }
        // A current manual/board/bootstrap request gets first claim. Stay
        // subscribed until it settles: a cancelled request may leave no page
        // and no error, in which case exactly one recovery is still needed.
        guard !workspace.isLoading else { return }
        refresh = Task { @MainActor [weak self, weak workspace] in
            guard !Task.isCancelled, let self, let workspace,
                  !self.disposed, self.generation == token,
                  self.session?.accessRevision == pendingRevision else { return }
            // Navigation or a manual refresh can run between scheduling and
            // this task. Recheck before entering Workspace.refresh(), which
            // itself starts synchronously and coalesces the actual listing key.
            guard workspace.query.isEmpty, !workspace.isSearchingForum,
                  !workspace.hasForumPage, !workspace.failedToRefresh,
                  !workspace.isLoading else {
                self.refresh = nil
                self.scheduleEvaluation()
                return
            }
            let board = workspace.board
            let order = workspace.feedOrder
            await workspace.refresh()
            guard !self.disposed, self.generation == token,
                  self.session?.accessRevision == pendingRevision else { return }
            self.refresh = nil
            if workspace.board == board && workspace.feedOrder == order {
                // One attempt is enough even when the transport yields a bare
                // CancellationError. Failures/fallback stay visible for retry.
                self.cancelPending()
            } else {
                // A different current board may already be loading/ready.
                // Re-evaluate it instead of replaying this request's old URL.
                self.scheduleEvaluation()
            }
        }
    }
}
