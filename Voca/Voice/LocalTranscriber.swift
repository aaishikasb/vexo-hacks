import AVFoundation
import Speech

@MainActor final class LocalTranscriber {
    enum Failure: LocalizedError {
        case unavailable, denied, busy, backpressure, discontinuity
        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device English speech recognition is unavailable. Download the iPhone’s speech assets and try again; no audio was sent to a cloud service."
            case .denied: "Allow Speech Recognition in iPhone Settings to transcribe locally."
            case .backpressure: "Local speech recognition fell behind. Resume listening to retry; that audio could not be transcribed."
            case .discontinuity: "Listening missed part of the conversation. Resume listening and repeat the sentence; incomplete speech was not used for a cue."
            case .busy: "Stop the current listening session first."
            }
        }
    }
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var starting = false
    private var origin: Date?
    private var hasGap = false
    private var timeout: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var continuous = false
    private var ending = false
    private var transcript = PracticeTranscript()
    private var latest = ""
    private var latestDate: Date?
    private var buffered: [(AVAudioPCMBuffer, Date, Int)] = []
    var onText: ((String, Bool, Date?) -> Void)?
    var onSegment: ((String, Bool, Date?, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    func start(continuous: Bool = false) async throws {
        guard task == nil, !starting else { throw Failure.busy }
        starting = true
        defer { starting = false }
        generation += 1
        let current = generation
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        guard authorization == .authorized else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        self.recognizer = recognizer
        self.continuous = continuous
        beginSegment()
    }

    private func beginSegment() {
        generation += 1
        let current = generation
        transcript = PracticeTranscript()
        ending = false; origin = nil; hasGap = false; latest = ""; latestDate = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        task = recognizer?.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let metadata = result?.speechRecognitionMetadata
            let start = result?.bestTranscription.segments.first?.timestamp ?? metadata?.speechStartTimestamp
            let offset = result?.bestTranscription.segments.last.map { $0.timestamp + $0.duration }
                ?? metadata.map { $0.speechStartTimestamp + $0.speechDuration }
            let settled = metadata != nil
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let text {
                    do {
                        self.latest = try self.transcript.update(text, start: start, end: offset, settled: settled, final: final)
                    } catch {
                        self.latest = ""; self.continuous = false
                        self.markGap(); self.finishSegment(final: false)
                        self.onError?(Failure.discontinuity)
                        return
                    }
                    self.latestDate = self.hasGap ? nil : offset.flatMap { self.origin?.addingTimeInterval($0) }
                    self.onText?(self.latest, final, self.latestDate)
                }
                if final { self.finishSegment(final: true) }
                else if let error {
                    // An empty window ended by us contains no evidence; keep listening through silence.
                    if self.continuous && self.ending && self.latest.isEmpty && self.recognizer?.isAvailable == true {
                        self.finishSegment(final: true)
                        return
                    }
                    self.continuous = false
                    self.finishSegment(final: false)
                    self.onError?(error)
                }
            }
        }
        let pending = buffered; buffered.removeAll()
        for (pcm, date, missing) in pending { append(pcm, approximateCaptureTime: date, missingPackets: missing) }
        if continuous {
            // Rotate before the recognizer's task limit; buffer incoming BLE audio while it finalizes.
            rotation = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.endSegment()
            }
        }
    }

    func append(_ pcm: AVAudioPCMBuffer, approximateCaptureTime: Date, missingPackets: Int) {
        if ending {
            // Three seconds covers the bounded finalization wait. Overflow is an explicit capture failure.
            guard buffered.count < 150 else {
                continuous = false; finishSegment(final: false)
                onError?(Failure.backpressure)
                return
            }
            buffered.append((pcm, approximateCaptureTime, missingPackets))
            return
        }
        if origin == nil { origin = approximateCaptureTime }
        if missingPackets > 0 { markGap() }
        request?.append(pcm)
    }
    func markGap() { hasGap = true; latestDate = nil }
    private func endSegment() {
        guard task != nil, !ending else { return }
        ending = true
        rotation?.cancel(); rotation = nil
        request?.endAudio()
        let current = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.finishSegment(final: false)
        }
    }
    private func finishSegment(final: Bool) {
        let text = latest, date = latestDate, gap = hasGap || !final
        generation += 1
        timeout?.cancel(); timeout = nil
        rotation?.cancel(); rotation = nil
        task?.cancel(); task = nil; request = nil
        latest = ""; ending = false
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSegment?(text, final, gap ? nil : date, gap) }
        if continuous { beginSegment() }
        else { buffered.removeAll() }
    }
    // Finalize the current turn at a cue request without ending authorized capture.
    func flush() async {
        guard task != nil, continuous else { return }
        let current = generation
        endSegment()
        for _ in 0..<35 {
            if generation != current || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    func discardSegment() {
        generation += 1
        timeout?.cancel(); rotation?.cancel()
        task?.cancel(); task = nil; request = nil
        buffered.removeAll(); latest = ""; ending = false
        if continuous { beginSegment() }
    }
    func endAudio() { continuous = false; endSegment() }
    func finish() async {
        endAudio()
        for _ in 0..<35 {
            if task == nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if task != nil { finishSegment(final: false) }
    }
    func stop() {
        continuous = false
        generation += 1
        timeout?.cancel(); timeout = nil
        rotation?.cancel(); rotation = nil
        task?.cancel(); task = nil
        request = nil; recognizer = nil; origin = nil; latest = ""; ending = false
        buffered.removeAll()
    }
}
