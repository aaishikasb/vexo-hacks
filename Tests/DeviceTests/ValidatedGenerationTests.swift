import Foundation
import Testing
import VocaCore
@testable import VocaDevice

private let retryProfile = ModelProfile(modelID: .gemma4E4B, artifactSHA256: "fixture-hash", promptVersion: "fixture-v1")
private let validRetryCue = #"{"text":"Ask which part of the event they enjoyed most.","sourceIDs":["s1"]}"#
private let unsupportedRetryCue = #"{"text":"Ask which part of the event they enjoyed most.","sourceIDs":["invented"]}"#
private enum RetryTestError: Error, Equatable { case native, validatorCalled }

private actor RetryModel: ModelGenerating {
    enum Step: Sendable { case text(String), wrongProfile, wrongRequest, nativeFailure, cancelled }
    let steps: [Step]
    private(set) var requests: [ModelRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func activeProfile() -> ModelProfile { retryProfile }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        requests.append(request)
        switch steps[min(requests.count - 1, steps.count - 1)] {
        case .text(let text): return ModelResponse(requestID: request.requestID, actualProfile: retryProfile, text: text)
        case .wrongProfile:
            var profile = retryProfile; profile.modelID = .gemma4E2B
            return ModelResponse(requestID: request.requestID, actualProfile: profile, text: validRetryCue)
        case .wrongRequest: return ModelResponse(requestID: UUID(), actualProfile: retryProfile, text: validRetryCue)
        case .nativeFailure: throw RetryTestError.native
        case .cancelled: throw CancellationError()
        }
    }
}

private func retryRequest() -> ModelRequest {
    ModelRequest(requestID: UUID(), decisionID: UUID(), kind: .cue, requestedProfile: retryProfile,
        prompt: "Fixture evidence: s1. Return a grounded cue.", imageJPEG: Data([1, 2, 3]),
        maxOutputTokens: 128, responseSchemaJSON: "fixture schema")
}

@Test(arguments: ["Not JSON", #"{"text":"Short","sourceIDs":["s1"]}"#, #"{"wrong":"field"}"#])
func validatedGenerationRecoversWithNewRequestIDAndOriginalAttribution(invalid: String) async throws {
    let request = retryRequest()
    let model = RetryModel([.text(invalid), .text(validRetryCue)])
    let result = try await ValidatedGeneration.run(request, model: model) {
        try GeneratedFields.cue($0, allowedSources: ["s1"])
    }
    #expect(result.value.sourceIDs == ["s1"])
    #expect(result.profile == request.requestedProfile)
    let requests = await model.requests
    #expect(requests.count == 2)
    #expect(requests.first == request)
    #expect(Set(requests.map(\.requestID)).count == 2)
    for attempt in requests {
        #expect(attempt.decisionID == request.decisionID)
        #expect(attempt.requestedProfile == request.requestedProfile)
        #expect(attempt.kind == request.kind)
        #expect(attempt.imageJPEG == request.imageJPEG)
        #expect(attempt.maxOutputTokens == request.maxOutputTokens)
        #expect(attempt.responseSchemaJSON == request.responseSchemaJSON)
        #expect(attempt.prompt.hasPrefix(request.prompt))
    }
}

@Test func validatedGenerationStopsAfterThreeMalformedOutputs() async {
    let model = RetryModel([.text("{")])
    await #expect(throws: GeneratedFields.Failure.malformed) {
        try await ValidatedGeneration.run(retryRequest(), model: model) {
            try GeneratedFields.cue($0, allowedSources: ["s1"])
        }
    }
    let requests = await model.requests
    #expect(requests.count == 3)
    #expect(Set(requests.map(\.requestID)).count == 3)
}

@Test func validatedGenerationNeverReturnsUnsupportedEvidence() async throws {
    let recovered = RetryModel([.text(unsupportedRetryCue), .text(validRetryCue)])
    let result = try await ValidatedGeneration.run(retryRequest(), model: recovered) {
        try GeneratedFields.cue($0, allowedSources: ["s1"])
    }
    #expect(result.value.sourceIDs == ["s1"])
    #expect(await recovered.requests.count == 2)
    let exhausted = RetryModel([.text(unsupportedRetryCue)])
    await #expect(throws: GeneratedFields.Failure.evidence) {
        try await ValidatedGeneration.run(retryRequest(), model: exhausted) {
            try GeneratedFields.cue($0, allowedSources: ["s1"])
        }
    }
    #expect(await exhausted.requests.count == 3)
}

@Test func validatedGenerationDoesNotRetryProfileMismatch() async {
    let model = RetryModel([.wrongProfile, .text(validRetryCue)])
    await #expect(throws: ModelResponseError.profileMismatch) {
        try await ValidatedGeneration.run(retryRequest(), model: model) { _ -> String in
            throw RetryTestError.validatorCalled
        }
    }
    #expect(await model.requests.count == 1)
}

@Test func validatedGenerationDoesNotRetryRequestMismatch() async {
    let model = RetryModel([.wrongRequest, .text(validRetryCue)])
    await #expect(throws: ModelResponseError.requestMismatch) {
        try await ValidatedGeneration.run(retryRequest(), model: model) { _ -> String in
            throw RetryTestError.validatorCalled
        }
    }
    #expect(await model.requests.count == 1)
}

@Test func validatedGenerationDoesNotRetryNativeFailureOrCancellation() async {
    let failed = RetryModel([.nativeFailure])
    await #expect(throws: RetryTestError.native) {
        try await ValidatedGeneration.run(retryRequest(), model: failed) { $0 }
    }
    #expect(await failed.requests.count == 1)
    let cancelled = RetryModel([.cancelled])
    await #expect(throws: CancellationError.self) {
        try await ValidatedGeneration.run(retryRequest(), model: cancelled) { $0 }
    }
    #expect(await cancelled.requests.count == 1)
}

@Test func validatedGenerationCancellationBetweenAttemptsPreventsMoreWork() async {
    let model = RetryModel([.text("malformed"), .text(validRetryCue)])
    let task = Task {
        try await ValidatedGeneration.run(retryRequest(), model: model) { _ -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            throw GeneratedFields.Failure.fields
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await model.requests.count == 1)
}

@Test func validatedGenerationDoesNotRetryUnrelatedValidatorErrors() async {
    let model = RetryModel([.text(validRetryCue)])
    await #expect(throws: RetryTestError.validatorCalled) {
        try await ValidatedGeneration.run(retryRequest(), model: model) { _ -> String in
            throw RetryTestError.validatorCalled
        }
    }
    #expect(await model.requests.count == 1)
}

/// Deliberately ignores cancellation, as a native inference call may do until it returns.
private actor NonCooperativeRetryModel: ModelGenerating {
    private(set) var calls = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func activeProfile() -> ModelProfile { retryProfile }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func generate(_ request: ModelRequest) async -> ModelResponse {
        calls += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
        return ModelResponse(requestID: request.requestID, actualProfile: retryProfile, text: validRetryCue)
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Test func validatedGenerationRejectsLateNonCooperativeResponseAfterCancellation() async {
    let model = NonCooperativeRetryModel()
    let task = Task {
        try await ValidatedGeneration.run(retryRequest(), model: model) {
            try GeneratedFields.cue($0, allowedSources: ["s1"])
        }
    }
    await model.waitUntilStarted()
    task.cancel()
    await model.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await model.calls == 1)
}

@Test func validatedGenerationRejectsSuccessfulValidationAfterCancellation() async {
    let model = RetryModel([.text(validRetryCue)])
    let task = Task {
        try await ValidatedGeneration.run(retryRequest(), model: model) { text in
            withUnsafeCurrentTask { $0?.cancel() }
            return try GeneratedFields.cue(text, allowedSources: ["s1"])
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await model.requests.count == 1)
}
