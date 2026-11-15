#!/usr/bin/env python3
"""Run the actual PracticeSession with fake speech/audio and model services on Mac.
No microphone, model downloads, personal data, or device access. Temporary build cleans itself up.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
session = (root / 'Voca/Product/PracticeSession.swift').read_text().replace('@preconcurrency import Speech', '')
stubs = r'''
import Foundation
import VocaCore
struct RecognitionResult: Sendable {
    struct Segment: Sendable { var timestamp: Double; var duration: Double }
    struct Metadata: Sendable { var speechStartTimestamp: Double; var speechDuration: Double }
    struct Transcription: Sendable { var formattedString: String; var segments: [Segment] = [] }
    var speechRecognitionMetadata: Metadata? { nil }
    var bestTranscription: Transcription
    var isFinal: Bool
}
@MainActor final class SFSpeechAudioBufferRecognitionRequest {
    var requiresOnDeviceRecognition = false, shouldReportPartialResults = false, ended = false
    func endAudio() { ended = true }
}
@MainActor final class SFSpeechRecognitionTask { func cancel() {}; func finish() {} }
@MainActor final class SFSpeechRecognizer {
    enum Authorization { case authorized }
    static var callback: (@Sendable (RecognitionResult?, (any Error)?) -> Void)?
    var isAvailable = true, supportsOnDeviceRecognition = true
    init?(locale: Locale) {}
    static func requestAuthorization(_ completion: @Sendable (Authorization) -> Void) { completion(.authorized) }
    func recognitionTask(with: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping @Sendable (RecognitionResult?, (any Error)?) -> Void) -> SFSpeechRecognitionTask {
        Self.callback = resultHandler; return SFSpeechRecognitionTask()
    }
    static func emit(_ text: String, final: Bool = true) {
        callback?(RecognitionResult(bestTranscription: .init(formattedString: text), isFinal: final), nil)
    }
}
enum LocalTranscriber { enum Failure: Error { case denied, unavailable } }
@MainActor final class NativeAudio {
    var onInterruption: (() -> Void)?
    var capturing = false
    var request: SFSpeechAudioBufferRecognitionRequest?
    func useCurrentOutputForPractice() throws {}
    func startPracticeCapture(_ request: SFSpeechAudioBufferRecognitionRequest) async throws {
        self.request = request; capturing = true
    }
    func stopCapture() { capturing = false }
    func endPracticeOutput() { stopCapture() }
}
@MainActor final class PipecatSpeech {
    enum Failure: Error { case notReady }
    var ready = true, failPlayback = false
    var spoken: [String] = []
    var accepted: [String] = []
    func speak(_ text: String) async throws {
        if failPlayback { throw Failure.notReady }
        spoken.append(text)
    }
    func acceptPracticeTurn(_ turn: PracticeTurn) async throws { accepted.append(turn.text) }
    func stop() {}
}
actor Model: ModelGenerating {
    var prompts: [String] = []
    var delayed = false
    var responseDelay = false
    var output = #"{"text":"What led you to build that robot?","updates":[]}"#
    func setOutput(_ value: String, delay: Bool = false) { output = value; responseDelay = delay }
    func setDelayed(_ value: Bool) { delayed = value }
    func activeProfile() async throws -> ModelProfile { VocaFixtures.profile() }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        prompts.append(request.prompt)
        if delayed { try await Task.sleep(for: .seconds(30)) }
        if responseDelay { try await Task.sleep(for: .milliseconds(200)) }
        return ModelResponse(requestID: request.requestID, actualProfile: request.requestedProfile,
            text: output)
    }
}
@main struct Check {
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }
    @MainActor static func main() async throws {
        let model = Model(), voice = PipecatSpeech(), audio = NativeAudio(), session = PracticeSession()
        let scenario = PracticeScenario(id: "test", title: "Meetup", setting: .event, goal: .enter,
            openingLine: "Hello", partnerInstructions: "Discuss gardens.", principleIDs: [])
        session.direction = "Talk about my robot"
        session.brief.audience = "A founder"
        session.brief.goal = "Explain why my project matters"
        await session.start(scenario: scenario, model: model, voice: voice, audio: audio)
        await settle()
        assert(session.listening && audio.capturing && session.messages.count == 1, "Auto-listen after opening")
        assert(session.context.entries[.audience]?.quote == "A founder")
        session.brief.audience = "A founder who is not technical"
        assert(session.context.entries[.audience]?.quote == "A founder who is not technical")
        session.forgetContext(.audience)
        assert(session.context.entries[.audience] == nil)
        assert(await model.prompts.first?.contains("Talk about my robot") == true)
        SFSpeechRecognizer.emit("I built a robot", final: false)
        await settle()
        assert(voice.accepted.isEmpty, "Partials must not reach model")
        try await Task.sleep(for: .milliseconds(5200))
        assert(session.finishing && !audio.capturing && audio.request?.ended == true, "Silence ends input")
        SFSpeechRecognizer.emit("I built a robot to water plants")
        await settle()
        assert(session.listening && session.messages.count == 3 && voice.accepted.count == 1, "One final causes reply then listening")
        let stale = SFSpeechRecognizer.callback
        await session.pause(voice: voice, audio: audio)
        stale?(RecognitionResult(bestTranscription: .init(formattedString: "stale words"), isFinal: true), nil)
        await settle()
        assert(session.paused && !session.listening && !audio.capturing && voice.accepted.count == 1)
        assert(session.context.entries[.goal] != nil, "Pause preserves session context")
        await session.listen(model: model, voice: voice, audio: audio)
        SFSpeechRecognizer.emit("", final: true)
        await settle()
        assert(!audio.capturing && !session.busy, "Empty finals stop without a reply")
        await session.listen(model: model, voice: voice, audio: audio)
        SFSpeechRecognizer.emit("unfinished words", final: false)
        await settle()
        session.finishListening(audio: audio)
        let awaitingFinal = SFSpeechRecognizer.callback
        await session.stop(voice: voice, audio: audio)
        awaitingFinal?(RecognitionResult(bestTranscription: .init(formattedString: "late final"), isFinal: true), nil)
        await settle()
        assert(!session.enabled && !audio.capturing && voice.accepted.count == 1)
        assert(session.context.entries.isEmpty, "End clears session context")
        session.direction = ""
        session.brief = PracticeBrief()
        await session.start(scenario: scenario, model: model, voice: voice, audio: audio)
        await settle()
        await model.setDelayed(true)
        SFSpeechRecognizer.emit("My next idea")
        await settle()
        assert(session.busy)
        await session.listen(model: model, voice: voice, audio: audio)
        assert(session.listening && !session.busy && session.messages.count == 2, "Interrupt cancels model without appending an unspoken reply")
        await model.setDelayed(false)
        session.pacingMode = .manual
        session.adjustPacing(audio: audio)
        SFSpeechRecognizer.emit("No final will arrive", final: false)
        await settle()
        try await Task.sleep(for: .milliseconds(5200))
        assert(session.listening && !session.finishing, "Manual pacing disables silence timeout")
        session.finishListening(audio: audio)
        let acceptedCount = voice.accepted.count
        try await Task.sleep(for: .milliseconds(5200))
        assert(!session.finishing && !audio.capturing && voice.accepted.count == acceptedCount, "Final timeout never submits partial words")
        await session.stop(voice: voice, audio: audio)
        await session.start(scenario: scenario, model: model, voice: voice, audio: audio)
        await settle()
        await model.setOutput(#"{"text":"Tell me about the robot.","updates":["topic"]}"#, delay: true)
        SFSpeechRecognizer.emit("My robot waters plants")
        await settle()
        session.brief.topic = "A different project"
        try await Task.sleep(for: .milliseconds(300))
        assert(session.context.entries[.topic]?.quote == "A different project", "New typed edit wins over in-flight update")
        SFSpeechRecognizer.emit("Actually, my robot does not water plants")
        try await Task.sleep(for: .milliseconds(300))
        assert(session.context.entries[.topic]?.quote == "Actually, my robot does not water plants", "Retain entire correction, not just selected word")
        await session.stop(voice: voice, audio: audio)
        await model.setOutput(#"{"text":"Tell me about the robot.","updates":[]}"#)
        session.brief = PracticeBrief()
        voice.failPlayback = true
        await session.start(scenario: scenario, model: model, voice: voice, audio: audio)
        await settle()
        assert(!session.listening && !audio.capturing && session.messages.isEmpty, "Failed playback cannot enter context or reopen mic")
        await session.stop(voice: voice, audio: audio)
        print("PASS: live turn lifecycle, situation brief, pause retention/end reset, manual pacing, full-source correction, edit-versus-generation race, missing-final recovery, and failed playback")
    }
}
'''
# Await outside assert's synchronous autoclosure.
stubs = stubs.replace('assert(await model.prompts.first?.contains("Talk about my robot") == true)',
                      'let prompts = await model.prompts; assert(prompts.first?.contains("Talk about my robot") == true)')
with tempfile.TemporaryDirectory(prefix='voca-practice-check-') as directory:
    folder = Path(directory)
    subprocess.run(['swiftc', '-parse-as-library', '-emit-module', '-emit-library', '-static',
                    '-module-name', 'VocaCore', '-emit-module-path', str(folder / 'VocaCore.swiftmodule'),
                    '-o', str(folder / 'libVocaCore.a'),
                    *map(str, (root / 'Packages/VocaCore/Sources/VocaCore').glob('*.swift'))], check=True)
    (folder / 'Session.swift').write_text(session)
    (folder / 'Check.swift').write_text(stubs)
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', directory, '-L', directory,
                    '-lVocaCore', '-o', str(folder / 'check'), str(folder / 'Session.swift'), str(folder / 'Check.swift'),
                    str(root / 'Voca/Product/PracticeTurnGate.swift'), str(root / 'Voca/Inference/GeneratedFields.swift'),
                    str(root / 'Voca/Inference/ValidatedGeneration.swift')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
