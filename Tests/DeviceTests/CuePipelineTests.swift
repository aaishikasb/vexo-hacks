import Foundation
import Testing
import VocaCore
@testable import VocaDevice

private actor FixtureModel: ModelGenerating {
    let coach: CoachEngine
    let fail: Bool
    var sceneID: UUID?
    var sawPersistedDecision = false
    let profile = ModelProfile(modelID: .gemma4E4B, artifactSHA256: "fixture", promptVersion: "fixture")
    init(coach: CoachEngine, fail: Bool = false) { self.coach = coach; self.fail = fail }
    func activeProfile() -> ModelProfile { profile }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        if request.kind == .scene {
            sceneID = request.requestID
            return ModelResponse(requestID: request.requestID, actualProfile: profile,
                text: #"{"setting":"cafe","observations":["A coffee menu is visible"],"uncertain":false}"#)
        }
        sawPersistedDecision = await coach.episodes().contains { $0.id == request.decisionID && $0.delivery == .pending }
        let source = fail ? "invented" : sceneID!.uuidString
        return ModelResponse(requestID: request.requestID, actualProfile: profile,
            text: "{\"text\":\"Ask which drink on the menu they would recommend today.\",\"sourceIDs\":[\"\(source)\"]}")
    }
}

@Test func cueDecisionIsPersistedBeforeGenerationAndNeedsPlayback() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let model = FixtureModel(coach: coach)
    let cue = try await CuePipeline(model: model, coach: coach).prepare(photo: Data([1]), observedAt: Date(),
        requestedAt: Date(), goal: .enter, knownPoint: nil)
    #expect(await model.sawPersistedDecision)
    let episode = try #require(await coach.episodes().first)
    #expect(episode.id == cue.decisionID)
    #expect(episode.delivery == .pending)
    #expect(!episode.decision.usedExploration)
    #expect(episode.cue == nil)
    #expect(cue.actualProfile == episode.decision.context.profile)
}

@Test func inventedCueEvidenceMarksDecisionFailed() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let model = FixtureModel(coach: coach, fail: true)
    await #expect(throws: GeneratedFields.Failure.self) {
        try await CuePipeline(model: model, coach: coach).prepare(photo: Data([1]), observedAt: Date(),
            requestedAt: Date(), goal: .enter, knownPoint: nil)
    }
    #expect(await coach.episodes().first?.delivery == .failed)
}
