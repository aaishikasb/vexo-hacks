#if DEBUG
import Foundation
import UIKit
import Metal
import VocaCore

/// Device inference with synthetic evidence only. Never records delivery, feedback, or microphone audio.
@MainActor enum InferenceStressCheck {
    private actor FixtureModel: ModelGenerating {
        let base: LiteRTExecutor
        var outputs: [String] = []
        init(base: LiteRTExecutor) { self.base = base }
        func activeProfile() async throws -> ModelProfile { try await base.activeProfile() }
        func generate(_ request: ModelRequest) async throws -> ModelResponse {
            let response = try await base.generate(request)
            outputs.append(response.text)
            return response
        }
        func reset() { outputs.removeAll() }
        func captured() -> [String] { outputs }
    }
    static func run(models: ModelLibrary, voice: PipecatSpeech, audio: NativeAudio) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inference-stress-" + UUID().uuidString)
        let output = URL.documentsDirectory.appending(path: "inference-stress-check.json")
        let sustained = ProcessInfo.processInfo.arguments.contains("--sustained")
        let cycles = ProcessInfo.processInfo.arguments.contains("--e2b") ? ["gemma4E2B"] :
            (sustained ? ["gemma4E4B", "gemma4E2B"] : ["gemma4E4B", "gemma4E2B", "gemma4E4B"])
        let countPerCycle = sustained ? 30 : 10
        let planned = cycles.count * countPerCycle
        var rows: [[String: Any]] = []
        var loads: [[String: Any]] = []
        var report: [String: Any] = ["fixture": "synthetic UIKit images and synthetic text; no playback or microphone", "plannedCases": planned, "syntheticTasteEnabled": ProcessInfo.processInfo.arguments.contains("--taste"), "stage": "startingPipecat", "startedAt": Date().ISO8601Format()]
        func save() {
            report["cases"] = rows; report["loads"] = loads
            report["completedCases"] = rows.count
            report["passedCases"] = rows.filter { $0["outcome"] as? String == "validated" }.count
            report["noEligibleCases"] = rows.filter { $0["outcome"] as? String == "noEligibleStrategy" }.count
            report["failedCases"] = rows.filter { $0["outcome"] as? String == "failed" }.count
            report["updatedAt"] = Date().ISO8601Format()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: [.atomic, .completeFileProtection])
            }
        }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdle
            try? FileManager.default.removeItem(at: directory)
        }
        save()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let coach = try CoachEngine(storeURL: directory.appending(path: "episodes.json"))
            voice.start(audio: audio)
            for _ in 0..<100 {
                if voice.ready { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard voice.ready else { throw CheckFailure.pipecat }
            report["pipecatReady"] = true
            let fixtureModel = FixtureModel(base: models.executor)
            let photos = [try image(shop: false), try image(shop: true)]
            for (cycle, modelID) in cycles.enumerated() {
                try Task.checkCancellation()
                report["stage"] = "loading"; report["cycle"] = cycle; report["modelID"] = modelID; save()
                let loadStart = Date()
                do {
                    try await models.load(modelID: modelID)
                    loads.append(["cycle": cycle, "modelID": modelID, "seconds": Date().timeIntervalSince(loadStart), "outcome": "loaded"])
                } catch {
                    loads.append(["cycle": cycle, "modelID": modelID, "seconds": Date().timeIntervalSince(loadStart), "outcome": "failed", "error": error.localizedDescription])
                    save(); continue
                }
                var reloaded = false
                for index in 0..<countPerCycle {
                    try Task.checkCancellation()
                    await fixtureModel.reset()
                    let start = Date(), photoCase = index.isMultiple(of: 2)
                    let goal: Goal = [.enter, .explain, .deepen][index % 3]
                    report["stage"] = "generating"; report["caseIndex"] = index; save()
                    var row: [String: Any] = ["cycle": cycle, "index": index, "modelID": modelID, "input": photoCase ? "syntheticImage" : "syntheticScene", "goal": goal.rawValue]
                    do {
                        if (try? await models.executor.activeProfile()) == nil, !reloaded {
                            reloaded = true
                            try await models.load(modelID: modelID)
                            row["reloadedAfterFailure"] = true
                        }
                        let snapshot = MemorySnapshot(approvedMemories: [Evidence(sourceID: "fixture-memory", text: "I enjoy making pottery on weekends.", speaker: "wearer", utteredAt: start, shareApproved: true)], dialogue: [], fetchedAt: start, coverage: .unavailable)
                        let style = ProcessInfo.processInfo.arguments.contains("--taste") ?
                            TasteGuidance(instructions: [TastePreference.relaxed.instruction, TastePreference.concise.instruction],
                                examples: ["Ask what they recommend, then share a little about your own experience."]) : TasteGuidance()
                        let pipeline = CuePipeline(model: fixtureModel, coach: coach, taste: style)
                        let cue: CueResult
                        if photoCase {
                            cue = try await pipeline.prepare(photo: photos[(index / 2) % 2], observedAt: start, requestedAt: start, goal: goal, knownPoint: "I make simple pottery mugs on weekends.", snapshot: snapshot)
                        } else {
                            let scene = SceneFacts(requestID: UUID(), observedAt: start, setting: index % 4 == 1 ? .cafe : .shop, observations: ["A counter holds cups and a small menu.", "There are wooden tables."], uncertain: false)
                            cue = try await pipeline.prepare(scene: scene, requestedAt: start, goal: goal, knownPoint: "I make simple pottery mugs on weekends.", snapshot: snapshot)
                        }
                        row["outcome"] = "validated"; row["actualModelID"] = cue.actualProfile.modelID.rawValue
                        row["wordCount"] = cue.text.split(whereSeparator: \.isWhitespace).count
                    } catch CuePipeline.Failure.noStrategy {
                        row["outcome"] = "noEligibleStrategy"
                    } catch {
                        if error is CancellationError { throw error }
                        row["outcome"] = "failed"; row["error"] = error.localizedDescription
                        row["syntheticOutputs"] = await fixtureModel.captured()
                    }
                    row["seconds"] = Date().timeIntervalSince(start)
                    row["metalAllocatedBytes"] = MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0
                    row["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
                    row["engineRecoveries"] = await models.executor.recoveryCount
                    rows.append(row); save()
                }
            }
            report["stage"] = "cancellation"; save()
            if let profile = try? await models.executor.activeProfile() {
                let executor = models.executor
                let blocker = ModelRequest(requestID: UUID(), kind: .practice, requestedProfile: profile, prompt: "Describe a quiet cafe in three short sentences.", maxOutputTokens: 128)
                let first = Task { try await executor.generate(blocker) }
                await Task.yield()
                let request = ModelRequest(requestID: UUID(), kind: .practice, requestedProfile: profile, prompt: "Say ready.", maxOutputTokens: 16)
                let cancelled = Task { try await executor.generate(request) }
                await Task.yield()
                cancelled.cancel()
                var cancellationObserved = false
                do { _ = try await cancelled.value } catch is CancellationError { cancellationObserved = true } catch { report["cancellationError"] = error.localizedDescription }
                _ = try? await first.value
                report["cancelledRequestRejected"] = cancellationObserved
                let next = ModelRequest(requestID: UUID(), kind: .cue, requestedProfile: profile, prompt: "Return only JSON: {\"text\":\"Ask what they recommend from the cafe menu today.\",\"sourceIDs\":[\"fixture-scene\"]}", maxOutputTokens: 96)
                let response = try await executor.generate(next)
                try response.validate(for: next)
                _ = try GeneratedFields.cue(response.text, allowedSources: ["fixture-scene"])
                report["postCancellationValidated"] = true
                report["cancellationQueuePosition"] = "Submission overlap requested; exact native queue position not instrumented"
            } else { report["cancellationSkipped"] = "No model remained loaded" }
            report["stage"] = "finished"
            report["passed"] = rows.count == planned && rows.allSatisfy { $0["outcome"] as? String == "validated" } && report["cancelledRequestRejected"] as? Bool == true && report["postCancellationValidated"] as? Bool == true
        } catch {
            report["stage"] = error is CancellationError ? "cancelled" : "failed"
            report["error"] = error.localizedDescription; report["passed"] = false
        }
        save()
    }

    private enum CheckFailure: Error { case pipecat, image }
    private static func image(shop: Bool) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 384))
        let image = renderer.image { context in
            UIColor(white: 0.88, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 384, height: 384))
            UIColor.brown.setFill(); context.fill(CGRect(x: 0, y: 235, width: 384, height: 149))
            UIColor.white.setFill()
            for x in [60, 160, 260] { context.fill(CGRect(x: CGFloat(x), y: 195, width: 48, height: 40)) }
            let text = shop ? "POTTERY SHOP\nHandmade mugs" : "CAFE\nCoffee • Tea"
            (text as NSString).draw(in: CGRect(x: 40, y: 50, width: 310, height: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: UIColor.black])
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw CheckFailure.image }
        return jpeg
    }
}
#endif
