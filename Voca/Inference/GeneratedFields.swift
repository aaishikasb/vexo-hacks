import Foundation

nonisolated enum GeneratedFields {
    enum Failure: Error { case malformed, fields, length, evidence }
    struct Cue: Decodable, Sendable { let text: String; let sourceIDs: [String] }
    struct Scene: Decodable, Sendable { let setting: String; let observations: [String]; let uncertain: Bool }
    struct Audit: Decodable, Sendable { let strength: String; let opportunity: String; let exercise: String; let sourceIDs: [String]; let principleID: String }

    static func decode<T: Decodable>(_ type: T.Type, text: String, keys: Set<String>) throws -> T {
        guard text.utf8.count <= 12_000, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else { throw Failure.fields }
        return try JSONDecoder().decode(type, from: data)
    }
    static func cue(_ text: String, allowedSources: Set<String>) throws -> Cue {
        let cue = try decode(Cue.self, text: text, keys: ["text", "sourceIDs"])
        let words = cue.text.split(whereSeparator: \.isWhitespace).count
        guard (8...18).contains(words), cue.text.count <= 240, clean(cue.text) else { throw Failure.length }
        try sources(cue.sourceIDs, allowed: allowedSources)
        return cue
    }
    static func scene(_ text: String) throws -> Scene {
        let scene = try decode(Scene.self, text: text, keys: ["setting", "observations", "uncertain"])
        guard ["cafe", "shop", "event", "other"].contains(scene.setting), scene.observations.count <= 5,
              scene.observations.allSatisfy({ !$0.isEmpty && $0.count <= 180 && clean($0) }) else { throw Failure.fields }
        return scene
    }
    static func audit(_ text: String, allowedSources: Set<String>, principleIDs: Set<String>) throws -> Audit {
        let audit = try decode(Audit.self, text: text, keys: ["strength", "opportunity", "exercise", "sourceIDs", "principleID"])
        guard [audit.strength, audit.opportunity, audit.exercise].allSatisfy({ !$0.isEmpty && $0.count <= 500 && clean($0) }),
              principleIDs.contains(audit.principleID) else { throw Failure.fields }
        try sources(audit.sourceIDs, allowed: allowedSources)
        return audit
    }
    static func sources(_ ids: [String], allowed: Set<String>) throws {
        guard !ids.isEmpty, ids.count <= 12, Set(ids).count == ids.count, Set(ids).isSubset(of: allowed) else { throw Failure.evidence }
    }
    private static func clean(_ text: String) -> Bool {
        !text.contains("```") && !text.contains("<|") && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
