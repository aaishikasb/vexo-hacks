import AVFoundation

/// Uses the system decoder; failure is surfaced before enabling band AUDIO.
final class OpusDecoder {
    enum Failure: Error { case unsupported, malformed, decode }
    private let source: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    init() throws {
        var description = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 320, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let source = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: output) else { throw Failure.unsupported }
        converter.primeMethod = .none
        self.source = source; self.output = output; self.converter = converter
    }
    func decode(_ opus: Data) throws -> AVAudioPCMBuffer {
        guard !opus.isEmpty, opus.count <= 240 else { throw Failure.malformed }
        let input = AVAudioCompressedBuffer(format: source, packetCapacity: 1, maximumPacketSize: opus.count)
        input.packetCount = 1
        input.byteLength = UInt32(opus.count)
        opus.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: opus.count)
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 320, mDataByteSize: UInt32(opus.count))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 320) else { throw Failure.decode }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        // Core Audio may trim decoder priming from the first packet; retain its actual frame count.
        guard status != .error, pcm.frameLength > 0, pcm.frameLength <= 320 else { throw Failure.decode }
        return pcm
    }
    func reset() { converter.reset() }
}
