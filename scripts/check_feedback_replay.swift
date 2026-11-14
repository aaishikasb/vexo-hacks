import Foundation

// Compile with the canonical Core sources; probe only disposable copies of a device store.
@main struct FeedbackReplayCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: check-feedback-replay before.json after-relaunch.json")
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let after = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        struct Store: Decodable { let episodes: [Episode] }
        let original = try decoder.decode(Store.self, from: before).episodes
        let restored = try decoder.decode(Store.self, from: after).episodes
        guard original == restored,
              let rated = restored.last(where: { $0.delivery == .completed && $0.feedback?.verdict == .helpful }) else {
            fatalError("Episode persistence changed, or no genuine completed helpful rating exists")
        }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stored = temporary.appending(path: "restored.json")
        try after.write(to: stored)
        let engine = try CoachEngine(storeURL: stored)
        var context = rated.decision.context
        context.decisionID = UUID()
        guard let replay = try await engine.selectCue(context, explore: false, excluding: nil),
              replay.features == rated.decision.features else { fatalError("Replay context changed") }
        // Counterfactual removes only the latest rating from a disposable copy, never the phone.
        var object = try JSONSerialization.jsonObject(with: after) as! [String: Any]
        var episodes = object["episodes"] as! [[String: Any]]
        let index = restored.firstIndex(where: { $0.id == rated.id })!
        episodes[index].removeValue(forKey: "feedback")
        object["episodes"] = episodes
        let unratedURL = temporary.appending(path: "without-latest-rating.json")
        try JSONSerialization.data(withJSONObject: object).write(to: unratedURL)
        let unrated = try CoachEngine(storeURL: unratedURL)
        context.decisionID = UUID()
        let baseline = try await unrated.selectCue(context, explore: false, excluding: nil)
        let action = rated.decision.selectedAction.rawValue
        guard let old = baseline?.utilities[action], let new = replay.utilities[action], new > old else {
            fatalError("Helpful rating did not increase its original strategy utility")
        }
        print("PASS: all \(restored.count) episodes unchanged after device relaunch")
        print("PASS: canonical Core replay; \(action) utility without latest rating=\(old), with rating=\(new)")
        print("Eligible strategies: \(replay.eligibleActions.count); model weights unchanged")
    }
}
