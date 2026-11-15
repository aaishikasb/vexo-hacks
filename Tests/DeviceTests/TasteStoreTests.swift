import Foundation
import Testing
import VocaCore
@testable import VocaDevice

private func ratedTasteEpisode(delivery: DeliveryStatus = .completed, verdict: FeedbackVerdict = .unhelpful) -> Episode {
    let context = VocaFixtures.context()
    let decision = CueDecision(context: context, features: CoachEngine.features(for: context),
        eligibleActions: [.personalConnection], selectedAction: .personalConnection,
        utilities: ["personalConnection": 0], policyVersion: "fixture", usedExploration: false)
    return Episode(decision: decision, cue: CueResult(decisionID: context.decisionID, actualProfile: context.profile,
        strategy: .personalConnection, text: "Mention the garden you built and ask about their experience.", sourceIDs: ["mem-story"]),
        delivery: delivery, feedback: FeedbackEvent(decisionID: context.decisionID, verdict: verdict, revision: 1))
}

@MainActor @Test func tasteSurvivesRestartButExamplesNeedApproval() throws {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "taste.json"), episode = ratedTasteEpisode()
    let store = TasteStore(url: url); try store.load()
    try store.save(episode: episode, reasons: [.relaxed], alternative: "How did you get started with that?", approvedExample: false)
    #expect(store.guidance(episodes: [episode], goal: .deepen).examples.isEmpty)
    try store.save(episode: episode, reasons: [.relaxed], alternative: "How did you get started with that?", approvedExample: true)
    let restored = TasteStore(url: url); try restored.load()
    #expect(restored.enabled(.relaxed, episodes: [episode]))
    #expect(restored.guidance(episodes: [episode], goal: .deepen).examples.count == 1)
    #expect(restored.guidance(episodes: [episode], goal: .enter).examples.isEmpty)
    #expect(restored.guidance(episodes: [episode], goal: .deepen).prompt.contains("not citable sources"))
    try restored.set(.relaxed, enabled: false)
    #expect(!restored.enabled(.relaxed, episodes: [episode]))
}

@MainActor @Test func correctedOrDeletedFeedbackStopsInfluencingTaste() throws {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TasteStore(url: dir.appending(path: "taste.json")); try store.load()
    var episode = ratedTasteEpisode()
    try store.save(episode: episode, reasons: [.lessPersonal], alternative: "A simpler opener", approvedExample: true)
    episode.feedback = FeedbackEvent(decisionID: episode.id, verdict: .notTried, revision: 2)
    #expect(store.note(for: episode) == nil)
    #expect(store.guidance(episodes: [episode], goal: .deepen).instructions.isEmpty)
    try store.prune(episodes: [])
    #expect(store.guidance(episodes: [], goal: .deepen).examples.isEmpty)
    try store.set(.concise, enabled: true)
    try store.reset()
    #expect(store.guidance(episodes: [], goal: .deepen).instructions.isEmpty)
}

@MainActor @Test func tasteDoesNotAcceptFailedDeliveryOrOversizedRewrites() throws {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TasteStore(url: dir.appending(path: "taste.json")); try store.load()
    #expect(throws: TasteStore.Failure.self) {
        try store.save(episode: ratedTasteEpisode(delivery: .failed), reasons: [.relaxed], alternative: "", approvedExample: false)
    }
    #expect(throws: TasteStore.Failure.self) {
        try store.save(episode: ratedTasteEpisode(), reasons: [], alternative: String(repeating: "x", count: 241), approvedExample: true)
    }
}

@MainActor @Test func corruptTasteStoreCannotBeOverwritten() throws {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "taste.json"), bytes = Data("invalid".utf8)
    try bytes.write(to: url)
    let store = TasteStore(url: url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: TasteStore.Failure.self) { try store.reset() }
    #expect(try Data(contentsOf: url) == bytes)
}

private actor TastePromptModel: ModelGenerating {
    var prompts: [String] = []
    let profile = VocaFixtures.profile(.gemma4E2B, prompt: "different-version")
    let invalidExampleCitation: Bool
    init(invalidExampleCitation: Bool) { self.invalidExampleCitation = invalidExampleCitation }
    func activeProfile() -> ModelProfile { profile }
    func generate(_ request: ModelRequest) -> ModelResponse {
        prompts.append(request.prompt)
        return ModelResponse(requestID: request.requestID, actualProfile: profile,
            text: "{\"text\":\"Ask which drink on the menu they would recommend today.\",\"sourceIDs\":[\"\(invalidExampleCitation ? "style-example" : "s1")\"]}")
    }
}

@MainActor @Test(arguments: [false, true])
func tasteTransfersAcrossModelsWithoutBecomingEvidence(invalidCitation: Bool) async throws {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TasteStore(url: dir.appending(path: "taste.json")); try store.load()
    let old = ratedTasteEpisode()
    try store.save(episode: old, reasons: [.relaxed], alternative: "", approvedExample: false)
    let model = TastePromptModel(invalidExampleCitation: invalidCitation)
    let coach = try CoachEngine(storeURL: dir.appending(path: "episodes.json"))
    let scene = VocaFixtures.context().scene
    let pipeline = CuePipeline(model: model, coach: coach, taste: store.guidance(episodes: [old], goal: .enter))
    if invalidCitation {
        await #expect(throws: GeneratedFields.Failure.evidence) {
            try await pipeline.prepare(scene: scene, requestedAt: scene.observedAt, goal: .enter, knownPoint: nil)
        }
    } else {
        let cue = try await pipeline.prepare(scene: scene, requestedAt: scene.observedAt, goal: .enter, knownPoint: nil)
        #expect(cue.actualProfile.modelID == .gemma4E2B)
        #expect(cue.sourceIDs == [scene.requestID.uuidString])
    }
    #expect(await model.prompts.first?.contains(TastePreference.relaxed.instruction) == true)
    #expect(await coach.episodes().allSatisfy { $0.feedback == nil })
}

@MainActor @Test func factualAndTimingCorrectionsNeverBecomeStylePreferences() throws {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TasteStore(url: dir.appending(path: "taste.json")); try store.load()
    let episode = ratedTasteEpisode()
    for issue in [FeedbackIssue.wrongFacts, .wrongMoment, .wrongStrategy] {
        try store.save(episode: episode, reasons: [.relaxed], alternative: "The object was a book", approvedExample: true, issue: issue)
        #expect(store.guidance(episodes: [episode], goal: .deepen).instructions.isEmpty)
        #expect(store.guidance(episodes: [episode], goal: .deepen).examples.isEmpty)
    }
}
