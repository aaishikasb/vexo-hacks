import Foundation
import Testing
@testable import VocaDevice

private let calibrationEpoch = Date(timeIntervalSince1970: 2_000)

private func beginDoubleCheck() -> BandTapCalibration {
    var check = BandTapCalibration()
    check.startSingle(at: calibrationEpoch)
    check.receive(milliseconds: 100, code: 1, at: calibrationEpoch)
    _ = check.startDouble(at: calibrationEpoch.addingTimeInterval(2))
    return check
}

@Test func calibrationRequiresSingleThenExplicitQuietDoubleFinish() {
    var check = BandTapCalibration()
    #expect(check.settlingInterval == nil)
    check.startSingle(at: calibrationEpoch)
    let noSingle = check.startDouble(at: calibrationEpoch)
    #expect(!noSingle)
    check.receive(milliseconds: 100, code: 1, at: calibrationEpoch)
    let tooSoon = check.startDouble(at: calibrationEpoch.addingTimeInterval(1))
    #expect(!tooSoon)
    let next = check.startDouble(at: calibrationEpoch.addingTimeInterval(2))
    #expect(next)
    let noDouble = check.finishDouble(at: calibrationEpoch.addingTimeInterval(5))
    #expect(!noDouble)
    check.receive(milliseconds: 3_000, code: 2, at: calibrationEpoch.addingTimeInterval(3))
    #expect(check.phase == .double)
    let finishEarly = check.finishDouble(at: calibrationEpoch.addingTimeInterval(4))
    #expect(!finishEarly)
    let finish = check.finishDouble(at: calibrationEpoch.addingTimeInterval(5))
    #expect(finish)
    #expect(check.phase == .complete)
    #expect(check.settlingInterval == 0.75)
}

@Test func calibrationUsesSlowerReceiptOrDeviceSpanAndTimestampWrap() {
    var check = beginDoubleCheck()
    check.receive(milliseconds: UInt32.max - 499, code: 1, at: calibrationEpoch.addingTimeInterval(3))
    check.receive(milliseconds: 500, code: 2, at: calibrationEpoch.addingTimeInterval(3.4))
    let finish = check.finishDouble(at: calibrationEpoch.addingTimeInterval(5.4))
    #expect(finish)
    #expect(check.settlingInterval == 1.25)
    check = beginDoubleCheck()
    check.receive(milliseconds: 3_000, code: 2, at: calibrationEpoch.addingTimeInterval(3))
    check.receive(milliseconds: 3_100, code: 1, at: calibrationEpoch.addingTimeInterval(4.5))
    let lateSingle = check.finishDouble(at: calibrationEpoch.addingTimeInterval(6.5))
    #expect(lateSingle)
    #expect(check.settlingInterval == 1.75)
}

@Test func calibrationRejectsUnsafeTimingInsteadOfClamping() {
    for slowDevice in [false, true] {
        var check = beginDoubleCheck()
        check.receive(milliseconds: 3_000, code: 1, at: calibrationEpoch.addingTimeInterval(3))
        check.receive(milliseconds: slowDevice ? 6_000 : 3_100, code: 2,
                      at: calibrationEpoch.addingTimeInterval(slowDevice ? 3.1 : 6))
        #expect(check.phase == .idle)
        #expect(check.settlingInterval == nil)
        let cannotFinish = check.finishDouble(at: calibrationEpoch.addingTimeInterval(10))
        #expect(!cannotFinish)
    }
}

@Test func calibrationRejectsDoubleInSingleStageAndIgnoresDuplicateEvents() {
    var check = BandTapCalibration()
    check.startSingle(at: calibrationEpoch)
    check.receive(milliseconds: 100, code: 2, at: calibrationEpoch)
    #expect(check.phase == .idle)
    check = beginDoubleCheck()
    check.receive(milliseconds: 3_000, code: 2, at: calibrationEpoch.addingTimeInterval(3))
    check.receive(milliseconds: 3_000, code: 2, at: calibrationEpoch.addingTimeInterval(4.9))
    let finish = check.finishDouble(at: calibrationEpoch.addingTimeInterval(5))
    #expect(finish)
    check.reset()
    #expect(check.phase == .idle)
    #expect(check.settlingInterval == nil)
}

private func calibrationBand(number: Int = 18, firmwarePatch: UInt8 = 0, events: Bool = true) throws -> BandProtocol.Info {
    try BandProtocol.Info(Data([1, 1, 1, 1, firmwarePatch, 1, UInt8(number & 255), UInt8(number >> 8),
                                events ? 4 : 0, 0, 244, 0, 0, 0, 0, 0]), assignedNumber: number)
}

@Test func completedTapCalibrationPersistsForSameBandAndFirmware() throws {
    let suite = "voca-tap-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let band = try calibrationBand()
    var firstLaunch = BandTapCalibration()
    let missing = firstLaunch.restore(for: band, defaults: defaults)
    #expect(!missing)
    var check = beginDoubleCheck()
    #expect(!check.save(for: band, defaults: defaults))
    check.receive(milliseconds: 3_000, code: 1, at: calibrationEpoch.addingTimeInterval(3))
    check.receive(milliseconds: 4_000, code: 2, at: calibrationEpoch.addingTimeInterval(3.4))
    let finished = check.finishDouble(at: calibrationEpoch.addingTimeInterval(5.4))
    #expect(finished)
    #expect(check.save(for: band, defaults: defaults))

    var relaunched = BandTapCalibration()
    let relaunchedDefaults = try #require(UserDefaults(suiteName: suite))
    let restored = relaunched.restore(for: band, defaults: relaunchedDefaults)
    #expect(restored)
    #expect(relaunched.phase == .complete)
    #expect(relaunched.settlingInterval == 1.25)
    let wrongBand = relaunched.restore(for: try calibrationBand(number: 19), defaults: defaults)
    #expect(!wrongBand)
    #expect(relaunched.settlingInterval == nil)
    let differentFirmware = relaunched.restore(for: try calibrationBand(firmwarePatch: 1), defaults: defaults)
    #expect(!differentFirmware)
    let unsupported = relaunched.restore(for: try calibrationBand(events: false), defaults: defaults)
    #expect(!unsupported)
    let existingCalibration = relaunched.restore(for: band, defaults: defaults)
    #expect(existingCalibration)
    check.startSingle(at: calibrationEpoch.addingTimeInterval(10))
    #expect(!check.save(for: band, defaults: defaults))
    let previousStillSaved = relaunched.restore(for: band, defaults: defaults)
    #expect(previousStillSaved)
    #expect(relaunched.settlingInterval == 1.25)
}

@Test func savedTapCalibrationRejectsCorruptAndUnsafeIntervals() throws {
    let suite = "voca-tap-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let band = try calibrationBand()
    let key = "voca.tap-calibration.v1.18.1.1.0"
    for invalid in ["true", "null", "\"1\"", "-1", "0", "0.74", "3.01", "1e400", "invalid"] {
        defaults.set(Data(invalid.utf8), forKey: key)
        var check = BandTapCalibration()
        let restoredCorrupt = check.restore(for: band, defaults: defaults)
        #expect(!restoredCorrupt)
        #expect(check.phase == .idle)
        #expect(check.settlingInterval == nil)
    }
}

@Test func restoringCalibrationDoesNotReplayTapFromPreviousConnection() throws {
    let suite = "voca-tap-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let band = try calibrationBand()
    var check = beginDoubleCheck()
    check.receive(milliseconds: 3_000, code: 2, at: calibrationEpoch.addingTimeInterval(3))
    let finished = check.finishDouble(at: calibrationEpoch.addingTimeInterval(5))
    #expect(finished)
    #expect(check.save(for: band, defaults: defaults))
    var gate = BandCueTrigger()
    let enabled = gate.enableVerifiedMapping(settlingInterval: try #require(check.settlingInterval))
    #expect(enabled)
    gate.receive(milliseconds: 4_000, code: 1, at: calibrationEpoch.addingTimeInterval(6), ready: true)
    gate.reset()
    let restored = check.restore(for: band, defaults: defaults)
    #expect(restored)
    let enabledAfterReconnect = gate.enableVerifiedMapping(settlingInterval: try #require(check.settlingInterval))
    #expect(enabledAfterReconnect)
    let pendingReplayed = gate.consume(at: calibrationEpoch.addingTimeInterval(10), ready: true)
    #expect(!pendingReplayed)
    gate.receive(milliseconds: 1, code: 1, at: calibrationEpoch.addingTimeInterval(11), ready: true)
    let firstTap = gate.consume(at: calibrationEpoch.addingTimeInterval(12), ready: true)
    #expect(firstTap)
    let replayed = gate.consume(at: calibrationEpoch.addingTimeInterval(13), ready: true)
    #expect(!replayed)
}
