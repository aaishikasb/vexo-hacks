import Foundation
import Testing
@testable import VocaDevice

private let glasses = AudioRouteApproval.Output(id: "glasses-a2dp", name: "Ray-Ban | Meta", isBluetooth: true)
private let headphones = AudioRouteApproval.Output(id: "headphones", name: "My headphones", isBluetooth: true)
private let speaker = AudioRouteApproval.Output(id: "phone-speaker", name: "iPhone Speaker", isBluetooth: false)

private func isolatedAudioDefaults() -> (UserDefaults, String) {
    let suite = "AudioRouteApprovalTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Test func connectedGlassesAutoApproveOnlyTheSelectedBluetoothOutput() {
    let (defaults, suite) = isolatedAudioDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var approvals = AudioRouteApproval(defaults: defaults)
    approvals.recognizeGlasses(in: [glasses], connected: false, names: [glasses.name])
    #expect(!approvals.accepts([glasses]))
    approvals.recognizeGlasses(in: [headphones], connected: true, names: [glasses.name])
    #expect(!approvals.accepts([headphones]))
    approvals.recognizeGlasses(in: [speaker], connected: true, names: [speaker.name])
    #expect(!approvals.accepts([speaker]))
    approvals.recognizeGlasses(in: [glasses], connected: true, names: [])
    #expect(approvals.accepts([glasses]))

    let renamed = AudioRouteApproval.Output(id: "custom-glasses", name: "Aishika’s glasses", isBluetooth: true)
    approvals.recognizeGlasses(in: [renamed], connected: true, names: ["Aishika’s Glasses"])
    #expect(approvals.accepts([renamed]))
    #expect(!approvals.accepts([AudioRouteApproval.Output(id: "other-glasses", name: glasses.name, isBluetooth: true)]))
}

@Test func explicitOutputApprovalPersistsAcrossLaunchAndReconnect() {
    let (defaults, suite) = isolatedAudioDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var approvals = AudioRouteApproval(defaults: defaults)
    let approval1 = approvals.approve(id: headphones.id, currentOutputs: [headphones])
    #expect(approval1)
    let approval2 = approvals.approve(id: speaker.id, currentOutputs: [speaker])
    #expect(approval2)
    approvals = AudioRouteApproval(defaults: defaults)
    #expect(approvals.accepts([headphones]))
    #expect(approvals.accepts([speaker]))
    #expect(!approvals.accepts([]))
    #expect(!approvals.accepts([glasses]))
    #expect(approvals.accepts([headphones]))
}

@Test func staleApprovalAndMultipleOutputsCannotAuthorizeSpeech() {
    let (defaults, suite) = isolatedAudioDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var approvals = AudioRouteApproval(defaults: defaults)
    let approval3 = approvals.approve(id: headphones.id, currentOutputs: [speaker])
    #expect(!approval3)
    #expect(!approvals.accepts([speaker]))
    #expect(!approvals.accepts([headphones]))
    let approval4 = approvals.approve(id: speaker.id, currentOutputs: [speaker, headphones])
    #expect(!approval4)
    let approval5 = approvals.approve(id: "", currentOutputs: [AudioRouteApproval.Output(id: "", name: "Unknown", isBluetooth: false)])
    #expect(!approval5)
    approvals.recognizeGlasses(in: [glasses, speaker], connected: true, names: [glasses.name])
    #expect(!approvals.accepts([glasses]))
    let approval6 = approvals.approve(id: speaker.id, currentOutputs: [speaker])
    #expect(approval6)
    #expect(!approvals.accepts([speaker, speaker]))
}

@Test func rememberedDestinationCannotTakeOverAnActiveUtterance() {
    let (defaults, suite) = isolatedAudioDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var approvals = AudioRouteApproval(defaults: defaults)
    let approval7 = approvals.approve(id: glasses.id, currentOutputs: [glasses])
    #expect(approval7)
    let approval8 = approvals.approve(id: headphones.id, currentOutputs: [headphones])
    #expect(approval8)
    #expect(approvals.accepts([headphones]))
    #expect(!AudioRouteApproval.isCurrentOutput(glasses.id, outputs: [headphones]))
    #expect(!AudioRouteApproval.isCurrentOutput(glasses.id, outputs: []))
    #expect(AudioRouteApproval.isCurrentOutput(glasses.id, outputs: [glasses]))
    #expect(AudioRouteApproval(defaults: defaults).accepts([glasses]))
}
