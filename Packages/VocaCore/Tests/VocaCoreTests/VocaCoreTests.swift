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

    func testPendingCuePersistsAndRecoveryCancellationRetainsItWithoutReward() async throws {
        let url = tempURL(), engine = try CoachEngine(storeURL: url), context = makeContext()
        let decision = try await selected(engine, context)
        let cue = CueResult(decisionID: decision.context.decisionID, actualProfile: decision.context.profile,
            strategy: decision.selectedAction, text: "A grounded cue survives a relaunch.",
            sourceIDs: decision.context.snapshot.dialogue.map(\.sourceID))
        try await engine.recordDelivery(decisionID: decision.context.decisionID, cue: cue, status: .pending)
        try await engine.recordDelivery(decisionID: decision.context.decisionID, cue: cue, status: .pending)
        let relaunched = try CoachEngine(storeURL: url)
        try await relaunched.recordDelivery(decisionID: decision.context.decisionID, cue: nil, status: .cancelled)
        try await relaunched.recordDelivery(decisionID: decision.context.decisionID, cue: nil, status: .cancelled)
        let persistedEpisodes = await relaunched.episodes()
        let episode = try XCTUnwrap(persistedEpisodes.first)
        XCTAssertEqual(episode.cue, cue)
        XCTAssertEqual(episode.delivery, .cancelled)
        do { try await relaunched.applyFeedback(FeedbackEvent(decisionID: decision.context.decisionID, verdict: .helpful, revision: 1)); XCTFail("recovered interrupted cue trained") } catch CoachEngineError.invalidFeedback {}
    }

    func testLatePendingCannotMutateTerminalDelivery() async throws {
        for status in [DeliveryStatus.cancelled, .failed, .completed] {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = try CoachEngine(storeURL: url), context = makeContext()
            let decision = try await selected(engine, context)
            let cue = CueResult(decisionID: context.decisionID, actualProfile: context.profile,
                strategy: decision.selectedAction, text: "A grounded cue.", sourceIDs: ["turn-1"])
            try await engine.recordDelivery(decisionID: context.decisionID,
                cue: status == .completed ? cue : nil, status: status)
            let before = await engine.episodes()
            for lateCue in [cue, nil] as [CueResult?] {
                do {
                    try await engine.recordDelivery(decisionID: context.decisionID, cue: lateCue, status: .pending)
                    XCTFail("Pending update accepted after terminal delivery")
                } catch CoachEngineError.conflictingTerminalDelivery {}
            }
            let after = await engine.episodes()
            XCTAssertEqual(after, before)
            let reopened = try CoachEngine(storeURL: url)
            let persisted = await reopened.episodes()
            XCTAssertEqual(persisted, before)
            try await engine.recordDelivery(decisionID: context.decisionID, cue: nil, status: status)
        }
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

    func testDelayedE4BFeedbackWhileE2BActiveAndCorrectedReplaySurvivesRelaunch() async throws {
        let url = tempURL(), e4b = VocaFixtures.profile(.gemma4E4B), e2b = VocaFixtures.profile(.gemma4E2B)
        let engine = try CoachEngine(storeURL: url)
        var originalContext = makeContext(.live, goal: .deepen, profile: e4b, dialogue: true, story: false)
        originalContext.knownPoint = nil
        let original = try await completedDecision(engine, context: originalContext)

        var e2bContext = originalContext; e2bContext.decisionID = UUID(); e2bContext.profile = e2b
        let activeE2B = try await selected(engine, e2bContext)
        try await engine.applyFeedback(FeedbackEvent(decisionID: original.context.decisionID, verdict: .helpful, revision: 1))

        var verifyE4B = originalContext; verifyE4B.decisionID = UUID()
        let e4bAfterDelayedFeedback = try await selected(engine, verifyE4B)
        XCTAssertEqual(e4bAfterDelayedFeedback.utilities[original.selectedAction.rawValue]!, 0.8, accuracy: 1e-9)
        var verifyE2B = e2bContext; verifyE2B.decisionID = UUID()
        let e2bUnaffected = try await selected(engine, verifyE2B)
        XCTAssertEqual(e2bUnaffected.utilities[original.selectedAction.rawValue], 0)
        XCTAssertEqual(activeE2B.context.profile, e2b)

        try await engine.applyFeedback(FeedbackEvent(decisionID: original.context.decisionID, verdict: .unhelpful, revision: 2))
        let reopened = try CoachEngine(storeURL: url)
        var relaunchE4B = originalContext; relaunchE4B.decisionID = UUID()
        let correctedE4B = try await selected(reopened, relaunchE4B)
        XCTAssertEqual(correctedE4B.utilities[original.selectedAction.rawValue]!, -0.8, accuracy: 1e-9)
        var relaunchE2B = e2bContext; relaunchE2B.decisionID = UUID()
        let correctedE2B = try await selected(reopened, relaunchE2B)
        XCTAssertEqual(correctedE2B.utilities[original.selectedAction.rawValue], 0)
    }

    func testFailedPersistenceRollsBackFeedbackAndPreservesLastStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = directory.appendingPathExtension("backup")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: backup)
        }
        let url = directory.appendingPathComponent("episodes.json")
        let engine = try CoachEngine(storeURL: url)
        let context = makeContext(story: false)
        let decision = try await completedDecision(engine, context: context)
        let before = await engine.episodes()
        let saved = try Data(contentsOf: url)
        // Block the parent path deterministically, without relying on filesystem permissions.
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data().write(to: directory)
        let feedback = FeedbackEvent(decisionID: context.decisionID, verdict: .helpful, revision: 1)
        do {
            try await engine.applyFeedback(feedback)
            XCTFail("Failed write accepted feedback")
        } catch CoachEngineError.persistenceFailure {}
        let after = await engine.episodes()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("episodes.json")), saved)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        try await engine.applyFeedback(feedback)
        let reopened = try CoachEngine(storeURL: url)
        var next = context; next.decisionID = UUID()
        let learned = try await selected(reopened, next)
        XCTAssertEqual(learned.utilities[decision.selectedAction.rawValue]!, 0.8, accuracy: 1e-9)
    }

    func testArtifactAndPromptNamespacesAndDuplicateFeedback() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try CoachEngine(storeURL: url)
        let context = makeContext(story: false)
        let decision = try await completedDecision(engine, context: context)
        let feedback = FeedbackEvent(decisionID: context.decisionID, verdict: .helpful, revision: 1)
        try await engine.applyFeedback(feedback)
        try await engine.applyFeedback(feedback)
        let reopened = try CoachEngine(storeURL: url)
        var next = context; next.decisionID = UUID()
        let learned = try await selected(reopened, next)
        XCTAssertEqual(learned.utilities[decision.selectedAction.rawValue]!, 0.8, accuracy: 1e-9)
        for changeArtifact in [true, false] {
            var other = context; other.decisionID = UUID()
            if changeArtifact { other.profile.artifactSHA256 = "different-artifact" }
            else { other.profile.promptVersion = "different-prompt" }
            let isolated = try await selected(reopened, other)
            XCTAssertTrue(isolated.utilities.values.allSatisfy { $0 == 0 })
        }
        try await reopened.applyFeedback(FeedbackEvent(decisionID: context.decisionID, verdict: .notTried, revision: 2))
        var corrected = context; corrected.decisionID = UUID()
        let noReward = try await selected(reopened, corrected)
        XCTAssertTrue(noReward.utilities.values.allSatisfy { $0 == 0 })
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
        let unlabelled = String(decoding: scenarios, as: UTF8.self).replacingOccurrences(of: "SIMULATED PARTNER: ", with: "PARTNER: ")
        XCTAssertThrowsError(try CoachingContent.decode(cards: cards, scenarios: Data(unlabelled.utf8))) { XCTAssertTrue($0 is ContentError) }
    }

    func testAuditReadyRequiresAttributableWearerSourceAndWaitingHasNoClaims() throws {
        let decisionID = UUID(), profile = VocaFixtures.profile()
        let wearer = Evidence(sourceID: "wearer-1", text: "I helped organize the garden", speaker: "wearer")
        let partner = Evidence(sourceID: "partner-1", text: "That sounds interesting", speaker: "partner-1")
        let valid = AuditReport(decisionID: decisionID, generationProfile: profile, status: .ready,
            strength: "You described one concrete action.", opportunity: "You could add what you learned.",
            exercise: "Try the explanation in two sentences.", sourceIDs: [wearer.sourceID], principleID: "clear-one-idea")
        XCTAssertNoThrow(try AuditReportValidator.validate(valid, decisionID: decisionID,
            dialogue: [partner, wearer], knownPrincipleIDs: ["clear-one-idea"]))

        var wrongSource = valid; wrongSource.sourceIDs = [partner.sourceID]
        XCTAssertThrowsError(try AuditReportValidator.validate(wrongSource, decisionID: decisionID,
            dialogue: [partner, wearer], knownPrincipleIDs: ["clear-one-idea"])) { XCTAssertEqual($0 as? AuditValidationError, .invalidSourceReferences) }
        XCTAssertThrowsError(try AuditReportValidator.validate(valid, decisionID: decisionID,
            dialogue: [partner], knownPrincipleIDs: ["clear-one-idea"])) { XCTAssertEqual($0 as? AuditValidationError, .noAttributableWearerEvidence) }

        let waiting = AuditReport(decisionID: decisionID, generationProfile: nil, status: .waitingForTranscript)
        XCTAssertNoThrow(try AuditReportValidator.validate(waiting, decisionID: decisionID, dialogue: [], knownPrincipleIDs: []))
        var unsupported = waiting; unsupported.opportunity = "Try asking a question."
        XCTAssertThrowsError(try AuditReportValidator.validate(unsupported, decisionID: decisionID, dialogue: [], knownPrincipleIDs: [])) { XCTAssertEqual($0 as? AuditValidationError, .waitingContainsClaims) }
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
