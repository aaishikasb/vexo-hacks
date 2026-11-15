import Foundation
import Testing
@testable import VocaDevice

@Test func identityMustMatchBeforeConnecting() {
    let service = [BandProtocol.service]
    #expect(!BandProtocol.matches(number: 0, services: service, name: "Vexo-HACK-00", manufacturer: nil))
    #expect(!BandProtocol.matches(number: 1, services: service, name: "Vexo-HACK-10", manufacturer: nil))
    #expect(!BandProtocol.matches(number: 1, services: [], name: "Vexo-HACK-01", manufacturer: nil))
    #expect(BandProtocol.matches(number: 1, services: service, name: nil, manufacturer: Data([255,255,79,1,1,0])))
    #expect(!BandProtocol.matches(number: 1, services: service, name: "Vexo-HACK-01", manufacturer: Data([255,255,79,1,2,0])))
}
@Test func validatesFramesAndInfo() throws {
    #expect(throws: (any Error).self) { try BandProtocol.parse(Data([0x13,0,0,3,1])) }
    #expect(throws: (any Error).self) { try BandProtocol.parse(Data([2,0,1,1,7])) }
    #expect(try BandProtocol.parse(Data([0x11,0,0,0,0,99,0])) == .unknown)
    #expect(try BandProtocol.parse(Data([0xfe])) == .unknown)
    let info = Data([1,1,1,1,0,1,42,0,0x34,0,244,0,0,0,0,0])
    #expect(try BandProtocol.Info(info, assignedNumber: 42).supportsAudio)
    #expect(throws: (any Error).self) { try BandProtocol.Info(info, assignedNumber: 43) }
    for length in 0..<16 {
        #expect(throws: (any Error).self) { try BandProtocol.Info(info.prefix(length), assignedNumber: 42) }
    }
}
@Test func audioWrapGapDuplicatesAndRestart() throws {
    var timeline = BandAudioTimeline()
    let start = Date(timeIntervalSince1970: 0)
    timeline.restart(commandSentAt: start, micAlreadyOn: false)
    _ = timeline.accept(sequence: 65535, receivedAt: start)
    let wrappedPacket = timeline.accept(sequence: 0, receivedAt: start.addingTimeInterval(9999))
    let wrapped = try #require(wrappedPacket)
    #expect(wrapped.missingPackets == 0)
    #expect(abs(wrapped.captureEstimate.timeIntervalSince1970 - (0.14 + 65536 * 0.02)) < 0.0001)
    let duplicate = timeline.accept(sequence: 0, receivedAt: start)
    #expect(duplicate == nil)
    let stale = timeline.accept(sequence: 65535, receivedAt: start)
    #expect(stale == nil)
    #expect(timeline.accept(sequence: 3, receivedAt: start)?.missingPackets == 2)
    timeline.restart(commandSentAt: start, micAlreadyOn: true)
    #expect(timeline.accept(sequence: 0, receivedAt: start)?.captureEstimate == start.addingTimeInterval(0.04))
}

@Test func responseMustMatchOutstandingCommand() {
    #expect(BandProtocol.responseMatches(sequence: 255, opcode: 1, status: 0, dataCount: 16, expectedSequence: 255, expectedOpcode: 1, expectedLength: 16))
    #expect(!BandProtocol.responseMatches(sequence: 0, opcode: 1, status: 0, dataCount: 16, expectedSequence: 255, expectedOpcode: 1, expectedLength: 16))
    #expect(!BandProtocol.responseMatches(sequence: 255, opcode: 2, status: 0, dataCount: 16, expectedSequence: 255, expectedOpcode: 1, expectedLength: 16))
    #expect(!BandProtocol.responseMatches(sequence: 255, opcode: 1, status: 0, dataCount: 15, expectedSequence: 255, expectedOpcode: 1, expectedLength: 16))
    #expect(BandProtocol.responseMatches(sequence: 255, opcode: 1, status: 5, dataCount: 0, expectedSequence: 255, expectedOpcode: 1, expectedLength: 16))
    #expect(!BandProtocol.responseMatches(sequence: 255, opcode: 1, status: 5, dataCount: 16, expectedSequence: 255, expectedOpcode: 1, expectedLength: 16))
}

@Test func assignedBand18RejectsNearbyAndConflictingIdentities() {
    let services = [BandProtocol.service.uppercased()]
    #expect(BandProtocol.matches(number: 18, services: services, name: "Vexo-HACK-18", manufacturer: Data([255,255,79,1,18,0])))
    #expect(BandProtocol.matches(number: 18, services: services, name: "Vexo-HACK-18", manufacturer: nil))
    #expect(!BandProtocol.matches(number: 18, services: services, name: "Vexo-HACK-180", manufacturer: nil))
    #expect(!BandProtocol.matches(number: 18, services: services, name: "Vexo-HACK-18", manufacturer: Data([255,255,79,1,19,0])))
    #expect(!BandProtocol.matches(number: 18, services: services, name: nil, manufacturer: Data([255,255,79,2,18,0])))
    #expect(!BandProtocol.matches(number: 18, services: services, name: nil, manufacturer: nil))
    #expect(throws: (any Error).self) { try BandProtocol.parse(Data([0x13,0,0,0])) }
}

@Test func acknowledgedStreamMasksMustMatchRequestedMicrophoneState() throws {
    try BandProtocol.validateStreams(Data([2,0]), required: 2, stopped: 0x88)
    try BandProtocol.validateStreams(Data([10,0]), required: 8)
    try BandProtocol.validateStreams(Data([2,0]), stopped: 0x88)
    #expect(throws: (any Error).self) { try BandProtocol.validateStreams(Data([2,0]), required: 8) }
    #expect(throws: (any Error).self) { try BandProtocol.validateStreams(Data([0x82,0]), stopped: 0x88) }
    #expect(throws: (any Error).self) { try BandProtocol.validateStreams(Data([10,0]), stopped: 0x88) }
    #expect(throws: (any Error).self) { try BandProtocol.validateStreams(Data([0])) }
}

@Test func tapDiagnosticsRetainOrderingWithoutTreatingDoubleAsSingle() throws {
    var taps = BandTapHistory()
    let received = Date(timeIntervalSince1970: 10)
    let first = taps.record(milliseconds: UInt32.max - 100, code: 1, receivedAt: received)
    #expect(first)
    let second = taps.record(milliseconds: 50, code: 2, receivedAt: received.addingTimeInterval(0.2))
    #expect(second)
    let duplicate = taps.record(milliseconds: 50, code: 2, receivedAt: received.addingTimeInterval(0.3))
    #expect(!duplicate)
    #expect(taps.observations.map(\.code) == [1, 2, 2])
    #expect(taps.observations.last?.duplicate == true)
    #expect(taps.observations[1].receivedAt == received.addingTimeInterval(0.2))
    let unknown = taps.record(milliseconds: 60, code: 99, receivedAt: received)
    #expect(!unknown)
    for time in 100..<140 { taps.record(milliseconds: UInt32(time), code: 1, receivedAt: received) }
    #expect(taps.observations.count == 32)
    #expect(taps.observations.last?.milliseconds == 139)
}

@Test func automaticBandReconnectStillRequiresVerified18() throws {
    let info = Data([1,1,1,1,0,1,18,0,0x34,0,244,0,0,0,0,0])
    _ = try BandProtocol.Info(info, assignedNumber: 18)
    #expect(throws: (any Error).self) { try BandProtocol.Info(info, assignedNumber: 19) }
    #expect(!BandProtocol.matches(number: 18, services: [], name: "Vexo-HACK-18", manufacturer: nil))
}
