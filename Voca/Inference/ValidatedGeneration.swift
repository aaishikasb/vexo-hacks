import Foundation
import VocaCore

nonisolated enum ValidatedGeneration {
    /// Retries generation, never delivery or policy selection; invalid output is never spoken.
    static func run<Value: Sendable>(_ request: ModelRequest, model: any ModelGenerating,
                                     validate: @Sendable (String) throws -> Value) async throws -> (value: Value, profile: ModelProfile) {
        var current = request
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let response = try await model.generate(current)
            try Task.checkCancellation()
            try response.validate(for: current)
            do {
                let value = try validate(response.text)
                try Task.checkCancellation()
                return (value, response.actualProfile)
            }
            catch let failure as GeneratedFields.Failure {
                #if DEBUG && os(iOS)
                let diagnostic: [String: Any] = ["kind": request.kind.rawValue,
                    "modelID": request.requestedProfile.modelID.rawValue, "attempt": attempt + 1,
                    "category": String(describing: failure), "responseBytes": response.text.utf8.count,
                    "recordedAt": Date().ISO8601Format()]
                if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "structured-output-failure.json"), options: .atomic)
                }
                #endif
                guard attempt < 2 else { throw failure }
                let correction: String
                switch failure {
                case .malformed, .fields:
                    correction = "Return one complete JSON object with exactly the required keys and value types. No prose, schema, or markdown."
                case .evidence:
                    correction = "Use only the exact short source IDs supplied in the evidence. Do not invent or rewrite source IDs."
                case .length:
                    correction = "Use 8–18 words in the cue text, no control characters or formatting."
                }
                current = ModelRequest(requestID: UUID(), decisionID: request.decisionID, kind: request.kind,
                    requestedProfile: request.requestedProfile, prompt: request.prompt + "\nCorrection: " + correction,
                    imageJPEG: request.imageJPEG, maxOutputTokens: request.maxOutputTokens,
                    responseSchemaJSON: request.responseSchemaJSON)
            }
        }
        throw GeneratedFields.Failure.fields
    }
}
