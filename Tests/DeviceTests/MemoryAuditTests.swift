import Foundation
import Testing
import VocaCore
@testable import VocaDevice

private func auditEpisode(mode: SessionMode = .live) -> Episode {
    Episode(decision: CueDecision(context: VocaFixtures.context(mode: mode, withDialogue: false, withStory: false),
        features: [], eligibleActions: [.followUp], selectedAction: .followUp, utilities: [:],
        policyVersion: "fixture", usedExploration: false))
}

private let auditCard = CoachingCard(id: "listen-then-follow", title: "Follow the thread", principle: "Listen to a concrete detail.",
    exercise: "Ask one follow-up.", bookTitle: "Fixture", sourceURL: "https://example.com")

private actor AuditModel: ModelGenerating {
    var calls = 0
    let output: String
    let mismatch: Bool
    init(output: String = "", mismatch: Bool = false) { self.output = output; self.mismatch = mismatch }
    func activeProfile() async throws -> ModelProfile { VocaFixtures.profile() }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        return ModelResponse(requestID: request.requestID,
            actualProfile: VocaFixtures.profile(mismatch ? .gemma4E2B : .gemma4E4B), text: output)
    }
}

@Test @MainActor func approvedMemoriesPersistWithoutInventingUtteranceTimes() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "memory.json")
    let store = MemoryStore(url: url)
    try store.load()
    for index in 0..<6 { try store.addMemory(text: "Fixture approved detail \(index)") }
    let episode = auditEpisode()
    try store.addDialogue(text: "Fixture real excerpt", speaker: nil, utteredAt: nil, decisionID: episode.id)
    let reopened = MemoryStore(url: url)
    try reopened.load()
    #expect(reopened.records.count == 7)
    #expect(reopened.snapshot().approvedMemories.count == 4)
    #expect(reopened.snapshot().approvedMemories.allSatisfy { $0.shareApproved && $0.speaker == "wearer" && $0.utteredAt == nil })
    #expect(reopened.snapshot().dialogue.isEmpty)
    #expect(reopened.dialogue(for: episode).first?.utteredAt == nil)
    #expect(reopened.dialogue(for: episode).first?.speaker == nil)
    #expect(reopened.dialogue(for: auditEpisode()).isEmpty)
    #expect(throws: MemoryStore.Failure.self) { try reopened.addMemory(text: String(repeating: "x", count: 241)) }
}

@Test @MainActor func memoryDeletionSurvivesInterruptedCoreInvalidation() async throws {
    enum TestFailure: Error { case failedWrite }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "memory.json")
    let store = MemoryStore(url: url)
    try store.load(); try store.addMemory(text: "Fixture approved memory")
    let id = try #require(store.records.first?.id)
    let report = AuditReport(decisionID: UUID(), generationProfile: nil, status: .waitingForTranscript)
    try store.saveAudit(report, dependencies: [id])
    do { try await store.delete(sourceID: id) { _ in throw TestFailure.failedWrite }; Issue.record("Expected invalidation failure") }
    catch TestFailure.failedWrite { }
    let reopened = MemoryStore(url: url)
    try reopened.load()
    #expect(reopened.records.isEmpty)
    #expect(reopened.audits.isEmpty)
    #expect(reopened.pendingDeletionIDs == [id])
    var invalidated: [String] = []
    try await reopened.finishPendingDeletions { invalidated.append($0) }
    #expect(invalidated == [id])
    #expect(reopened.pendingDeletionIDs.isEmpty)
}

@Test @MainActor func deletingAnEpisodeErasesOnlyItsDerivedDialogueAndAudit() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MemoryStore(url: directory.appending(path: "memory.json"))
    try store.load()
    let removedID = UUID(), retainedID = UUID()
    try store.addDialogue(text: "Remove this excerpt", speaker: "wearer", utteredAt: nil, decisionID: removedID)
    try store.addDialogue(text: "Keep this excerpt", speaker: "wearer", utteredAt: nil, decisionID: retainedID)
    try store.addMemory(text: "Keep this approved memory")
    try store.saveAudit(AuditReport(decisionID: removedID, generationProfile: nil, status: .waitingForTranscript))
    try store.removeDerivedData(decisionIDs: [removedID])
    #expect(store.records.count == 2)
    #expect(store.records.contains { $0.decisionID == retainedID })
    #expect(store.records.contains { $0.kind == .personalMemory })
    #expect(store.audits.isEmpty)
}

@Test @MainActor func corruptMemoryIsPreservedAndCannotBeOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "memory.json")
    let original = Data("broken-json".utf8)
    try original.write(to: url)
    let store = MemoryStore(url: url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: MemoryStore.Failure.self) { try store.addMemory(text: "Do not overwrite") }
    #expect(try Data(contentsOf: url) == original)
}

@Test func auditWaitsForAttributableRealDialogueWithoutCallingModel() async throws {
    let model = AuditModel()
    let pipeline = AuditPipeline(model: model)
    let unknown = try await pipeline.generate(episode: auditEpisode(), dialogue: [VocaFixtures.unknownSpeakerEvidence()], cards: [auditCard])
    #expect(unknown.status == .waitingForTranscript)
    let simulated = try await pipeline.generate(episode: auditEpisode(mode: .practice),
        dialogue: [Evidence(sourceID: "practice", text: "Simulated words", speaker: "wearer")], cards: [auditCard])
    #expect(simulated.status == .waitingForTranscript)
    #expect(await model.calls == 0)
}

@Test func auditRejectsUnsupportedSourcesAndWrongProfile() async throws {
    let dialogue = [Evidence(sourceID: "real", text: "I asked about your garden.", speaker: "wearer")]
    let invalid = #"{"strength":"You asked a concrete question.","opportunity":"You could ask one follow-up.","exercise":"Ask about one detail.","sourceIDs":["invented"],"principleID":"listen-then-follow"}"#
    await #expect(throws: GeneratedFields.Failure.evidence) {
        try await AuditPipeline(model: AuditModel(output: invalid)).generate(episode: auditEpisode(), dialogue: dialogue, cards: [auditCard])
    }
    let valid = invalid.replacingOccurrences(of: "invented", with: "real")
    await #expect(throws: ModelResponseError.profileMismatch) {
        try await AuditPipeline(model: AuditModel(output: valid, mismatch: true)).generate(episode: auditEpisode(), dialogue: dialogue, cards: [auditCard])
    }
    let report = try await AuditPipeline(model: AuditModel(output: valid)).generate(episode: auditEpisode(), dialogue: dialogue, cards: [auditCard])
    #expect(report.status == .ready)
    #expect(report.sourceIDs == ["real"])
    #expect(report.generationProfile == VocaFixtures.profile())
}
