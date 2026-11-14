import Foundation

public enum CoachEngineError: Error, Equatable { case unknownDecision, duplicateDecision, invalidCue, conflictingTerminalDelivery, invalidFeedback, staleFeedback, persistenceFailure, invalidEvidenceReferences }

/// Serialized, profile- and mode-specific LinUCB policy with atomic JSON persistence.
public actor CoachEngine {
    public static let policyVersion = "linucb-v1"
    public static let dialogueFreshness: TimeInterval = 30
    private struct Store: Codable { var episodes: [Episode] = []; var invalidatedSourceIDs: Set<String> = [] }
    private struct PolicyKey: Hashable { var profile: ModelProfile; var mode: SessionMode }
    private struct Arm { var p: [[Double]]; var b: [Double] }
    private let storeURL: URL
    private var store: Store
    private var policies: [PolicyKey: [Strategy: Arm]] = [:]

    public init(storeURL: URL) throws {
        self.storeURL = storeURL
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do { self.store = try JSONDecoder.voca.decode(Store.self, from: Data(contentsOf: storeURL)) }
            catch { throw CoachEngineError.persistenceFailure }
        } else { self.store = Store() }
        self.policies = Self.replayPolicies(self.store)
    }

    /// Canonical feature vector, in the one shared order owned by Core.
    public static func features(for c: CueContext) -> [Double] {
        [1, c.scene.setting == .cafe ? 1 : 0, c.scene.setting == .shop ? 1 : 0,
         c.scene.setting == .event ? 1 : 0, c.scene.setting == .other ? 1 : 0,
         c.goal == .enter ? 1 : 0, c.goal == .deepen ? 1 : 0, c.goal == .explain ? 1 : 0,
         c.snapshot.approvedMemories.contains { $0.shareApproved && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? 1 : 0,
         freshDialogue(in: c.snapshot, at: c.requestedAt) ? 1 : 0]
    }

    private static func freshDialogue(in s: MemorySnapshot, at now: Date) -> Bool {
        s.dialogue.contains { evidence in
            guard let time = evidence.utteredAt, let speaker = evidence.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speaker.isEmpty, !["unknown", "undiarized", "unattributed"].contains(speaker.lowercased()) else { return false }
            let age = now.timeIntervalSince(time)
            return age >= 0 && age <= dialogueFreshness && !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func selectCue(_ context: CueContext, explore: Bool, excluding: Strategy? = nil) throws -> CueDecision? {
        guard !store.episodes.contains(where: { $0.id == context.decisionID }) else { throw CoachEngineError.duplicateDecision }
        let suppliedEvidenceIDs = Set(context.snapshot.approvedMemories.map(\.sourceID) + context.snapshot.dialogue.map(\.sourceID) + [context.knownPointSourceID].compactMap { $0 })
        guard suppliedEvidenceIDs.isDisjoint(with: store.invalidatedSourceIDs) else { throw CoachEngineError.invalidEvidenceReferences }
        let features = Self.features(for: context)
        let fresh = features[9] == 1
        let story = features[8] == 1
        let sceneUseful = !context.scene.uncertain && !context.scene.observations.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var eligible = Strategy.allCases.filter { action in
            guard !context.disabledStrategies.contains(action) else { return false }
            switch action {
            case .followUp, .reflectClarify: return fresh
            case .personalConnection: return story
            case .explainClearly:
                return context.knownPoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                    context.knownPointSourceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .situationalOpener: return sceneUseful && context.goal == .enter
            }
        }
        if let excluding, eligible.count > 1 { eligible.removeAll { $0 == excluding } }
        guard !eligible.isEmpty else { return nil }
        let key = PolicyKey(profile: context.profile, mode: context.mode)
        let arms = policies[key] ?? Self.emptyArms()
        let utilities = Dictionary(uniqueKeysWithValues: eligible.map { ($0.rawValue, Self.utility(arms[$0]!, features)) })
        func tieRank(_ action: Strategy) -> Int {
            let preferred: [Strategy] = switch context.goal {
            case .enter: [.situationalOpener, .personalConnection, .followUp, .reflectClarify, .explainClearly]
            case .deepen: [.reflectClarify, .followUp, .personalConnection, .situationalOpener, .explainClearly]
            case .explain: [.explainClearly, .personalConnection, .reflectClarify, .followUp, .situationalOpener]
            }
            return preferred.firstIndex(of: action) ?? 99
        }
        let chosen = eligible.sorted {
            let a = Self.score(arms[$0]!, features, explore: explore), b = Self.score(arms[$1]!, features, explore: explore)
            return a == b ? tieRank($0) < tieRank($1) : a > b
        }.first!
        let decision = CueDecision(context: context, features: features, eligibleActions: eligible, selectedAction: chosen, utilities: utilities, policyVersion: Self.policyVersion, usedExploration: explore)
        let previousStore = store
        store.episodes.append(Episode(decision: decision))
        do { try persist() } catch { store = previousStore; throw error }
        policies[key] = arms
        return decision
    }

    public func recordDelivery(decisionID: UUID, cue: CueResult?, status: DeliveryStatus) throws {
        guard let i = store.episodes.firstIndex(where: { $0.id == decisionID }) else { throw CoachEngineError.unknownDecision }
        var episode = store.episodes[i]
        if status == .pending {
            guard let cue else { return }
            try Self.validate(cue: cue, for: episode)
            if let existing = episode.cue {
                guard existing == cue else { throw CoachEngineError.invalidCue }
                return
            }
            let previousStore = store
            episode.cue = cue; store.episodes[i] = episode
            do { try persist() } catch { store = previousStore; throw error }
            return
        }
        if episode.delivery != .pending {
            let candidate = cue ?? episode.cue
            if episode.delivery == status && episode.cue == candidate { return }
            throw CoachEngineError.conflictingTerminalDelivery
        }
        if let cue, let existing = episode.cue, cue != existing { throw CoachEngineError.invalidCue }
        let effectiveCue = cue ?? episode.cue
        if let effectiveCue { try Self.validate(cue: effectiveCue, for: episode) }
        guard (status == .completed && effectiveCue != nil) || status == .failed || status == .cancelled else { throw CoachEngineError.invalidCue }
        let previousStore = store
        episode.cue = effectiveCue; episode.delivery = status; store.episodes[i] = episode
        do { try persist() } catch { store = previousStore; throw error }
    }

    private static func validate(cue: CueResult, for episode: Episode) throws {
        guard cue.decisionID == episode.id, cue.actualProfile == episode.decision.context.profile,
              cue.strategy == episode.decision.selectedAction,
              !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoachEngineError.invalidCue }
        let approvedMemorySources = episode.decision.context.snapshot.approvedMemories.filter(\.shareApproved).map(\.sourceID)
        let knownPointSources = episode.decision.context.knownPoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? [episode.decision.context.knownPointSourceID].compactMap { $0 } : []
        let allowed = Set(approvedMemorySources + episode.decision.context.snapshot.dialogue.map(\.sourceID) + [episode.decision.context.scene.requestID.uuidString] + knownPointSources)
        guard Set(cue.sourceIDs).isSubset(of: allowed) else { throw CoachEngineError.invalidEvidenceReferences }
        if episode.decision.selectedAction == .explainClearly {
            guard let sourceID = episode.decision.context.knownPointSourceID, cue.sourceIDs.contains(sourceID) else {
                throw CoachEngineError.invalidEvidenceReferences
            }
        }
    }

    public func applyFeedback(_ event: FeedbackEvent) throws {
        guard let i = store.episodes.firstIndex(where: { $0.id == event.decisionID }) else { throw CoachEngineError.unknownDecision }
        var episode = store.episodes[i]
        let contextSources = Set(episode.decision.context.snapshot.approvedMemories.map(\.sourceID) + episode.decision.context.snapshot.dialogue.map(\.sourceID) + [episode.decision.context.knownPointSourceID].compactMap { $0 })
        guard contextSources.isDisjoint(with: store.invalidatedSourceIDs), Set(episode.cue?.sourceIDs ?? []).isDisjoint(with: store.invalidatedSourceIDs) else { throw CoachEngineError.invalidFeedback }
        guard episode.delivery == .completed, episode.cue != nil else { throw CoachEngineError.invalidFeedback }
        if let old = episode.feedback {
            if old == event { return }
            guard event.revision > old.revision else { throw CoachEngineError.staleFeedback }
        } else if event.revision < 1 { throw CoachEngineError.staleFeedback }
        let previousStore = store
        episode.feedback = event; store.episodes[i] = episode
        do { try persist() } catch { store = previousStore; throw error }
        rebuild(key: PolicyKey(profile: episode.decision.context.profile, mode: episode.decision.context.mode))
    }

    /// Permanently removes episodes derived from this evidence and rebuilds affected policies.
    /// This also erases private transcript/memory text held in frozen episode snapshots.
    public func deleteEvidence(sourceID: String) throws {
        let previousStore = store
        store.invalidatedSourceIDs.insert(sourceID)
        store.episodes.removeAll { e in
            e.decision.context.snapshot.approvedMemories.contains(where: { $0.sourceID == sourceID }) ||
            e.decision.context.snapshot.dialogue.contains(where: { $0.sourceID == sourceID }) ||
            e.decision.context.knownPointSourceID == sourceID ||
            e.cue?.sourceIDs.contains(sourceID) == true
        }
        do { try persist() } catch { store = previousStore; throw error }
        policies = Self.replayPolicies(store)
    }

    /// Compatibility spelling for callers that treat deletion as policy invalidation.
    public func invalidateEvidence(sourceID: String) throws { try deleteEvidence(sourceID: sourceID) }

    public func episodes() -> [Episode] { store.episodes }

    private func rebuild(key: PolicyKey) {
        var arms = Self.emptyArms()
        for e in store.episodes where e.decision.context.profile == key.profile && e.decision.context.mode == key.mode {
            guard let f = e.feedback, e.delivery == .completed, e.cue != nil, f.verdict == .helpful || f.verdict == .unhelpful else { continue }
            let sourceIDs = Set(e.cue?.sourceIDs ?? [])
            guard sourceIDs.isDisjoint(with: store.invalidatedSourceIDs) else { continue }
            let reward = f.verdict == .helpful ? 1.0 : -1.0
            Self.update(&arms[e.decision.selectedAction]!, x: e.decision.features, reward: reward)
        }
        policies[key] = arms
    }
    private static func replayPolicies(_ store: Store) -> [PolicyKey: [Strategy: Arm]] {
        var result: [PolicyKey: [Strategy: Arm]] = [:]
        for e in store.episodes {
            let key = PolicyKey(profile: e.decision.context.profile, mode: e.decision.context.mode)
            var arms = result[key] ?? emptyArms()
            guard let f = e.feedback, e.delivery == .completed, e.cue != nil, f.verdict == .helpful || f.verdict == .unhelpful,
                  Set(e.cue?.sourceIDs ?? []).isDisjoint(with: store.invalidatedSourceIDs) else { result[key] = arms; continue }
            update(&arms[e.decision.selectedAction]!, x: e.decision.features, reward: f.verdict == .helpful ? 1 : -1)
            result[key] = arms
        }
        return result
    }
    private func persist() throws {
        do {
            let data = try JSONEncoder.voca.encode(store)
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch { throw CoachEngineError.persistenceFailure }
    }
    private static func emptyArms() -> [Strategy: Arm] {
        Dictionary(uniqueKeysWithValues: Strategy.allCases.map { ($0, Arm(p: identity(10), b: Array(repeating: 0, count: 10))) })
    }
    private static func identity(_ n: Int) -> [[Double]] { (0..<n).map { r in (0..<n).map { $0 == r ? 1 : 0 } } }
    private static func utility(_ arm: Arm, _ x: [Double]) -> Double { dot(x, multiply(arm.p, arm.b)) }
    private static func score(_ arm: Arm, _ x: [Double], explore: Bool) -> Double {
        let base = utility(arm, x); guard explore else { return base }
        return base + 0.5 * sqrt(max(0, dot(x, multiply(arm.p, x))))
    }
    private static func update(_ arm: inout Arm, x: [Double], reward: Double) {
        let v = multiply(arm.p, x), denom = 1 + dot(x, v)
        for r in 0..<10 { for c in 0..<10 { arm.p[r][c] -= v[r] * v[c] / denom } }
        for i in 0..<10 { arm.b[i] += reward * x[i] }
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func multiply(_ m: [[Double]], _ v: [Double]) -> [Double] { m.map { dot($0, v) } }
}

private extension JSONDecoder { static var voca: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
private extension JSONEncoder { static var voca: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e } }
