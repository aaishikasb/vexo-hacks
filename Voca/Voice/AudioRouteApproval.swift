import Foundation

/// A cue output is remembered by identity, never by a display name alone.
nonisolated struct AudioRouteApproval {
    struct Output: Equatable, Identifiable {
        let id: String
        let name: String
        let isBluetooth: Bool
    }

    private let defaults: UserDefaults
    private static let key = "approvedCueAudioOutputs.v1"
    private(set) var approvedIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        approvedIDs = Set((defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.isEmpty })
    }

    func accepts(_ outputs: [Output]) -> Bool {
        outputs.count == 1 && outputs.first.map { approvedIDs.contains($0.id) } == true
    }

    @discardableResult mutating func approve(id: String, currentOutputs: [Output]) -> Bool {
        guard !id.isEmpty, Self.isCurrentOutput(id, outputs: currentOutputs) else { return false }
        approvedIDs.insert(id)
        defaults.set(approvedIDs.sorted(), forKey: Self.key)
        return true
    }

    mutating func recognizeGlasses(in outputs: [Output], connected: Bool, names: [String]) {
        guard connected, outputs.count == 1, let output = outputs.first, output.isBluetooth else { return }
        let name = Self.normalized(output.name)
        guard !name.isEmpty,
              names.contains(where: { Self.normalized($0) == name }) || name.contains("raybanmeta") else { return }
        if !approvedIDs.contains(output.id) { approve(id: output.id, currentOutputs: outputs) }
    }

    /// An already approved destination still cannot take over speech that began elsewhere.
    static func isCurrentOutput(_ id: String, outputs: [Output]) -> Bool {
        outputs.count == 1 && outputs.first?.id == id
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
