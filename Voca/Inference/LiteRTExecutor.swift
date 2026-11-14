import Foundation
import LiteRTLM
import VocaCore

actor LiteRTExecutor: ModelGenerating {
    enum Failure: LocalizedError {
        case notLoaded, switching, invalidRequest, profileMismatch, outputLimit
        var errorDescription: String? {
            switch self {
            case .notLoaded: "Import and load a model before requesting a cue."
            case .switching: "Wait for the model switch to finish."
            case .invalidRequest: "The model request exceeded supported limits."
            case .profileMismatch: "The model changed during this request. Request a new cue."
            case .outputLimit: "The model response was too long. Request a new cue."
            }
        }
    }
    private struct Job {
        let request: ModelRequest
        let result: CheckedContinuation<ModelResponse, Error>
    }
    private var engine: Engine?
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
        engine = nil; profile = nil
        guard let modelID = ModelID(rawValue: artifact.modelID) else { throw Failure.invalidRequest }
        let url = ModelArtifact.directory.appending(path: artifact.filename)
        guard artifact.filename == artifact.sha256 + ".litertlm", try ModelArtifact.hash(url) == artifact.sha256 else {
            throw ModelArtifact.Failure.checksum
        }
        let config = try EngineConfig(modelPath: url.path, backend: .gpu, visionBackend: .cpu(), maxNumTokens: 4096, cacheDir: URL.cachesDirectory.path)
        let newEngine = Engine(engineConfig: config)
        try await newEngine.initialize()
        try Task.checkCancellation()
        engine = newEngine
        profile = ModelProfile(modelID: modelID, artifactSHA256: artifact.sha256, promptVersion: "voca-v2.1")
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
            do { job.result.resume(returning: try await execute(job.request)) }
            catch { job.result.resume(throwing: error) }
            cancelled.remove(job.request.requestID)
            conversation = nil; activeID = nil; running = nil
            startNext()
        }
    }
    private func execute(_ request: ModelRequest) async throws -> ModelResponse {
        guard let engine, let profile else { throw Failure.notLoaded }
        let config = ConversationConfig(thinkingConfig: ThinkingConfig(enableThinking: false), automaticToolCalling: false, enableResponseFormat: request.responseSchemaJSON != nil)
        let conversation = try await engine.createConversation(with: config)
        self.conversation = conversation
        guard !cancelled.contains(request.requestID) else { throw CancellationError() }
        var contents: [Content] = [.text(request.prompt)]
        if let image = request.imageJPEG { contents.append(.imageData(image)) }
        let format = try request.responseSchemaJSON.map { try ResponseFormat.json(schema: $0) }
        var text = ""
        var outputExceeded = false
        // Drain the native stream even after cancellation; never reuse its engine early.
        for try await chunk in conversation.sendMessageStream(Message(contents: contents), maxOutputTokens: request.maxOutputTokens, thinkingConfig: ThinkingConfig(enableThinking: false), responseFormat: format) {
            if cancelled.contains(request.requestID) || outputExceeded { continue }
            text += chunk.toString
            if text.utf8.count > 12_000 { outputExceeded = true; try conversation.cancel() }
        }
        guard !outputExceeded else { throw Failure.outputLimit }
        guard !cancelled.contains(request.requestID) else { throw CancellationError() }
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
