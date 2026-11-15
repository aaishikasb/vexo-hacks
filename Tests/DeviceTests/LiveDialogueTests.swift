import Foundation
import Testing
import VocaCore
@testable import VocaDevice

@Test func liveDialogueRejectsGapsPartialsFutureStaleAndDuplicates() {
    let now = Date()
    var buffer = LiveDialogue()
    buffer.append(id: "one", text: "The battery keeps failing in cold weather.", final: true, capturedAt: now, gap: false, now: now)
    buffer.append(id: "one", text: "duplicate", final: true, capturedAt: now, gap: false, now: now)
    #expect(buffer.fresh(at: now).count == 1)
    #expect(buffer.fresh(at: now)[0].speaker == nil)
    #expect(!buffer.fresh(at: now)[0].shareApproved)
    #expect(buffer.fresh(at: now.addingTimeInterval(31)).isEmpty)
    buffer.append(id: "gap", text: "uncertain", final: true, capturedAt: now, gap: true, now: now)
    #expect(buffer.evidence.isEmpty)
    buffer.append(id: "partial", text: "not final", final: false, capturedAt: now, gap: false, now: now)
    buffer.append(id: "future", text: "future", final: true, capturedAt: now.addingTimeInterval(1), gap: false, now: now)
    #expect(buffer.evidence.isEmpty)
}

private actor DialogueModel: ModelGenerating {
    let profile = ModelProfile(modelID: .gemma4E2B, artifactSHA256: "fixture", promptVersion: "live-topic")
    var prompt = ""
    func activeProfile() -> ModelProfile { profile }
    func generate(_ request: ModelRequest) -> ModelResponse {
        prompt = request.prompt
        return ModelResponse(requestID: request.requestID, actualProfile: profile,
            text: #"{"text":"Ask what they have tried to keep the battery working in cold weather.","sourceIDs":["d1"]}"#)
    }
}

@MainActor @Test func capturedDialogueFlowsIntoPersistedCueWithoutApprovingMemory() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let memory = MemoryStore(url: directory.appending(path: "memory.json")); try memory.load()
    var buffer = LiveDialogue()
    buffer.append(id: "band-dialogue:test", text: "The battery keeps failing in cold weather.", final: true,
                  capturedAt: now, gap: false, now: now)
    let snapshot = buffer.snapshot(memories: memory.snapshot(), now: now)
    let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let model = DialogueModel()
    let cue = try await CuePipeline(model: model, coach: coach).prepare(
        scene: SceneFacts(requestID: UUID(), observedAt: now, setting: .event, observations: ["A table"], uncertain: false),
        requestedAt: now, goal: .enter, knownPoint: nil, snapshot: snapshot)
    #expect(cue.strategy == .followUp)
    #expect(cue.sourceIDs == ["band-dialogue:test"])
    #expect(await model.prompt.contains("cold weather"))
    #expect(await model.prompt.contains("null speaker"))
    #expect(memory.records.isEmpty)
    #expect(memory.snapshot().approvedMemories.isEmpty)
    let episode = try #require(await coach.episodes().first)
    #expect(episode.delivery == .pending)
    #expect(episode.decision.context.snapshot.dialogue.first?.speaker == nil)
    try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .completed)
    let restored = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    #expect(await restored.episodes().first?.cue?.sourceIDs == ["band-dialogue:test"])
    buffer.clear()
    #expect(buffer.snapshot(memories: memory.snapshot(), now: now).dialogue.isEmpty)
}

@Test func liveDialogueIsBoundedAndNeverUsesFetchTimeAsUtteranceTime() {
    let now = Date()
    var buffer = LiveDialogue()
    for index in 0..<10 {
        buffer.append(id: String(index), text: "Topic \(index)", final: true, capturedAt: now, gap: false, now: now)
    }
    #expect(buffer.evidence.count == 4)
    buffer.append(id: "oversized", text: String(repeating: "x", count: 501), final: true, capturedAt: now, gap: false, now: now)
    #expect(buffer.evidence.count == 4)
    buffer.append(id: "missing-time", text: "New fetch but missing capture time", final: true, capturedAt: nil, gap: false, now: now)
    #expect(buffer.evidence.isEmpty)
}

@Test func staleDialogueIsRemovedBeforePolicyAndPromptEvenIfCallerSuppliesIt() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(), coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
    let model = DialogueModel()
    let snapshot = MemorySnapshot(approvedMemories: [], dialogue: [Evidence(sourceID: "old",
        text: "STALE_PRIVATE_TOPIC", speaker: nil, utteredAt: now.addingTimeInterval(-31), shareApproved: false)], fetchedAt: now, coverage: .partial)
    await #expect(throws: GeneratedFields.Failure.self) {
        try await CuePipeline(model: model, coach: coach).prepare(
            scene: SceneFacts(requestID: UUID(), observedAt: now, setting: .event, observations: ["A table"], uncertain: false),
            requestedAt: now, goal: .enter, knownPoint: nil, snapshot: snapshot)
    }
    #expect(await !model.prompt.contains("STALE_PRIVATE_TOPIC"))
    #expect(await coach.episodes().first?.decision.context.snapshot.dialogue.isEmpty == true)
    #expect(await coach.episodes().first?.delivery == .failed)
}
