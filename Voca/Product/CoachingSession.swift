import Foundation
import Observation
import VocaCore

@MainActor @Observable final class CoachingSession {
    var goal: Goal = .enter
    var knownPoint = ""
    private(set) var status = "Load a model, start the camera, and confirm your glasses audio output."
    private(set) var episodes: [Episode] = []
    private(set) var busy = false
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
            coach = store
            episodes = await store.episodes()
            let failures = directory.appending(path: "Failures", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
            failureDirectory = failures
            for episode in episodes where episode.delivery != .completed {
                if let reason = try? String(contentsOf: failures.appending(path: episode.id.uuidString + ".txt"), encoding: .utf8) {
                    failureReasons[episode.id] = reason
                }
            }
        } catch { status = "Coaching history could not be opened. Your existing data has been preserved. Restart Voca to retry."; lastError = status }
    }

    func request(models: ModelLibrary, camera: GlassesCamera, voice: PipecatSpeech, snapshot: MemorySnapshot? = nil) {
        guard !busy, let coach else { return }
        guard camera.ready, voice.ready else { status = "Start the glasses camera and embedded Pipecat first."; return }
        busy = true
        lastError = nil
        let model = models.executor
        let requestedAt = Date(), goal = self.goal, knownPoint = self.knownPoint
        work = Task {
            var cue: CueResult?
            do {
                status = "Capturing context…"
                let (photo, observedAt) = try await camera.photo()
                status = "Finding a grounded cue on this iPhone…"
                let requestedProfile = try await model.activeProfile()
                do {
                    cue = try await CuePipeline(model: model, coach: coach).prepare(photo: photo, observedAt: observedAt,
                        requestedAt: requestedAt, goal: goal, knownPoint: knownPoint, snapshot: snapshot)
                } catch LiteRTExecutor.Failure.nativeFailure where requestedProfile.modelID == .gemma4E4B {
                    await recordFailure("E4B native inference failed after its recovery attempt. Voca attempted E2B fallback.", requestedAt: requestedAt, modelID: .gemma4E4B)
                    try Task.checkCancellation()
                    status = "E4B recovery failed. Loading E2B fallback for this cue…"
                    try await models.load(modelID: "gemma4E2B")
                    try Task.checkCancellation()
                    // A new pipeline decision records E2B's profile; the failed E4B episode stays failed.
                    cue = try await CuePipeline(model: model, coach: coach).prepare(photo: photo, observedAt: observedAt,
                        requestedAt: requestedAt, goal: goal, knownPoint: knownPoint, snapshot: snapshot)
                }
                guard let cue else { return }
                try Task.checkCancellation()
                try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .pending)
                status = cue.actualProfile.modelID == .gemma4E2B ? "Speaking your cue with E2B fallback…" : "Speaking your cue with E4B…"
                try await voice.speak(cue.text)
                // A finished native utterance remains completed even if cancellation arrives afterward.
                try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .completed)
                status = "Cue delivered. Rate it only after you decide whether it helped."
            } catch {
                if let cue {
                    do { try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue,
                        status: error is CancellationError ? .cancelled : .failed) }
                    catch { status = "Delivery could not be saved. Feedback is unavailable." }
                }
                status = error is CancellationError ? "Cue cancelled." : error.localizedDescription
                lastError = error is CancellationError ? nil : status
                await recordFailure(status, requestedAt: requestedAt)
            }
            episodes = await coach.episodes()
            busy = false; work = nil
        }
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
        for id in previousIDs.subtracting(episodes.map(\.id)) {
            failureReasons.removeValue(forKey: id)
            if let directory = failureDirectory { try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString + ".txt")) }
        }
    }

    func feedback(_ verdict: FeedbackVerdict, episode: Episode) async {
        guard let coach else { return }
        do {
            try await coach.applyFeedback(FeedbackEvent(decisionID: episode.id, verdict: verdict,
                revision: (episode.feedback?.revision ?? 0) + 1))
            episodes = await coach.episodes()
            status = "Feedback saved for this cue’s original model and context."
            lastError = nil
        } catch { status = "Feedback was not saved. Try rating this cue again: \(error.localizedDescription)"; lastError = status }
    }
}
