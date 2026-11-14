import Foundation
import VocaCore

/// Session generations reject callbacks from an interrupted recognition request.
struct PracticeTurnGate {
    let sessionID = UUID()
    private(set) var generation = 0
    private var accepted: Set<UUID> = []
    mutating func restart() { generation += 1; accepted.removeAll() }
    mutating func accept(_ turn: PracticeTurn) -> Bool {
        guard turn.sessionID == sessionID, turn.generation == generation, turn.isFinal,
              !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return accepted.insert(turn.id).inserted
    }
    static func reply(_ raw: String) throws -> String {
        struct Reply: Decodable { let text: String }
        let result = try GeneratedFields.decode(Reply.self, text: raw, keys: ["text"]).text
        guard (1...60).contains(result.split(whereSeparator: \.isWhitespace).count), result.count <= 500,
              !result.contains("```"), !result.contains("<|"),
              !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GeneratedFields.Failure.fields
        }
        return result
    }
}
