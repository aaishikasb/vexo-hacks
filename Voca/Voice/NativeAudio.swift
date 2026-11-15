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
            case .route: "Check the selected audio output, then request the cue again."
            case .interrupted: "Speech stopped because playback was interrupted or the output route changed."
            case .busy: "Wait for speech to finish or stop it first."
            }
        }
    }
    private(set) var status = "Choose an audio output"
    private(set) var currentOutput = ""
    private(set) var routeIsValid = false
    private(set) var outputNeedingApproval: AudioRouteApproval.Output?
    private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let session = AVAudioSession.sharedInstance()
    private var approvals = AudioRouteApproval()
    private var glassesConnected = false
    private var glassesNames: [String] = []
    private var speechOutputUID: String?
    private var practiceOutputUID: String?
    private var captureEngine: AVAudioEngine?
    private var captureGeneration = 0
    private var utterance: AVSpeechUtterance?
    private var playbackID: UUID?
    private nonisolated let callbackIDs = Mutex<[ObjectIdentifier: UUID]>([:])
    private var completion: CheckedContinuation<Void, Error>?
    var onPlaybackStarted: (() -> Void)?
    private var requestStarted: (() -> Void)?
    var onInterruption: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
        refreshOutput()
    }
    private var outputs: [AudioRouteApproval.Output] {
        session.currentRoute.outputs.map {
            AudioRouteApproval.Output(id: $0.uid, name: $0.portName,
                                      isBluetooth: [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType))
        }
    }

    func refreshGlassesConnection(connected: Bool, names: [String]) {
        glassesConnected = connected
        glassesNames = names
        refreshOutput()
    }

    func confirmOutput(id: String) throws {
        guard approvals.approve(id: id, currentOutputs: outputs) else {
            refreshOutput()
            throw Failure.route
        }
        refreshOutput()
    }

    private func refreshOutput() {
        let current = outputs
        approvals.recognizeGlasses(in: current, connected: glassesConnected, names: glassesNames)
        currentOutput = current.map(\.name).joined(separator: ", ")
        routeIsValid = approvals.accepts(current)
        outputNeedingApproval = !routeIsValid && current.count == 1 && practiceOutputUID == nil ? current.first : nil
        status = current.isEmpty ? "Choose an audio output" : routeIsValid ? "Ready: \(currentOutput)" : "Approve output: \(currentOutput)"
    }

    @discardableResult func activate(capture: Bool = false) throws -> String {
        refreshOutput()
        let expected = practiceOutputUID ?? (routeIsValid ? outputs.first?.id : nil)
        guard let expected else { throw Failure.route }
        if practiceOutputUID != nil {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .allowBluetoothHFP, .defaultToSpeaker])
        } else if capture { try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP]) }
        else { try session.setCategory(.playback, mode: .spokenAudio) }
        try session.setActive(true)
        refreshOutput()
        guard AudioRouteApproval.isCurrentOutput(expected, outputs: outputs) else { throw Failure.route }
        return expected
    }
    private var playbackRouteIsValid: Bool {
        if let expected = speechOutputUID ?? practiceOutputUID {
            return AudioRouteApproval.isCurrentOutput(expected, outputs: outputs)
        }
        return approvals.accepts(outputs)
    }
    func useCurrentOutputForPractice() throws {
        stopCapture()
        practiceOutputUID = nil
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        if let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(input) }
        guard session.currentRoute.outputs.count == 1, let output = session.currentRoute.outputs.first else { throw Failure.practiceRoute }
        practiceOutputUID = output.uid
        refreshOutput()
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
        refreshOutput()
    }
    func speak(_ text: String, onStarted: (() -> Void)? = nil) async throws {
        guard completion == nil else { throw Failure.busy }
        try Task.checkCancellation()
        let outputUID = try activate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.interrupted }
        requestStarted = onStarted
        speechOutputUID = outputUID
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
        if (speechOutputUID != nil || practiceOutputUID != nil), !playbackRouteIsValid {
            stopCapture()
            practiceOutputUID = nil
            synthesizer.stopSpeaking(at: .immediate)
            finish(.failure(Failure.interrupted))
            onInterruption?()
        }
        refreshOutput()
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
        completion = nil; utterance = nil; playbackID = nil; requestStarted = nil; speechOutputUID = nil; speaking = false
        continuation?.resume(with: result)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let id = callbackIDs.withLock({ $0[ObjectIdentifier(utterance)] }) else { return }
        Task { @MainActor in
            guard playbackID == id else { return }
            guard playbackRouteIsValid else { stop(); return }
            requestStarted?(); requestStarted = nil
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
