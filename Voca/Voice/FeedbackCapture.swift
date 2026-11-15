import Foundation
import Observation
import Speech

/// Explicit, final-only local recognition. Never sends a model turn or saves audio.
@MainActor @Observable final class FeedbackCapture {
    private(set) var listening = false
    private(set) var preparing = false
    private(set) var status = ""
    private(set) var finalText = ""
    private var generation = 0
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timeout: Task<Void, Never>?
    private weak var audio: NativeAudio?
    func start(audio: NativeAudio) async {
        guard !listening, !preparing else { return }
        stop(); self.audio = audio; preparing = true; finalText = ""
        let epoch = generation
        defer { if epoch == generation { preparing = false } }
        do {
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable value in continuation.resume(returning: value) }
            }
            try Task.checkCancellation()
            guard epoch == generation else { return }
            guard permission == .authorized else { throw LocalTranscriber.Failure.denied }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else { throw LocalTranscriber.Failure.unavailable }
            try audio.useCurrentOutputForPractice()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
            self.request = request
            recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == epoch else { return }
                    if let text {
                        self.stop()
                        if text.count <= 240 { self.finalText = text; self.status = "Check what I heard, then save when you’re ready." }
                        else { self.status = "That was longer than 240 characters. Try a shorter correction." }
                    } else if let message { self.stop(); self.status = "Recognition stopped: \(message)" }
                }
            }
            try await audio.startPracticeCapture(request)
            guard epoch == generation else { return }
            listening = true; status = "Listening on this iPhone · tap Finish when done."
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self?.generation == epoch else { return }
                self?.finish()
            }
        } catch {
            guard epoch == generation else { return }
            stop(); status = error is CancellationError ? "Stopped." : error.localizedDescription
        }
    }
    func finish() {
        guard listening else { return }
        audio?.stopCapture(); listening = false; request?.endAudio(); status = "Finishing recognition…"
        timeout?.cancel()
        let epoch = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.generation == epoch else { return }
            self.stop(); self.status = "No final words arrived. Tap Speak to try again."
        }
    }
    func stop() {
        generation += 1; timeout?.cancel(); timeout = nil
        audio?.stopCapture(); audio?.endPracticeOutput(); audio = nil
        recognition?.cancel(); recognition = nil; request = nil
        listening = false; preparing = false
    }
}
