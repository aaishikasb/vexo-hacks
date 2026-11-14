import Foundation
import Observation
import VocaCore

@MainActor @Observable final class CoachingSession {
    var goal: Goal = .enter
    var knownPoint = ""
    private(set) var status = "Load a model, start the camera, and confirm your glasses audio output."
    private(set) var episodes: [Episode] = []
    private(set) var busy = false
    private var coach: CoachEngine?
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
        } catch { status = "Coaching history could not be opened. Your existing data has been preserved." }
    }

    func request(model: any ModelGenerating, camera: GlassesCamera, voice: PipecatSpeech) {
        guard !busy, let coach else { return }
        guard camera.ready, voice.ready else { status = "Start the glasses camera and embedded Pipecat first."; return }
        busy = true
        let requestedAt = Date(), goal = self.goal, knownPoint = self.knownPoint
        work = Task {
            var cue: CueResult?
            do {
                status = "Capturing context…"
                let (photo, observedAt) = try await camera.photo()
                status = "Finding a grounded cue on this iPhone…"
                cue = try await CuePipeline(model: model, coach: coach).prepare(photo: photo, observedAt: observedAt,
                    requestedAt: requestedAt, goal: goal, knownPoint: knownPoint)
                guard let cue else { return }
                try Task.checkCancellation()
                try await coach.recordDelivery(decisionID: cue.decisionID, cue: cue, status: .pending)
                status = "Speaking your cue…"
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
            }
            episodes = await coach.episodes()
            busy = false; work = nil
        }
    }

    func stop(voice: PipecatSpeech, executor: LiteRTExecutor) async {
        work?.cancel()
        voice.stop()
        await executor.cancelAll()
        await work?.value
    }

    func feedback(_ verdict: FeedbackVerdict, episode: Episode) async {
        guard let coach else { return }
        do {
            try await coach.applyFeedback(FeedbackEvent(decisionID: episode.id, verdict: verdict,
                revision: (episode.feedback?.revision ?? 0) + 1))
            episodes = await coach.episodes()
            status = "Feedback saved for this cue’s original model and context."
        } catch { status = "Feedback was not saved: \(error.localizedDescription)" }
    }
}
