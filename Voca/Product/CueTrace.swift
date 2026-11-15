import Foundation
import Synchronization

nonisolated struct CueTiming: Codable, Sendable {
    struct Event: Codable, Sendable { let stage: String; let seconds: Double }
    let requestID: UUID
    let origin: String
    let recordedAt: Date
    var events: [Event] = []
    var outcome = "pending"
    // Pair attempts separately so retries and fallback are included, not hidden.
    func duration(from start: String, to end: String) -> Double? {
        var began: Double?, total = 0.0, pairs = 0
        for event in events {
            if event.stage == start { began = event.seconds }
            if event.stage == end, let value = began {
                total += max(0, event.seconds - value); pairs += 1; began = nil
            }
        }
        return pairs == 0 ? nil : total
    }
    var firstSpeech: Double? { events.first { $0.stage == "playbackStarted" }?.seconds }
}

nonisolated final class CueTrace: Sendable {
    private let began: Double
    private let state: Mutex<CueTiming>
    init(origin: String = "button", began: Double = ProcessInfo.processInfo.systemUptime) {
        self.began = began
        state = Mutex(CueTiming(requestID: UUID(), origin: origin, recordedAt: Date()))
        mark("requested")
    }
    func mark(_ stage: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        state.withLock { value in
            guard value.outcome == "pending", value.events.count < 80 else { return }
            value.events.append(.init(stage: stage, seconds: max(0, now - began)))
        }
    }
    func finish(_ outcome: String) -> CueTiming {
        state.withLock { value in
            if value.outcome == "pending" { value.outcome = outcome }
            return value
        }
    }
    static func save(_ timing: CueTiming, to url: URL) throws {
        var history = (try? JSONDecoder().decode([CueTiming].self, from: Data(contentsOf: url))) ?? []
        history.append(timing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(history.suffix(40)))
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
