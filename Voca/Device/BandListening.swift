import Foundation
import Observation

@MainActor @Observable final class BandListening {
    private(set) var active = false
    private(set) var transcript = ""
    private(set) var status = "Microphone off"
    private let transcriber = LocalTranscriber()
    private var decoder: OpusDecoder?
    private var timer: Task<Void, Never>?
    private var starting = false
    private var generation = 0

    func startConsentedSample(band: BandClient) async throws {
        guard !active, !starting else { throw BandProtocol.Failure.busy }
        starting = true
        defer { starting = false }
        generation += 1
        let current = generation
        let decoder = try OpusDecoder()
        self.decoder = decoder
        transcriber.onText = { [weak self] text, _, _ in self?.transcript = text }
        transcriber.onError = { [weak self, weak band] error in
            guard let self, let band else { return }
            self.status = error.localizedDescription
            Task { await self.stop(band: band) }
        }
        try await transcriber.start()
        guard generation == current else { transcriber.stop(); throw CancellationError() }
        transcript = ""
        band.onAudioGap = { [weak self] in self?.transcriber.markGap() }
        band.onAudio = { [weak self, weak band] opus, packet in
            guard let self, let band, self.active else { return }
            do {
                if packet.missingPackets > 0 { decoder.reset() }
                let pcm = try decoder.decode(opus)
                self.transcriber.append(pcm, approximateCaptureTime: packet.captureEstimate, missingPackets: packet.missingPackets)
            } catch {
                self.status = "Audio decoding failed. Listening stopped; no transcript is approved memory."
                Task { await self.stop(band: band) }
            }
        }
        active = true
        do { try await band.startListening() }
        catch { await stop(band: band); throw error }
        guard generation == current else { await stop(band: band); throw CancellationError() }
        status = "Listening for 10 seconds · blue band light on"
        timer = Task { [weak self, weak band] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let band else { return }
            await self.stop(band: band)
        }
    }
    func stop(band: BandClient) async {
        generation += 1
        active = false
        timer?.cancel(); timer = nil
        await band.stopListening()
        band.onAudio = nil; band.onAudioGap = nil
        transcriber.endAudio()
        decoder = nil
        status = "Microphone off · speaker unknown · transcript not saved"
    }
}
