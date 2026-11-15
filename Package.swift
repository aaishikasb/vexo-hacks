// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "VocaDeviceChecks",
    platforms: [.macOS(.v15)],
    products: [.library(name: "VocaDevice", targets: ["VocaDevice"])],
    dependencies: [.package(path: "Packages/VocaCore")],
    targets: [
        .target(name: "VocaDevice", dependencies: [.product(name: "VocaCore", package: "VocaCore")], path: "Voca", exclude: ["Voice/FeedbackCapture.swift", "Product/TasteViews.swift", "Assets.xcassets", "Product/PhosphorIcon.swift", "App/VocaApp.swift", "App/Info.plist", "Product/CoachingSession.swift", "Product/PracticeSession.swift", "Product/PracticeView.swift", "Product/ReviewModelCheck.swift", "Product/InferenceStressCheck.swift", "Product/MemoryView.swift", "Product/AuditView.swift", "Product/SessionComponents.swift", "Product/DeviceConnectionVisual.swift", "Voice/NativeAudio.swift", "Voice/PipecatSpeech.swift", "Voice/LocalTranscriber.swift", "Voice/Python", "Voice/Voca-Bridging-Header.h", "Voice/PCPythonRuntime.m", "Voice/PCPythonRuntime.h", "Device/BandClient.swift", "Device/BandListening.swift", "Device/GlassesCamera.swift", "Inference/LiteRTExecutor.swift", "Inference/ModelArtifact.swift", "Inference/ModelLibrary.swift"], sources: ["Product/LiveDialogue.swift", "Product/CueTrace.swift", "Product/TasteStore.swift", "Voice/AudioRouteApproval.swift", "Product/CuePhase.swift", "Product/MemorySuggestion.swift", "Inference/ValidatedGeneration.swift", "Product/MemoryStore.swift", "Product/AuditPipeline.swift", "Product/PracticeTurnGate.swift", "Voice/SpeechUtterance.swift", "App/OperationState.swift", "Device/BandProtocol.swift", "Device/BandCueTrigger.swift", "Device/BandTapCalibration.swift", "Device/OpusDecoder.swift", "Inference/GeneratedFields.swift", "Product/CuePipeline.swift"]),
        .testTarget(name: "DeviceTests", dependencies: ["VocaDevice"], path: "Tests/DeviceTests")
    ]
)
