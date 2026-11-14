import Foundation
import MWDATCore
import MWDATCamera
import Observation

@MainActor @Observable final class GlassesCamera {
    private(set) var status = "Glasses not connected"
    private(set) var ready = false
    private(set) var previewJPEG: Data?
    private var session: DeviceSession?
    private var selector: AutoDeviceSelector?
    private var startupTimeout: Task<Void, Never>?
    private var camera: Camera?
    private let sessionTokens = ListenerTokenBag()
    private let streamTokens = ListenerTokenBag()
    private var capture: CheckedContinuation<(Data, Date), Error>?
    private var captureTimeout: Task<Void, Never>?
    private var generation = 0
    private var captureRequestedAt: Date?
    private var configured = false
    enum Failure: LocalizedError {
        case notReady, busy, interrupted, timeout, notRegistered, unavailable, deviceUpdate, sdkUpdate
        var errorDescription: String? {
            switch self {
            case .notRegistered: "Finish connecting Voca in Meta AI before starting the camera."
            case .unavailable: "Meta AI has not exposed any glasses to Voca. Wear the glasses with the arms open, check their connection in Meta AI, then retry."
            case .deviceUpdate: "The glasses need an update for this SDK. Open Meta AI and check the glasses and DAT app updates."
            case .sdkUpdate: "These glasses require a newer iOS DAT SDK. Camera startup stopped."
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
        selector = AutoDeviceSelector(wearables: Wearables.shared)
        configured = true
    }
    func register() async throws {
        try configure()
        if Wearables.shared.registrationState == .registered {
            status = "Meta AI registration complete. Start the glasses camera."
            return
        }
        status = "Waiting for registration in Meta AI…"
        try await Wearables.shared.startRegistration()
        try Task.checkCancellation()
        status = "Meta AI registration: \(Wearables.shared.registrationState.description). Start the camera when registered."
    }
    func handleURL(_ url: URL) async throws {
        try configure()
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        _ = try await Wearables.shared.handleUrl(url)
    }
    func start() async throws {
        try configure()
        guard session == nil else { return }
        guard Wearables.shared.registrationState == .registered else { throw Failure.notRegistered }
        status = "Checking glasses camera permission…"
        if try await Wearables.shared.checkPermissionStatus(.camera) != .granted {
            status = "Waiting for camera permission in Meta AI…"
            guard try await Wearables.shared.requestPermission(.camera) == .granted else { throw Failure.notReady }
        }
        try Task.checkCancellation()
        guard !Wearables.shared.devices.isEmpty else { throw Failure.unavailable }
        let compatibility = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0)?.compatibility() }
        if !compatibility.contains(.compatible) {
            if compatibility.contains(.deviceUpdateRequired) { throw Failure.deviceUpdate }
            if compatibility.contains(.sdkUpdateRequired) { throw Failure.sdkUpdate }
        }
        guard let selector else { throw Failure.notReady }
        let current = generation
        let session = try Wearables.shared.createSession(deviceSelector: selector)
        self.session = session
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.status = "Glasses session: \(state.description)"
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
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == current, !self.ready else { return }
            let lastStatus = self.status
            self.stop()
            self.status = "Camera did not become ready (\(lastStatus)). Check the glasses are connected and worn, then retry."
        }
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
                    if self.ready { self.startupTimeout?.cancel() }
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
    func suspendForBackground() {
        // Meta permission redirects background the app before a camera session exists.
        if session != nil { stop() }
    }
    func stop() {
        generation += 1
        ready = false
        startupTimeout?.cancel()
        captureTimeout?.cancel()
        capture?.resume(throwing: Failure.interrupted)
        capture = nil; captureRequestedAt = nil
        camera?.stop(); camera = nil
        session?.stop(); session = nil
        sessionTokens.clear(); streamTokens.clear()
        status = "Glasses camera stopped"
    }
}
