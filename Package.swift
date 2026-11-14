// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "VocaDeviceChecks",
    platforms: [.macOS(.v15)],
    products: [.library(name: "VocaDevice", targets: ["VocaDevice"])],
    targets: [
        .target(name: "VocaDevice", path: "Voca", exclude: ["App/VocaApp.swift", "App/Info.plist", "Product", "Voice", "Device/BandClient.swift", "Device/BandListening.swift", "Device/GlassesCamera.swift", "Inference/LiteRTExecutor.swift", "Inference/ModelArtifact.swift", "Inference/ModelLibrary.swift"], sources: ["App/OperationState.swift", "Device/BandProtocol.swift", "Device/OpusDecoder.swift", "Inference/GeneratedFields.swift"]),
        .testTarget(name: "DeviceTests", dependencies: ["VocaDevice"], path: "Tests/DeviceTests")
    ]
)
