#if DEBUG
import Foundation
import VocaCore

/// Synthetic device checks never enter the user's history or learning store.
@MainActor enum ReviewModelCheck {
    private actor RecordingModel: ModelGenerating {
        let base: any ModelGenerating
        init(base: any ModelGenerating) { self.base = base }
        func activeProfile() async throws -> ModelProfile { try await base.activeProfile() }
        func generate(_ request: ModelRequest) async throws -> ModelResponse {
            let response = try await base.generate(request)
            try response.text.write(to: URL.documentsDirectory.appending(path: "review-fixture-output.txt"), atomically: true, encoding: .utf8)
            return response
        }
    }
    static func replayFailedCues(models: ModelLibrary) async {
        var result: [String: Any] = ["replay": true]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await models.load(modelID: "gemma4E2B")
            let history = try CoachEngine(storeURL: URL.applicationSupportDirectory.appending(path: "Voca/Coaching/episodes.json"))
            let failed = await history.episodes().filter { $0.delivery == .failed && $0.cue == nil }.suffix(5)
            let temporaryCoach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
            var checks: [[String: Any]] = []
            for episode in failed {
                let context = episode.decision.context
                do {
                    _ = try await CuePipeline(model: models.executor, coach: temporaryCoach).prepare(scene: context.scene,
                        requestedAt: context.requestedAt, goal: context.goal, knownPoint: context.knownPoint, snapshot: context.snapshot)
                    checks.append(["passed": true])
                } catch { checks.append(["passed": false, "error": error.localizedDescription]) }
            }
            result["checks"] = checks
        } catch { result["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: URL.documentsDirectory.appending(path: "failed-cue-replay.json"), options: .atomic)
        }
    }

    static func checkCueFormat(models: ModelLibrary) async {
        var result: [String: Any] = ["fixture": true, "passed": 0]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await models.load(modelID: "gemma4E2B")
            let model = RecordingModel(base: models.executor)
            let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
            var passed = 0
            for _ in 0..<5 {
                let scene = SceneFacts(requestID: UUID(), observedAt: Date(), setting: .cafe,
                    observations: ["A coffee menu and two chairs are visible."], uncertain: false)
                _ = try await CuePipeline(model: model, coach: coach).prepare(scene: scene,
                    requestedAt: Date(), goal: .enter, knownPoint: nil)
                passed += 1
                result["passed"] = passed
            }
        } catch { result["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: URL.documentsDirectory.appending(path: "cue-format-check.json"), options: .atomic)
        }
    }

    static func checkPractice(models: ModelLibrary) async {
        var result: [String: Any] = ["fixture": true, "protocol": "practice-context-v2", "checks": []]
        do {
            try await models.load(modelID: "gemma4E4B")
            let model = RecordingModel(base: models.executor)
            let profile = try await model.activeProfile()
            let scenario = PracticeScenario(id: "practice-check", title: "Meetup", setting: .event, goal: .enter,
                openingLine: "We were comparing talks.", partnerInstructions: "You attended a talk about urban gardens.", principleIDs: [])
            var context = PracticeContext()
            context.set(.audience, quote: "A technical founder")
            context.set(.relationship, quote: "We just met")
            context.set(.topic, quote: "My plant-watering robot")
            context.set(.goal, quote: "Tell a clear story about why I built it")
            let cases: [(String, [(text: String, fromUser: Bool)])] = [
                ("brief-opening", []),
                ("audience-correction", [("Actually, this founder is not technical. Please help me explain my plant-watering robot without jargon.", true)]),
                ("retained-after-window", (0..<14).map { ("We are still discussing the project, turn \($0).", $0.isMultiple(of: 2)) } +
                    [("How would you explain the idea to this person?", true)]),
                ("brief-answer", [("I was curious.", true)])
            ]
            var checks: [[String: Any]] = []
            for (stage, messages) in cases {
                let start = Date()
                let request = try context.request(scenario: scenario, direction: "",
                    messages: messages, profile: profile)
                let latestUserText = messages.last(where: \.fromUser)?.text ?? ""
                let generated = try await ValidatedGeneration.run(request, model: model) {
                    try PracticeContext.decode($0, latestUserText: latestUserText)
                }
                if !latestUserText.isEmpty {
                    let turn = PracticeTurn(id: UUID(), sessionID: UUID(), generation: 0, text: latestUserText, isFinal: true)
                    context.apply(generated.value.updates, turn: turn, profile: generated.profile)
                }
                checks.append(["stage": stage, "reply": generated.value.text,
                               "updatedFields": generated.value.updates.map { $0.field.rawValue },
                               "retainedAudience": context.entries[.audience]?.quote ?? "",
                               "seconds": Date().timeIntervalSince(start), "model": generated.profile.modelID.rawValue])
                result["checks"] = checks
                if stage == "audience-correction" || stage == "retained-after-window" {
                    guard context.entries[.audience]?.quote.contains("not technical") == true else {
                        result["error"] = "Audience correction was not retained in the audience field."
                        break
                    }
                }
            }
        } catch { result["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "practice-model-check.json"), options: .atomic)
        }
    }

    static func run(models: ModelLibrary) async {
        var result: [String: Any] = ["fixture": true, "auditPassed": false, "practicePassed": false]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            result["stage"] = "load"
            try await models.load(modelID: "gemma4E4B")
            let model = RecordingModel(base: models.executor)
            let profile = try await model.activeProfile()
            let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
            let context = VocaFixtures.context(profile: profile)
            guard let decision = try await coach.selectCue(context, explore: false) else { return }
            let episode = Episode(decision: decision)
            result["stage"] = "content"
            let cardsURL = Bundle.main.url(forResource: "coaching-cards", withExtension: "json")!
            let cards = try JSONDecoder().decode([CoachingCard].self, from: Data(contentsOf: cardsURL))
            let started = Date()
            result["stage"] = "audit"
            let audit = try await AuditPipeline(model: model).generate(episode: episode,
                dialogue: [Evidence(sourceID: "fixture-wearer", text: "I asked which part of gardening they enjoy most and waited for their answer.", speaker: "wearer", utteredAt: nil)], cards: cards)
            result["auditPassed"] = audit.status == .ready
            result["auditSeconds"] = Date().timeIntervalSince(started)
            result["stage"] = "practice"
            let request = ModelRequest(requestID: UUID(), kind: .practice, requestedProfile: profile,
                prompt: "You are a simulated cafe conversation partner. Reply to 'I enjoy growing tomatoes' with one friendly question. Return only JSON with one text field, at most 60 words.", maxOutputTokens: 160, responseSchemaJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#)
            let response = try await model.generate(request)
            try response.validate(for: request)
            _ = try PracticeTurnGate.reply(response.text)
            result["practicePassed"] = true
        } catch { result["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: URL.documentsDirectory.appending(path: "review-model-check.json"), options: .atomic)
        }
    }
}
#endif
