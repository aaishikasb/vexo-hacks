import Foundation
import Observation

@MainActor @Observable final class ModelLibrary {
    private(set) var artifacts: [ModelArtifact] = []
    private(set) var status = "Import a generic Gemma 4 model to begin."
    private let indexURL = ModelArtifact.directory.appending(path: "index.json")
    #if canImport(VocaCore)
    let executor = LiteRTExecutor()
    #endif
    init() {
        do {
            if FileManager.default.fileExists(atPath: indexURL.path) {
                artifacts = try JSONDecoder().decode([ModelArtifact].self, from: Data(contentsOf: indexURL))
            }
        } catch { status = "Model index could not be read. Reimport a model to recover." }
    }
    func importFile(_ url: URL, modelID: String, expectedSHA256: String) async throws {
        let artifact = try await ModelArtifact.importFile(url, modelID: modelID, expectedSHA256: expectedSHA256)
        var next = artifacts.filter { $0.modelID != modelID }
        next.append(artifact)
        try JSONEncoder().encode(next).write(to: indexURL, options: .atomic)
        artifacts = next
        status = "Model imported and SHA-256 verified."
    }
    #if canImport(VocaCore)
    func load(modelID: String) async throws {
        guard let artifact = artifacts.first(where: { $0.modelID == modelID }) else { throw ModelArtifact.Failure.invalid }
        status = "Loading model…"
        do { try await executor.load(artifact); status = "Model loaded. A device inference check is still required." }
        catch { status = "Model failed to load. Select another imported model to recover."; throw error }
    }
    #endif
}
