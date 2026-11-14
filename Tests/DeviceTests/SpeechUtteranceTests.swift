import AVFoundation
import Testing
@testable import VocaDevice

@Test func speechPreservesTextAndNaturalPitchWithoutDownloadedVoices() {
    let text = "That sounds interesting. What got you into it?"
    let utterance = makeSpeechUtterance(text, voices: [])
    #expect(utterance.speechString == text)
    #expect(utterance.voice?.identifier == AVSpeechSynthesisVoice(language: "en-US")?.identifier)
    #expect(utterance.pitchMultiplier == 1)
    #expect(utterance.rate < AVSpeechUtteranceDefaultSpeechRate)
    #expect(utterance.rate > AVSpeechUtteranceMinimumSpeechRate)
}

@Test func speechPrefersHighestInstalledEnglishQuality() {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let utterance = makeSpeechUtterance("Tell me more.", voices: voices)
    let bestQuality = voices.filter { $0.language == "en-US" && $0.quality != .default }
        .map { $0.quality.rawValue }.max()
    if let bestQuality {
        #expect(utterance.voice?.language == "en-US")
        #expect(utterance.voice?.quality.rawValue == bestQuality)
    } else {
        #expect(utterance.voice?.identifier == AVSpeechSynthesisVoice(language: "en-US")?.identifier)
    }
    let otherLanguages = voices.filter { $0.language != "en-US" }
    #expect(makeSpeechUtterance("Hello.", voices: otherLanguages).voice?.identifier
        == AVSpeechSynthesisVoice(language: "en-US")?.identifier)
}
