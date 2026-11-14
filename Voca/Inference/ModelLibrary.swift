import Foundation
import Observation
import VocaCore

@MainActor @Observable final class ModelLibrary {
    private(set) var artifacts: [ModelArtifact] = []
    private(set) var status = "Import a generic Gemma 4 model to begin."
    private let indexURL = ModelArtifact.directory.appending(path: "index.json")
        let executor = LiteRTExecutor()
        struct CatalogEntry: Decodable {
        let modelID: String
        let filename: String
        let sha256: String
    }
    static var catalog: [CatalogEntry] {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CatalogEntry].self, from: data)) ?? []
    }
    func importStaged(modelID: String) async throws {
        guard let entry = Self.catalog.first(where: { $0.modelID == modelID }) else { throw ModelArtifact.Failure.invalid }
        let url = URL.documentsDirectory.appending(path: entry.filename)
        try await importFile(url, modelID: modelID, expectedSHA256: entry.sha256)
        try FileManager.default.removeItem(at: url)
    }
    init() {
        do {
            if FileManager.default.fileExists(atPath: indexURL.path) {
                artifacts = try JSONDecoder().decode([ModelArtifact].self, from: Data(contentsOf: indexURL))
            }
        } catch { status = "Model index could not be read. Reimport a model to recover." }
    }
    func importFile(_ url: URL, modelID: String, expectedSHA256: String) async throws {
        status = "Verifying and importing model…"
        let artifact = try await ModelArtifact.importFile(url, modelID: modelID, expectedSHA256: expectedSHA256)
        var next = artifacts.filter { $0.modelID != modelID }
        next.append(artifact)
        try JSONEncoder().encode(next).write(to: indexURL, options: .atomic)
        artifacts = next
        status = "Model imported and SHA-256 verified."
    }
    func load(modelID: String) async throws {
        do {
            if !artifacts.contains(where: { $0.modelID == modelID }),
               let entry = Self.catalog.first(where: { $0.modelID == modelID }),
               FileManager.default.fileExists(atPath: URL.documentsDirectory.appending(path: entry.filename).path) {
                try await importStaged(modelID: modelID)
            }
            guard let artifact = artifacts.first(where: { $0.modelID == modelID }) else { throw ModelArtifact.Failure.invalid }
            status = "Loading model…"
            try await executor.load(artifact)
            status = "\(modelID == "gemma4E2B" ? "E2B fallback" : "E4B") loaded."
        } catch {
            status = "Model failed to load: " + error.localizedDescription
#if DEBUG
            let diagnostic = ["modelID": modelID, "stage": "load", "error": error.localizedDescription,
                              "recordedAt": ISO8601DateFormatter().string(from: Date())]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
                try? data.write(to: URL.documentsDirectory.appending(path: "model-load-failure.json"), options: .atomic)
            }
#endif
            throw error
        }
    }
    }

#if DEBUG
extension ModelLibrary {
    func checkSceneOnDevice(camera: GlassesCamera, pipecatReady: Bool, modelID: String) async {
        var result: [String: Any] = ["passed": false, "stage": "loading", "visionBackend": "metal", "pipecatReady": pipecatReady, "modelID": modelID]
        func report() {
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                try? data.write(to: URL.documentsDirectory.appending(path: "scene-check.json"), options: .atomic)
            }
        }
        report()
        defer { camera.stop() }
        do {
            try camera.configure()
            if !artifacts.contains(where: { $0.modelID == modelID }) { try await importStaged(modelID: modelID) }
            if modelID == "gemma4E4B", ProcessInfo.processInfo.arguments.contains("--switch-from-e2b") {
                result["stage"] = "warmingE2B"; report()
                try await load(modelID: "gemma4E2B")
                let oldProfile = try await executor.activeProfile()
                let warm = ModelRequest(requestID: UUID(), kind: .cue, requestedProfile: oldProfile,
                    prompt: "Say ready.", maxOutputTokens: 16)
                _ = try await executor.generate(warm)
                result["stage"] = "switchingToE4B"; report()
            }
            try await load(modelID: modelID)
            result["stage"] = "camera"; report()
            try await camera.start()
            for _ in 0..<100 {
                if camera.ready { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            let (jpeg, _) = try await camera.photo()
            result["photoBytes"] = jpeg.count
            result["stage"] = "vision"; report()
            let profile = try await executor.activeProfile()
            let request = ModelRequest(requestID: UUID(), kind: .scene, requestedProfile: profile,
                prompt: CuePipeline.scenePrompt, imageJPEG: jpeg, maxOutputTokens: 256,
                responseSchemaJSON: CuePipeline.sceneSchema)
            let began = Date()
            let response = try await executor.generate(request)
            try response.validate(for: request)
            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result["sceneResponseBytes"] = response.text.utf8.count
            result["sceneJSONFence"] = trimmed.hasPrefix("```json") && trimmed.hasSuffix("```")
            result["sceneObjectEnvelope"] = trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result["sceneKeys"] = object.keys.sorted()
                result["settingAllowed"] = ["cafe", "shop", "event", "other"].contains(object["setting"] as? String ?? "")
                if let observations = object["observations"] as? [String] {
                    result["rawObservationCount"] = observations.count
                    result["maxObservationLength"] = observations.map(\.count).max() ?? 0
                }
            }
            report()
            let scene = try GeneratedFields.scene(response.text)
            result["seconds"] = Date().timeIntervalSince(began)
            result["observationCount"] = scene.observations.count
            result["stage"] = "textAfterVision"; report()
            let cueRequest = ModelRequest(requestID: UUID(), kind: .cue, requestedProfile: profile,
                prompt: "Return only JSON with text and sourceIDs. Text must be exactly: Voca is ready to help you find your own words. sourceIDs must be [\"diagnostic\"].",
                maxOutputTokens: 128, responseSchemaJSON: CuePipeline.cueSchema)
            let cueResponse = try await executor.generate(cueRequest)
            try cueResponse.validate(for: cueRequest)
            _ = try GeneratedFields.cue(cueResponse.text, allowedSources: ["diagnostic"])
            result["stage"] = "secondVision"; report()
            let secondResponse = try await executor.generate(request)
            try secondResponse.validate(for: request)
            _ = try GeneratedFields.scene(secondResponse.text)
            result["stage"] = "fullCuePipeline"; report()
            let checkStore = URL.temporaryDirectory.appending(path: "cue-check-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: checkStore) }
            let coach = try CoachEngine(storeURL: checkStore)
            var validatedCues = 0
            var rejectedCues = 0
            for index in 0..<10 {
                result["stage"] = "fullCuePipeline\(index)"; report()
                do {
                    let (freshJPEG, capturedAt) = try await camera.photo()
                    let cue = try await CuePipeline(model: executor, coach: coach).prepare(photo: freshJPEG,
                        observedAt: capturedAt, requestedAt: Date(), goal: index == 1 ? .explain : .enter,
                        knownPoint: index == 1 ? "I am building a local conversation companion." : nil)
                    result["cueWordCount"] = cue.text.split(whereSeparator: \.isWhitespace).count
                    validatedCues += 1
                } catch is GeneratedFields.Failure {
                    rejectedCues += 1
                }
                result["validatedCues"] = validatedCues
                result["rejectedCues"] = rejectedCues
                report()
            }
            result["engineRecoveries"] = await executor.recoveryCount
            result["nativeSequencePassed"] = true
            result["passed"] = rejectedCues == 0; result["stage"] = "completed"
        } catch { result["error"] = error.localizedDescription }
        report()
    }
    func checkOnDevice(modelID: String) async {
        var result: [String: Any] = ["modelID": modelID, "passed": false]
        func report() {
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                try? data.write(to: URL.documentsDirectory.appending(path: "model-check.json"), options: .atomic)
            }
        }
        do {
            result["stage"] = "importing"; report()
            if !artifacts.contains(where: { $0.modelID == modelID }) { try await importStaged(modelID: modelID) }
            result["stage"] = "loading"; report()
            let start = Date()
            try await load(modelID: modelID)
            result["loadSeconds"] = Date().timeIntervalSince(start)
            let profile = try await executor.activeProfile()
            result["artifactSHA256"] = profile.artifactSHA256
            for index in 0..<2 {
                result["stage"] = "generating\(index)"; report()
                let request = ModelRequest(requestID: UUID(), kind: .cue, requestedProfile: profile,
                    prompt: "Return only JSON with text and sourceIDs. Text must be exactly: Voca is ready to help you find your own words. sourceIDs must be [\"diagnostic\"].",
                    maxOutputTokens: 128, responseSchemaJSON: CuePipeline.cueSchema)
                let began = Date()
                let response = try await executor.generate(request)
                try response.validate(for: request)
                _ = try GeneratedFields.cue(response.text, allowedSources: ["diagnostic"])
                result["generation\(index)Seconds"] = Date().timeIntervalSince(began)
            }
            result["passed"] = true; result["stage"] = "completed"
        } catch { result["stage"] = "failed"; result["error"] = error.localizedDescription }
        report()
    }
}
#endif
