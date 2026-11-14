import Foundation
import Testing
@testable import VocaDevice

private let tapEpoch = Date(timeIntervalSince1970: 1_000)

@Test func bandCueRequiresVerifiedMappingAndSettlesOnce() {
    var trigger = BandCueTrigger()
    trigger.receive(milliseconds: 1, code: 1, at: tapEpoch, ready: true)
    let result9 = trigger.consume(at: tapEpoch.addingTimeInterval(1), ready: true)
    #expect(!result9)
    let result10 = trigger.enableVerifiedMapping(settlingInterval: .infinity)
    #expect(!result10)
    let result11 = trigger.enableVerifiedMapping(settlingInterval: 0.7)
    #expect(result11)
    trigger.receive(milliseconds: 1_000, code: 1, at: tapEpoch, ready: true)
    let result13 = trigger.consume(at: tapEpoch.addingTimeInterval(0.6), ready: true)
    #expect(!result13)
    let result14 = trigger.consume(at: tapEpoch.addingTimeInterval(0.7), ready: true)
    #expect(result14)
    let result15 = trigger.consume(at: tapEpoch.addingTimeInterval(2), ready: true)
    #expect(!result15)
    trigger.receive(milliseconds: 1_000, code: 1, at: tapEpoch.addingTimeInterval(3), ready: true)
    let result17 = trigger.consume(at: tapEpoch.addingTimeInterval(4), ready: true)
    #expect(!result17)
}

@Test func bandCueSuppressesSinglesAroundDoubleEvents() {
    for codes: [UInt8] in [[1, 2], [2, 1], [1, 1, 2], [1, 1]] {
        var trigger = BandCueTrigger()
        trigger.enableVerifiedMapping(settlingInterval: 0.7)
        for (index, code) in codes.enumerated() {
            trigger.receive(milliseconds: 1_000 + UInt32(index * 100), code: code,
                            at: tapEpoch.addingTimeInterval(Double(index) * 0.1), ready: true)
        }
        let result28 = trigger.consume(at: tapEpoch.addingTimeInterval(2), ready: true)
        #expect(!result28)
    }
}

@Test func bandCueRejectsStaleEventsAndHandlesTimestampWrap() {
    var trigger = BandCueTrigger()
    trigger.enableVerifiedMapping(settlingInterval: 0.7)
    trigger.receive(milliseconds: UInt32.max - 100, code: 2, at: tapEpoch, ready: true)
    trigger.receive(milliseconds: 20, code: 1, at: tapEpoch.addingTimeInterval(0.2), ready: true)
    let result37 = trigger.consume(at: tapEpoch.addingTimeInterval(1), ready: true)
    #expect(!result37)
    trigger.receive(milliseconds: 1_000, code: 1, at: tapEpoch.addingTimeInterval(2), ready: true)
    trigger.receive(milliseconds: 900, code: 2, at: tapEpoch.addingTimeInterval(2.1), ready: true)
    let result40 = trigger.consume(at: tapEpoch.addingTimeInterval(3), ready: true)
    #expect(result40)
}

@Test func bandCueNeverQueuesAnActionAcrossBusyDisconnectOrDisable() {
    var trigger = BandCueTrigger()
    trigger.enableVerifiedMapping(settlingInterval: 0.7)
    trigger.receive(milliseconds: 1_000, code: 1, at: tapEpoch, ready: false)
    let result47 = trigger.consume(at: tapEpoch.addingTimeInterval(1), ready: true)
    #expect(!result47)
    trigger.receive(milliseconds: 2_000, code: 1, at: tapEpoch, ready: true)
    let result49 = trigger.consume(at: tapEpoch.addingTimeInterval(1), ready: false)
    #expect(!result49)
    let result50 = trigger.consume(at: tapEpoch.addingTimeInterval(2), ready: true)
    #expect(!result50)
    trigger.receive(milliseconds: 3_000, code: 1, at: tapEpoch, ready: true)
    trigger.disableMapping()
    let result53 = trigger.consume(at: tapEpoch.addingTimeInterval(2), ready: true)
    #expect(!result53)
    trigger.enableVerifiedMapping(settlingInterval: 0.7)
    trigger.receive(milliseconds: 4_000, code: 1, at: tapEpoch, ready: true)
    trigger.reset()
    #expect(!trigger.mappingVerified)
    let result58 = trigger.consume(at: tapEpoch.addingTimeInterval(2), ready: true)
    #expect(!result58)
}
