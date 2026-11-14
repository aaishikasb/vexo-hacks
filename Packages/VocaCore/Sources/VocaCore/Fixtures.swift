import Foundation

/// Synthetic data only. Never represents a real user or conversation.
public enum VocaFixtures {
    public static let simulatedLabel = "SIMULATED DATA"
    public static func profile(_ model: ModelID = .gemma4E4B, prompt: String = "cue-v1") -> ModelProfile {
        ModelProfile(modelID: model, artifactSHA256: model == .gemma4E4B ? "fixture-e4b-sha256" : "fixture-e2b-sha256", promptVersion: prompt)
    }
    public static func context(mode: SessionMode = .live, goal: Goal = .deepen, now: Date = Date(timeIntervalSince1970: 1_800_000_000), withDialogue: Bool = true, withStory: Bool = true, profile: ModelProfile? = nil) -> CueContext {
        let memories = withStory ? [Evidence(sourceID: "mem-story", text: "I built a small garden with my neighbors.", speaker: "wearer", shareApproved: true)] : []
        let dialogue = withDialogue ? [Evidence(sourceID: "turn-1", text: "I started a community garden.", speaker: "wearer", utteredAt: now.addingTimeInterval(-10))] : []
        let snapshot = MemorySnapshot(approvedMemories: memories, dialogue: dialogue, fetchedAt: now, coverage: .complete)
        let scene = SceneFacts(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, observedAt: now, setting: .cafe, observations: ["A small group is talking near the counter."], uncertain: false)
        return CueContext(decisionID: UUID(), requestedAt: now, scene: scene, goal: goal, mode: mode, profile: profile ?? self.profile(), snapshot: snapshot, knownPoint: "community garden", disabledStrategies: [])
    }
    public static func unknownSpeakerEvidence(at date: Date = Date()) -> Evidence { Evidence(sourceID: "unknown-speaker", text: "We should meet again", speaker: nil, utteredAt: date) }
    public static func staleDialogue(now: Date = Date()) -> Evidence { Evidence(sourceID: "stale-turn", text: "I like hiking", speaker: "wearer", utteredAt: now.addingTimeInterval(-31)) }
    public static func gappedDialogue() -> MemorySnapshot { MemorySnapshot(approvedMemories: [], dialogue: [], fetchedAt: Date(), coverage: .partial) }
    public static func duplicateTapIDs() -> [UUID] { let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!; return [id, id] }
    public static func interruptedSpeech(request: SpeechRequest, at date: Date = Date()) -> [VoiceEvent] { [VoiceEvent(requestID: request.requestID, sessionID: request.sessionID, generation: request.generation, kind: .started, occurredAt: date), VoiceEvent(requestID: request.requestID, sessionID: request.sessionID, generation: request.generation, kind: .cancelled, occurredAt: date.addingTimeInterval(0.2))] }
}

/// Deterministic model boundary for tests and previews; never contacts a model runtime.
public actor FixtureModelGenerator: ModelGenerating {
    public let profile: ModelProfile
    public let output: String
    public init(profile: ModelProfile = VocaFixtures.profile(), output: String = "SIMULATED DATA: What drew you to that?") { self.profile = profile; self.output = output }
    public func activeProfile() async throws -> ModelProfile { profile }
    public func generate(_ request: ModelRequest) async throws -> ModelResponse { ModelResponse(requestID: request.requestID, actualProfile: profile, text: output) }
}

/// Synthetic speech/recognition streams for lifecycle tests; no audio is captured or played.
public actor FixtureVoiceCoordinator: VoiceCoordinating {
    public var completion: VoiceEventKind
    public init(completion: VoiceEventKind = .completed) { self.completion = completion }
    public func speak(_ request: SpeechRequest) async throws -> AsyncThrowingStream<VoiceEvent, Error> {
        let terminal = completion
        return AsyncThrowingStream { continuation in
            let now = Date()
            continuation.yield(VoiceEvent(requestID: request.requestID, sessionID: request.sessionID, generation: request.generation, kind: .started, occurredAt: now))
            continuation.yield(VoiceEvent(requestID: request.requestID, sessionID: request.sessionID, generation: request.generation, kind: terminal, occurredAt: now.addingTimeInterval(0.1)))
            continuation.finish()
        }
    }
    public func cancel(sessionID: UUID) async {}
    public func startPractice(sessionID: UUID, generation: Int) async throws -> AsyncThrowingStream<PracticeTurn, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    public func stopPractice(sessionID: UUID) async {}
}

/// Reference-safe JSON resource decoder for card/scenario data.
public enum CoachingContent {
    public static let simulatedPartnerLabel = "SIMULATED PARTNER:"
    public static func decode(cards cardData: Data, scenarios scenarioData: Data) throws -> (cards: [CoachingCard], scenarios: [PracticeScenario]) {
        let cards = try JSONDecoder().decode([CoachingCard].self, from: cardData)
        let scenarios = try JSONDecoder().decode([PracticeScenario].self, from: scenarioData)
        let ids = Set(cards.map(\.id))
        guard scenarios.allSatisfy({ $0.partnerInstructions.hasPrefix(simulatedPartnerLabel) }) else { throw ContentError.missingSimulatedLabel }
        guard ids.count == cards.count, Set(scenarios.map(\.id)).count == scenarios.count,
              scenarios.allSatisfy({ !$0.principleIDs.isEmpty && $0.principleIDs.allSatisfy(ids.contains) }),
              cards.allSatisfy({ URL(string: $0.sourceURL)?.scheme == "https" && !$0.principle.isEmpty && !$0.exercise.isEmpty }) else {
            throw ContentError.invalidReferences
        }
        return (cards, scenarios)
    }
}
public enum ContentError: Error { case invalidReferences, missingSimulatedLabel }
