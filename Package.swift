// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "VocaDeviceChecks",
    platforms: [.macOS(.v15)],
    products: [.library(name: "VocaDevice", targets: ["VocaDevice"])],
    dependencies: [.package(path: "Packages/VocaCore")],
    targets: [
        .target(name: "VocaDevice", dependencies: [.product(name: "VocaCore", package: "VocaCore")], path: "Voca", exclude: ["App/VocaApp.swift", "App/Info.plist", "Product/CoachingSession.swift", "Voice", "Device/BandClient.swift", "Device/BandListening.swift", "Device/GlassesCamera.swift", "Inference/LiteRTExecutor.swift", "Inference/ModelArtifact.swift", "Inference/ModelLibrary.swift"], sources: ["App/OperationState.swift", "Device/BandProtocol.swift", "Device/OpusDecoder.swift", "Inference/GeneratedFields.swift", "Product/CuePipeline.swift"]),
        .testTarget(name: "DeviceTests", dependencies: ["VocaDevice"], path: "Tests/DeviceTests")
    ]
)
