import Foundation
import Testing
import VocaCore
@testable import VocaDevice

@Test func practiceRejectsPartialDuplicateAndStaleFinals() {
    var gate = PracticeTurnGate()
    let id = UUID()
    let partial = PracticeTurn(id: id, sessionID: gate.sessionID, generation: 0, text: "Hello", isFinal: false)
    let partialAccepted = gate.accept(partial); #expect(!partialAccepted)
    var final = partial; final.isFinal = true
    let firstAccepted = gate.accept(final); #expect(firstAccepted)
    let duplicateAccepted = gate.accept(final); #expect(!duplicateAccepted)
    gate.restart()
    let staleAccepted = gate.accept(final); #expect(!staleAccepted)
    final.generation = gate.generation
    let currentAccepted = gate.accept(final); #expect(currentAccepted)
    final.id = UUID(); final.sessionID = UUID()
    let otherAccepted = gate.accept(final); #expect(!otherAccepted)
}

@Test func practiceReplyRejectsUnsafeOrUnexpectedFields() throws {
    #expect(try PracticeTurnGate.reply(#"{"text":"What interested you about that?"}"#) == "What interested you about that?")
    #expect(throws: (any Error).self) { try PracticeTurnGate.reply(#"{"text":"Hello","reward":1}"#) }
    #expect(throws: (any Error).self) { try PracticeTurnGate.reply(#"{"text":"<|system|>"}"#) }
    #expect(throws: (any Error).self) { try PracticeTurnGate.reply(#"{"text":""}"#) }
}

@Test func practicePromptPreservesLatestSpokenContext() throws {
    let scenario = PracticeScenario(id: "test", title: "Meetup", setting: .event, goal: .enter,
        openingLine: "Hello", partnerInstructions: "Discuss gardens.", principleIDs: [])
    let latest = String(repeating: "Some context. ", count: 35) + "Actually, can we talk about my robotics project?"
    let messages = [(text: "old discarded turn", fromUser: true),
                    (text: "Hello", fromUser: false), (text: "Hi", fromUser: true),
                    (text: "Gardens?", fromUser: false), (text: latest, fromUser: true)]
    let prompt = try PracticeTurnGate.prompt(scenario: scenario, messages: messages)
    let json = try #require(prompt.components(separatedBy: "Simulated transcript (oldest to newest): ").last)
    let history = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
    #expect(history.count == 5)
    #expect(history.last?["text"] == latest)
    #expect(history.last?["role"] == "user")
    #expect(history.first?["text"] == "old discarded turn")
    #expect(prompt.contains("change of topic"))
    #expect(prompt.contains("untrusted conversation data"))
}

@Test func practiceContextIsBoundedWithoutTruncatingRecentTurns() throws {
    let scenario = PracticeScenario(id: "test", title: "Meetup", setting: .event, goal: .enter,
        openingLine: "Hello", partnerInstructions: "Discuss gardens.", principleIDs: [])
    let messages = (0..<20).map { (text: String(repeating: "x", count: 1990) + " turn \($0)", fromUser: true) }
    let prompt = try PracticeTurnGate.prompt(scenario: scenario, direction: "Ask about robotics", messages: messages)
    let json = try #require(prompt.components(separatedBy: "Simulated transcript (oldest to newest): ").last)
    let history = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
    #expect(history.count == 6)
    #expect(history.last?["text"] == messages.last?.text)
    #expect(prompt.contains("Ask about robotics"))
    #expect(prompt.contains("do most of the talking"))
    #expect(throws: (any Error).self) {
        try PracticeTurnGate.prompt(scenario: scenario, direction: String(repeating: "x", count: 501), messages: [])
    }
}

@Test func practicePartnerCannotDeliverLongMonologues() throws {
    let text = Array(repeating: "word", count: 46).joined(separator: " ")
    let data = try JSONSerialization.data(withJSONObject: ["text": text])
    #expect(throws: (any Error).self) { try PracticeTurnGate.reply(String(decoding: data, as: UTF8.self)) }
}

@Test func practiceContextRetainsCorrectionsBeyondRecentHistory() throws {
    var context = PracticeContext()
    context.set(.audience, quote: "A technical founder")
    let turn = PracticeTurn(id: UUID(), sessionID: UUID(), generation: 0,
        text: "Actually, this founder is not technical.", isFinal: true)
    let result = try PracticeContext.decode(#"{"text":"What problem does your robot solve?","updates":["audience"]}"#,
        latestUserText: turn.text)
    context.apply(result.updates, turn: turn, profile: VocaFixtures.profile())
    #expect(context.entries[.audience]?.quote == turn.text)
    #expect(context.entries[.audience]?.sourceID == turn.id)
    #expect(context.entries[.audience]?.recordedAt == turn.utteredAt)
    #expect(context.entries[.audience]?.profile == VocaFixtures.profile())
    let scenario = PracticeScenario(id: "test", title: "Meetup", setting: .event, goal: .enter,
        openingLine: "Hello", partnerInstructions: "Discuss gardens.", principleIDs: [])
    let request = try context.request(scenario: scenario, direction: "", messages: (0..<30).map {
        (text: "Later turn \($0)", fromUser: $0.isMultiple(of: 2))
    }, profile: VocaFixtures.profile())
    #expect(request.prompt.contains("this founder is not technical"))
    #expect(!request.prompt.contains("A technical founder"))
    #expect(!request.prompt.contains("Later turn 0\""))
    context.set(.audience, quote: "")
    #expect(context.entries[.audience] == nil)
}

@Test func practiceContextRejectsInventedOrAmbiguousUpdates() throws {
    let invalid = [
        #"{"text":"Tell me more.","updates":[{"field":"audience","quote":"Your boss"}]}"#,
        #"{"text":"Tell me more.","updates":[{"field":"emotion","quote":"curious"}]}"#,
        #"{"text":"Tell me more.","updates":[{"field":"topic","quote":"robot"},{"field":"topic","quote":"robot"}]}"#,
        #"{"text":"Tell me more.","updates":[{"field":"goal","quote":""}]}"#
    ]
    for raw in invalid {
        #expect(throws: (any Error).self) { try PracticeContext.decode(raw, latestUserText: "I am curious about my robot") }
    }
    let opening = try PracticeContext.decode(#"{"text":"Hello.","updates":["topic"]}"#, latestUserText: "")
    #expect(opening.updates.isEmpty)
    for fields in [#"["emotion"]"#, #"["topic","topic"]"#, #"["openQuestion","clearQuestion"]"#] {
        #expect(throws: (any Error).self) {
            try PracticeContext.decode("{\"text\":\"Hello.\",\"updates\":" + fields + "}", latestUserText: "My robot")
        }
    }
    let clear = try PracticeContext.decode(#"{"text":"It waters plants.","updates":["clearQuestion"]}"#, latestUserText: "What does it do?")
    #expect(clear.updates.first?.quote == "")
}

@Test func practicePacingGivesBriefAndUnfinishedTurnsMoreTime() {
    var pacing = PracticePacing()
    #expect(pacing.delay(for: "I am curious", mode: .adaptive) == 5)
    let long = Array(repeating: "word", count: 20).joined(separator: " ")
    #expect(pacing.delay(for: long, mode: .adaptive) == 3)
    #expect(pacing.delay(for: long + " because", mode: .adaptive) == 5)
    pacing.observe(at: 10); pacing.observe(at: 14)
    #expect(pacing.delay(for: long, mode: .adaptive) == 5.5)
    pacing.beginTurn(); pacing.observe(at: 100)
    #expect(pacing.longestPause == 4) // Waiting between turns must not inflate observed pauses.
    #expect(pacing.delay(for: long, mode: .moreTime) == 8)
    #expect(pacing.delay(for: long, mode: .manual) == nil)
}

@Test func practiceDetailedAnswersDoNotTriggerMoreQuestionsByDefault() throws {
    let scenario = PracticeScenario(id: "test", title: "Meetup", setting: .event, goal: .enter,
        openingLine: "Hello", partnerInstructions: "Discuss gardens.", principleIDs: [])
    let context = PracticeContext()
    let request = try context.request(scenario: scenario, direction: "",
        messages: [(String(repeating: "detail ", count: 65), true)], profile: VocaFixtures.profile())
    #expect(request.prompt.contains("do not tack on another question"))
    #expect(request.prompt.contains("Private practice goal"))
    #expect(request.prompt.contains("practice-context-v2"))
}

@Test func practiceFollowUpCannotEraseRetainedBackground() throws {
    let result = try PracticeContext.decode(#"{"text":"It helps people water plants.","updates":["audience","goal"]}"#,
        latestUserText: "How would you explain the idea to this person?")
    #expect(result.updates.isEmpty)
    let pivot = try PracticeContext.decode(#"{"text":"What interests you about robotics?","updates":["topic"]}"#,
        latestUserText: "Can we talk about robotics instead?")
    #expect(pivot.updates.first?.field == .topic)
}

@Test func practiceBriefAnswerCannotReplaceExplicitGoal() throws {
    let result = try PracticeContext.decode(#"{"text":"What sparked your curiosity?","updates":["goal"]}"#,
        latestUserText: "I was curious.")
    #expect(result.updates.isEmpty)
}

@Test func practiceRecognitionKeepsSettledUtterancesAcrossPauses() throws {
    var transcript = PracticeTranscript()
    _ = try transcript.update("This founder is not technical.", start: 0, end: 2, settled: true, final: false)
    #expect(try transcript.update("Please help", start: 4, end: 5, settled: false, final: false) == "This founder is not technical. Please help")
    let combined = try transcript.update("Please help me explain my robot.", start: 4, end: 7, settled: true, final: false)
    #expect(combined == "This founder is not technical. Please help me explain my robot.")
    #expect(try transcript.update("Please help me explain my robot.", start: 4, end: 7, settled: true, final: true) == combined)
    #expect(transcript.completedCount == 2)
    #expect(try transcript.update(combined, start: 0, end: 7, settled: true, final: true) == combined)
    #expect(transcript.completedCount == 1)
}

@Test func practiceRecognitionDoesNotPromoteUnsettledDroppedWords() throws {
    var transcript = PracticeTranscript()
    _ = try transcript.update("Possibly incorrect words", start: 0, end: 2, settled: false, final: false)
    #expect(throws: (any Error).self) {
        try transcript.update("Second sentence", start: 4, end: 6, settled: false, final: true)
    }
    var empty = PracticeTranscript()
    _ = try empty.update("Unfinished", start: 0, end: 2, settled: false, final: false)
    #expect(try empty.update("", start: nil, end: nil, settled: false, final: true) == "")
}
