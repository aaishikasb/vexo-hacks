#!/usr/bin/env python3
"""Run the actual camera request/next-frame code with a no-hardware Swift fixture."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'Voca/Device/GlassesCamera.swift').read_text()
def balanced(start):
    brace = app.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (app[end] == '{') - (app[end] == '}')
        end += 1
    return app[start:end]
def method(name):
    start = app.index('    private func ' + name) if '    private func ' + name in app else app.index('    func ' + name)
    return balanced(start).replace('private func ', 'func ')
listener = balanced(app.index('            camera.stream.videoFramePublisher.listen'))
body = listener[listener.index('                Task {'):listener.rfind('            }')]
source = '''import Foundation
struct Frame: Sendable {
    func makeUIImage() -> Frame? { self }
    func jpegData(compressionQuality: Double) -> Data? { Data([7]) }
}
@MainActor final class Stream {
    enum Format { case jpeg }
    var requests = 0
    func capturePhoto(format: Format) -> Bool { requests += 1; return true }
}
@MainActor final class Camera { let stream = Stream() }
@MainActor final class Fixture {
    enum Failure: Error { case notReady, busy, interrupted, timeout }
    var ready = true
    var camera: Camera? = Camera()
    var generation = 1
    var status = ""
    var previewJPEG: Data?
    var capture: CheckedContinuation<(Data, Date), Error>?
    var captureRequestedAt: Date?
    var captureTimeout: Task<Void, Never>?
    var awaitingStreamFrame = false
    var lastCaptureKind = "stillPhoto"
    func stop() {
        generation += 1; ready = false; captureTimeout?.cancel()
        let pending = capture; capture = nil; captureRequestedAt = nil; awaitingStreamFrame = false
        pending?.resume(throwing: Failure.interrupted)
    }
    func frame(receivedAt: Date, current: Int = 1) {
        let frame = Frame()
'''
source += body.replace('Task { @MainActor in', 'Task { @MainActor [weak self] in') + '\n    }\n'
source += '\n'.join(method(name) for name in ['completeCapture(', 'requestStillPhoto(', 'photo('])
source += '''
    static func wait(_ predicate: () -> Bool) async {
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            precondition(ContinuousClock.now < until, "Capture did not settle")
            try! await Task.sleep(for: .milliseconds(1))
        }
    }
    static func check() async throws {
        let fresh = Fixture()
        let first = Task { try await fresh.photo(preferStreamFrame: true) }
        await wait { fresh.capture != nil }
        do { _ = try await fresh.photo(); assertionFailure("Concurrent request accepted") }
        catch Failure.busy { }
        fresh.frame(receivedAt: Date().addingTimeInterval(-10))
        fresh.frame(receivedAt: Date(), current: 0)
        try await Task.sleep(for: .milliseconds(20))
        assert(fresh.capture != nil, "Old frame or old session accepted")
        fresh.frame(receivedAt: Date())
        let result = try await first.value
        assert(result.0 == Data([7]) && fresh.lastCaptureKind == "nextStreamFrame")
        assert(fresh.camera!.stream.requests == 0 && !fresh.awaitingStreamFrame)
        fresh.completeCapture(Data([8]), observedAt: Date())
        assert(fresh.previewJPEG == Data([7]), "Duplicate callback changed completed capture")

        let fallback = Fixture()
        let second = Task { try await fallback.photo(preferStreamFrame: true) }
        await wait { fallback.camera!.stream.requests == 1 }
        assert(!fallback.awaitingStreamFrame)
        fallback.completeCapture(Data([9]), observedAt: Date())
        let fallbackResult = try await second.value
        assert(fallbackResult.0 == Data([9]))

        for _ in 0..<20 {
            let repeated = Task { try await fresh.photo(preferStreamFrame: true) }
            await wait { fresh.capture != nil }
            fresh.frame(receivedAt: Date())
            _ = try await repeated.value
            assert(fresh.capture == nil && fresh.camera!.stream.requests == 0)
        }

        let cancelled = Fixture()
        let third = Task { try await cancelled.photo(preferStreamFrame: true) }
        await wait { cancelled.capture != nil }
        third.cancel()
        do { _ = try await third.value; assertionFailure("Cancelled capture completed") }
        catch { }
        assert(cancelled.capture == nil && !cancelled.awaitingStreamFrame)
        print("PASS: actual next-frame capture rejects stale/session frames and duplicate callbacks; busy, 250ms still fallback, cancellation verified")
    }
}
@main struct Check { static func main() async throws { try await Fixture.check() } }
'''
# Error.localizedDescription is supplied by Foundation for the fixture's Error enum.
with tempfile.TemporaryDirectory(prefix='voca-camera-check-') as temp:
    path = Path(temp)
    (path / 'Check.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
        '-module-cache-path', str(path / 'ModuleCache'), str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
