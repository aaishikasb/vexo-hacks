import Foundation

public enum AuditValidationError: Error, Equatable {
    case wrongDecision
    case waitingContainsClaims
    case missingGenerationProfile
    case missingClaim
    case noAttributableWearerEvidence
    case invalidSourceReferences
    case unknownPrinciple
}

/// Structural and source-reference validation for evidence-grounded review output.
/// The caller supplies only evidence belonging to this live session; Core never infers speaker identity.
public enum AuditReportValidator {
    public static let maximumClaimLength = 500

    @discardableResult
    public static func validate(_ report: AuditReport, decisionID: UUID,
                                dialogue: [Evidence], knownPrincipleIDs: Set<String>) throws -> AuditReport {
        guard report.decisionID == decisionID else { throw AuditValidationError.wrongDecision }
        if report.status == .waitingForTranscript {
            guard report.strength == nil, report.opportunity == nil, report.exercise == nil,
                  report.sourceIDs.isEmpty, report.principleID == nil else {
                throw AuditValidationError.waitingContainsClaims
            }
            return report
        }

        guard let profile = report.generationProfile,
              !profile.artifactSHA256.isEmpty, !profile.promptVersion.isEmpty else {
            throw AuditValidationError.missingGenerationProfile
        }
        for claim in [report.strength, report.opportunity, report.exercise] {
            guard let claim, !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  claim.count <= maximumClaimLength else { throw AuditValidationError.missingClaim }
        }
        let attributableIDs = Set(dialogue.compactMap { evidence -> String? in
            guard evidence.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "wearer",
                  !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return evidence.sourceID
        })
        guard !attributableIDs.isEmpty else { throw AuditValidationError.noAttributableWearerEvidence }
        guard !report.sourceIDs.isEmpty, Set(report.sourceIDs).count == report.sourceIDs.count,
              Set(report.sourceIDs).isSubset(of: attributableIDs) else { throw AuditValidationError.invalidSourceReferences }
        guard let principleID = report.principleID, knownPrincipleIDs.contains(principleID) else {
            throw AuditValidationError.unknownPrinciple
        }
        return report
    }
}
