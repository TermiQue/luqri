import Foundation

actor SerialWorkQueue {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
