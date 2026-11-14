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
        let source = fail ? "invented" : (!photoOnly && context?.knownPointSourceID != nil ? "p1" : "s1")
        if context?.knownPointSourceID != nil { #expect(request.prompt.contains("p1")) }
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
            text = "{\"text\":\"Share how growing tomatoes helped you enjoy gardening this summer.\",\"sourceIDs\":[\"\(useMemory ? "m1" : "invented")\"]}"
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

private actor ScopedEvidenceModel: ModelGenerating {
    let profile = ModelProfile(modelID: .gemma4E2B, artifactSHA256: "scoped-fixture", promptVersion: "scoped-fixture")
    let sources: [String]
    private(set) var prompts: [String] = []
    init(sources: [String]) { self.sources = sources }
    func activeProfile() -> ModelProfile { profile }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        prompts.append(request.prompt)
        let ids = String(decoding: try JSONEncoder().encode(sources), as: UTF8.self)
        return ModelResponse(requestID: request.requestID, actualProfile: profile,
            text: "{\"text\":\"Ask which part of the event they enjoyed most today.\",\"sourceIDs\":\(ids)}")
    }
}

@Test(arguments: [Goal.enter, Goal.explain])
func cuePromptIncludesOnlySelectedStrategyEvidence(goal: Goal) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let now = Date()
    let scene = SceneFacts(requestID: UUID(), observedAt: now, setting: .event,
        observations: ["UNIQUE_SCENE_A stage with a microphone"], uncertain: false)
    let snapshot = MemorySnapshot(approvedMemories: [Evidence(sourceID: "canonical-memory",
        text: "UNIQUE_MEMORY_I grow tomatoes", speaker: "wearer", utteredAt: nil, shareApproved: true)],
        dialogue: [Evidence(sourceID: "canonical-dialogue", text: "UNIQUE_DIALOGUE_I enjoy gardening",
            speaker: "partner", utteredAt: now, shareApproved: false)], fetchedAt: now, coverage: .complete)
    let point = "UNIQUE_POINT_Explain my solar project"
    let model = ScopedEvidenceModel(sources: [goal == .enter ? "s1" : "p1"])
    let cue = try await CuePipeline(model: model, coach: coach).prepare(scene: scene,
        requestedAt: now, goal: goal, knownPoint: point, snapshot: snapshot)
    let prompt = try #require(await model.prompts.first)
    #expect(!prompt.contains("UNIQUE_MEMORY_"))
    #expect(!prompt.contains("UNIQUE_DIALOGUE_"))
    #expect(prompt.contains("UNIQUE_SCENE_") == (goal == .enter))
    #expect(prompt.contains("UNIQUE_POINT_") == (goal == .explain))
    #expect(cue.strategy == (goal == .enter ? .situationalOpener : .explainClearly))
    let episode = try #require(await coach.episodes().first)
    // Prompt scoping must not change the frozen decision evidence or canonical IDs.
    #expect(episode.decision.context.snapshot == snapshot)
    #expect(episode.decision.context.knownPoint == point)
    #expect(cue.sourceIDs == [goal == .enter ? scene.requestID.uuidString : "user-input:\(cue.decisionID.uuidString)"])
}

@Test(arguments: [Goal.enter, Goal.explain])
func cueRejectsUnrelatedMemoryEvenAlongsideRequiredSource(goal: Goal) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let now = Date()
    let scene = SceneFacts(requestID: UUID(), observedAt: now, setting: .event,
        observations: ["A microphone is visible"], uncertain: false)
    let snapshot = MemorySnapshot(approvedMemories: [Evidence(sourceID: "canonical-memory",
        text: "I grow tomatoes", speaker: "wearer", utteredAt: nil, shareApproved: true)],
        dialogue: [], fetchedAt: now, coverage: .complete)
    let model = ScopedEvidenceModel(sources: [goal == .enter ? "s1" : "p1", "m1"])
    await #expect(throws: GeneratedFields.Failure.evidence) {
        try await CuePipeline(model: model, coach: coach).prepare(scene: scene,
            requestedAt: now, goal: goal, knownPoint: "Explain my solar project", snapshot: snapshot)
    }
    #expect(await model.prompts.count == 3)
    let episode = try #require(await coach.episodes().first)
    #expect(episode.delivery == .failed)
    #expect(episode.cue == nil)
}
