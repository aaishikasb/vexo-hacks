import AVFoundation

func makeSpeechUtterance(_ text: String, voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> AVSpeechUtterance {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voices
        .filter { $0.language == "en-US" && $0.quality != .default }
        .max { $0.quality.rawValue < $1.quality.rawValue }
        ?? AVSpeechSynthesisVoice(language: "en-US")
    // Slightly calmer pacing without shifting the voice's natural pitch.
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
    return utterance
}
