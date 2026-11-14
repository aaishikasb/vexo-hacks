import Foundation
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

private let groundedCueJSON = #"{"text":"Ask which part of the event they enjoyed the most.","sourceIDs":["scene:one"]}"#

@Test func enclosingJSONFencesPreserveExactCueAndEvidence() throws {
    for wrapped in [groundedCueJSON, " \n\t" + groundedCueJSON + "\r\n", "```json\n" + groundedCueJSON + "\n```",
                    "```\n" + groundedCueJSON + "\n```", "```JSON\r\n" + groundedCueJSON + "\r\n```"] {
        let cue = try GeneratedFields.cue(wrapped, allowedSources: ["scene:one"])
        #expect(cue.text == "Ask which part of the event they enjoyed the most.")
        #expect(cue.sourceIDs == ["scene:one"])
    }
    let scene = try GeneratedFields.scene("```json\n" + #"{"setting":"cafe","observations":["A table"],"uncertain":false}"# + "\n```")
    #expect(scene.setting == "cafe")
}

@Test func outputParserNeverSalvagesProseMultipleObjectsOrBrokenFences() {
    let invalid = ["Here is your cue: " + groundedCueJSON, groundedCueJSON + " Please use it.",
                   groundedCueJSON + groundedCueJSON, "```json\n" + groundedCueJSON,
                   "```swift\n" + groundedCueJSON + "\n```", "```json " + groundedCueJSON + "```",
                   "```json\n" + groundedCueJSON + "\n```\nExplanation", "```json\n" + groundedCueJSON + "\n```\n```json\n{}\n```",
                   "```json\n\n```", "[]", "null", "42", ""]
    for raw in invalid {
        #expect(throws: GeneratedFields.Failure.self) { try GeneratedFields.cue(raw, allowedSources: ["scene:one"]) }
    }
    for end in 0..<groundedCueJSON.count {
        #expect(throws: GeneratedFields.Failure.self) {
            try GeneratedFields.cue(String(groundedCueJSON.prefix(end)), allowedSources: ["scene:one"])
        }
    }
}

@Test func outputParserRejectsWrongTypesAndAuthorityEvenInsideFences() {
    let wrong = [#"{"text":true,"sourceIDs":["scene:one"]}"#, #"{"text":null,"sourceIDs":["scene:one"]}"#,
                 #"{"text":[],"sourceIDs":["scene:one"]}"#, #"{"text":{},"sourceIDs":["scene:one"]}"#,
                 #"{"text":"Ask which part of the event they enjoyed the most.","sourceIDs":"scene:one"}"#,
                 #"{"text":"Ask which part of the event they enjoyed the most.","sourceIDs":[1]}"#,
                 #"{"text":"Ask which part of the event they enjoyed the most.","sourceIDs":null}"#,
                 #"{"text":"Ask which part of the event they enjoyed the most.","sourceIDs":["scene:one"],"reward":1}"#,
                 #"{"text":"Ask which part of the event they enjoyed the most."}"#]
    for raw in wrong {
        for wrapped in [raw, "```json\n" + raw + "\n```"] {
            #expect(throws: GeneratedFields.Failure.fields) { try GeneratedFields.cue(wrapped, allowedSources: ["scene:one"]) }
        }
    }
}

@Test func cueSourceValidationNeverNormalizesOrInventsReferences() {
    for sources in [["scene:one", "scene:one"], ["SCENE:ONE"], ["scene:one "], ["scene:two"], ["source ID"], []] {
        #expect(throws: GeneratedFields.Failure.evidence) { try GeneratedFields.sources(sources, allowed: ["scene:one"]) }
    }
    #expect(throws: GeneratedFields.Failure.evidence) { try GeneratedFields.sources([""], allowed: [""]) }
    #expect(throws: GeneratedFields.Failure.evidence) { try GeneratedFields.sources([" "], allowed: [" "]) }
    let thirteen = (0..<13).map { "source:\($0)" }
    #expect(throws: GeneratedFields.Failure.evidence) { try GeneratedFields.sources(thirteen, allowed: Set(thirteen)) }
}

@Test func cueLengthAndUnsafeTextRemainBounded() throws {
    for count in [7, 8, 18, 19] {
        let text = Array(repeating: "word", count: count).joined(separator: " ")
        let json = "{\"text\":\"\(text)\",\"sourceIDs\":[\"scene:one\"]}"
        if (8...18).contains(count) { _ = try GeneratedFields.cue(json, allowedSources: ["scene:one"]) }
        else { #expect(throws: GeneratedFields.Failure.length) { try GeneratedFields.cue(json, allowedSources: ["scene:one"]) } }
    }
    for token in ["\\n", "\\t", "\\u0000", "<|system|>", "```"] {
        let raw = groundedCueJSON.replacingOccurrences(of: "Ask", with: "Ask" + token)
        #expect(throws: GeneratedFields.Failure.length) { try GeneratedFields.cue(raw, allowedSources: ["scene:one"]) }
    }
    let longWords = Array(repeating: String(repeating: "a", count: 31), count: 8).joined(separator: " ")
    #expect(throws: GeneratedFields.Failure.length) {
        try GeneratedFields.cue("{\"text\":\"\(longWords)\",\"sourceIDs\":[\"scene:one\"]}", allowedSources: ["scene:one"])
    }
    #expect(throws: GeneratedFields.Failure.fields) {
        try GeneratedFields.cue(String(repeating: " ", count: 12_001) + groundedCueJSON, allowedSources: ["scene:one"])
    }
}

@Test func sceneAndAuditSemanticFieldsRemainStrict() throws {
    for invalid in [#"{"setting":"cafe","observations":[" "],"uncertain":false}"#,
                    #"{"setting":"cafe","observations":[null],"uncertain":false}"#,
                    #"{"setting":"cafe","observations":[],"uncertain":0}"#,
                    #"{"setting":"cafe","observations":[],"uncertain":null}"#,
                    #"{"setting":"cafe","observations":["one","two","three","four","five","six"],"uncertain":false}"#] {
        #expect(throws: GeneratedFields.Failure.fields) { try GeneratedFields.scene(invalid) }
    }
    let audit = #"{"strength":"You asked a question.","opportunity":"You could invite one example.","exercise":"Ask for one example.","sourceIDs":["wearer:one"],"principleID":"listen"}"#
    _ = try GeneratedFields.audit("```json\n" + audit + "\n```", allowedSources: ["wearer:one"], principleIDs: ["listen"])
    #expect(throws: GeneratedFields.Failure.fields) {
        try GeneratedFields.audit(audit.replacingOccurrences(of: "You asked a question.", with: " "), allowedSources: ["wearer:one"], principleIDs: ["listen"])
    }
    #expect(throws: GeneratedFields.Failure.fields) {
        try GeneratedFields.audit(audit, allowedSources: ["wearer:one"], principleIDs: ["other"])
    }
    #expect(throws: GeneratedFields.Failure.evidence) {
        try GeneratedFields.audit(audit, allowedSources: [], principleIDs: ["listen"])
    }
}
