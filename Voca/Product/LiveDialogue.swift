import Foundation
import VocaCore

/// Short-lived conversation context, never a personal memory. Only cue-used excerpts are frozen in history.
struct LiveDialogue {
    private(set) var evidence: [Evidence] = []
    mutating func clear() { evidence.removeAll() }
    mutating func append(id: String, text: String, final: Bool, capturedAt: Date?, gap: Bool, now: Date = Date()) {
        guard final, !gap, let capturedAt else { clear(); return }
        let age = now.timeIntervalSince(capturedAt)
        guard age >= 0, age <= CoachEngine.dialogueFreshness else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, !evidence.contains(where: { $0.sourceID == id }) else { return }
        evidence.append(Evidence(sourceID: id, text: text, speaker: nil, utteredAt: capturedAt, shareApproved: false))
        evidence = Array(fresh(at: now).suffix(4))
    }
    func fresh(at now: Date) -> [Evidence] {
        evidence.filter { item in
            guard let time = item.utteredAt else { return false }
            return (0...CoachEngine.dialogueFreshness).contains(now.timeIntervalSince(time))
        }
    }
    func snapshot(memories: MemorySnapshot, now: Date = Date()) -> MemorySnapshot {
        let dialogue = fresh(at: now)
        return MemorySnapshot(approvedMemories: memories.approvedMemories, dialogue: dialogue,
                              fetchedAt: now, coverage: dialogue.isEmpty ? .unavailable : .partial)
    }
}
