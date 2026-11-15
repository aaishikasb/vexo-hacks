import Foundation
import Observation
@preconcurrency import Speech
import VocaCore

@MainActor @Observable final class PracticeSession {
    struct Message: Identifiable {
        let id = UUID()
        let text: String
        let fromUser: Bool
        let profile: ModelProfile?
    }
    private(set) var messages: [Message] = []
    private(set) var status = "Choose a scenario to begin." {
        didSet {
            #if DEBUG
            if let data = try? JSONSerialization.data(withJSONObject: ["status": status, "recordedAt": Date().ISO8601Format()]) {
                try? data.write(to: URL.documentsDirectory.appending(path: "practice-status.json"), options: .atomic)
            }
            #endif
        }
    }
    private(set) var listening = false
    private(set) var startingListening = false
    private(set) var busy = false
    private(set) var enabled = false
    private(set) var partial = ""
    var direction = ""
    var brief = PracticeBrief() {
        didSet {
            for (field, value) in brief.values where value != oldValue.values.first(where: { $0.0 == field })?.1 {
                context.set(field, quote: String(value.prefix(240)))
            }
        }
    }
    private(set) var context = PracticeContext()
    var pacingMode: PracticePacing.Mode = .adaptive
    private var pacing = PracticePacing()
    private var transcript = PracticeTranscript()

    func forgetContext(_ field: PracticeContext.Field) {
        switch field {
        case .audience: brief.audience = ""
        case .relationship: brief.relationship = ""
        case .topic: brief.topic = ""
        case .goal: brief.goal = ""
        case .detail, .openQuestion: break
        }
        context.set(field, quote: "")
    }

    private(set) var paused = false
    private(set) var finishing = false
    private var silenceTimeout: Task<Void, Never>?
    private var gate = PracticeTurnGate()
    private var recognition: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var work: Task<Void, Never>?
    private var recognitionTimeout: Task<Void, Never>?
    private var scenario: PracticeScenario?
    private var activeTurnID: UUID?

    #if DEBUG
    private var checkEvents: [[String: Any]] = []
    #endif
    func writePracticeCheck(event: String = "snapshot", delay: TimeInterval? = nil) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--practice-live-check") else { return }
        if event != "snapshot" {
            checkEvents.append(["event": event, "uptime": ProcessInfo.processInfo.systemUptime,
                                "delay": delay ?? -1, "mode": pacingMode.rawValue])
            checkEvents = Array(checkEvents.suffix(40))
        }
        let user = messages.last(where: \.fromUser)?.text.lowercased() ?? ""
        let audience = context.entries[.audience]?.quote.lowercased() ?? ""
        let correctionTerms = ["not technical", "nontechnical", "non-technical", "isn't technical"]
        let report: [String: Any] = [
            "recordedAt": Date().ISO8601Format(), "status": status,
            "enabled": enabled, "listening": listening, "finishing": finishing, "busy": busy, "paused": paused,
            "settledUtterances": transcript.completedCount,
            "mode": pacingMode.rawValue, "partialWords": partial.split(whereSeparator: \.isWhitespace).count,
            "userTurns": messages.filter(\.fromUser).count, "completedPartnerTurns": messages.filter { !$0.fromUser }.count,
            "lastUserWords": user.split(whereSeparator: \.isWhitespace).count,
            "lastPartnerWords": messages.last(where: { !$0.fromUser })?.text.split(whereSeparator: \.isWhitespace).count ?? 0,
            "contextFields": context.entries.keys.map(\.rawValue).sorted(),
            "audienceUpdatedByModel": context.entries[.audience]?.profile != nil,
            "userContainsTestCorrection": correctionTerms.contains(where: user.contains),
            "audienceContainsTestCorrection": correctionTerms.contains(where: audience.contains),
            "events": checkEvents
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
            try? data.write(to: URL.documentsDirectory.appending(path: "practice-live-check.json"), options: [.atomic, .completeFileProtection])
        }
        #endif
    }

    func start(scenario: PracticeScenario, model: any ModelGenerating, voice: PipecatSpeech, audio: NativeAudio) async {
        await stop(voice: voice, audio: audio)
        let epoch = gate.generation
        status = "Checking on-device guidance…"
        do {
            _ = try await model.activeProfile()
            guard epoch == gate.generation else { return }
            guard voice.ready else { throw PipecatSpeech.Failure.notReady }
            status = "Preparing the selected audio output…"
            try audio.useCurrentOutputForPractice()
            audio.onInterruption = { [weak self] in Task { @MainActor in
                await self?.stop(voice: voice, audio: audio)
                self?.status = "Practice stopped because the audio route changed. Check your audio output and start again."
            } }
            self.scenario = scenario; enabled = true; paused = false; messages = []; partial = ""; busy = true
            context = PracticeContext(); pacing = PracticePacing()
            for (field, value) in brief.values { context.set(field, quote: String(value.prefix(240))) }
            let generation = gate.generation
            work = Task {
                do {
                    let profile = try await model.activeProfile()
                    var opening = scenario.openingLine
                    var openingProfile: ModelProfile?
                    if !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !brief.isEmpty {
                        status = "Thinking…"
                        let request = try context.request(scenario: scenario, direction: direction,
                            messages: [], profile: profile)
                        let generated = try await ValidatedGeneration.run(request, model: model) {
                            try PracticeContext.decode($0, latestUserText: "")
                        }
                        opening = generated.value.text; openingProfile = generated.profile
                    }
                    try Task.checkCancellation()
                    guard generation == gate.generation else { return }
                    status = "Speaking…"
                    try await voice.speak(opening)
                    guard generation == gate.generation else { return }
                    messages.append(Message(text: opening, fromUser: false, profile: openingProfile))
                    writePracticeCheck(event: "playbackCompleted")
                    busy = false; work = nil
                    await listen(model: model, voice: voice, audio: audio)
                    return
                } catch { if generation == gate.generation { status = error is GeneratedFields.Failure ? "The partner couldn’t form a short reply. Tap Speak to try again." : error.localizedDescription } }
                if generation == gate.generation { busy = false; work = nil }
            }
        } catch { status = error.localizedDescription }
    }

    func listen(model: any ModelGenerating, voice: PipecatSpeech, audio: NativeAudio) async {
        guard enabled, !startingListening, !listening, !finishing, let scenario else { return }
        paused = false
        startingListening = true
        gate.restart()
        let generation = gate.generation
        defer { if generation == gate.generation { startingListening = false } }
        work?.cancel(); voice.stop(); await work?.value
        guard generation == gate.generation else { return }
        work = nil
        stopRecognition(audio: audio)
        busy = false; partial = ""; pacing.beginTurn(); transcript = PracticeTranscript()
        do {
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
            }
            guard generation == gate.generation else { return }
            guard authorization == .authorized else { throw LocalTranscriber.Failure.denied }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw LocalTranscriber.Failure.unavailable }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            recognitionRequest = request
            let turnID = UUID(), sessionID = gate.sessionID
            activeTurnID = turnID
            recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let metadata = result?.speechRecognitionMetadata
                let start = result?.bestTranscription.segments.first?.timestamp ?? metadata?.speechStartTimestamp
                let end = result?.bestTranscription.segments.last.map { $0.timestamp + $0.duration }
                    ?? metadata.map { $0.speechStartTimestamp + $0.speechDuration }
                let settled = metadata != nil
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, generation == self.gate.generation, self.activeTurnID == turnID else { return }
                    if let text {
                        let combined: String
                        do { combined = try self.transcript.update(text, start: start, end: end, settled: settled, final: final) }
                        catch { self.stopRecognition(audio: audio); self.status = error.localizedDescription; return }
                        let changed = combined != self.partial
                        self.partial = combined
                        if !final, changed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.pacing.observe(at: ProcessInfo.processInfo.systemUptime)
                            self.adjustPacing(audio: audio)
                        }
                        if final {
                            let turn = PracticeTurn(id: turnID, sessionID: sessionID, generation: generation, text: combined, isFinal: true)
                            guard self.gate.accept(turn) else {
                                self.stopRecognition(audio: audio)
                                self.status = "I didn’t catch any words. Tap Speak to try again."
                                return
                            }
                            self.writePracticeCheck(event: "finalTranscript")
                            self.stopRecognition(audio: audio)
                            self.reply(to: turn, scenario: scenario, model: model, voice: voice, audio: audio)
                            return
                        }
                    }
                    if let message { self.stopRecognition(audio: audio); self.status = "Recognition stopped: \(message). Tap Speak to retry." }
                }
            }
            try await audio.startPracticeCapture(request)
            guard generation == gate.generation, activeTurnID == turnID else { audio.stopCapture(); return }
            listening = true; status = "Listening · Take your time. I’ll respond after a pause."
            writePracticeCheck(event: "captureStarted")
            recognitionTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard !Task.isCancelled, self?.gate.generation == generation else { return }
                self?.finishListening(audio: audio)
            }
        } catch { if generation == gate.generation { stopRecognition(audio: audio); status = error.localizedDescription } }
    }

    func adjustPacing(audio: NativeAudio) {
        silenceTimeout?.cancel(); silenceTimeout = nil
        guard listening, let turnID = activeTurnID, !partial.isEmpty,
              let delay = pacing.delay(for: partial, mode: pacingMode) else { return }
        writePracticeCheck(event: "pauseTimerScheduled", delay: delay)
        let generation = gate.generation
        silenceTimeout = Task { [weak self] in
            // shortcut: recognition updates approximate silence; calibrate audio VAD before hands-free talk-over.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.gate.generation == generation,
                  self.activeTurnID == turnID else { return }
            self.finishListening(audio: audio)
        }
    }

    func finishListening(audio: NativeAudio) {
        guard listening else { return }
        writePracticeCheck(event: "finishRequested")
        audio.stopCapture(); listening = false; finishing = true
        silenceTimeout?.cancel(); silenceTimeout = nil
        recognitionRequest?.endAudio()
        recognition?.finish()
        status = "Finishing your turn…"
        recognitionTimeout?.cancel()
        let generation = gate.generation
        recognitionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.gate.generation == generation else { return }
            self.stopRecognition(audio: audio)
            self.status = "No final transcript arrived. Tap Speak to try again; partial text was not sent."
        }
    }

    private func reply(to turn: PracticeTurn, scenario: PracticeScenario, model: any ModelGenerating, voice: PipecatSpeech, audio: NativeAudio) {
        guard turn.text.count <= 2000 else { status = "That turn was too long. Tap Speak and try a shorter reply."; return }
        busy = true; status = "Thinking…"
        let generation = gate.generation
        messages.append(Message(text: turn.text, fromUser: true, profile: nil))
        work = Task {
            do {
                try await voice.acceptPracticeTurn(turn)
                try Task.checkCancellation()
                let profile = try await model.activeProfile()
                let request = try context.request(scenario: scenario, direction: direction,
                    messages: messages.map { (text: $0.text, fromUser: $0.fromUser) }, profile: profile)
                let contextRevision = context.revision
                let generated = try await ValidatedGeneration.run(request, model: model) {
                    try PracticeContext.decode($0, latestUserText: turn.text)
                }
                let text = generated.value.text
                try Task.checkCancellation()
                guard generation == gate.generation else { return }
                // A newer user edit or removal wins over an in-flight model update.
                let contextUnchanged = context.revision == contextRevision
                if contextUnchanged {
                    context.apply(generated.value.updates.filter { !$0.quote.isEmpty }, turn: turn, profile: generated.profile)
                }
                let playbackContextRevision = context.revision
                status = "Speaking…"
                try await voice.speak(text)
                guard generation == gate.generation else { return }
                if contextUnchanged && context.revision == playbackContextRevision {
                    context.apply(generated.value.updates.filter { $0.quote.isEmpty }, turn: turn, profile: generated.profile)
                }
                messages.append(Message(text: text, fromUser: false, profile: generated.profile))
                writePracticeCheck(event: "playbackCompleted")
                busy = false; work = nil
                await listen(model: model, voice: voice, audio: audio)
                return
            } catch { if generation == gate.generation { status = error is CancellationError ? "Reply stopped." : error is GeneratedFields.Failure ? "The partner couldn’t form a short reply. Tap Speak to try again." : error.localizedDescription } }
            if generation == gate.generation { busy = false; work = nil }
        }
    }

    private func stopRecognition(audio: NativeAudio) {
        activeTurnID = nil; finishing = false
        silenceTimeout?.cancel(); silenceTimeout = nil
        recognitionTimeout?.cancel(); recognitionTimeout = nil
        audio.stopCapture(); recognition?.cancel(); recognition = nil; recognitionRequest = nil; listening = false
    }
    func pause(voice: PipecatSpeech, audio: NativeAudio) async {
        gate.restart(); paused = true; startingListening = false
        stopRecognition(audio: audio)
        work?.cancel(); voice.stop(); await work?.value; work = nil; busy = false
        status = "Paused. The microphone is off. Resume when you’re ready."
    }

    func stop(voice: PipecatSpeech, audio: NativeAudio) async {
        gate.restart(); enabled = false; paused = false; startingListening = false
        stopRecognition(audio: audio)
        work?.cancel(); voice.stop(); await work?.value; work = nil; busy = false
        audio.onInterruption = nil; audio.endPracticeOutput()
        context = PracticeContext(); pacing = PracticePacing()
        status = "Practice ended. The microphone is off."
    }
}
