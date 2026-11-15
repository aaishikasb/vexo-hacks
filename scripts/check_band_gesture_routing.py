#!/usr/bin/env python3
"""Exercise actual VocaApp gesture methods with no-op hardware in a temporary host runner."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'Voca/App/VocaApp.swift').read_text()
def method(name):
    start = app.index('    private func ' + name + '(')
    brace = app.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (app[end] == '{') - (app[end] == '}')
        end += 1
    return app[start:end]

source = '''import Foundation
@MainActor final class UIApplication { static let shared = UIApplication(); enum Phase { case active, background }; var applicationState = Phase.active }
@MainActor struct FakeBand { var verified = true }
@MainActor final class FakeVoice { var ready = true; func start(audio: GestureFixture.Audio) {} }
@MainActor final class FakeListening {
    var busy = false
    var starts = 0
    func startContinuous(band: FakeBand, memory: Int, voice: FakeVoice, playbackActive: @escaping () -> Bool = { false }) async throws {
        starts += 1; busy = true
    }
}
@MainActor final class GestureFixture {
    enum Phase { case active, background }
    var scenePhase = Phase.active
    var band = FakeBand()
    var showPractice = false
    var rememberBandDetails = false
    var listening = FakeListening()
    var capturePreparing = false
    var captureError: String?
    var captureStartTask: Task<Void, Never>?
    let pipecat = FakeVoice()
    final class Audio { var speaking = false }
    let audio = Audio()
    let memory = 0
    var tapCalibration = BandTapCalibration()
    var tapGate = BandCueTrigger()
    var tapTask: Task<Void, Never>?
    var cueReady = false
    var cueRequestError: String?
    func requestCue(trace: CueTrace) { assertionFailure("Unexpected cue") }
'''
source += '\n'.join(method(name) for name in ['enableMemoryListening', 'startMemoryListening', 'receiveTap'])
source += '''
    static func check() async {
        let normal = GestureFixture()
        normal.receiveTap(milliseconds: 1000, code: 2)
        assert(normal.rememberBandDetails)
        await normal.captureStartTask?.value
        assert(normal.listening.starts == 1)
        normal.receiveTap(milliseconds: 4000, code: 2)
        await normal.captureStartTask?.value
        assert(normal.listening.starts == 1, "Active capture restarted")

        let single = GestureFixture()
        single.receiveTap(milliseconds: 1000, code: 1)
        assert(!single.rememberBandDetails && single.captureStartTask == nil)

        let unverified = GestureFixture()
        unverified.band.verified = false
        unverified.receiveTap(milliseconds: 1000, code: 2)
        assert(!unverified.rememberBandDetails && unverified.captureStartTask == nil)

        let practice = GestureFixture()
        practice.showPractice = true
        practice.receiveTap(milliseconds: 1000, code: 2)
        assert(!practice.rememberBandDetails && practice.captureStartTask == nil)

        for doubleStage in [false, true] {
            let calibrating = GestureFixture()
            let then = Date().addingTimeInterval(-10)
            calibrating.tapCalibration.startSingle(at: then)
            if doubleStage {
                calibrating.tapCalibration.receive(milliseconds: 100, code: 1, at: then)
                _ = calibrating.tapCalibration.startDouble(at: then.addingTimeInterval(2))
            }
            calibrating.receiveTap(milliseconds: 1000, code: 2)
            assert(!calibrating.rememberBandDetails && calibrating.captureStartTask == nil,
                   "Calibration double tap started capture")
        }
        print("PASS: actual gesture methods start once on verified double tap; ignore single, unverified, practice and calibration taps")
    }
}
@main struct Check { static func main() async { await GestureFixture.check() } }
'''
with tempfile.TemporaryDirectory(prefix='voca-gesture-check-') as temp:
    path = Path(temp)
    (path / 'Check.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-module-cache-path', str(path / 'ModuleCache'), str(path / 'Check.swift'),
                    str(root / 'Voca/Device/BandProtocol.swift'), str(root / 'Voca/Device/BandTapCalibration.swift'),
                    str(root / 'Voca/Device/BandCueTrigger.swift'), str(root / 'Voca/Product/CueTrace.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
