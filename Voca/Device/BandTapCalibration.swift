import Foundation

/// Measures a deliberate single/double sequence without enabling capture or cue delivery.
nonisolated struct BandTapCalibration {
    enum Phase: Sendable, Equatable { case idle, single, double, complete }
    private(set) var phase: Phase = .idle
    private(set) var status = "Check your band’s tap timing before enabling tap cues."
    private(set) var settlingInterval: TimeInterval?
    private(set) var singleObserved = false
    private(set) var doubleObserved = false
    private var startedAt: Date?
    private var firstReceipt: Date?
    private var lastReceipt: Date?
    private var deviceAnchor: UInt32?
    private var minimumOffset: Int32 = 0
    private var maximumOffset: Int32 = 0
    private var history = BandTapHistory()

    mutating func reset() { self = Self() }

    mutating func startSingle(at now: Date) {
        reset()
        phase = .single
        startedAt = now
        status = "Tap your band once, then wait two seconds."
    }

    @discardableResult mutating func startDouble(at now: Date) -> Bool {
        guard phase == .single, singleObserved, let lastReceipt else {
            status = "Complete the single-tap check first."
            return false
        }
        guard now.timeIntervalSince(lastReceipt) >= 2 else {
            status = "Wait two seconds after the single tap, then continue."
            return false
        }
        phase = .double
        startedAt = now
        firstReceipt = nil; self.lastReceipt = nil; deviceAnchor = nil
        minimumOffset = 0; maximumOffset = 0
        status = "Double-tap your band once, then wait two seconds."
        return true
    }

    mutating func receive(milliseconds: UInt32, code: UInt8, at receivedAt: Date) {
        guard phase == .single || phase == .double, let startedAt, receivedAt >= startedAt,
              history.record(milliseconds: milliseconds, code: code, receivedAt: receivedAt) else { return }
        if phase == .single {
            guard code == 1, !singleObserved else {
                fail("More than one tap was detected. Restart the check and tap once.")
                return
            }
            singleObserved = true
            lastReceipt = receivedAt
            status = "Single tap detected. Wait two seconds, then continue."
            return
        }
        if let lastReceipt, receivedAt < lastReceipt {
            fail("Tap timing arrived out of order. Restart the check.")
            return
        }
        if firstReceipt == nil { firstReceipt = receivedAt }
        lastReceipt = receivedAt
        if let deviceAnchor {
            let offset = Int32(bitPattern: milliseconds &- deviceAnchor)
            minimumOffset = min(minimumOffset, offset)
            maximumOffset = max(maximumOffset, offset)
        } else { deviceAnchor = milliseconds }
        doubleObserved = doubleObserved || code == 2
        guard measuredInterval <= 3 else {
            fail("Tap events arrived too far apart. Restart the check near your iPhone.")
            return
        }
        status = doubleObserved ? "Double tap detected. Wait two seconds, then finish the check." :
            "Waiting for the double-tap event. Finish after it is detected."
    }

    @discardableResult mutating func finishDouble(at now: Date) -> Bool {
        guard phase == .double, doubleObserved, let lastReceipt else {
            status = "Double-tap your band and wait for it to be detected."
            return false
        }
        guard now.timeIntervalSince(lastReceipt) >= 2 else {
            status = "Wait two seconds after the last tap event, then finish the check."
            return false
        }
        guard measuredInterval <= 3 else {
            fail("Tap timing exceeded the supported window. Restart the check.")
            return false
        }
        settlingInterval = measuredInterval
        phase = .complete
        status = "Tap timing checked. A single tap can now request a cue."
        return true
    }

    private var measuredInterval: TimeInterval {
        let receiptSpan = (lastReceipt ?? .distantPast).timeIntervalSince(firstReceipt ?? lastReceipt ?? .distantPast)
        let deviceSpan = Double(Int64(maximumOffset) - Int64(minimumOffset)) / 1_000
        // Reserve 250 ms beyond the slower observed clock; never silently clamp unsafe timing.
        return max(0.75, max(receiptSpan, deviceSpan) + 0.25)
    }

    private mutating func fail(_ message: String) {
        phase = .idle
        settlingInterval = nil
        singleObserved = false; doubleObserved = false
        status = message
    }
}
