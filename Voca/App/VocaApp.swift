import SwiftUI
import UniformTypeIdentifiers
import VocaCore

@main struct VocaApp: App {
    @State private var camera = GlassesCamera()
    @State private var band = BandClient()
    @State private var error: String?
    var body: some Scene {
        WindowGroup {
            SetupView(camera: camera, band: band)
                .task {
                    #if DEBUG
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "--camera-check"), args.indices.contains(index + 1) {
                        await camera.checkOnDevice(runID: args[index + 1])
                    }
                    #endif
                }
                .onOpenURL { url in
                    Task { do { try await camera.handleURL(url) } catch { self.error = error.localizedDescription } }
                }
                .alert("Connection needs attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}

struct SetupView: View {
    @Bindable var camera: GlassesCamera
    @Bindable var band: BandClient
    @State private var models = ModelLibrary()
    @State private var coaching = CoachingSession()
    @State private var selectedModel = "gemma4E4B"
    @State private var expectedSHA256 = ""
    @State private var importingModel = false
    @State private var checkingModel = false
    @State private var audio = NativeAudio()
    @State private var pipecat = PipecatSpeech()
    @State private var listening = BandListening()
    @State private var showCaptureConsent = false
    @State private var bandNumber = ""
    @State private var operation = OperationState()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    Section {
                        Text("Find your own words.").font(.title2).fontWeight(.semibold)
                        Text("A short cue grounded in what you see, what you choose to share, and the conversation available.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Glasses") {
                        Text(camera.status)
                        Button("Connect with Meta AI") { run(cameraTimeout: true) { try await camera.register() } }
                        Button("Start glasses camera") { run(cameraTimeout: true) { try await camera.start() } }
                        Button("Capture context photo") { run { _ = try await camera.photo() } }.disabled(!camera.ready)
                        if let jpeg = camera.previewJPEG, let photo = UIImage(data: jpeg) {
                            Image(uiImage: photo).resizable().scaledToFit().accessibilityLabel("Latest context photo from your glasses")
                        }
                        Button("Stop camera") { camera.stop() }
                    }
                    Section("Audio route check") {
                        Text(audio.currentOutput.isEmpty ? "No output available" : audio.currentOutput)
                        Text(audio.status)
                        Button("Confirm this output is my glasses") {
                            do { try audio.confirmGlassesRoute() } catch { operation.error = error.localizedDescription }
                        }
                        Button("Speak native test phrase") { run { try await audio.speak("Voca is ready to help you find your own words.") } }
                        Button("Stop speech") { pipecat.stop(); audio.stop() }
                        Text(pipecat.status)
                        Button("Start embedded Pipecat") { pipecat.start(audio: audio) }
                        Button("Speak test phrase through Pipecat") {
                            run { try await pipecat.speak("Voca is ready to help you find your own words.") }
                        }.disabled(!pipecat.ready)
                        Text("The native test bypasses Pipecat. Neither test records a coaching delivery.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Assigned band") {
                        TextField("Number printed on your band’s bag", text: $bandNumber).keyboardType(.numberPad)
                        Text("Close the laptop dashboard, then double-tap your band to open its connection window.")
                            .foregroundStyle(.secondary)
                        Button("Connect assigned band") {
                            do {
                                guard let number = Int(bandNumber) else { throw BandProtocol.Failure.identity }
                                try band.connect(assignedNumber: number)
                            } catch { operation.error = "Enter the exact number on your band’s bag (1–999), then try again." }
                        }
                        Text(band.status)
                        Text(band.lastEvent).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Tap timing diagnostics") {
                            if band.taps.observations.isEmpty { Text("Connect the assigned band, then try separate single and double taps.") }
                            ForEach(Array(band.taps.observations.enumerated()), id: \.offset) { _, event in
                                Text("\(event.code == 1 ? "Single" : "Double") · \(event.milliseconds) ms\(event.duplicate ? " · duplicate" : "")")
                                    .font(.caption).monospacedDigit()
                            }
                        }
                        Button("Capture a 10-second local transcript") { showCaptureConsent = true }.disabled(band.info == nil || listening.active)
                        Button("Stop listening") { Task { await listening.stop(band: band) } }
                        Text(listening.status)
                        if !listening.transcript.isEmpty { Text(listening.transcript); Text("Unknown speaker · not approved memory").font(.caption) }
                        Button("Disconnect band") { Task { await listening.stop(band: band); band.disconnect() } }
                        Text("Band Bluetooth has no encryption. Capture requires consent and is indicated by the band’s blue light. Taps are diagnostic until verified on your band.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("On-device model") {
                        Picker("Model artifact", selection: $selectedModel) {
                            Text("Gemma 4 E4B — primary").tag("gemma4E4B")
                            Text("Gemma 4 E2B — fallback").tag("gemma4E2B")
                        }
                        TextField("Expected SHA-256 from the model source", text: $expectedSHA256).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Import .litertlm model") { importingModel = true }
                        Text(models.status).foregroundStyle(.secondary)
                        ForEach(models.artifacts, id: \.modelID) { artifact in
                            Text("\(artifact.modelID) · SHA-256 \(artifact.sha256)").font(.caption).textSelection(.enabled)
                        }
                        Button("Import staged official model") { run { try await models.importStaged(modelID: selectedModel) } }
                        Button("Load selected model") { run {
                            await coaching.stop(voice: pipecat, executor: models.executor)
                            try await models.load(modelID: selectedModel)
                        } }
                        Text("Use the generic artifact, not a device-specific accelerator build. Models stay on this iPhone and are excluded from backup.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Your cue") {
                        Picker("Conversation goal", selection: $coaching.goal) {
                            Text("Enter").tag(Goal.enter)
                            Text("Deepen").tag(Goal.deepen)
                            Text("Explain").tag(Goal.explain)
                        }
                        if coaching.goal == .explain {
                            TextField("Point you want to explain", text: $coaching.knownPoint, axis: .vertical)
                        }
                        Text(coaching.status)
                        Button("Request a spoken cue") {
                            coaching.request(model: models.executor, camera: camera, voice: pipecat)
                        }.disabled(coaching.busy || !camera.ready || !pipecat.ready)
                        Button("Cancel cue") {
                            Task { await coaching.stop(voice: pipecat, executor: models.executor) }
                        }.disabled(!coaching.busy)
                        if let episode = coaching.episodes.last, let cue = episode.cue {
                            Text(cue.text).font(.headline)
                            Text("Delivery: \(episode.delivery.rawValue)").font(.caption)
                            if episode.delivery == .completed {
                                ForEach([FeedbackVerdict.helpful, .unhelpful, .notTried], id: \.self) { verdict in
                                    Button(verdict == .helpful ? "Helpful" : verdict == .unhelpful ? "Unhelpful" : "Not tried") {
                                        Task { await coaching.feedback(verdict, episode: episode) }
                                    }
                                }
                                if let feedback = episode.feedback { Text("Saved: \(feedback.verdict.rawValue)").font(.caption) }
                            }
                        }
                    }
                    if let error = operation.error { Section { Text(error).foregroundStyle(.red) } }
                }
                .overlay { if operation.busy { ProgressView("Working…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false) } }
                .navigationTitle("Session")
            }.tabItem { Label("Session", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack {
                ContentUnavailableView("Waiting for a conversation", systemImage: "text.bubble", description: Text("Reviews require attributable dialogue. A photo alone cannot show how a conversation went."))
                    .navigationTitle("Review")
            }.tabItem { Label("Review", systemImage: "text.bubble") }
            NavigationStack {
                ContentUnavailableView("Your stories stay yours", systemImage: "lock", description: Text("Only attributable stories you explicitly approve can be shared in a cue. Memory editing is not connected in this build."))
                    .navigationTitle("Memory")
            }.tabItem { Label("Memory", systemImage: "person.text.rectangle") }
        }
        .disabled(checkingModel)
        .task {
            do { try camera.configure() } catch { operation.error = error.localizedDescription }
            await coaching.configure()
            expectedSHA256 = ModelLibrary.catalog.first(where: { $0.modelID == selectedModel })?.sha256 ?? ""
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--scene-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                pipecat.start(audio: audio)
                for _ in 0..<100 {
                    if pipecat.ready { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                await models.checkSceneOnDevice(camera: camera, pipecatReady: pipecat.ready)
                UIApplication.shared.isIdleTimerDisabled = false
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--speech-check") {
                let transcriber = LocalTranscriber()
                var result: [String: Any] = ["passed": false]
                do { try await transcriber.start(); result["passed"] = true }
                catch { result["error"] = error.localizedDescription }
                transcriber.stop()
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "speech-check.json"), options: .atomic)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--model-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                await models.checkOnDevice(modelID: selectedModel)
                UIApplication.shared.isIdleTimerDisabled = false
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--pipecat-check") {
                pipecat.start(audio: audio)
                for _ in 0..<100 {
                    if pipecat.ready { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let result: [String: Any] = ["ready": pipecat.ready, "status": pipecat.status]
                try? FileManager.default.createDirectory(at: URL.documentsDirectory, withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "pipecat-check.json"), options: .atomic)
                }
            }
            #endif
        }
        .onChange(of: selectedModel) { _, selected in
            expectedSHA256 = ModelLibrary.catalog.first(where: { $0.modelID == selected })?.sha256 ?? ""
        }
        .fileImporter(isPresented: $importingModel, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                let model = selectedModel
                let hash = expectedSHA256
                run { try await models.importFile(url, modelID: model, expectedSHA256: hash) }
            case .failure(let failure): operation.error = failure.localizedDescription
            }
        }
        .confirmationDialog("Everyone nearby must agree to microphone capture. Audio is transcribed on this iPhone; the band Bluetooth link is not encrypted. Keep the blue microphone light visible.", isPresented: $showCaptureConsent, titleVisibility: .visible) {
            Button("Everyone agrees — start 10-second capture") { run { try await listening.startConsentedSample(band: band) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { camera.suspendForBackground(); pipecat.stop(); audio.deactivate(); Task { await coaching.stop(voice: pipecat, executor: models.executor); await listening.stop(band: band) } }
        }
    }
    private func run(cameraTimeout: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        operation.run(timeout: cameraTimeout ? .seconds(25) : nil, onTimeout: {
            let stage = camera.status
            camera.stop()
            return "Meta AI did not finish: \(stage) Close and reopen Voca, then retry Start glasses camera."
        }, action)
    }
}
