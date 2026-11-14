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
