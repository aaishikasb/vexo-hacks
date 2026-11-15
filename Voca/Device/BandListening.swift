import Foundation
import CryptoKit
import Observation
import VocaCore

@MainActor @Observable final class BandListening {
    private(set) var decodedPackets = 0
    private(set) var active = false
    private(set) var continuous = false
    private(set) var transcript = ""
    private(set) var sourceID: String?
    private(set) var utteredAt: Date?
    private(set) var isFinal = false
    private(set) var hasGap = false
    private(set) var status = "Microphone off"
    private let transcriber = LocalTranscriber()
    private var decoder: OpusDecoder?
    private var timer: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var pendingSegments = 0
    private var processingError: String?
    private var seen = Set<String>()
    private(set) var starting = false
    private(set) var stopping = false
    private var generation = 0
    private var dialogue = LiveDialogue()
    private var playbackActive: () -> Bool = { false }
    private var wasPlaying = false
    var freshDialogueCount: Int { dialogue.fresh(at: Date()).count }

    func cueSnapshot(memories: MemorySnapshot) async -> MemorySnapshot {
        guard active, continuous else { return memories }
        await transcriber.flush()
        guard active, !Task.isCancelled else { return memories }
        return dialogue.snapshot(memories: memories)
    }
    var busy: Bool { active || starting || stopping }

    func startConsentedSample(band: BandClient) async throws {
        try await start(band: band, memory: nil, voice: nil)
    }
    func startContinuous(band: BandClient, memory: MemoryStore, voice: PipecatSpeech, playbackActive: @escaping () -> Bool = { false }) async throws {
        self.playbackActive = playbackActive
        guard memory.loaded, voice.ready else { throw PipecatSpeech.Failure.notReady }
        guard memory.suggestions.count < 100 else { throw MemoryStore.Failure.suggestionsFull }
        try await start(band: band, memory: memory, voice: voice)
    }
    private func start(band: BandClient, memory: MemoryStore?, voice: PipecatSpeech?) async throws {
        guard !busy else { throw BandProtocol.Failure.busy }
        starting = true
        defer { starting = false; if !active { continuous = false } }
        generation += 1
        let current = generation
        let sessionID = UUID()
        let sourceID = sessionID.uuidString
        self.sourceID = sourceID
        continuous = memory != nil
        dialogue.clear(); wasPlaying = false
        decodedPackets = 0
        seen.removeAll()
        processingError = nil
        transcript = ""; utteredAt = nil; isFinal = false; hasGap = false
        status = "Preparing local speech recognition…"
        let decoder = try OpusDecoder()
        transcriber.onText = { [weak self] text, final, time in
            guard let self, self.sourceID == sourceID else { return }
            self.transcript = text; self.isFinal = final; self.utteredAt = time
        }
        transcriber.onSegment = { [weak self, weak band] text, final, time, gap in
            guard let self, let band, self.sourceID == sourceID, let memory, let voice else { return }
            self.transcript = ""
            self.enqueue(text: text, final: final, time: time, gap: gap, sessionID: sessionID,
                         band: band, memory: memory, voice: voice)
        }
        transcriber.onError = { [weak self, weak band] error in
            guard let self, let band, self.generation == current else { return }
            Task { await self.stop(band: band, message: "Listening stopped: \(error.localizedDescription)") }
        }
        do { try await transcriber.start(continuous: continuous) }
        catch { transcriber.stop(); status = error.localizedDescription; throw error }
        guard generation == current else { transcriber.stop(); throw CancellationError() }
        self.decoder = decoder
        band.onAudioGap = { [weak self] in
            guard let self, self.generation == current else { return }
            self.dialogue.clear()
            self.hasGap = true; self.utteredAt = nil
            self.transcriber.markGap(); decoder.reset()
            self.status = "Listening · audio gap detected; check suggested details carefully"
        }
        band.onListeningEnded = { [weak self, weak band] message in
            guard let self, let band, self.generation == current else { return }
            Task { await self.stop(band: band, message: message) }
        }
        band.onAudio = { [weak self, weak band] opus, packet in
            guard let self, let band, self.active, self.generation == current else { return }
            if self.playbackActive() {
                if !self.wasPlaying { self.dialogue.clear(); self.transcriber.discardSegment() }
                self.wasPlaying = true
                return
            }
            if self.wasPlaying { self.wasPlaying = false; self.transcriber.discardSegment() }
            do {
                let pcm = try decoder.decode(opus)
                self.decodedPackets += 1
                self.transcriber.append(pcm, approximateCaptureTime: packet.captureEstimate, missingPackets: packet.missingPackets)
            } catch {
                Task { await self.stop(band: band, message: "Audio decoding failed. Reconnect your band and resume listening.") }
            }
        }
        active = true
        do { try await band.startListening() }
        catch { await stop(band: band, message: "Band listening failed. Reconnect to your assigned band and retry."); throw error }
        guard generation == current else { throw CancellationError() }
        status = continuous ? "Listening for useful details · audio stays on this iPhone" : "Listening for 10 seconds · blue band light on"
        if !continuous {
            timer = Task { [weak self, weak band] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let band, self.generation == current else { return }
                await self.stop(band: band)
            }
        }
    }

    private func enqueue(text: String, final: Bool, time: Date?, gap: Bool, sessionID: UUID,
                         band: BandClient, memory: MemoryStore, voice: PipecatSpeech) {
        guard !playbackActive() else { return }
        let id = UUID(), capturedAt = Date(), bandNumber = band.info?.number
        dialogue.append(id: "band-dialogue:\(sessionID.uuidString):\(id.uuidString)", text: text,
                        final: final, capturedAt: time, gap: gap, now: capturedAt)
        let excerpts = MemorySuggestion.excerpts(from: text).filter { !seen.contains(Self.fingerprint($0)) }
        let suggestions = excerpts.enumerated().map { index, excerpt in
            MemorySuggestion(id: "band:\(sessionID.uuidString):\(id.uuidString):\(index)", sessionID: sessionID,
                text: excerpt, capturedAt: capturedAt, utteredAt: gap || !final ? nil : time,
                hasGap: gap || !final, ruleVersion: "explicit-details-en-v2", bandNumber: bandNumber)
        }
        do {
            // Save the review queue before an async voice acknowledgement can fail or the app can exit.
            if !suggestions.isEmpty { try memory.addSuggestions(suggestions) }
            if seen.count >= 1024 { seen.removeAll() }
            for excerpt in excerpts { seen.insert(Self.fingerprint(excerpt)) }
        } catch {
            processingError = "Suggestions could not be saved. \(error.localizedDescription)"
            let message = processingError ?? "Suggestions could not be saved."
            status = message
            Task { await self.stop(band: band, message: message) }
            return
        }
        // Incomplete recognition remains visibly uncertain and unapproved, never a final Pipecat turn.
        guard final else { return }
        guard text.count <= 2000, pendingSegments < 8 else {
            processingError = "Speech processing reached its limit. Saved suggestions remain in Memory."
            status = processingError ?? "Review your captured suggestions."
            Task { await self.stop(band: band, message: "Resume listening after reviewing suggestions.") }
            return
        }
        let previous = processing
        pendingSegments += 1
        processing = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.pendingSegments -= 1 }
            do {
                try await voice.acceptBandTranscript(id: id, sessionID: sessionID, text: text, capturedAt: capturedAt)
            } catch {
                self.processingError = "Speech processing stopped. Saved suggestions remain in Memory. \(error.localizedDescription)"
                let message = self.processingError ?? "Speech processing stopped."
                self.status = message
                Task { await self.stop(band: band, message: message) }
            }
        }
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.lowercased().utf8)).description
    }

    func stop(band: BandClient, message: String = "Microphone off") async {
        if stopping {
            while stopping { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        guard busy else { return }
        stopping = true
        defer { stopping = false }
        generation += 1
        active = false
        timer?.cancel(); timer = nil
        await band.stopListening()
        band.onAudio = nil; band.onAudioGap = nil; band.onListeningEnded = nil
        await transcriber.finish()
        await processing?.value
        processing = nil
        transcriber.stop()
        transcriber.onSegment = nil
        decoder = nil
        if continuous { transcript = "" }
        continuous = false
        dialogue.clear()
        status = processingError.map { "\(message). \($0)" } ?? message
    }
}
