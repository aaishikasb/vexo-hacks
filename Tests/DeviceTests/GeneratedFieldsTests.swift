import Testing
@testable import VocaDevice

@Test func cueRejectsInventedEvidenceAndExtraModelAuthority() throws {
    let valid = #"{"text":"Ask what brought them to this event and listen for a shared interest.","sourceIDs":["scene:one"]}"#
    #expect(try GeneratedFields.cue(valid, allowedSources: ["scene:one"]).sourceIDs == ["scene:one"])
    #expect(throws: (any Error).self) { try GeneratedFields.cue(valid, allowedSources: ["other"]) }
    #expect(throws: (any Error).self) { try GeneratedFields.cue(#"{"text":"Hello","sourceIDs":[]}"#, allowedSources: []) }
    #expect(throws: (any Error).self) { try GeneratedFields.cue(valid.dropLast() + #", "decisionID":"invented"}"#, allowedSources: ["scene:one"]) }
}
@Test func sceneAndAuditRejectInvalidFields() {
    #expect(throws: (any Error).self) { try GeneratedFields.scene(#"{"setting":"office","observations":[],"uncertain":false}"#) }
    #expect(throws: (any Error).self) { try GeneratedFields.audit(#"{"strength":"You listened.","opportunity":"You could ask more.","exercise":"Ask a question.","sourceIDs":["unknown"],"principleID":"listen"}"#, allowedSources: [], principleIDs: ["listen"]) }
}

@Test func wrongModelFieldTypesAreValidationFailures() {
    #expect(throws: GeneratedFields.Failure.fields) {
        _ = try GeneratedFields.scene(#"{"setting":"other","observations":["A table"],"uncertain":"true"}"#)
    }
    #expect(throws: GeneratedFields.Failure.fields) {
        _ = try GeneratedFields.cue(#"{"text":42,"sourceIDs":["scene"]}"#, allowedSources: ["scene"])
    }
}
