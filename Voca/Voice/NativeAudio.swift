import AVFoundation
import Foundation
import Observation
import Synchronization

@MainActor @Observable final class NativeAudio: NSObject, AVSpeechSynthesizerDelegate {
    enum Failure: LocalizedError {
        case route, interrupted, busy
        var errorDescription: String? {
            switch self {
            case .route: "Select your glasses in the iPhone audio output picker, then confirm the route before speaking."
            case .interrupted: "Speech stopped because playback was interrupted or the output route changed."
            case .busy: "Wait for speech to finish or stop it first."
            }
        }
    }
    private(set) var status = "No glasses audio route confirmed"
    private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()
    private var routeUID: String?
    private var utterance: AVSpeechUtterance?
    private var playbackID: UUID?
    private nonisolated let callbackIDs = Mutex<[ObjectIdentifier: UUID]>([:])
    private var completion: CheckedContinuation<Void, Error>?
    var onPlaybackStarted: (() -> Void)?
    var onInterruption: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
    }
    var currentOutput: String { session.currentRoute.outputs.map(\.portName).joined(separator: ", ") }
    func confirmGlassesRoute() throws {
        let outputs = session.currentRoute.outputs
        guard outputs.count == 1, let output = outputs.first,
              [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(output.portType) else { throw Failure.route }
        routeUID = output.uid
        status = "Confirmed output: \(output.portName)"
    }
    func activate(capture: Bool = false) throws {
        if capture { try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP]) }
        else { try session.setCategory(.playback, mode: .spokenAudio) }
        try session.setActive(true)
        guard routeIsValid else { throw Failure.route }
    }
    private var routeIsValid: Bool {
        guard let routeUID else { return false }
        return session.currentRoute.outputs.count == 1 && session.currentRoute.outputs.first?.uid == routeUID
    }
    func speak(_ text: String) async throws {
        guard completion == nil else { throw Failure.busy }
        try Task.checkCancellation()
        try activate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.interrupted }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        self.utterance = utterance
        let id = UUID()
        playbackID = id
        callbackIDs.withLock { $0[ObjectIdentifier(utterance)] = id }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                speaking = true
                synthesizer.speak(utterance)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(CancellationError()))
    }
    func deactivate() {
        stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    @objc private func routeChanged() {
        guard routeUID != nil, !routeIsValid else { return }
        routeUID = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(Failure.interrupted))
        status = "Output changed. Confirm the glasses route again."
        onInterruption?()
    }
    @objc private func interrupted() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(Failure.interrupted))
        onInterruption?()
    }
    private func finish(_ result: Result<Void, Error>) {
        let continuation = completion
        if let utterance { _ = callbackIDs.withLock { $0.removeValue(forKey: ObjectIdentifier(utterance)) } }
        completion = nil; utterance = nil; playbackID = nil; speaking = false
        continuation?.resume(with: result)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let id = callbackIDs.withLock({ $0[ObjectIdentifier(utterance)] }) else { return }
        Task { @MainActor in
            guard playbackID == id else { return }
            guard routeIsValid else { stop(); return }
            onPlaybackStarted?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let id = callbackIDs.withLock({ $0[ObjectIdentifier(utterance)] }) else { return }
        Task { @MainActor in
            guard playbackID == id else { return }
            finish(routeIsValid ? .success(()) : .failure(Failure.route))
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let id = callbackIDs.withLock({ $0[ObjectIdentifier(utterance)] }) else { return }
        Task { @MainActor in
            guard playbackID == id else { return }
            finish(.failure(CancellationError()))
        }
    }
}
