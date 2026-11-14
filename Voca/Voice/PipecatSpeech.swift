import Foundation
import Observation

/// Fixed-phrase integration stage; shared VoiceCoordinating is integrated with Core next.
@MainActor @Observable final class PipecatSpeech {
    private(set) var ready = false
    private(set) var status = "Pipecat has not started"
    private let runtime = PCPythonRuntime()
    private var audio: NativeAudio?
    private var requestID: UUID?
    private var completion: CheckedContinuation<Void, Error>?
    private var playback: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var started = false

    func start(audio: NativeAudio) {
        guard !started else { return }
        started = true
        self.audio = audio
        status = "Starting embedded Pipecat…"
        runtime.start { [weak self] json in
            Task { @MainActor in self?.receive(json) }
        }
    }

    func speak(_ text: String) async throws {
        guard ready else { throw Failure.notReady }
        guard completion == nil else { throw NativeAudio.Failure.busy }
        try Task.checkCancellation()
        let id = UUID()
        requestID = id
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                status = "Pipecat is preparing speech…"
                send(["type": "speech", "requestID": id.uuidString.lowercased(), "text": text])
                watchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(35))
                    guard !Task.isCancelled, let self, self.requestID == id else { return }
                    self.stop()
                    self.status = "Pipecat speech timed out. Restart Voca to retry."
                }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.requestID == id { self?.stop() } } }
    }

    func stop() {
        guard let id = requestID else { return }
        playback?.cancel()
        audio?.stop()
        send(["type": "playback", "requestID": id.uuidString.lowercased(), "outcome": "cancelled"])
        finish(.failure(CancellationError()))
        status = "Pipecat speech cancelled"
    }

    private func send(_ event: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        runtime.sendJSON(json)
    }

    private func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        if event["type"] == "ready" { ready = true; status = "Embedded Pipecat ready"; return }
        if event["type"] == "error" {
            ready = false
            stop()
            status = "Pipecat failed to start. Restart Voca after checking the runtime build."
            return
        }
        guard let rawID = event["requestID"], let id = UUID(uuidString: rawID), id == requestID else {
            // Reject stale queued speech without playing it.
            if event["type"] == "speak", let rawID = event["requestID"] {
                send(["type": "playback", "requestID": rawID, "outcome": "cancelled"])
            }
            return
        }
        switch event["type"] {
        case "speak":
            guard playback == nil, let text = event["text"], let audio else { return }
            playback = Task { [weak self] in
                let outcome: String
                do { try await audio.speak(text); outcome = "completed" }
                catch is CancellationError { outcome = "cancelled" }
                catch { outcome = "failed"; self?.status = error.localizedDescription }
                guard let self, self.requestID == id else { return }
                self.send(["type": "playback", "requestID": rawID, "outcome": outcome])
            }
        case "stop": stop()
        case "terminal":
            if event["outcome"] == "completed" {
                finish(.success(())); status = "Pipecat speech playback completed"
            } else { finish(.failure(Failure.playback)) }
        default: break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        watchdog?.cancel(); watchdog = nil
        let pending = completion
        completion = nil; requestID = nil; playback = nil
        pending?.resume(with: result)
    }

    enum Failure: LocalizedError {
        case notReady, playback
        var errorDescription: String? {
            switch self {
            case .notReady: "Start embedded Pipecat and wait until it is ready."
            case .playback: "Pipecat speech did not finish. Confirm the glasses output and retry."
            }
        }
    }
}
