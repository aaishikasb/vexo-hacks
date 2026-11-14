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
