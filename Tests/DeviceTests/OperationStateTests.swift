import Foundation
import Testing
@testable import VocaDevice

@Test @MainActor func timedOutSDKCallbackCannotClearNewOperation() async throws {
    let state = OperationState()
    var old: CheckedContinuation<Void, Never>?
    var next: CheckedContinuation<Void, Never>?
    state.run(timeout: .milliseconds(5), onTimeout: { "Retry camera" }) {
        await withCheckedContinuation { old = $0 }
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!state.busy)
    #expect(state.error == "Retry camera")
    state.run { await withCheckedContinuation { next = $0 } }
    await Task.yield()
    old?.resume()
    await Task.yield()
    #expect(state.busy)
    #expect(state.error == nil)
    next?.resume()
    try await Task.sleep(for: .milliseconds(5))
    #expect(!state.busy)
}

@Test @MainActor func duplicateUserActionIsNotStarted() async throws {
    let state = OperationState()
    var calls = 0
    var finish: CheckedContinuation<Void, Never>?
    state.run {
        calls += 1
        await withCheckedContinuation { finish = $0 }
    }
    state.run { calls += 1 }
    await Task.yield()
    #expect(calls == 1)
    finish?.resume()
    try await Task.sleep(for: .milliseconds(5))
    #expect(!state.busy)
}
