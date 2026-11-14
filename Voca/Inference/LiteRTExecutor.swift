import Foundation
import LiteRTLM
import Metal
import VocaCore

actor LiteRTExecutor: ModelGenerating {
    enum Failure: LocalizedError {
        case notLoaded, switching, invalidRequest, profileMismatch, outputLimit, nativeFailure
        var errorDescription: String? {
            switch self {
            case .notLoaded: "Import and load a model before requesting a cue."
            case .switching: "Wait for the model switch to finish."
            case .invalidRequest: "The model request exceeded supported limits."
            case .profileMismatch: "The model changed during this request. Request a new cue."
            case .outputLimit: "The model response was too long. Request a new cue."
            case .nativeFailure: "On-device inference failed and the model was released. Reload E4B, or select and load E2B before trying again."
            }
        }
    }
    private struct Job {
        let request: ModelRequest
        let result: CheckedContinuation<ModelResponse, Error>
    }
    private var engine: Engine?
    private var engineConfig: EngineConfig?
    private(set) var recoveryCount = 0
    private var profile: ModelProfile?
    private var queue: [Job] = []
    private var running: Task<Void, Never>?
    private var activeID: UUID?
    private var conversation: Conversation?
    private var cancelled = Set<UUID>()
    private var switching = false

    func activeProfile() throws -> ModelProfile {
        guard !switching, let profile else { throw Failure.notLoaded }
        return profile
    }
    func load(_ artifact: ModelArtifact) async throws {
        guard !switching else { throw Failure.switching }
        switching = true
        defer { switching = false }
        await cancelAll()
        engine = nil; profile = nil; engineConfig = nil
        guard let modelID = ModelID(rawValue: artifact.modelID) else { throw Failure.invalidRequest }
        let url = ModelArtifact.directory.appending(path: artifact.filename)
        guard artifact.filename == artifact.sha256 + ".litertlm", try ModelArtifact.hash(url) == artifact.sha256 else {
            throw ModelArtifact.Failure.checksum
        }
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.visualTokenBudget = 280
        let config = try EngineConfig(modelPath: url.path, backend: .gpu, visionBackend: .gpu, maxNumTokens: 2048, cacheDir: URL.cachesDirectory.path)
        let newEngine = Engine(engineConfig: config)
        try await newEngine.initialize()
        try Task.checkCancellation()
        engine = newEngine
        engineConfig = config
        recoveryCount = 0
        profile = ModelProfile(modelID: modelID, artifactSHA256: artifact.sha256, promptVersion: "voca-v2.6-complete-json-instance")
    }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation()
        guard !switching else { throw Failure.switching }
        guard let profile, engine != nil else { throw Failure.notLoaded }
        guard Self.matches(profile, request.requestedProfile) else { throw Failure.profileMismatch }
        guard request.prompt.utf8.count <= 16_000, (1...512).contains(request.maxOutputTokens),
              (request.imageJPEG?.count ?? 0) <= 12_000_000 else { throw Failure.invalidRequest }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result in
                queue.append(Job(request: request, result: result))
                startNext()
            }
        } onCancel: { Task { await self.cancel(requestID: request.requestID) } }
    }
    private func startNext() {
        guard running == nil, !switching, !queue.isEmpty else { return }
        let index = queue.firstIndex { $0.request.kind == .cue || $0.request.kind == .scene } ?? 0
        let job = queue.remove(at: index)
        activeID = job.request.requestID
        running = Task {
            do { job.result.resume(returning: try await executeWithRecovery(job.request)) }
            catch {
#if DEBUG
                let diagnostic: [String: Any] = [
                    "kind": job.request.kind.rawValue,
                    "modelID": job.request.requestedProfile.modelID.rawValue,
                    "promptVersion": job.request.requestedProfile.promptVersion,
                    "promptBytes": job.request.prompt.utf8.count,
                    "imageBytes": job.request.imageJPEG?.count ?? 0,
                    "metalAllocatedBytes": MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0,
                    "error": error.localizedDescription,
                    "recordedAt": ISO8601DateFormatter().string(from: Date())
                ]
                if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "inference-failure.json"), options: .atomic)
                }
#endif
                if error is LiteRTLMError {
                    // A failed native allocation can leave reusable executor state incomplete.
                    conversation = nil; engine = nil; profile = nil
                    let pending = queue; queue.removeAll()
                    for next in pending { next.result.resume(throwing: Failure.notLoaded) }
                    job.result.resume(throwing: Failure.nativeFailure)
                } else {
                    job.result.resume(throwing: error)
                }
            }
            cancelled.remove(job.request.requestID)
            conversation = nil; activeID = nil; running = nil
            startNext()
        }
    }
    private func executeWithRecovery(_ request: ModelRequest) async throws -> ModelResponse {
        do { return try await execute(request) }
        catch {
            guard !cancelled.contains(request.requestID) else { throw CancellationError() }
            guard error is LiteRTLMError, request.requestedProfile.modelID == .gemma4E4B,
                  let config = engineConfig else { throw error }
            // Generation has no delivery side effect: retry once with the same verified artifact/profile.
            conversation = nil; engine = nil
            let replacement = Engine(engineConfig: config)
            try await replacement.initialize()
            engine = replacement
            guard !cancelled.contains(request.requestID) else { throw CancellationError() }
            recoveryCount += 1
            return try await execute(request)
        }
    }
    private func execute(_ request: ModelRequest) async throws -> ModelResponse {
        guard let engine, let profile else { throw Failure.notLoaded }
        let config = ConversationConfig(thinkingConfig: ThinkingConfig(enableThinking: false), automaticToolCalling: false, enableResponseFormat: false)
        let conversation = try await engine.createConversation(with: config)
        self.conversation = conversation
        guard !cancelled.contains(request.requestID) else { throw CancellationError() }
        // shortcut: Native constrained decoding aborts in llguidance allocation on device; recheck after an SDK fix.
        let prompt = (request.responseSchemaJSON.map {
            "Output schema metadata (do not repeat this schema): " + $0 + "\n\n"
        } ?? "") + request.prompt + (request.responseSchemaJSON == nil ? "" :
            "\nReturn only the answer object with actual values, not the schema, without markdown.")
        var contents: [Content] = [.text(prompt)]
        if let image = request.imageJPEG { contents.append(.imageData(image)) }
        // Complete-response API returns after native execution, avoiding stream-terminal callback overlap.
        let response = try await conversation.sendMessage(Message(contents: contents),
            maxOutputTokens: request.maxOutputTokens,
            thinkingConfig: ThinkingConfig(enableThinking: false), responseFormat: nil)
        guard !cancelled.contains(request.requestID) else { throw CancellationError() }
        let text = response.toString
        guard text.utf8.count <= 12_000 else { throw Failure.outputLimit }
        return ModelResponse(requestID: request.requestID, actualProfile: profile, text: text)
    }
    func cancel(requestID: UUID) {
        if let index = queue.firstIndex(where: { $0.request.requestID == requestID }) {
            queue.remove(at: index).result.resume(throwing: CancellationError())
        }
        if activeID == requestID {
            cancelled.insert(requestID)
            try? conversation?.cancel()
        }
    }
    func cancelAll() async {
        let queued = queue; queue.removeAll()
        for job in queued { job.result.resume(throwing: CancellationError()) }
        if let activeID { cancel(requestID: activeID) }
        let task = running
        await task?.value
    }
    nonisolated static func matches(_ lhs: ModelProfile, _ rhs: ModelProfile) -> Bool {
        lhs.modelID == rhs.modelID && lhs.artifactSHA256 == rhs.artifactSHA256 && lhs.promptVersion == rhs.promptVersion
    }
}
