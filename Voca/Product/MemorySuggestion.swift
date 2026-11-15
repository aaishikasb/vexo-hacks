import Foundation
import NaturalLanguage

nonisolated struct MemorySuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: UUID
    let text: String
    let capturedAt: Date
    let utteredAt: Date?
    let hasGap: Bool
    let ruleVersion: String
    var bandNumber: Int? = nil

    /// Exact excerpts, never generated facts or speaker identification.
    static func excerpts(from transcript: String) -> [String] {
        // shortcut: English explicit-detail rules, replace with evaluated local extraction when recall warrants it.
        let pattern = #"(?i)\b(my name is|name is|i am a|i'm a|i’m a|i work|works? (at|for|on)|working on|(i (like|love|enjoy|prefer|study|live|grew up)|likes|loves|enjoys|prefers|studies|lives)|interested in|passionate about|my (job|project|hobby|favorite|favourite)|follow up|follow-up|remind me|i('ll|’ll| will) (send|call|email|meet|bring)|let's (meet|catch up)|let’s (meet|catch up))\b"#
        return transcript.components(separatedBy: CharacterSet(charactersIn: ".!?\n;"))
            .flatMap { sentence in
                // Split only explicit first-person clauses; never cut a long detail at an arbitrary character.
                sentence.count > 240
                    ? sentence.replacingOccurrences(of: #"\s+(?=(?:and|but)\s+I\b)"#, with: "\n",
                                                    options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\n")
                    : [sentence]
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (8...240).contains($0.count) && ($0.range(of: pattern, options: .regularExpression) != nil || containsPersonName($0)) }
    }

    private static func containsPersonName(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if tag == .personalName { found = true; return false }
            return true
        }
        return found
    }
}
