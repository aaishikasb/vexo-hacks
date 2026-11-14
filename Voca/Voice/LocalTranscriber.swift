import AVFoundation
import Speech

@MainActor final class LocalTranscriber {
    enum Failure: LocalizedError {
        case unavailable, denied, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device English speech recognition is unavailable. Download the iPhone’s speech assets and try again; no audio was sent to a cloud service."
            case .denied: "Allow Speech Recognition in iPhone Settings to transcribe locally."
            case .busy: "Stop the current listening session first."
            }
        }
    }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var origin: Date?
    private var hasGap = false
    private var timeout: Task<Void, Never>?
    var onText: ((String, Bool, Date?) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        guard task == nil else { throw Failure.busy }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        generation += 1
        let current = generation
        origin = nil; hasGap = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let offset = result?.bestTranscription.segments.last.map { $0.timestamp + $0.duration }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let text {
                    let date = self.hasGap ? nil : offset.flatMap { self.origin?.addingTimeInterval($0) }
                    self.onText?(text, final, date)
                }
                if let error { self.onError?(error); self.stop() }
                else if final { self.stop() }
            }
        }
    }
    func append(_ pcm: AVAudioPCMBuffer, approximateCaptureTime: Date, missingPackets: Int) {
        if origin == nil { origin = approximateCaptureTime }
        if missingPackets > 0 { hasGap = true }
        request?.append(pcm)
    }
    func markGap() { hasGap = true }
    func endAudio() {
        request?.endAudio()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
    func stop() {
        generation += 1
        timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
        request = nil; origin = nil
    }
}
