#!/usr/bin/env python3
"""Run SetupView's actual cue predicate/request method against no-op host services.

This checks routing and async history recovery, not wearable capture or inference.
The Swift bodies are extracted from VocaApp.swift; readiness is never reimplemented
in the fixture. Requires the project's Xcode Swift toolchain, no extra packages.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / "Voca/App/VocaApp.swift").read_text()


def block(declaration):
    start = app.index("    private " + declaration)
    brace = app.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (app[end] == "{") - (app[end] == "}")
        end += 1
    return app[start:end]


source = '''import Foundation
@MainActor private final class UIApplication { static let shared = UIApplication(); var applicationState = ScenePhase.active }
private enum ScenePhase { case active, inactive, background }
@MainActor private struct Device {
    var ready = true
    mutating func suspendForBackground() { ready = false }
    func stop() {}
}
@MainActor private struct Audio {
    var routeIsValid = true
    var outputNeedingApproval: Int? = 1
    func deactivate() {}
}
private struct Snapshot { var dialogue: [String] = [] }
private struct Models { let executor = 0 }
@MainActor private final class Listening {
    var active = false
    func cueSnapshot(memories: Snapshot) async -> Snapshot { memories }
    var continuous = false
    var stops = 0
    func stop(band: Int) async { stops += 1 }
}
@MainActor private struct Memory {
    var loaded = true
    var pendingDeletionIDs: Set<String> = []
    func snapshot() -> Snapshot { Snapshot() }
}
@MainActor private struct Operation { var busy = false; var error: String? }
@MainActor private struct TapGate {
    var cancellations = 0
    mutating func cancelPending() { cancellations += 1 }
}
@MainActor private final class Coaching {
    var isConfigured = true
    var busy = false
    var lastError: String?
    var requests = 0
    var configureCalls = 0
    var configureSucceeds = true
    var resumeConfiguration: CheckedContinuation<Void, Never>?
    var resumeStop: CheckedContinuation<Void, Never>?
    func stop(voice: Device, executor: Int) async {
        await withCheckedContinuation { resumeStop = $0 }
    }
    func configure() async {
        configureCalls += 1
        await withCheckedContinuation { resumeConfiguration = $0 }
        isConfigured = configureSucceeds
        lastError = configureSucceeds ? nil : "History fixture failure"
    }
    func request(models: Models, camera: Device, voice: Device, snapshot: Snapshot, trace: CueTrace) {
        requests += 1
        busy = true
    }
}
@MainActor private final class Fixture {
    var scenePhase = ScenePhase.active
    var memory = Memory()
    var camera = Device()
    var pipecat = Device()
    var audio = Audio()
    var operation = Operation()
    var coaching = Coaching()
    var softwareReady = true
    var showPractice = false
    var reviewingEpisode: Int?
    var preparingCue = false
    var tasteEpisode: Int?
    var cuePreparationTask: Task<Void, Never>?
    var captureStartTask: Task<Void, Never>?
    var stoppingCue = false
    var cueRequestError: String?
    var showSetup = false
    var activeTab = 0
    var tapTask: Task<Void, Never>?
    var tapGate = TapGate()
    var models = Models()
    var listening = Listening()
    var band = 0
    var approvalPrompts = 0
    var softwareRetries = 0
    func stopMemoryListening() async { await listening.stop(band: band) }
    func presentAudioApproval() { approvalPrompts += 1 }
    func prepareSoftware() { softwareRetries += 1 }
    func openReadiness() { showSetup = true }
'''
source += block("var cueReady: Bool") + "\n" + block("func requestCue(trace:") + "\n" + block("func suspendSession()")
source += '''
    static func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "Fixture task did not settle")
            try! await Task.sleep(for: .milliseconds(1))
        }
    }
    static func blocked(_ name: String, change: (Fixture) -> Void,
                        prompts: Int = 0, retries: Int = 0) {
        let fixture = Fixture()
        UIApplication.shared.applicationState = .active
        change(fixture)
        UIApplication.shared.applicationState = fixture.scenePhase
        assert(!fixture.cueReady, "\\(name): incorrectly ready")
        fixture.requestCue()
        assert(fixture.coaching.requests == 0, "\\(name): cue started")
        assert(!fixture.showSetup, "\\(name): silently opened Settings")
        assert(fixture.approvalPrompts == prompts, "\\(name): incorrect output prompt")
        assert(fixture.softwareRetries == retries, "\\(name): incorrect guidance retry")
    }
    static func check() async {
        let staleCallback = Fixture()
        staleCallback.scenePhase = .inactive
        UIApplication.shared.applicationState = .active
        assert(staleCallback.cueReady, "A callback captured at startup must read current foreground state")
        let ready = Fixture()
        ready.activeTab = 2
        ready.operation.error = "Old setup failure"
        assert(ready.cueReady, "All visible prerequisites are ready in foreground")
        ready.requestCue()
        await ready.cuePreparationTask?.value
        assert(ready.coaching.requests == 1 && !ready.showSetup)
        assert(ready.activeTab == 0 && ready.operation.error == nil)
        assert(ready.tapGate.cancellations == 1)
        ready.requestCue()
        await ready.cuePreparationTask?.value
        assert(ready.coaching.requests == 1, "A busy cue restarted")

        let silence = Fixture()
        silence.listening.active = true
        silence.requestCue()
        await silence.cuePreparationTask?.value
        assert(silence.coaching.requests == 0 && silence.cueRequestError != nil, "Silent listening became an unrelated cue")

        blocked("background", change: { $0.scenePhase = .background })
        blocked("inactive", change: { $0.scenePhase = .inactive })
        blocked("memory unavailable", change: { $0.memory.loaded = false })
        blocked("pending deletion", change: { $0.memory.pendingDeletionIDs = ["memory"] })
        blocked("camera unavailable", change: { $0.camera.ready = false })
        blocked("unapproved audio", change: { $0.audio.routeIsValid = false }, prompts: 1)
        blocked("no audio output", change: { $0.audio.routeIsValid = false; $0.audio.outputNeedingApproval = nil })
        blocked("model unavailable", change: { $0.softwareReady = false }, retries: 1)
        blocked("voice unavailable", change: { $0.pipecat.ready = false }, retries: 1)
        blocked("practice", change: { $0.showPractice = true })
        blocked("review", change: { $0.reviewingEpisode = 1 })
        blocked("operation busy", change: { $0.operation.busy = true })
        blocked("coaching busy", change: { $0.coaching.busy = true })
        blocked("preparing", change: { $0.preparingCue = true })
        blocked("stopping previous cue", change: { $0.stoppingCue = true })

        UIApplication.shared.applicationState = .active
        let returning = Fixture()
        returning.scenePhase = .background
        returning.suspendSession()
        assert(returning.stoppingCue)
        await waitUntil { returning.coaching.resumeStop != nil }
        returning.scenePhase = .active
        returning.camera.ready = true
        assert(!returning.cueReady, "Background cleanup is still draining")
        returning.requestCue()
        assert(returning.coaching.requests == 0)
        returning.coaching.resumeStop?.resume()
        await waitUntil { !returning.stoppingCue }
        assert(returning.listening.stops == 1 && returning.cueReady)
        returning.requestCue()
        await returning.cuePreparationTask?.value
        assert(returning.coaching.requests == 1 && !returning.showSetup)

        for succeeds in [true, false] {
            let history = Fixture()
            history.coaching.isConfigured = false
            history.coaching.configureSucceeds = succeeds
            assert(!history.cueReady)
            history.requestCue()
            assert(history.preparingCue && !history.showSetup)
            history.requestCue()
            await waitUntil { history.coaching.resumeConfiguration != nil }
            assert(history.coaching.configureCalls == 1, "Duplicate history retry")
            history.coaching.resumeConfiguration?.resume()
            await waitUntil { !history.preparingCue }
            assert(history.coaching.requests == (succeeds ? 1 : 0))
            assert(!history.showSetup, "History recovery opened Settings")
            assert(succeeds ? history.cueRequestError == nil : history.cueRequestError == "History fixture failure")
        }

        for loseAudio in [false, true] {
            UIApplication.shared.applicationState = .active
            let changed = Fixture()
            changed.coaching.isConfigured = false
            changed.requestCue()
            await waitUntil { changed.coaching.resumeConfiguration != nil }
            if loseAudio { changed.audio.routeIsValid = false }
            else { changed.scenePhase = .background; UIApplication.shared.applicationState = .background }
            changed.coaching.resumeConfiguration?.resume()
            await waitUntil { !changed.preparingCue }
            assert(changed.coaching.requests == 0, "Readiness changed during history recovery")
            assert(!changed.showSetup && changed.approvalPrompts == (loseAudio ? 1 : 0))
        }
        print("PASS: actual cueReady/requestCue start when ready, preserve blockers, retry history once, and never redirect to Settings")
    }
}
@main struct Check { static func main() async { await Fixture.check() } }
'''
with tempfile.TemporaryDirectory(prefix="voca-cue-readiness-") as temporary:
    path = Path(temporary)
    (path / "Check.swift").write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", str(path / "ModuleCache"), str(path / "Check.swift"),
                    str(root / "Voca/Product/CueTrace.swift"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
