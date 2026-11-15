import Foundation
import Testing
@testable import VocaDevice

@Test func cueTimingIncludesRetriesAndRejectsLateCallbacks() {
    let trace = CueTrace(origin: "band", began: 0)
    trace.mark("cueStarted", now: 1)
    trace.mark("cueReady", now: 3)
    trace.mark("cueStarted", now: 4)
    trace.mark("cueReady", now: 7)
    trace.mark("playbackStarted", now: 8)
    let result = trace.finish("completed")
    trace.mark("playbackStarted", now: 10)
    #expect(result.duration(from: "cueStarted", to: "cueReady") == 5)
    #expect(result.firstSpeech == 8)
    #expect(trace.finish("failed").outcome == "completed")
    #expect(trace.finish("failed").events.count == result.events.count)
}
