import AVFoundation
import Foundation
import Testing
@testable import VocaDevice

@Test func nativeOpusPreservesPrimingAndSteadyPacketDuration() throws {
    let decoder = try OpusDecoder()
    // RFC 6716-compatible 20 ms Opus silence packet, not a personal recording.
    let pcm = try decoder.decode(Data([0xf8, 0xff, 0xfe]))
    #expect(pcm.frameLength > 0 && pcm.frameLength <= 320)
    let steady = try decoder.decode(Data([0xf8, 0xff, 0xfe]))
    #expect(steady.frameLength == 320)
    #expect(pcm.format.sampleRate == 16000)
    #expect(pcm.format.channelCount == 1)
    #expect(throws: (any Error).self) { try decoder.decode(Data()) }
    decoder.reset()
    let restarted = try decoder.decode(Data([0xf8, 0xff, 0xfe]))
    #expect(restarted.frameLength > 0 && restarted.frameLength <= 320)
}
