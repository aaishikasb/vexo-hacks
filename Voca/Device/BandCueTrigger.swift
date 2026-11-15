import Foundation

/// Defers verified single taps so a detector's later double-tap event can suppress them.
nonisolated struct BandCueTrigger {
    private(set) var settlingInterval: TimeInterval?
    var mappingVerified: Bool { settlingInterval != nil }
    private(set) var deadline: Date?
    private var pendingMilliseconds: UInt32?
    private var lastMilliseconds: UInt32?
    private var suppressedMilliseconds: UInt32?
    private var history = BandTapHistory()

    /// Supply a settling interval only after measuring this assigned band's detector timing.
    @discardableResult mutating func enableVerifiedMapping(settlingInterval: TimeInterval) -> Bool {
        guard settlingInterval.isFinite, settlingInterval > 0 else { disableMapping(); return false }
        self.settlingInterval = settlingInterval
        cancelPending()
        return true
    }

    mutating func disableMapping() {
        settlingInterval = nil
        cancelPending()
    }

    /// Discard link-scoped events; restore saved calibration only after the assigned band is verified.
    mutating func reset() { self = Self() }

    /// Returns the deadline the caller should schedule. Call `consume` with current readiness then.
    @discardableResult mutating func receive(milliseconds: UInt32, code: UInt8, at receivedAt: Date,
                                            ready: Bool) -> Date? {
        if !ready { cancelPending() }
        guard history.record(milliseconds: milliseconds, code: code, receivedAt: receivedAt) else { return deadline }
        if let lastMilliseconds, milliseconds &- lastMilliseconds >= 0x8000_0000 { return deadline }
        lastMilliseconds = milliseconds
        guard let settlingInterval, ready else { cancelPending(); return nil }
        if code == 2 {
            suppressedMilliseconds = milliseconds
            cancelPending()
            return nil
        }
        if let suppressedMilliseconds,
           TimeInterval(milliseconds &- suppressedMilliseconds) / 1_000 <= settlingInterval { return deadline }
        if let pendingMilliseconds,
           TimeInterval(milliseconds &- pendingMilliseconds) / 1_000 <= settlingInterval {
            // Two close singles may be a double whose classification is delayed: never deliver both.
            suppressedMilliseconds = milliseconds
            cancelPending()
            return nil
        }
        pendingMilliseconds = milliseconds
        deadline = receivedAt.addingTimeInterval(settlingInterval)
        return deadline
    }

    /// Consumes at most once; a stale timer cannot replay a tap after cancellation or lost readiness.
    mutating func consume(at now: Date, ready: Bool) -> Bool {
        guard mappingVerified, ready else { cancelPending(); return false }
        guard let deadline, now >= deadline else { return false }
        cancelPending()
        return true
    }

    mutating func cancelPending() {
        deadline = nil
        pendingMilliseconds = nil
    }
}
