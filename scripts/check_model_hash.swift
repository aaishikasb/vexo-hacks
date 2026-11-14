import Foundation
import Darwin

// Compile with ModelArtifact.swift; run against a large pinned artifact and its expected SHA.
@main struct ModelHashCheck {
    static func main() throws {
        precondition(CommandLine.arguments.count == 3, "Usage: check_model_hash MODEL EXPECTED_SHA256")
        let digest = try ModelArtifact.hash(URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(digest == CommandLine.arguments[2], "SHA-256 mismatch")
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        precondition(usage.ru_maxrss < 256 * 1024 * 1024, "Hashing retained large file buffers")
        print("Verified SHA-256; peak resident bytes: \(usage.ru_maxrss)")
    }
}
