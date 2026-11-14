import Foundation
import Observation

@MainActor @Observable final class BandListening {
    private(set) var active = false
    private(set) var transcript = ""
    private(set) var sourceID: String?
    private(set) var utteredAt: Date?
    private(set) var isFinal = false
    private(set) var hasGap = false
    private(set) var status = "Microphone off"
    private let transcriber = LocalTranscriber()
    private var decoder: OpusDecoder?
    private var timer: Task<Void, Never>?
    private var starting = false
    private var stopping = false
    private var generation = 0

    func startConsentedSample(band: BandClient) async throws {
        guard !active, !starting, !stopping else { throw BandProtocol.Failure.busy }
        starting = true
        defer { starting = false }
        generation += 1
        let current = generation
        let sourceID = UUID().uuidString
        self.sourceID = sourceID
        transcript = ""; utteredAt = nil; isFinal = false; hasGap = false
        let decoder = try OpusDecoder()
        try await transcriber.start()
        guard generation == current else { transcriber.stop(); throw CancellationError() }
        self.decoder = decoder
        transcriber.onText = { [weak self] text, final, time in
            guard let self, self.sourceID == sourceID else { return }
            self.transcript = text
            self.isFinal = final
            self.utteredAt = self.hasGap ? nil : time
        }
        transcriber.onError = { [weak self, weak band] error in
            guard let self, let band, self.generation == current else { return }
            Task { await self.stop(band: band, message: error.localizedDescription) }
        }
        band.onAudioGap = { [weak self] in
            guard let self, self.generation == current else { return }
            self.hasGap = true; self.utteredAt = nil
            self.transcriber.markGap()
            decoder.reset()
        }
        band.onListeningEnded = { [weak self, weak band] message in
            guard let self, let band, self.generation == current else { return }
            Task { await self.stop(band: band, message: message) }
        }
        band.onAudio = { [weak self, weak band] opus, packet in
            guard let self, let band, self.active, self.generation == current else { return }
            do {
                if packet.missingPackets > 0 { decoder.reset() }
                let pcm = try decoder.decode(opus)
                self.transcriber.append(pcm, approximateCaptureTime: packet.captureEstimate, missingPackets: packet.missingPackets)
            } catch {
                Task { await self.stop(band: band, message: "Audio decoding failed. Listening stopped; no transcript is approved memory.") }
            }
        }
        active = true
        do { try await band.startListening() }
        catch { await stop(band: band, message: "Band listening failed. Reconnect to your assigned band and retry."); throw error }
        guard generation == current else { await stop(band: band); throw CancellationError() }
        status = "Listening for 10 seconds · blue band light on"
        timer = Task { [weak self, weak band] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let band, self.generation == current else { return }
            await self.stop(band: band)
        }
    }
    func stop(band: BandClient, message: String = "Microphone off · speaker unknown · transcript not saved") async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        generation += 1
        active = false
        timer?.cancel(); timer = nil
        await band.stopListening()
        band.onAudio = nil; band.onAudioGap = nil; band.onListeningEnded = nil
        transcriber.endAudio()
        decoder = nil
        status = message
    }
}
