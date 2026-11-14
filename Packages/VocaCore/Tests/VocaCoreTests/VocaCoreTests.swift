import Foundation
import XCTest
@testable import VocaCore

final class VocaCoreTests: XCTestCase {
    private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("voca-\(UUID().uuidString).json") }
    private func makeContext(_ mode: SessionMode = .live, goal: Goal = .deepen, profile: ModelProfile? = nil, dialogue: Bool = true, story: Bool = true) -> CueContext {
        VocaFixtures.context(mode: mode, goal: goal, withDialogue: dialogue, withStory: story, profile: profile)
    }
    private func selected(_ engine: CoachEngine, _ context: CueContext, excluding: Strategy? = nil) async throws -> CueDecision {
        let value = try await engine.selectCue(context, explore: false, excluding: excluding)
        return try XCTUnwrap(value)
    }
    private func completedDecision(_ engine: CoachEngine, context: CueContext) async throws -> CueDecision {
        let d = try await selected(engine, context)
        let cue = CueResult(decisionID: d.context.decisionID, actualProfile: d.context.profile, strategy: d.selectedAction, text: "Ask what drew them to it.", sourceIDs: d.context.snapshot.dialogue.map(\.sourceID))
        try await engine.recordDelivery(decisionID: d.context.decisionID, cue: cue, status: .completed)
        return d
    }

    func testCanonicalFeatureOrderAndMasks() throws {
        let c = makeContext(.live, goal: .deepen)
        XCTAssertEqual(CoachEngine.features(for: c), [1,1,0,0,0,0,1,0,1,1])
        XCTAssertEqual(Set(Strategy.allCases), Set([.followUp,.personalConnection,.explainClearly,.reflectClarify,.situationalOpener]))
        let stale = VocaFixtures.staleDialogue(now: c.requestedAt)
        let s = MemorySnapshot(approvedMemories: [], dialogue: [stale, VocaFixtures.unknownSpeakerEvidence(at: c.requestedAt)], fetchedAt: c.requestedAt, coverage: .partial)
        let modified = CueContext(decisionID: UUID(), requestedAt: c.requestedAt, scene: c.scene, goal: c.goal, mode: c.mode, profile: c.profile, snapshot: s, knownPoint: nil)
        XCTAssertEqual(CoachEngine.features(for: modified)[9], 0)
        let partner = Evidence(sourceID: "partner-turn", text: "I started pottery last month", speaker: "partner-1", utteredAt: c.requestedAt.addingTimeInterval(-5))
        let partnerSnapshot = MemorySnapshot(approvedMemories: [], dialogue: [partner], fetchedAt: c.requestedAt, coverage: .complete)
        var partnerContext = modified; partnerContext.snapshot = partnerSnapshot
        XCTAssertEqual(CoachEngine.features(for: partnerContext)[9], 1)
    }

    func testUnavailableDisabledNoActionAndAlternativeExclusion() async throws {
        let engine = try CoachEngine(storeURL: tempURL())
        var c = makeContext(.live, goal: .deepen, dialogue: false, story: false); c.knownPoint = nil
        let noAction = try await engine.selectCue(c, explore: false, excluding: nil)
        XCTAssertNil(noAction)
        var open = makeContext(.live, goal: .enter, dialogue: false, story: false); open.knownPoint = nil
        open.disabledStrategies = [.situationalOpener]
        let disabled = try await engine.selectCue(open, explore: false, excluding: nil)
        XCTAssertNil(disabled)
        let d = try await selected(engine, makeContext(), excluding: nil)
        if d.eligibleActions.count > 1 {
            let alt = try await selected(engine, makeContext(), excluding: d.selectedAction)
            XCTAssertNotEqual(alt.selectedAction, d.selectedAction)
        }
    }

    func testDuplicateDecisionIDRejectedAndUnapprovedMemorySourceRejected() async throws {
        let engine = try CoachEngine(storeURL: tempURL())
        let context = makeContext()
        _ = try await selected(engine, context)
        do { _ = try await engine.selectCue(context, explore: false, excluding: nil); XCTFail("duplicate decision ID accepted") } catch CoachEngineError.duplicateDecision {}

        var unapproved = makeContext()
        unapproved.snapshot.approvedMemories[0].shareApproved = false
        let decision = try await selected(engine, unapproved)
        let cue = CueResult(decisionID: decision.context.decisionID, actualProfile: decision.context.profile, strategy: decision.selectedAction, text: "A grounded short cue.", sourceIDs: ["mem-story"])
        do { try await engine.recordDelivery(decisionID: decision.context.decisionID, cue: cue, status: .completed); XCTFail("unapproved memory source accepted") } catch CoachEngineError.invalidEvidenceReferences {}
    }

    func testExplainCueMustCiteWearerProvidedKnownPoint() async throws {
        let engine = try CoachEngine(storeURL: tempURL())
        var missingCitation = makeContext(.live, goal: .explain, dialogue: false, story: false)
        missingCitation.knownPointSourceID = nil
        let none = try await engine.selectCue(missingCitation, explore: false, excluding: nil)
        XCTAssertNil(none)

        var context = missingCitation
        context.decisionID = UUID()
        context.knownPointSourceID = "known-point:\(context.decisionID.uuidString)"
        let decision = try await selected(engine, context)
        XCTAssertEqual(decision.selectedAction, .explainClearly)
        let photoOnly = CueResult(decisionID: decision.context.decisionID, actualProfile: context.profile,
            strategy: .explainClearly, text: "Explain the point you entered clearly.", sourceIDs: [context.scene.requestID.uuidString])
        do { try await engine.recordDelivery(decisionID: decision.context.decisionID, cue: photoOnly, status: .completed); XCTFail("photo was accepted as source for wearer input") } catch CoachEngineError.invalidEvidenceReferences {}
        let attributed = CueResult(decisionID: decision.context.decisionID, actualProfile: context.profile,
            strategy: .explainClearly, text: "Explain the point you entered clearly.", sourceIDs: [context.knownPointSourceID!])
        try await engine.recordDelivery(decisionID: decision.context.decisionID, cue: attributed, status: .completed)
        let episodes = await engine.episodes()
        XCTAssertEqual(episodes.first?.cue?.sourceIDs, [context.knownPointSourceID!])
    }

    func testSignedUpdateNumericFeedbackReplayAndProfileSeparation() async throws {
        let url = tempURL(), profile = VocaFixtures.profile()
        let engine = try CoachEngine(storeURL: url)
        var c = makeContext(.live, goal: .deepen, profile: profile)
        c.snapshot = MemorySnapshot(approvedMemories: [], dialogue: [Evidence(sourceID: "d", text: "I like it", speaker: "wearer", utteredAt: c.requestedAt)], fetchedAt: c.requestedAt, coverage: .complete)
        c.knownPoint = nil
        let d = try await completedDecision(engine, context: c)
        let reward = FeedbackEvent(decisionID: d.context.decisionID, verdict: .helpful, revision: 1)
        try await engine.applyFeedback(reward)
        var nextContext = c; nextContext.decisionID = UUID()
        let next = try await selected(engine, nextContext, excluding: nil)
        XCTAssertEqual(next.utilities[d.selectedAction.rawValue]!, 0.8, accuracy: 1e-9)
        XCTAssertEqual(d.features.filter { $0 == 1 }.count, 4)

        let e2 = try await selected(engine, makeContext(.live, goal: .deepen, profile: VocaFixtures.profile(.gemma4E2B)), excluding: nil)
        XCTAssertEqual(e2.utilities[d.selectedAction.rawValue], 0)
        let practice = try await selected(engine, makeContext(.practice, goal: .deepen, profile: profile), excluding: nil)
        XCTAssertEqual(practice.utilities[d.selectedAction.rawValue], 0)

        let reopened = try CoachEngine(storeURL: url)
        var relaunchContext = c; relaunchContext.decisionID = UUID()
        let relaunch = try await selected(reopened, relaunchContext, excluding: nil)
        XCTAssertEqual(relaunch.utilities[d.selectedAction.rawValue]!, 0.8, accuracy: 1e-9)
        let bad = FeedbackEvent(decisionID: d.context.decisionID, verdict: .unhelpful, revision: 1)
        do { try await reopened.applyFeedback(bad); XCTFail("stale revision must fail") } catch CoachEngineError.staleFeedback {}
        try await reopened.applyFeedback(FeedbackEvent(decisionID: d.context.decisionID, verdict: .unhelpful, revision: 2))
        var correctedContext = c; correctedContext.decisionID = UUID()
        let corrected = try await selected(reopened, correctedContext, excluding: nil)
        XCTAssertEqual(corrected.utilities[d.selectedAction.rawValue]!, -0.8, accuracy: 1e-9)
        // Original E4B feedback still trains its frozen namespace after E2B selection.
        XCTAssertEqual(corrected.context.profile, profile)
    }

    func testDeliveryValidationIdempotencyAndFeedbackNoOps() async throws {
        let engine = try CoachEngine(storeURL: tempURL()), c = makeContext()
        let d = try await selected(engine, c, excluding: nil)
        let cue = CueResult(decisionID: d.context.decisionID, actualProfile: d.context.profile, strategy: d.selectedAction, text: "A cue", sourceIDs: ["made-up"])
        do { try await engine.recordDelivery(decisionID: d.context.decisionID, cue: cue, status: .completed); XCTFail("bad evidence accepted") } catch CoachEngineError.invalidEvidenceReferences {}
        let valid = CueResult(decisionID: d.context.decisionID, actualProfile: d.context.profile, strategy: d.selectedAction, text: "A cue", sourceIDs: [])
        try await engine.recordDelivery(decisionID: d.context.decisionID, cue: valid, status: .completed)
        try await engine.recordDelivery(decisionID: d.context.decisionID, cue: valid, status: .completed)
        do { try await engine.recordDelivery(decisionID: d.context.decisionID, cue: valid, status: .failed); XCTFail("terminal conflict accepted") } catch CoachEngineError.conflictingTerminalDelivery {}
        try await engine.applyFeedback(FeedbackEvent(decisionID: d.context.decisionID, verdict: .invalidEvidence, revision: 1))
        var sameContext = c; sameContext.decisionID = UUID()
        let same = try await selected(engine, sameContext, excluding: nil)
        XCTAssertEqual(same.utilities[d.selectedAction.rawValue], 0)
    }

    func testCueAttributionDeliveryFailuresAndEvidenceDeletion() async throws {
        let url = tempURL(), engine = try CoachEngine(storeURL: url), c = makeContext()
        let d = try await selected(engine, c)
        let wrongModel = CueResult(decisionID: d.context.decisionID, actualProfile: VocaFixtures.profile(.gemma4E2B), strategy: d.selectedAction, text: "Cue", sourceIDs: [])
        do { try await engine.recordDelivery(decisionID: d.context.decisionID, cue: wrongModel, status: .completed); XCTFail("model substitution accepted") } catch CoachEngineError.invalidCue {}
        let wrongStrategy = CueResult(decisionID: d.context.decisionID, actualProfile: d.context.profile, strategy: .personalConnection, text: "Cue", sourceIDs: [])
        do { try await engine.recordDelivery(decisionID: d.context.decisionID, cue: wrongStrategy, status: .completed); XCTFail("strategy mismatch accepted") } catch CoachEngineError.invalidCue {}
        try await engine.recordDelivery(decisionID: d.context.decisionID, cue: nil, status: .cancelled)
        do { try await engine.applyFeedback(FeedbackEvent(decisionID: d.context.decisionID, verdict: .helpful, revision: 1)); XCTFail("cancelled cue trained") } catch CoachEngineError.invalidFeedback {}

        let pendingDecision = try await selected(engine, makeContext())
        try await engine.recordDelivery(decisionID: pendingDecision.context.decisionID, cue: nil, status: .pending)
        do { try await engine.applyFeedback(FeedbackEvent(decisionID: pendingDecision.context.decisionID, verdict: .helpful, revision: 1)); XCTFail("pending cue trained") } catch CoachEngineError.invalidFeedback {}
        let failedDecision = try await selected(engine, makeContext())
        try await engine.recordDelivery(decisionID: failedDecision.context.decisionID, cue: nil, status: .failed)
        do { try await engine.applyFeedback(FeedbackEvent(decisionID: failedDecision.context.decisionID, verdict: .helpful, revision: 1)); XCTFail("failed cue trained") } catch CoachEngineError.invalidFeedback {}

        let c2 = makeContext(), d2 = try await selected(engine, c2)
        let cue2 = CueResult(decisionID: d2.context.decisionID, actualProfile: d2.context.profile, strategy: d2.selectedAction, text: "Cue", sourceIDs: ["turn-1"])
        try await engine.recordDelivery(decisionID: d2.context.decisionID, cue: cue2, status: .completed)
        try await engine.applyFeedback(FeedbackEvent(decisionID: d2.context.decisionID, verdict: .helpful, revision: 1))
        try await engine.deleteEvidence(sourceID: "turn-1")
        let remaining = await engine.episodes()
        XCTAssertFalse(remaining.contains { $0.id == d2.context.decisionID })
        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(persisted.contains("I started a community garden."))
        do { try await engine.applyFeedback(FeedbackEvent(decisionID: d2.context.decisionID, verdict: .unhelpful, revision: 2)); XCTFail("deleted evidence retrained") } catch CoachEngineError.unknownDecision {}
        do { _ = try await engine.selectCue(c2, explore: false, excluding: nil); XCTFail("deleted evidence reused") } catch CoachEngineError.invalidEvidenceReferences {}
    }

    func testContentDecodesAndReferencesAreValid() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cards = try Data(contentsOf: base.appendingPathComponent("Resources/CoachingCards/coaching-cards.json"))
        let scenarios = try Data(contentsOf: base.appendingPathComponent("Resources/PracticeScenarios/practice-scenarios.json"))
        let decoded = try CoachingContent.decode(cards: cards, scenarios: scenarios)
        XCTAssertEqual(decoded.scenarios.count, 3)
        XCTAssertEqual(decoded.cards.count, 9)
        XCTAssertEqual(Set(decoded.cards.map(\.bookTitle)), Set(["The Communication Book", "The Art of Witty Banter", "How to Listen with Intention", "Thanks for the Feedback", "The Decision Book", "Show Your Work!", "Radical Candor", "Read People Like a Book", "The Well-Spoken Thesaurus"]))
        let invalid = String(decoding: scenarios, as: UTF8.self).replacingOccurrences(of: "listen-then-follow", with: "missing-card")
        XCTAssertThrowsError(try CoachingContent.decode(cards: cards, scenarios: Data(invalid.utf8)))
    }

    func testVoiceFixtureInterruptedNeverMeansCompletion() {
        let request = SpeechRequest(requestID: UUID(), sessionID: UUID(), generation: 4, decisionID: UUID(), profile: VocaFixtures.profile(), mode: .live, text: "Short cue")
        let events = VocaFixtures.interruptedSpeech(request: request)
        XCTAssertEqual(events.map(\.kind), [.started, .cancelled])
        XCTAssertFalse(events.contains { $0.kind == .completed })
        XCTAssertEqual(VocaFixtures.duplicateTapIDs()[0], VocaFixtures.duplicateTapIDs()[1])
        XCTAssertEqual(VocaFixtures.gappedDialogue().coverage, .partial)
    }

    func testModelResponseRejectsSubstitutionAndWrongRequest() throws {
        let request = ModelRequest(requestID: UUID(), decisionID: UUID(), kind: .cue, requestedProfile: VocaFixtures.profile(), prompt: "fixture", maxOutputTokens: 32)
        XCTAssertNoThrow(try ModelResponse(requestID: request.requestID, actualProfile: request.requestedProfile, text: "Cue").validate(for: request))
        XCTAssertThrowsError(try ModelResponse(requestID: request.requestID, actualProfile: VocaFixtures.profile(.gemma4E2B), text: "Cue").validate(for: request)) { XCTAssertEqual($0 as? ModelResponseError, .profileMismatch) }
        XCTAssertThrowsError(try ModelResponse(requestID: UUID(), actualProfile: request.requestedProfile, text: "Cue").validate(for: request)) { XCTAssertEqual($0 as? ModelResponseError, .requestMismatch) }
    }

    func testFixtureServicesAreDeterministicAndLabelled() async throws {
        let generator = FixtureModelGenerator(), request = ModelRequest(requestID: UUID(), kind: .cue, requestedProfile: VocaFixtures.profile(), prompt: "fixture", maxOutputTokens: 12)
        let response = try await generator.generate(request)
        try response.validate(for: request)
        XCTAssertTrue(response.text.contains(VocaFixtures.simulatedLabel))
        let voice = FixtureVoiceCoordinator(completion: .cancelled)
        let speech = SpeechRequest(requestID: UUID(), sessionID: UUID(), generation: 1, decisionID: nil, profile: request.requestedProfile, mode: .practice, text: "fixture")
        let stream = try await voice.speak(speech)
        var events: [VoiceEventKind] = []
        for try await event in stream { events.append(event.kind) }
        XCTAssertEqual(events, [.started, .cancelled])
    }
}
