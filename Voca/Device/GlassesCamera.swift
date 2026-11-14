import Foundation
import MWDATCore
import MWDATCamera
import Observation

@MainActor @Observable final class GlassesCamera {
    private(set) var status = "Glasses not connected"
    private(set) var ready = false
    private(set) var previewJPEG: Data?
    private var session: DeviceSession?
    private var camera: Camera?
    private let sessionTokens = ListenerTokenBag()
    private let streamTokens = ListenerTokenBag()
    private var capture: CheckedContinuation<(Data, Date), Error>?
    private var captureTimeout: Task<Void, Never>?
    private var generation = 0
    private var captureRequestedAt: Date?
    private var configured = false
    enum Failure: LocalizedError {
        case notReady, busy, interrupted, timeout
        var errorDescription: String? {
            switch self {
            case .notReady: "Connect your glasses and start the camera first."
            case .busy: "A photo is already being captured."
            case .interrupted: "Photo capture stopped. Reconnect your glasses and try again."
            case .timeout: "The glasses did not return a photo. Reconnect and try again."
            }
        }
    }
    func configure() throws {
        guard !configured else { return }
        try Wearables.configure()
        configured = true
    }
    func register() async throws {
        try configure()
        try await Wearables.shared.startRegistration()
        status = "Finish connecting in Meta AI, then start the camera."
    }
    func handleURL(_ url: URL) async throws {
        try configure()
        _ = try await Wearables.shared.handleUrl(url)
    }
    func start() async throws {
        try configure()
        guard session == nil else { return }
        guard try await Wearables.shared.requestPermission(.camera) == .granted else { throw Failure.notReady }
        let current = generation
        let session = try Wearables.shared.createSession(deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))
        self.session = session
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                if state == .started { self.startStream() }
                if state == .stopped { self.stop() }
            }
        }.store(in: sessionTokens)
        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.stop(); self.status = error.localizedDescription
            }
        }.store(in: sessionTokens)
        status = "Starting glasses camera…"
        try session.start()
    }
    private func startStream() {
        guard let session, camera == nil else { return }
        do {
            let config = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 24)
            guard let camera = try session.addCamera(config: config) else { throw Failure.notReady }
            self.camera = camera
            let current = generation
            camera.stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    self.ready = state == .streaming
                    self.status = self.ready ? "Glasses camera ready" : "Camera: \(state)"
                }
            }.store(in: streamTokens)
            camera.stream.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor in
                    guard let self, current == self.generation, let capture = self.capture else { return }
                    self.capture = nil
                    self.captureTimeout?.cancel()
                    self.previewJPEG = photo.data
                    capture.resume(returning: (photo.data, self.captureRequestedAt ?? Date()))
                    self.captureRequestedAt = nil
                }
            }.store(in: streamTokens)
            camera.stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    self.stop(); self.status = error.localizedDescription
                }
            }.store(in: streamTokens)
            camera.stream.start()
        } catch { stop(); status = error.localizedDescription }
    }
    func photo() async throws -> (Data, Date) {
        guard ready else { throw Failure.notReady }
        guard capture == nil else { throw Failure.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                captureRequestedAt = Date()
                capture = continuation
                guard camera?.stream.capturePhoto(format: .jpeg) == true else {
                    capture = nil; continuation.resume(throwing: Failure.notReady); return
                }
                captureTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.stop()
                    self?.status = Failure.timeout.localizedDescription
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }
    func stop() {
        generation += 1
        ready = false
        captureTimeout?.cancel()
        capture?.resume(throwing: Failure.interrupted)
        capture = nil; captureRequestedAt = nil
        camera?.stop(); camera = nil
        session?.stop(); session = nil
        sessionTokens.clear(); streamTokens.clear()
        status = "Glasses camera stopped"
    }
}
