import Testing
@testable import VocaDevice

@Test func fallbackDoesNotAdvanceOrClaimDelivery() {
    #expect(CuePhase.capturing.step == 0)
    #expect(CuePhase.thinking.step == 1)
    #expect(CuePhase.fallback.step == CuePhase.thinking.step)
    #expect(CuePhase.speaking.step == 2)
    #expect(CuePhase.fallback.detail.contains("E2B"))
    #expect(CuePhase.speaking.title == "Your cue is playing")
}
