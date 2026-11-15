import Foundation
import Observation
import VocaCore

@MainActor @Observable final class CoachingSession {
    let taste = TasteStore()
    var goal: Goal = .enter
    var knownPoint = ""
    private(set) var status = "Connect your glasses to get started."
    private(set) var episodes: [Episode] = []
    private(set) var busy = false
    private(set) var phase: CuePhase = .capturing
    private(set) var lastTiming: CueTiming?
    private(set) var lastError: String?
    private(set) var failureReasons: [UUID: String] = [:]
    private var failureDirectory: URL?
    private var coach: CoachEngine?
    var isConfigured: Bool { coach != nil }
    private var work: Task<Void, Never>?

    func configure() async {
        guard coach == nil else { return }
        do {
            var directory = URL.applicationSupportDirectory.appending(path: "Voca/Coaching", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let store = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
            for episode in await store.episodes() where episode.delivery == .pending {
                try await store.recordDelivery(decisionID: episode.id, cue: nil, status: .cancelled)
            }
            episodes = await store.episodes()
            try taste.load()
            try taste.prune(episodes: episodes)
            let failures = directory.appending(path: "Failures", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
            failureDirectory = failures
            for episode in episodes where episode.delivery != .completed {
                if let reason = try? String(contentsOf: failures.appending(path: episode.id.uuidString + ".txt"), encoding: .utf8) {
                    failureReasons[episode.id] = reason
                }
            }
            coach = store
            lastError = nil
            status = "Ready for a cue."
        } catch { status = "Cue history could not be opened. Tap Get cue to retry. Your saved data is unchanged."; lastError = status }
    }

    func request(models: ModelLibrary, camera: GlassesCamera, voice: PipecatSpeech, snapshot: MemorySnapshot? = nil, trace: CueTrace = CueTrace()) {
        guard !busy, let coach else { return }
        guard camera.ready, voice.ready else { status = "Start the glasses camera and embedded Pipecat first."; return }
        phase = .capturing
        busy = true
        lastError = nil
        let model = models.executor
        let requestedAt = Date(), goal = self.goal, knownPoint = self.knownPoint
        let style = taste.guidance(episodes: episodes, goal: goal)
        work = Task {
            var cue: CueResult?
            do {
                status = "Capturing context…"
                trace.mark("photoStarted")
                let (photo, observedAt) = try await camera.photo(preferStreamFrame: true)
                trace.mark("photoReady")
                trace.mark(camera.lastCaptureKind)
                phase = .thinking
                status = "Finding a grounded cue on this iPhone…"
                let requestedProfile = try await model.activeProfile()
                trace.mark("thermal:\(ProcessInfo.processInfo.thermalState.rawValue)")
                do {
                    cue = try await CuePipeline(model: model, coach: coach, taste: style, trace: trace).prepare(photo: photo, observedAt: observedAt,
                        requestedAt: requestedAt, goal: goal, knownPoint: knownPoint, snapshot: snapshot)
                } catch {
                    guard requestedProfile.modelID == .gemma4E4B, Self.canUseFallback(after: error) else { throw error }
                    try Task.checkCancellation()
                    await recordFailure("E4B could not produce a valid cue after recovery. Voca attempted E2B fallback. " + error.localizedDescription,
                        requestedAt: requestedAt, modelID: .gemma4E4B)
                    phase = .fallback
                    status = "E4B could not finish this cue. Loading E2B fallback…"
                    trace.mark("fallbackStarted")
                    try await models.load(modelID: "gemma4E2B")
                    trace.mark("fallbackReady")
                    try Task.checkCancellation()
                    // A new pipeline decision records E2B's profile; the failed E4B episode stays failed.
                    cue = try await CuePipeline(model: model, coach: coach, taste: style, trace: trace).prepare(photo: photo, observedAt: observedAt,
                        requestedAt: requestedAt, goal: goal, knownPoint: knownPoint, snapshot: snapshot)
                }
                guard let cue else { return }
                trace.mark(cue.actualProfile.modelID.rawValue)
                if let snapshot, snapshot.dialogue.contains(where: { cue.sourceIDs.contains($0.sourceID) }) {
                    trace.mark("dialogueCited")
                }
                try Task.checkCancellation()
                if let snapshot, !snapshot.dialogue.isEmpty {
                    guard snapshot.dialogue.contains(where: { cue.sourceIDs.contains($0.sourceID) && CoachEngine.isFreshDialogue($0, at: Date()) }) else {
                        throw LiveCueFailure.expired
                    }
                }
                try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .pending)
                phase = .speaking
                status = cue.actualProfile.modelID == .gemma4E2B ? "Speaking your cue with E2B fallback…" : "Speaking your cue with E4B…"
                trace.mark("speechRequested")
                try await voice.speak(cue.text, onStarted: { trace.mark("playbackStarted") })
                trace.mark("playbackCompleted")
                // A finished native utterance remains completed even if cancellation arrives afterward.
                try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .completed)
                status = "Cue delivered. Rate it only after you decide whether it helped."
                saveTiming(trace.finish("completed"))
            } catch {
                if let cue {
                    do { try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue,
                        status: error is CancellationError ? .cancelled : .failed) }
                    catch { status = "Delivery could not be saved. Feedback is unavailable." }
                }
                status = error is CancellationError ? "Cue cancelled." : error.localizedDescription
                saveTiming(trace.finish(error is CancellationError ? "cancelled" : "failed"))
                lastError = error is CancellationError ? nil : status
                await recordFailure(status, requestedAt: requestedAt)
            }
            episodes = await coach.episodes()
            busy = false; work = nil
        }
    }

    private func saveTiming(_ timing: CueTiming) {
        lastTiming = timing
        let url = URL.applicationSupportDirectory.appending(path: "Voca/Coaching/timings.json")
        try? CueTrace.save(timing, to: url)
    }

    func report(_ issue: FeedbackIssue, episode: Episode, reasons: [TastePreference], text: String, approved: Bool) async throws {
        guard let coach, let current = (await coach.episodes()).first(where: { $0.id == episode.id }) else { throw TasteStore.Failure.invalid }
        // Only explicit fact/strategy diagnoses change Core feedback; timing/wording stay separate.
        if issue == .wrongFacts || issue == .wrongStrategy {
            try await coach.applyFeedback(FeedbackEvent(decisionID: current.id,
                verdict: issue == .wrongFacts ? .invalidEvidence : .unhelpful,
                revision: (current.feedback?.revision ?? 0) + 1))
        }
        episodes = await coach.episodes()
        guard let updated = episodes.first(where: { $0.id == current.id }) else { throw TasteStore.Failure.invalid }
        try taste.save(episode: updated, reasons: reasons, alternative: text, approvedExample: approved, issue: issue)
    }

    private static func canUseFallback(after error: Error) -> Bool {
        if error is GeneratedFields.Failure { return true }
        if let failure = error as? LiteRTExecutor.Failure, case .nativeFailure = failure { return true }
        return false
    }

    private func recordFailure(_ reason: String, requestedAt: Date, modelID: ModelID? = nil) async {
        guard let coach, let directory = failureDirectory else { return }
        let attempts = await coach.episodes()
        guard let episode = attempts.last(where: {
            $0.decision.context.requestedAt == requestedAt && $0.delivery != .completed &&
            (modelID == nil || $0.decision.context.profile.modelID == modelID)
        }) else { return }
        let message = String(reason.prefix(1500))
        failureReasons[episode.id] = message
        try? Data(message.utf8).write(to: directory.appending(path: episode.id.uuidString + ".txt"),
                                     options: [.atomic, .completeFileProtection])
    }

    func stop(voice: PipecatSpeech, executor: LiteRTExecutor) async {
        work?.cancel()
        voice.stop()
        await executor.cancelAll()
        await work?.value
    }

    func deleteEvidence(sourceID: String) async throws {
        guard let coach else { throw CoachEngineError.persistenceFailure }
        let previousIDs = Set(episodes.map(\.id))
        try await coach.deleteEvidence(sourceID: sourceID)
        episodes = await coach.episodes()
        try taste.prune(episodes: episodes)
        for id in previousIDs.subtracting(episodes.map(\.id)) {
            failureReasons.removeValue(forKey: id)
            if let directory = failureDirectory { try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString + ".txt")) }
        }
    }

    func feedback(_ verdict: FeedbackVerdict, episode: Episode) async {
        guard let coach else { return }
        do {
            try await coach.applyFeedback(FeedbackEvent(decisionID: episode.id, verdict: verdict,
                revision: ((await coach.episodes()).first { $0.id == episode.id }?.feedback?.revision ?? 0) + 1))
            episodes = await coach.episodes()
            status = "Feedback saved for this cue’s original model and context."
            lastError = nil
        } catch { status = "Feedback was not saved. Try rating this cue again: \(error.localizedDescription)"; lastError = status }
    }
}

private enum LiveCueFailure: LocalizedError {
    case expired
    var errorDescription: String? { "The conversation context became too old while preparing your cue. Tap again for the current conversation." }
}
