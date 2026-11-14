import AVFoundation
import Foundation
import Observation
import Synchronization
@preconcurrency import Speech

@MainActor @Observable final class NativeAudio: NSObject, AVSpeechSynthesizerDelegate {
    enum Failure: LocalizedError {
        case route, practiceRoute, interrupted, busy
        var errorDescription: String? {
            switch self {
            case .practiceRoute: "Choose an audio output, then start practice again. Voca stopped because the selected route is unavailable."
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
    private var practiceOutputUID: String?
    private var captureEngine: AVAudioEngine?
    private var captureGeneration = 0
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
        practiceOutputUID = nil
        let outputs = session.currentRoute.outputs
        guard outputs.count == 1, let output = outputs.first,
              [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(output.portType) else { throw Failure.route }
        routeUID = output.uid
        status = "Confirmed output: \(output.portName)"
    }
    func activate(capture: Bool = false) throws {
        if practiceOutputUID != nil {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .allowBluetoothHFP, .defaultToSpeaker])
        } else if capture { try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP]) }
        else { try session.setCategory(.playback, mode: .spokenAudio) }
        try session.setActive(true)
        guard playbackRouteIsValid else { throw Failure.route }
    }
    var routeIsValid: Bool {
        guard let routeUID else { return false }
        return session.currentRoute.outputs.count == 1 && session.currentRoute.outputs.first?.uid == routeUID
    }
    private var playbackRouteIsValid: Bool {
        if let practiceOutputUID { return session.currentRoute.outputs.count == 1 && session.currentRoute.outputs.first?.uid == practiceOutputUID }
        return routeIsValid
    }
    func useCurrentOutputForPractice() throws {
        stopCapture()
        routeUID = nil
        practiceOutputUID = nil
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        if let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(input) }
        guard session.currentRoute.outputs.count == 1, let output = session.currentRoute.outputs.first else { throw Failure.practiceRoute }
        practiceOutputUID = output.uid
        status = "Practice output: \(output.portName)"
    }
    func startPracticeCapture(_ request: SFSpeechAudioBufferRecognitionRequest) async throws {
        guard captureEngine == nil else { throw Failure.busy }
        let generation = captureGeneration
        let granted = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard generation == captureGeneration else { throw CancellationError() }
        guard granted else { throw LocalTranscriber.Failure.denied }
        guard practiceOutputUID != nil else { throw Failure.practiceRoute }
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        if let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(input) }
        guard playbackRouteIsValid else { throw Failure.route }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.interrupted }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in request.append(buffer) }
        do { try engine.start(); captureEngine = engine }
        catch { input.removeTap(onBus: 0); throw error }
    }
    func stopCapture() {
        captureGeneration += 1
        guard let engine = captureEngine else { return }
        engine.inputNode.removeTap(onBus: 0); engine.stop(); captureEngine = nil
    }
    func endPracticeOutput() {
        stopCapture(); stop(); practiceOutputUID = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    func speak(_ text: String) async throws {
        guard completion == nil else { throw Failure.busy }
        try Task.checkCancellation()
        try activate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.interrupted }
        let utterance = makeSpeechUtterance(text)
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
        } onCancel: { Task { @MainActor [weak self] in if self?.playbackID == id { self?.stop() } } }
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
        guard (routeUID != nil || practiceOutputUID != nil), !playbackRouteIsValid else { return }
        stopCapture()
        practiceOutputUID = nil
        routeUID = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(Failure.interrupted))
        status = "Output changed. Confirm the glasses route again."
        onInterruption?()
    }
    @objc private func interrupted() {
        stopCapture()
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
            guard playbackRouteIsValid else { stop(); return }
            onPlaybackStarted?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let id = callbackIDs.withLock({ $0[ObjectIdentifier(utterance)] }) else { return }
        Task { @MainActor in
            guard playbackID == id else { return }
            finish(playbackRouteIsValid ? .success(()) : .failure(Failure.route))
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
