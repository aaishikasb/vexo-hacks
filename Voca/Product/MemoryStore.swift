import Foundation
import Observation
import VocaCore

struct MemoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case personalMemory, dialogue }
    let evidence: Evidence
    let kind: Kind
    let decisionID: UUID?
    let savedAt: Date
    var capturedSource: MemorySuggestion? = nil
    var id: String { evidence.sourceID }
}

@MainActor @Observable final class MemoryStore {
    enum Failure: LocalizedError {
        case text, unavailable, limit, corrupt, suggestionsFull, confirmation
        var errorDescription: String? {
            switch self {
            case .suggestionsFull: "Your 100 suggestion slots are full. Review or clear suggestions, then resume listening."
            case .confirmation: "Confirm this detail is accurate and yours to share before approving it."
            case .text: "Enter a short memory (up to 240 characters) or a conversation excerpt (up to 500 characters)."
            case .unavailable: "Your saved memories could not be opened. Existing data has been preserved. Restart Voca to retry."
            case .limit: "You have 100 saved entries. Delete an entry before adding another."
            case .corrupt: "The memory file could not be read safely. Existing data has been preserved."
            }
        }
    }
    private struct Document: Codable {
        var entries: [MemoryEntry] = []
        var audits: [AuditReport] = []
        var auditSources: [String: [String]] = [:]
        var pendingDeletionIDs: Set<String> = []
    }
    private var document = Document()
    private(set) var loaded = false
    private(set) var loadError: String?
    let url: URL
    private var pendingSuggestions: [MemorySuggestion] = []
    var suggestions: [MemorySuggestion] { pendingSuggestions.filter { suggestion in !records.contains { $0.id == suggestion.id } } }
    private var suggestionsURL: URL { url.deletingLastPathComponent().appending(path: "Capture/suggestions.json") }
    var records: [MemoryEntry] { document.entries }
    var audits: [AuditReport] { document.audits }
    var pendingDeletionIDs: Set<String> { document.pendingDeletionIDs }

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "Voca/Memory/evidence.json")
    }

    func load() throws {
        guard !loaded else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
            var directoryURL = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directoryURL.setResourceValues(values)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 1_000_000 else { throw Failure.corrupt }
                let decoded = try JSONDecoder().decode(Document.self, from: data)
                guard decoded.entries.count <= 100,
                      Set(decoded.entries.map(\.id)).count == decoded.entries.count,
                      decoded.entries.allSatisfy({ !$0.evidence.text.isEmpty && $0.evidence.text.count <= 500 &&
                          ($0.kind != .personalMemory || ($0.evidence.shareApproved && $0.evidence.speaker == "wearer")) &&
                          ($0.kind != .dialogue || $0.decisionID != nil) }) else { throw Failure.corrupt }
                document = decoded
            }
            let captureDirectory = suggestionsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            var captureURL = captureDirectory
            try captureURL.setResourceValues(values)
            #if os(iOS)
            // Pending suggestions must remain writable during authorized locked-phone BLE capture.
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: captureDirectory.path)
            #endif
            if FileManager.default.fileExists(atPath: suggestionsURL.path) {
                let data = try Data(contentsOf: suggestionsURL)
                guard data.count <= 500_000 else { throw Failure.corrupt }
                let decoded = try JSONDecoder().decode([MemorySuggestion].self, from: data)
                guard decoded.count <= 100, Set(decoded.map(\.id)).count == decoded.count,
                      decoded.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 240 && $0.id.hasPrefix("band:") }) else { throw Failure.corrupt }
                pendingSuggestions = decoded
            }
            loaded = true; loadError = nil
        } catch {
            loadError = Failure.unavailable.localizedDescription
            throw error
        }
    }

    func addMemory(text: String) throws {
        let text = try validText(text, maximum: 240)
        try add(MemoryEntry(evidence: Evidence(sourceID: "memory:\(UUID().uuidString)", text: text,
            speaker: "wearer", utteredAt: nil, shareApproved: true), kind: .personalMemory,
            decisionID: nil, savedAt: Date()))
    }

    func addSuggestions(_ values: [MemorySuggestion]) throws {
        var pending = suggestions
        for value in values {
            guard !value.text.isEmpty, value.text.count <= 240, value.id.hasPrefix("band:") else { throw Failure.text }
            guard !pending.contains(where: { $0.id == value.id || $0.text.caseInsensitiveCompare(value.text) == .orderedSame }),
                  !records.contains(where: { $0.id == value.id || $0.evidence.text.caseInsensitiveCompare(value.text) == .orderedSame }) else { continue }
            pending.append(value)
        }
        guard pending.count <= 100 else { throw Failure.suggestionsFull }
        try persistSuggestions(pending)
    }

    func approveSuggestion(id: String, confirmed: Bool) throws {
        guard confirmed else { throw Failure.confirmation }
        guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
        guard document.entries.count < 100 else { throw Failure.limit }
        var next = document
        // Approval adopts this detail as the user's shareable memory; the captured speaker remains unknown.
        next.entries.append(MemoryEntry(evidence: Evidence(sourceID: suggestion.id, text: suggestion.text,
            speaker: "wearer", utteredAt: nil, shareApproved: true), kind: .personalMemory,
            decisionID: nil, savedAt: Date(), capturedSource: suggestion))
        // Persist approval first; a failed queue cleanup cannot lose or duplicate the approved memory.
        try persist(next)
        try persistSuggestions(pendingSuggestions.filter { $0.id != id })
    }

    func rejectSuggestion(id: String) throws {
        try persistSuggestions(pendingSuggestions.filter { $0.id != id })
    }

    func clearSuggestions() throws {
        try persistSuggestions([])
    }

    func addDialogue(text: String, speaker: String?, utteredAt: Date?, decisionID: UUID) throws {
        let text = try validText(text)
        let knownSpeaker = ["wearer", "other"].contains(speaker ?? "") ? speaker : nil
        try add(MemoryEntry(evidence: Evidence(sourceID: "dialogue:\(UUID().uuidString)", text: text,
            speaker: knownSpeaker, utteredAt: utteredAt, shareApproved: false), kind: .dialogue,
            decisionID: decisionID, savedAt: Date()))
    }

    func snapshot(now: Date = Date()) -> MemorySnapshot {
        // Historical dialogue belongs to its reviewed cue; saving it does not make it fresh live speech.
        MemorySnapshot(approvedMemories: Array(records.filter { $0.kind == .personalMemory && $0.evidence.text.count <= 240 }.suffix(4).map(\.evidence)),
                       dialogue: [], fetchedAt: now, coverage: .unavailable)
    }

    func dialogue(for episode: Episode) -> [Evidence] {
        guard episode.decision.context.mode == .live else { return [] }
        let saved = records.filter { $0.kind == .dialogue && $0.decisionID == episode.id }.map(\.evidence)
        var seen = Set<String>()
        return (episode.decision.context.snapshot.dialogue + saved).filter {
            !pendingDeletionIDs.contains($0.sourceID) && seen.insert($0.sourceID).inserted
        }
    }

    func saveAudit(_ report: AuditReport, dependencies: [String] = []) throws {
        var next = document
        next.audits.removeAll { $0.decisionID == report.decisionID }
        next.audits.append(report)
        next.auditSources[report.decisionID.uuidString] = Array(Set(dependencies + report.sourceIDs))
        try persist(next)
    }

    func delete(sourceID: String, invalidate: @MainActor (String) async throws -> Void) async throws {
        var next = document
        let affectedDecisions = Set(next.entries.filter { $0.id == sourceID }.compactMap(\.decisionID))
        let auditSources = next.auditSources
        next.entries.removeAll { $0.id == sourceID }
        try persistSuggestions(pendingSuggestions.filter { $0.id != sourceID })
        next.audits.removeAll { $0.sourceIDs.contains(sourceID) || affectedDecisions.contains($0.decisionID) ||
            auditSources[$0.decisionID.uuidString]?.contains(sourceID) == true }
        let remainingAuditIDs = Set(next.audits.map { $0.decisionID.uuidString })
        next.auditSources = next.auditSources.filter { remainingAuditIDs.contains($0.key) }
        // Persist the deletion before touching Core; a failed Core write is retried after relaunch.
        next.pendingDeletionIDs.insert(sourceID)
        try persist(next)
        try await invalidate(sourceID)
        next = document
        next.pendingDeletionIDs.remove(sourceID)
        try persist(next)
    }

    func finishPendingDeletions(invalidate: @MainActor (String) async throws -> Void) async throws {
        for id in pendingDeletionIDs { try await delete(sourceID: id, invalidate: invalidate) }
    }

    func removeDerivedData(decisionIDs: Set<UUID>) throws {
        guard !decisionIDs.isEmpty else { return }
        var next = document
        next.entries.removeAll { $0.kind == .dialogue && $0.decisionID.map(decisionIDs.contains) == true }
        next.audits.removeAll { decisionIDs.contains($0.decisionID) }
        for id in decisionIDs { next.auditSources.removeValue(forKey: id.uuidString) }
        try persist(next)
    }

    private func add(_ entry: MemoryEntry) throws {
        guard document.entries.count < 100 else { throw Failure.limit }
        var next = document
        next.entries.append(entry)
        if let decisionID = entry.decisionID { next.audits.removeAll { $0.decisionID == decisionID } }
        try persist(next)
    }

    private func validText(_ text: String, maximum: Int = 500) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximum else { throw Failure.text }
        return value
    }

    private func persistSuggestions(_ next: [MemorySuggestion]) throws {
        guard loaded else { throw Failure.unavailable }
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: suggestionsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: suggestionsURL, options: .atomic)
        #endif
        pendingSuggestions = next
    }

    private func persist(_ next: Document) throws {
        guard loaded else { throw Failure.unavailable }
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        document = next
    }
}
