import Foundation

/// Shares a download/decode pipeline while keeping each view's cancellation local.
/// A cancelled worker retains its slot until it actually exits, so rapid scrolls
/// cannot exceed the limit by repeatedly cancelling and replacing requests.
actor ImageRequestCoordinator<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let large: Bool
        let operation: @Sendable () async throws -> Value
        var subscribers: [UUID: CheckedContinuation<Value, Error>]
        var worker: Task<Void, Never>?
    }

    private let maximumConcurrent: Int
    private let maximumLargeConcurrent: Int
    private var entries: [Key: Entry] = [:]
    private var queue: [Key] = []
    private var active: [UUID: Bool] = [:]

    init(maximumConcurrent: Int = 4, maximumLargeConcurrent: Int = 1) {
        precondition(maximumConcurrent > 0 && maximumLargeConcurrent > 0)
        self.maximumConcurrent = maximumConcurrent
        self.maximumLargeConcurrent = maximumLargeConcurrent
    }

    func value(for key: Key, large: Bool = false,
               operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                if entries[key] != nil {
                    entries[key]?.subscribers[subscriber] = continuation
                } else {
                    entries[key] = Entry(id: UUID(), large: large, operation: operation,
                                         subscribers: [subscriber: continuation])
                    queue.append(key)
                }
                startAvailable()
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancel(subscriber, for: key) }
        }
    }

    private func cancel(_ subscriber: UUID, for key: Key) {
        guard var entry = entries[key], let waiting = entry.subscribers.removeValue(forKey: subscriber) else { return }
        if entry.subscribers.isEmpty {
            entries[key] = nil
            queue.removeAll { $0 == key }
            entry.worker?.cancel()
        } else {
            entries[key] = entry
        }
        waiting.resume(throwing: CancellationError())
        startAvailable()
    }

    private func startAvailable() {
        while active.count < maximumConcurrent {
            let largeCount = active.values.filter { $0 }.count
            // A queued original must not block ordinary thumbnails or avatars.
            guard let index = queue.firstIndex(where: { key in
                guard let entry = entries[key] else { return false }
                return !entry.large || largeCount < maximumLargeConcurrent
            }) else { return }
            let key = queue.remove(at: index)
            guard var entry = entries[key] else { continue }
            let id = entry.id
            let operation = entry.operation
            active[id] = entry.large
            entry.worker = Task.detached(priority: .userInitiated) { [weak self] in
                let result: Result<Value, Error>
                do { result = .success(try await operation()) }
                catch { result = .failure(error) }
                await self?.finished(result, for: key, id: id)
            }
            entries[key] = entry
        }
    }

    private func finished(_ result: Result<Value, Error>, for key: Key, id: UUID) {
        active[id] = nil
        // An old cancelled worker may finish after a replacement was enqueued.
        if let entry = entries[key], entry.id == id {
            entries[key] = nil
            for subscriber in entry.subscribers.values { subscriber.resume(with: result) }
        }
        startAvailable()
    }
}
