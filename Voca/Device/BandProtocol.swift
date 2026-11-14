import Foundation

nonisolated enum BandProtocol {
    static let service = "254f0001-df82-4a9c-a2b5-563a0f6b2021"
    static let rx = "254f0002-df82-4a9c-a2b5-563a0f6b2021"
    static let tx = "254f0003-df82-4a9c-a2b5-563a0f6b2021"
    enum Failure: Error { case malformed, unsupported, identity, busy, disconnected, timeout, status(UInt8) }

    static func matches(number: Int, services: [String], name: String?, manufacturer: Data?) -> Bool {
        guard (1...999).contains(number), services.contains(where: { $0.lowercased() == service }) else { return false }
        let exactName = String(format: "Vexo-HACK-%02d", number)
        if let name, name != exactName { return false }
        if let manufacturer {
            let b = [UInt8](manufacturer)
            guard b.count == 6, b[0] == 0xff, b[1] == 0xff, b[2] == 0x4f,
                  b[3] == 1, u16(b, 4) == number else { return false }
            return true
        }
        return name == exactName
    }

    struct Info: Equatable, Sendable {
        let number: Int
        let capabilities: UInt16
        let maxFrame: Int
        let firmware: String
        init(_ data: Data, assignedNumber: Int) throws {
            let b = [UInt8](data)
            guard b.count == 16 else { throw Failure.malformed }
            guard b[0] == 1, b[1] >= 1 else { throw Failure.unsupported }
            number = Int(u16(b, 6))
            guard number == assignedNumber else { throw Failure.identity }
            capabilities = u16(b, 8)
            maxFrame = Int(u16(b, 10))
            guard (20...244).contains(maxFrame) else { throw Failure.unsupported }
            firmware = "\(b[2]).\(b[3]).\(b[4])"
        }
        var supportsEvents: Bool { capabilities & (1 << 2) != 0 }
        var supportsAudio: Bool { capabilities & 0x30 == 0x30 }
    }

    enum Frame: Equatable, Sendable {
        case response(sequence: UInt8, opcode: UInt8, status: UInt8, data: Data)
        case event(milliseconds: UInt32, code: UInt8, argument: UInt8)
        case audio(sequence: UInt16, opus: Data)
        case notice(code: UInt8, argument: UInt8)
        case unknown
    }
    static func parse(_ data: Data, maxFrame: Int = 244) throws -> Frame {
        let b = [UInt8](data)
        guard !b.isEmpty, b.count <= maxFrame else { throw Failure.malformed }
        switch b[0] {
        case 2:
            guard b.count >= 4, b[3] == 0 || b.count == 4 else { throw Failure.malformed }
            return .response(sequence: b[1], opcode: b[2], status: b[3], data: Data(b.dropFirst(4)))
        case 3:
            guard b.count == 3 else { throw Failure.malformed }
            return .notice(code: b[1], argument: b[2])
        case 0x11:
            guard b.count == 7 else { throw Failure.malformed }
            guard (1...7).contains(b[5]) else { return .unknown }
            let time = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
            return .event(milliseconds: time, code: b[5], argument: b[6])
        case 0x13:
            guard b.count > 4, Int(b[3]) == b.count - 4 else { throw Failure.malformed }
            return .audio(sequence: u16(b, 1), opus: Data(b.dropFirst(4)))
        default: return .unknown
        }
    }
    static func responseMatches(sequence: UInt8, opcode: UInt8, status: UInt8, dataCount: Int,
                                expectedSequence: UInt8, expectedOpcode: UInt8, expectedLength: Int) -> Bool {
        sequence == expectedSequence && opcode == expectedOpcode &&
            (status == 0 ? dataCount == expectedLength : dataCount == 0)
    }
    static func validateStreams(_ data: Data, required: UInt16 = 0, stopped: UInt16 = 0) throws {
        let bytes = [UInt8](data)
        guard bytes.count == 2 else { throw Failure.malformed }
        let active = u16(bytes, 0)
        guard active & required == required, active & stopped == 0 else { throw Failure.unsupported }
    }
    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    static func mask(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]) }
}

/// Capture estimates are anchored to STREAM_START, never notification arrival time.
nonisolated struct BandAudioTimeline {
    struct Packet: Sendable {
        let captureEstimate: Date
        let receivedAt: Date
        let missingPackets: Int
    }
    private var previous: UInt16?
    private var index = 0
    private var start: Date?
    mutating func restart(commandSentAt: Date, micAlreadyOn: Bool) {
        previous = nil
        index = 0
        start = commandSentAt.addingTimeInterval(micAlreadyOn ? 0.04 : 0.14)
    }
    mutating func accept(sequence: UInt16, receivedAt: Date) -> Packet? {
        guard let start else { return nil }
        let missing: Int
        if let previous {
            let delta = sequence &- previous
            // Old/duplicate frames are not a new stream. Restart only after an acknowledged start.
            guard delta > 0, delta < 32768 else { return nil }
            index += Int(delta)
            missing = Int(delta) - 1
        } else {
            index = Int(sequence)
            missing = Int(sequence)
        }
        previous = sequence
        return Packet(captureEstimate: start.addingTimeInterval(Double(index) * 0.02), receivedAt: receivedAt, missingPackets: missing)
    }
}

/// Retains receipt ordering for detector calibration; never treats timing as a verified gesture mapping.
nonisolated struct BandTapHistory {
    struct Observation: Sendable {
        let milliseconds: UInt32
        let code: UInt8
        let receivedAt: Date
        let duplicate: Bool
    }
    private(set) var observations: [Observation] = []
    @discardableResult mutating func record(milliseconds: UInt32, code: UInt8, receivedAt: Date) -> Bool {
        guard code == 1 || code == 2 else { return false }
        let duplicate = observations.contains { $0.milliseconds == milliseconds && $0.code == code }
        observations.append(Observation(milliseconds: milliseconds, code: code, receivedAt: receivedAt, duplicate: duplicate))
        if observations.count > 32 { observations.removeFirst(observations.count - 32) }
        return !duplicate
    }
}
