import Foundation
import Observation

/// A timed-out SDK callback must not clear the state of a later user action.
@MainActor @Observable final class OperationState {
    private(set) var busy = false
    var error: String?
    private var id: UUID?
    private var work: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    func run(timeout: Duration? = nil, onTimeout: @escaping @MainActor () -> String = { "Operation timed out. Please try again." },
             _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        let current = UUID()
        id = current
        work = Task {
            do { try await action() }
            catch { if id == current { self.error = error.localizedDescription } }
            guard id == current else { return }
            watchdog?.cancel()
            id = nil; busy = false
        }
        if let timeout {
            watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, id == current else { return }
                work?.cancel()
                id = nil; busy = false
                error = onTimeout()
            }
        }
    }
}
