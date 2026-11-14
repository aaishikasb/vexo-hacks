import Foundation
import Testing
import VocaCore
@testable import VocaDevice

private actor FixtureModel: ModelGenerating {
    let coach: CoachEngine
    let fail: Bool
    let photoOnly: Bool
    var sceneID: UUID?
    var sawPersistedDecision = false
    let profile = ModelProfile(modelID: .gemma4E4B, artifactSHA256: "fixture", promptVersion: "fixture")
    init(coach: CoachEngine, fail: Bool = false, photoOnly: Bool = false) { self.coach = coach; self.fail = fail; self.photoOnly = photoOnly }
    func activeProfile() -> ModelProfile { profile }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        if request.kind == .scene {
            sceneID = request.requestID
            return ModelResponse(requestID: request.requestID, actualProfile: profile,
                text: #"{"setting":"cafe","observations":["A coffee menu is visible"],"uncertain":false}"#)
        }
        sawPersistedDecision = await coach.episodes().contains { $0.id == request.decisionID && $0.delivery == .pending }
        let context = await coach.episodes().first { $0.id == request.decisionID }?.decision.context
        let source = fail ? "invented" : (photoOnly ? nil : context?.knownPointSourceID) ?? sceneID!.uuidString
        if let pointSource = context?.knownPointSourceID { #expect(request.prompt.contains(pointSource)) }
        return ModelResponse(requestID: request.requestID, actualProfile: profile,
            text: "{\"text\":\"Ask which drink on the menu they would recommend today.\",\"sourceIDs\":[\"\(source)\"]}")
    }
}

@Test(arguments: [false, true]) func explainCitesTypedPointBeforeSpeech(photoOnly: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let model = FixtureModel(coach: coach, photoOnly: photoOnly)
    let pipeline = CuePipeline(model: model, coach: coach)
    if photoOnly {
        await #expect(throws: GeneratedFields.Failure.self) {
            try await pipeline.prepare(photo: Data([1]), observedAt: Date(), requestedAt: Date(), goal: .explain, knownPoint: "My garden project")
        }
        #expect(await coach.episodes().first?.delivery == .failed)
    } else {
        let cue = try await pipeline.prepare(photo: Data([1]), observedAt: Date(), requestedAt: Date(), goal: .explain, knownPoint: "My garden project")
        let episode = try #require(await coach.episodes().first)
        let source = try #require(episode.decision.context.knownPointSourceID)
        #expect(source == "user-input:\(episode.id.uuidString)")
        #expect(cue.sourceIDs == [source])
        #expect(episode.delivery == .pending)
        try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .completed)
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

private actor MemoryCueModel: ModelGenerating {
    let profile = ModelProfile(modelID: .gemma4E4B, artifactSHA256: "fixture", promptVersion: "memory-fixture")
    let useMemory: Bool
    init(useMemory: Bool) { self.useMemory = useMemory }
    func activeProfile() -> ModelProfile { profile }
    func generate(_ request: ModelRequest) -> ModelResponse {
        let text: String
        if request.kind == .scene {
            text = #"{"setting":"other","observations":[],"uncertain":true}"#
        } else {
            text = "{\"text\":\"Share how growing tomatoes helped you enjoy gardening this summer.\",\"sourceIDs\":[\"\(useMemory ? "approved-story" : "invented")\"]}"
        }
        return ModelResponse(requestID: request.requestID, actualProfile: profile, text: text)
    }
}

@Test(arguments: [true, false]) func personalCueMustCiteApprovedMemory(useMemory: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let snapshot = MemorySnapshot(approvedMemories: [Evidence(sourceID: "approved-story", text: "I grew tomatoes this summer.", speaker: "wearer", utteredAt: nil, shareApproved: true)], dialogue: [], fetchedAt: Date(), coverage: .partial)
    let pipeline = CuePipeline(model: MemoryCueModel(useMemory: useMemory), coach: coach)
    if useMemory {
        let cue = try await pipeline.prepare(photo: Data([1]), observedAt: Date(), requestedAt: Date(), goal: .deepen, knownPoint: nil, snapshot: snapshot)
        #expect(cue.strategy == .personalConnection)
        #expect(cue.sourceIDs == ["approved-story"])
        #expect(await coach.episodes().first?.decision.context.snapshot == snapshot)
    } else {
        await #expect(throws: GeneratedFields.Failure.self) {
            try await pipeline.prepare(photo: Data([1]), observedAt: Date(), requestedAt: Date(), goal: .deepen, knownPoint: nil, snapshot: snapshot)
        }
    }
}
