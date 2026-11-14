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
        guard let artifact = artifacts.first(where: { $0.modelID == modelID }) else { throw ModelArtifact.Failure.invalid }
        status = "Loading model…"
        do { try await executor.load(artifact); status = "Model loaded. A device inference check is still required." }
        catch { status = "Model failed to load. Select another imported model to recover."; throw error }
    }
    }

#if DEBUG
extension ModelLibrary {
    func checkSceneOnDevice(camera: GlassesCamera, pipecatReady: Bool) async {
        var result: [String: Any] = ["passed": false, "stage": "loading", "visionBackend": "metal", "pipecatReady": pipecatReady]
        func report() {
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                try? data.write(to: URL.documentsDirectory.appending(path: "scene-check.json"), options: .atomic)
            }
        }
        report()
        defer { camera.stop() }
        do {
            try camera.configure()
            try await load(modelID: "gemma4E4B")
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
            for index in 0..<3 {
                result["stage"] = "fullCuePipeline\(index)"; report()
                let cue = try await CuePipeline(model: executor, coach: coach).prepare(photo: jpeg,
                    observedAt: Date(), requestedAt: Date(), goal: index == 1 ? .explain : .enter,
                    knownPoint: index == 1 ? "I am building a local conversation companion." : nil)
                result["cueWordCount"] = cue.text.split(whereSeparator: \.isWhitespace).count
            }
            result["passed"] = true; result["stage"] = "completed"
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
