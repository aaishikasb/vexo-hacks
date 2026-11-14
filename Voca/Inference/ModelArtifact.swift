import CryptoKit
import Foundation

nonisolated struct ModelArtifact: Codable, Sendable, Equatable {
    let modelID: String
    let sha256: String
    let filename: String
    enum Failure: LocalizedError {
        case invalid, checksum
        var errorDescription: String? {
            switch self {
            case .invalid: "Import the selected generic Gemma 4 .litertlm file before loading it."
            case .checksum: "The model file does not match its expected SHA-256. Download the official artifact again."
            }
        }
    }
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Voca/Models", directoryHint: .isDirectory)
    }
    @concurrent static func importFile(_ source: URL, modelID: String, expectedSHA256: String) async throws -> ModelArtifact {
        guard ["gemma4E4B", "gemma4E2B"].contains(modelID), source.pathExtension == "litertlm",
              expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isHexDigit }) else { throw Failure.invalid }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let staging = directory.appending(path: UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let digest = try hash(staging)
        guard digest == expectedSHA256.lowercased() else { throw Failure.checksum }
        let filename = digest + ".litertlm"
        let destination = directory.appending(path: filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try hash(destination) == digest else { throw Failure.checksum }
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        return ModelArtifact(modelID: modelID, sha256: digest, filename: filename)
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        // Drain Foundation autoreleased read buffers on each chunk, not after gigabytes.
        while let block = try autoreleasepool(invoking: { try handle.read(upToCount: 1024 * 1024) }), !block.isEmpty {
            try Task.checkCancellation()
            digest.update(data: block)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
