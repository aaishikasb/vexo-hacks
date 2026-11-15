import Foundation

/// Presentation follows real pipeline milestones, never elapsed time or guessed progress.
enum CuePhase: String, CaseIterable {
    case capturing, thinking, fallback, speaking

    var title: String {
        switch self {
        case .capturing: "Reading the scene"
        case .thinking: "Preparing your cue"
        case .fallback: "Trying a lighter model"
        case .speaking: "Your cue is playing"
        }
    }

    var detail: String {
        switch self {
        case .capturing: "Taking a photo through your glasses."
        case .thinking: "Preparing a short cue from the context available."
        case .fallback: "The first attempt couldn’t finish. E2B is preparing a new cue on this iPhone."
        case .speaking: "Listen through your confirmed audio output."
        }
    }

    var step: Int {
        switch self {
        case .capturing: 0
        case .thinking, .fallback: 1
        case .speaking: 2
        }
    }
}
