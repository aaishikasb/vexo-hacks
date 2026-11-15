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
                    Button("Dismiss") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}

struct SetupView: View {
    @Bindable var camera: GlassesCamera
    @Bindable var band: BandClient
    @State private var models = ModelLibrary()
    @State private var coaching = CoachingSession()
    @State private var memory = MemoryStore()
    @State private var reviewingEpisode: Episode?
    @State private var showPractice = false
    @State private var stoppingCue = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedModel = "gemma4E4B"
    @State private var expectedSHA256 = ""
    @State private var importingModel = false
    @State private var checkingModel = false
    @State private var audio = NativeAudio()
    @State private var pipecat = PipecatSpeech()
    @State private var listening = BandListening()
    @State private var showCaptureConsent = false
    @State private var showAudioApproval = false
    @State private var pendingAudioOutput: AudioRouteApproval.Output?
    @State private var declinedAudioOutputs = Set<String>()
    @AppStorage("rememberBandDetails") private var rememberBandDetails = false
    @State private var captureStartTask: Task<Void, Never>?
    @State private var capturePreparing = false
    @State private var captureError: String?
    @AppStorage("assignedBandNumber") private var bandNumber = "18"
    @State private var showSetup = false
    @State private var showDiagnostics = false
    @State private var activeTab = 0
    @State private var softwareReady = false
    @State private var preparingCue = false
    @State private var cuePreparationTask: Task<Void, Never>?
    @State private var cueRequestError: String?
    @State private var setupStatus = "Connect your devices when you’re ready."
    @State private var tapGate = BandCueTrigger()
    @State private var tapTask: Task<Void, Never>?
    @State private var tapCalibration = BandTapCalibration()
    @State private var tasteEpisode: Episode?
    @State private var draftBandNumber = "18"
    @State private var showTapCalibration = false
    @State private var operation = OperationState()
    @Environment(\.scenePhase) private var scenePhase
    private var tabs: some View {
        TabView(selection: $activeTab) {
            NavigationStack {
                sessionScreen
                    .navigationTitle("voca")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showSetup = true } label: { PhosphorIcon("gearshape") }
                                .accessibilityLabel("Open settings")
                        }
                    }
            }.tabItem { Label { Text("Session") } icon: { PhosphorIcon.image("waveform") } }.tag(0)
            NavigationStack {
                reviewScreen
                    .navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("Your style") { TasteProfileView(store: coaching.taste, episodes: coaching.episodes, audio: audio, beforeCapture: prepareFeedbackCapture, onReport: coaching.report) }
                            .disabled(!coaching.taste.loaded)
                    } }
            }.tabItem { Label { Text("Review") } icon: { PhosphorIcon.image("text.bubble") } }.tag(1)
            NavigationStack {
                MemoryView(store: memory, listeningStatus: captureError ?? listening.status,
                           listeningActive: listening.active, listeningBusy: listening.busy || capturePreparing,
                           captureEnabled: rememberBandDetails, bandConnected: band.verified,
                           startListening: { enableMemoryListening() },
                           stopListening: { await stopMemoryListening() }) { sourceID in
                    try await deleteEvidence(sourceID)
                }
            }.tabItem { Label { Text("Memory") } icon: { PhosphorIcon.image("person.text.rectangle") } }.tag(2)
        }
    }
    private var presentedTabs: some View {
        tabs
        .tint(VocaTheme.foreground)
        .foregroundStyle(VocaTheme.foreground)
        .sheet(item: $tasteEpisode) { episode in TasteFeedbackView(episode: episode, store: coaching.taste, audio: audio, beforeCapture: prepareFeedbackCapture, onReport: coaching.report) }
        .sheet(item: $reviewingEpisode) { episode in
            NavigationStack {
                AuditView(episode: episode, store: memory, model: models.executor, canGenerate: softwareReady)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { reviewingEpisode = nil } } }
            }
        }
        .sheet(isPresented: $showPractice) {
            PracticeView(model: models.executor, voice: pipecat, audio: audio)
        }
        .sheet(isPresented: $showSetup) { setupSheet }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack { diagnostics.navigationTitle("Advanced controls")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } } }
        }
        .alert("Use this audio output?", isPresented: audioApprovalPresentation(inSettings: false), presenting: pendingAudioOutput) { output in
            audioApprovalActions(output)
        } message: { output in
            Text("Play cues through \(output.name)? Voca will remember this output.")
        }
        .disabled(checkingModel)
    }
    var body: some View {
        presentedTabs
        .preferredColorScheme(.dark)
        .task { await initializeSession() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Retry discovery while foregrounded; each client keeps an in-flight connection intact.
            while !Task.isCancelled {
                await reconnectDevices()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--live-dialogue-session") else { return }
            while !Task.isCancelled {
                let episode = coaching.episodes.last
                let dialogue = episode?.decision.context.snapshot.dialogue ?? []
                let cited = Set(episode?.cue?.sourceIDs ?? [])
                let report: [String: Any] = [
                    "recordedAt": Date().timeIntervalSince1970,
                    "band": band.info?.number ?? -1, "listening": listening.active,
                    "tapMappingVerified": tapGate.mappingVerified,
                    "lastTapEvent": band.lastEvent,
                    "singleTapEvents": band.taps.observations.filter { $0.code == 1 && !$0.duplicate }.count,
                    "duplicateTapEvents": band.taps.observations.filter(\.duplicate).count,
                    "captureKind": camera.lastCaptureKind,
                    "listeningStatus": listening.status,
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "cueReady": cueReady,
                    "cueRequestError": cueRequestError ?? "",
                    "packets": listening.decodedPackets, "freshExcerpts": listening.freshDialogueCount,
                    "cameraReady": camera.ready, "modelReady": softwareReady,
                    "voiceReady": pipecat.ready, "audioReady": audio.routeIsValid,
                    "busy": coaching.busy || preparingCue,
                    "tapToPlaybackSeconds": coaching.lastTiming?.firstSpeech ?? -1,
                    "requestOrigin": coaching.lastTiming?.origin ?? "",
                    "model": episode?.cue?.actualProfile.modelID.rawValue ?? "",
                    "decisionID": episode?.id.uuidString ?? "", "delivery": episode?.delivery.rawValue ?? "",
                    "dialogueInputs": dialogue.count,
                    "dialogueCitations": dialogue.filter { cited.contains($0.sourceID) }.count,
                    "unknownSpeakers": dialogue.filter { $0.speaker == nil }.count,
                    "approvedDialogue": dialogue.filter(\.shareApproved).count,
                    "approvedMemories": memory.records.filter { $0.kind == .personalMemory }.count,
                    "error": coaching.lastError ?? captureError ?? ""
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "live-cue-status.json"), options: [.atomic, .completeFileProtection])
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
            #endif
        }
        .onChange(of: band.verified) { _, verified in
            if verified {
                restoreTapMapping()
                if rememberBandDetails && !showPractice { startMemoryListening() }
            } else {
                captureStartTask?.cancel()
                tapTask?.cancel(); tapGate.reset()
                if tapCalibration.phase != .complete { tapCalibration.reset() }
            }
        }
        .onChange(of: camera.ready) { _, _ in refreshAudioOutput() }
        .onChange(of: audio.outputNeedingApproval?.id) { _, _ in refreshAudioOutput() }
        .onChange(of: memory.loaded) { _, loaded in
            if loaded && rememberBandDetails && band.verified { startMemoryListening() }
        }
        .onChange(of: showPractice) { _, practicing in
            if !practicing {
                refreshAudioOutput()
                if rememberBandDetails && band.verified { startMemoryListening() }
            }
        }
        .onChange(of: coaching.busy) { _, busy in
            if !busy {
                refreshAudioOutput()
                Task { softwareReady = (try? await models.executor.activeProfile()) != nil }
            }
        }
        .onChange(of: activeTab) { _, tab in
            if tab == 0 { refreshAudioOutput() }
        }
        .onChange(of: coaching.status) { _, status in
            UIAccessibility.post(notification: .announcement, argument: status)
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
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .background { suspendSession() }
            if phase == .active { refreshAudioOutput() }
        }
    }
    private func initializeSession() async {
            do { try camera.configure() } catch { operation.error = error.localizedDescription }
            refreshAudioOutput()
            if band.verified { restoreTapMapping() }
            await coaching.configure()
            do {
                try memory.load()
                try await memory.finishPendingDeletions { try await deleteEvidence($0) }
            } catch { operation.error = "Memory needs attention. Open Memory to retry pending deletions, or restart Voca; existing data is preserved." }
            draftBandNumber = bandNumber
            band.onTap = { milliseconds, code in receiveTap(milliseconds: milliseconds, code: code) }
            expectedSHA256 = ModelLibrary.catalog.first(where: { $0.modelID == selectedModel })?.sha256 ?? ""
            #if DEBUG
            // Only invoke after explicit consent for this foreground hardware session.
            if ProcessInfo.processInfo.arguments.contains("--consented-listening-check") {
                checkingModel = true
                defer { checkingModel = false }
                for _ in 0..<50 {
                    if UIApplication.shared.applicationState == .active { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if bandNumber == "18", UIApplication.shared.applicationState == .active {
                    do { try band.connect(assignedNumber: 18) }
                    catch { captureError = error.localizedDescription }
                    for _ in 0..<150 {
                        if band.verified || UIApplication.shared.applicationState != .active { break }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if band.verified, UIApplication.shared.applicationState == .active {
                        enableMemoryListening()
                        await captureStartTask?.value
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
                let result: [String: Any] = [
                    "verifiedBand": band.info?.number ?? -1,
                    "bandStatus": band.status,
                    "listening": listening.active,
                    "status": listening.status,
                    "decodedPackets": listening.decodedPackets,
                    "pipecatReady": pipecat.ready,
                    "error": captureError ?? "",
                    "foreground": UIApplication.shared.applicationState == .active
                ]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "live-listening-status.json"), options: [.atomic, .completeFileProtection])
                }
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--scene-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                pipecat.start(audio: audio)
                for _ in 0..<100 {
                    if pipecat.ready { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let checkModel = ProcessInfo.processInfo.arguments.contains("--e2b") ? "gemma4E2B" : "gemma4E4B"
                selectedModel = checkModel
                await models.checkSceneOnDevice(camera: camera, pipecatReady: pipecat.ready, modelID: checkModel)
                UIApplication.shared.isIdleTimerDisabled = false
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--inference-stress-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                await InferenceStressCheck.run(models: models, voice: pipecat, audio: audio)
                UIApplication.shared.isIdleTimerDisabled = false
                softwareReady = (try? await models.executor.activeProfile()) != nil
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--cue-format-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                if ProcessInfo.processInfo.arguments.contains("--replay-failed-cues") {
                    await ReviewModelCheck.replayFailedCues(models: models)
                } else { await ReviewModelCheck.checkCueFormat(models: models) }
                UIApplication.shared.isIdleTimerDisabled = false
                softwareReady = (try? await models.executor.activeProfile()) != nil
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--practice-live-check") {
                checkingModel = true
                captureStartTask?.cancel()
                await captureStartTask?.value
                await listening.stop(band: band, message: "Listening paused during practice")
                await coaching.stop(voice: pipecat, executor: models.executor)
                pipecat.start(audio: audio)
                do { try await models.load(modelID: "gemma4E4B"); softwareReady = true }
                catch { operation.error = error.localizedDescription }
                for _ in 0..<100 {
                    if pipecat.ready { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                checkingModel = false
                if softwareReady && pipecat.ready { showPractice = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--practice-model-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                await ReviewModelCheck.checkPractice(models: models)
                UIApplication.shared.isIdleTimerDisabled = false
                softwareReady = (try? await models.executor.activeProfile()) != nil
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--review-model-check") {
                checkingModel = true
                UIApplication.shared.isIdleTimerDisabled = true
                await ReviewModelCheck.run(models: models)
                UIApplication.shared.isIdleTimerDisabled = false
                softwareReady = (try? await models.executor.activeProfile()) != nil
                checkingModel = false
            }
            if ProcessInfo.processInfo.arguments.contains("--practice-bridge-check") {
                pipecat.start(audio: audio)
                for _ in 0..<100 {
                    if pipecat.ready { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                var result: [String: Any] = ["passed": false, "fixture": true]
                do {
                    try await pipecat.acceptPracticeTurn(PracticeTurn(id: UUID(), sessionID: UUID(), generation: 0,
                        text: "This is a synthetic practice bridge check.", isFinal: true))
                    result["passed"] = true
                } catch { result["error"] = error.localizedDescription }
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "practice-bridge-check.json"), options: .atomic)
                }
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
            if !ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("-check") }) {
                prepareSoftware()
            }
    }

    private func reconnectDevices() async {
        guard !checkingModel, !ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("-check") }) else { return }
        if let number = Int(bandNumber), !band.connectionActive {
            do { try band.connect(assignedNumber: number) }
            catch { setupStatus = error.localizedDescription }
        }
        if !camera.ready {
            do { try await camera.start() }
            catch is CancellationError { return }
            catch { setupStatus = error.localizedDescription }
        }
        refreshAudioOutput()
        if softwareReady && !pipecat.ready && !operation.busy { prepareSoftware() }
        if rememberBandDetails, band.verified, UIApplication.shared.applicationState == .active { startMemoryListening() }
    }

    private func deleteEvidence(_ sourceID: String) async throws {
        await coaching.stop(voice: pipecat, executor: models.executor)
        let dependentIDs = Set(coaching.episodes.filter { episode in
            let context = episode.decision.context
            return context.snapshot.approvedMemories.contains { $0.sourceID == sourceID } ||
                context.snapshot.dialogue.contains { $0.sourceID == sourceID } ||
                context.knownPointSourceID == sourceID || episode.cue?.sourceIDs.contains(sourceID) == true
        }.map(\.id))
        try memory.removeDerivedData(decisionIDs: dependentIDs)
        try await coaching.deleteEvidence(sourceID: sourceID)
    }

    private func suspendSession() {
        cuePreparationTask?.cancel()
        showPractice = false
        reviewingEpisode = nil
        stoppingCue = true
        tapTask?.cancel()
        tapGate.cancelPending()
        camera.suspendForBackground()
        pipecat.stop()
        audio.deactivate()
        captureStartTask?.cancel()
        Task {
            await captureStartTask?.value
            await listening.stop(band: band)
            await coaching.stop(voice: pipecat, executor: models.executor)
            stoppingCue = false
        }
    }

    private func enableMemoryListening() {
        guard band.verified, !showPractice else { return }
        rememberBandDetails = true
        startMemoryListening()
    }

    private func startMemoryListening() {
        guard !listening.busy, !capturePreparing, band.verified, !showPractice else { return }
        capturePreparing = true
        captureError = nil
        captureStartTask = Task {
            defer { capturePreparing = false }
            do {
                pipecat.start(audio: audio)
                for _ in 0..<100 {
                    if pipecat.ready { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                try Task.checkCancellation()
                guard rememberBandDetails, band.verified, !showPractice else { return }
                guard UIApplication.shared.applicationState == .active else { return }
                try await listening.startContinuous(band: band, memory: memory, voice: pipecat, playbackActive: { [weak audio] in audio?.speaking ?? true })
            } catch is CancellationError { }
            catch { captureError = error.localizedDescription }
        }
    }

    private func stopMemoryListening() async {
        rememberBandDetails = false
        captureStartTask?.cancel()
        await captureStartTask?.value
        await listening.stop(band: band)
        captureError = nil
    }

    private var diagnostics: some View {
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
                        Button("Review audio output") {
                            showDiagnostics = false; showSetup = true
                            presentAudioApproval()
                        }.disabled(audio.routeIsValid || audio.outputNeedingApproval == nil)
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
                        TextField("Number printed on your band’s bag", text: $draftBandNumber).keyboardType(.numberPad)
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
                        Button("Capture a 10-second local transcript") { showCaptureConsent = true }.disabled(!band.verified || listening.busy || capturePreparing)
                        Button("Stop listening") { Task { await stopMemoryListening() } }
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
                            activeTab = 0
        coaching.request(models: models, camera: camera, voice: pipecat, snapshot: memory.snapshot())
                        }.disabled(coaching.busy || !camera.ready || !pipecat.ready)
                        Button("Cancel cue") {
                            Task { await coaching.stop(voice: pipecat, executor: models.executor) }
                        }.disabled(!coaching.busy)
                        if let episode = coaching.episodes.last, let cue = episode.cue {
                            Text(cue.text).font(.headline)
                            Text("Delivery: \(episode.delivery.rawValue)").font(.caption)
                            Text(cue.actualProfile.modelID == .gemma4E2B ? "Model: E2B fallback" : "Model: E4B").font(.caption)
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
                    if let error = coaching.lastError ?? operation.error { Section { Text(error).foregroundStyle(.red) } }
                }
    }

    private var cueReady: Bool {
        UIApplication.shared.applicationState == .active && memory.loaded && memory.pendingDeletionIDs.isEmpty && !showPractice && reviewingEpisode == nil && coaching.isConfigured && softwareReady && camera.ready && pipecat.ready && audio.routeIsValid && !coaching.busy && !operation.busy && !preparingCue && !stoppingCue
    }

    private var goalTitle: String {
        switch coaching.goal {
        case .enter: "Start talking"
        case .deepen: "Go deeper"
        case .explain: "Explain a point"
        }
    }

    private var connectionTitle: String {
        if coaching.busy { return coaching.phase == .speaking ? "Speaking" : "Preparing cue" }
        if stoppingCue { return "Finishing previous cue" }
        if preparingCue { return "Opening cue history" }
        if !memory.loaded { return "Check memory" }
        if !memory.pendingDeletionIDs.isEmpty { return "Finish deleting memory" }
        if !coaching.isConfigured { return "Check cue history" }
        if cueReady { return "Ready" }
        if !camera.ready { return "Connect glasses" }
        if !audio.routeIsValid { return "Choose audio" }
        if !softwareReady || !pipecat.ready { return "Preparing guidance" }
        return "Check connection"
    }

    private func openReadiness() {
        if !memory.loaded || !memory.pendingDeletionIDs.isEmpty { activeTab = 2 }
        else if camera.ready, !audio.routeIsValid, audio.outputNeedingApproval != nil { presentAudioApproval() }
        else { showSetup = true }
    }

    private var sessionScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Button { openReadiness() } label: {
                        PhosphorLabel(connectionTitle, icon: cueReady ? "checkmark.circle" : coaching.busy ? "waveform" : "circle.dashed", size: 16)
                            .font(.caption).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(VocaTheme.secondary)
                        .accessibilityHint(!memory.loaded || !memory.pendingDeletionIDs.isEmpty ? "Opens Memory to resolve the issue" : camera.ready && !audio.routeIsValid && audio.outputNeedingApproval != nil ? "Reviews the selected audio output" : "Opens device and guidance settings")
                    Spacer(minLength: 0)
                    if listening.active || capturePreparing {
                        PhosphorLabel(capturePreparing ? "Starting…" : "Listening for your next cue", icon: "mic.fill", size: 16)
                            .font(.caption).foregroundStyle(VocaTheme.secondary)
                        Button { Task { await stopMemoryListening() } } label: {
                            PhosphorIcon("stop.fill", size: 16).frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Stop listening")
                    }
                }
                if listening.active {
                    Text("Recent speech helps your next cue. Used excerpts stay in cue history; personal memories still need your approval.")
                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                }
                CueGenerationView(phase: coaching.busy ? coaching.phase : nil,
                                  active: activeTab == 0 && !showSetup && !showDiagnostics && !showPractice && reviewingEpisode == nil)
                if coaching.busy {
                    HStack {
                        Spacer()
                        Button(stoppingCue ? "Stopping…" : "Cancel cue", role: .cancel) { stopSessionWork() }
                            .buttonStyle(VocaSecondaryButton()).disabled(stoppingCue)
                        Spacer()
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { goalControl; Spacer(minLength: 0); cueAction }
                        VStack(alignment: .leading, spacing: 12) { goalControl; cueAction }
                    }
                    if coaching.goal == .explain {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your main point").font(.subheadline)
                            TextField("For example, my garden project", text: $coaching.knownPoint, axis: .vertical)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("Your main point")
                        }
                    }
                    if let episode = coaching.episodes.last, episode.cue != nil { cueCard(episode) }
                    if let error = operation.error ?? cueRequestError ?? coaching.lastError {
                        VStack(alignment: .leading, spacing: 12) {
                            PhosphorLabel("Cue needs attention", icon: "exclamationmark.circle").font(.headline)
                            Text(error).font(.subheadline).foregroundStyle(VocaTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Button(!memory.loaded || !memory.pendingDeletionIDs.isEmpty ? "Open Memory" : "Connection details") { openReadiness() }.buttonStyle(VocaSecondaryButton())
                        }.vocaSurface()
                    }
                    if coaching.episodes.count > 1 {
                        HStack {
                            Text("Recent").font(.headline)
                            Spacer()
                            Button("See all") { activeTab = 1 }.font(.subheadline).frame(minHeight: 44)
                        }
                        ForEach(Array(coaching.episodes.dropLast().suffix(2).reversed())) { episode in
                            historyRow(episode)
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(VocaTheme.background).scrollDismissesKeyboard(.interactively)
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.3), value: coaching.busy)
    }

    private var cueAction: some View {
        Button { requestCue() } label: { PhosphorLabel(preparingCue ? "Preparing…" : "Get cue", icon: "sparkle", size: 18) }
            .buttonStyle(VocaPrimaryButton()).disabled(operation.busy || preparingCue || stoppingCue)
            .accessibilityHint("Creates and speaks a new cue, or explains what needs attention")
    }

    private var goalControl: some View {
        Menu {
            Picker("Conversation goal", selection: $coaching.goal) {
                Text("Start a conversation").tag(Goal.enter)
                Text("Go deeper").tag(Goal.deepen)
                Text("Explain a point").tag(Goal.explain)
            }
        } label: {
            HStack(spacing: 8) {
                Text(goalTitle).fixedSize(horizontal: false, vertical: true)
                PhosphorIcon("chevron.down", size: 16)
            }.font(.subheadline).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(VocaTheme.secondary)
            .accessibilityLabel("Conversation goal, " + goalTitle)
    }

    private var reviewScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { practiceSummary; Spacer(minLength: 0); practiceAction }
                    VStack(alignment: .leading, spacing: 16) { practiceSummary; practiceAction }
                }.vocaSurface()
                Text("Recent cues").font(.headline).accessibilityAddTraits(.isHeader)
                if coaching.episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        VocaEmptyState(symbol: "text.bubble", title: "No cues yet", detail: "Your cues and feedback will appear here.")
                        Button("Get your first cue") { activeTab = 0 }.buttonStyle(VocaSecondaryButton())
                    }
                }
                ForEach(coaching.episodes.reversed()) { episode in historyRow(episode) }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(VocaTheme.background)
    }

    private var practiceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) { PracticeInvitationVisual(); Text("Practice").font(.headline) }
            Text("Try a short conversation.").font(.subheadline).foregroundStyle(VocaTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var practiceAction: some View {
        Button(softwareReady && pipecat.ready ? "Start" : "Set up") {
            if softwareReady && pipecat.ready {
                Task {
                    await coaching.stop(voice: pipecat, executor: models.executor)
                    captureStartTask?.cancel()
                    await captureStartTask?.value
                    await listening.stop(band: band, message: "Listening paused during practice")
                    showPractice = true
                }
            } else { prepareSoftware() }
        }.buttonStyle(VocaPrimaryButton()).disabled(operation.busy)
            .accessibilityLabel(softwareReady && pipecat.ready ? "Start practice" : "Set up practice")
    }

    private func historyRow(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task {
                    await coaching.stop(voice: pipecat, executor: models.executor)
                    reviewingEpisode = episode
                }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(episode.decision.context.requestedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).monospacedDigit().foregroundStyle(VocaTheme.secondary)
                        Spacer()
                        PhosphorIcon("arrow.up.right", size: 16)
                    }
                    Text(episode.cue?.text ?? "Cue unavailable").font(.body.weight(.medium))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    PhosphorLabel(episode.delivery == .completed ? "Delivered" : "Not delivered",
                                  icon: episode.delivery == .completed ? "checkmark.circle" : "exclamationmark.circle", size: 16)
                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(operation.busy).accessibilityHint("Opens cue review")
            if episode.delivery == .completed {
                HStack(spacing: 8) { feedbackButtons(episode); Spacer(minLength: 0) }
            } else {
                Text(coaching.failureReasons[episode.id] ?? "Request another cue in Session.")
                    .font(.subheadline).foregroundStyle(VocaTheme.secondary)
            }
        }.vocaSurface()
    }

    private func cueCard(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(episode.delivery == .completed ? "Latest cue" : "Cue not delivered").font(.caption)
                Spacer()
                Text(episode.decision.context.requestedAt, style: .time).font(.caption).monospacedDigit()
            }.foregroundStyle(VocaTheme.secondary)
            if let cue = episode.cue {
                Text(cue.text).font(.title3.weight(.medium)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if episode.delivery == .completed { feedbackButtons(episode) }
                Spacer(minLength: 0)
                Button { reviewingEpisode = episode } label: { PhosphorIcon("arrow.up.right").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Review cue and details")
            }
            if episode.delivery != .completed {
                Text(coaching.failureReasons[episode.id] ?? "Only a fully spoken cue can be rated.")
                    .font(.subheadline).foregroundStyle(VocaTheme.secondary)
            }
        }.vocaSurface()
    }

    @ViewBuilder private func feedbackButtons(_ episode: Episode) -> some View {
        ForEach([FeedbackVerdict.helpful, .unhelpful, .notTried], id: \.self) { verdict in
            let selected = episode.feedback?.verdict == verdict
            Button { Task {
                if verdict == .unhelpful { tasteEpisode = episode }
                else { await coaching.feedback(verdict, episode: episode) }
            } } label: {
                PhosphorIcon(verdict == .helpful ? "hand.thumbsup" : verdict == .unhelpful ? "hand.thumbsdown" : "minus.circle", size: 18)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(selected ? VocaTheme.background : VocaTheme.secondary)
                    .background(selected ? VocaTheme.foreground : VocaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .accessibilityLabel(verdict == .helpful ? "Helpful" : verdict == .unhelpful ? "Unhelpful" : "Not tried")
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private var setupSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DeviceConnectionVisual(connected: camera.ready && band.info != nil,
                                           connecting: band.connectionActive || operation.busy)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Devices").font(.headline).accessibilityAddTraits(.isHeader)
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(camera.status).font(.subheadline).foregroundStyle(VocaTheme.secondary)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) { glassesActions }
                                    VStack(alignment: .leading, spacing: 12) { glassesActions }
                                }
                            }.padding(.top, 12)
                        } label: {
                            ReadinessRow(title: "Ray-Ban Meta", detail: camera.ready ? "Connected" : "Connection options", ready: camera.ready)
                        }
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(band.status).font(.subheadline).foregroundStyle(VocaTheme.secondary)
                                Text("Assigned band number").font(.subheadline)
                                TextField("18", text: $draftBandNumber).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Assigned band number")
                                Text("Use the number on your bag. Close other band clients, then double-tap the band to make it available.")
                                    .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                                Button("Connect assigned band") { connectAssignedBand() }.buttonStyle(VocaSecondaryButton())
                            }.padding(.top, 12)
                        } label: {
                            ReadinessRow(title: "Band \(bandNumber)", detail: band.info != nil ? "Connected" : "Connection options", ready: band.info != nil)
                        }
                    }.vocaSurface()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            ReadinessRow(title: "Audio output",
                                         detail: audio.currentOutput.isEmpty ? "Choose an output" : audio.currentOutput,
                                         ready: audio.routeIsValid)
                            AudioOutputPicker().frame(width: 44, height: 44)
                        }
                        if !audio.routeIsValid, audio.outputNeedingApproval != nil {
                            Button("Review output") { presentAudioApproval() }.buttonStyle(VocaSecondaryButton())
                        }
                    }.vocaSurface()
                    VStack(alignment: .leading, spacing: 12) {
                        VocaSectionHeading(title: "On this iPhone")
                        ReadinessRow(title: "Guidance", detail: !coaching.isConfigured ? "Cue history needs attention" : softwareReady ? "Ready" : setupStatus, ready: softwareReady && coaching.isConfigured)
                        ReadinessRow(title: "Voice", detail: pipecat.ready ? "Ready" : pipecat.status, ready: pipecat.ready)
                        if !softwareReady || !pipecat.ready || !coaching.isConfigured {
                            Button(operation.busy ? "Preparing guidance…" : "Retry guidance setup") { prepareSoftware() }
                                .buttonStyle(VocaPrimaryButton()).disabled(operation.busy)
                        }
                    }
                    DisclosureGroup(tapCalibration.phase == .complete ? "Band taps" : "Set up single-tap cues", isExpanded: $showTapCalibration) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tapCalibration.phase == .complete ? "Single tap for a cue. Double tap to listen for memories." : tapCalibration.status)
                                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            switch tapCalibration.phase {
                            case .idle:
                                Button("Calibrate taps") { startTapCalibration() }.buttonStyle(VocaSecondaryButton())
                            case .single:
                                Button("Continue to double tap") { _ = tapCalibration.startDouble(at: Date()) }.buttonStyle(VocaSecondaryButton())
                            case .double:
                                Button("Save calibration") { enableTapMapping() }.buttonStyle(VocaSecondaryButton())
                            case .complete:
                                PhosphorLabel("Calibration saved for band \(bandNumber)", icon: "checkmark.circle", size: 16)
                                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                                Button("Recalibrate taps") { startTapCalibration() }.buttonStyle(VocaSecondaryButton())
                            }
                            if tapCalibration.phase == .single || tapCalibration.phase == .double {
                                Button("Cancel calibration", role: .cancel) { restoreTapMapping() }.font(.subheadline).frame(minHeight: 44)
                            }
                        }.padding(.top, 12).disabled(!band.verified)
                    }

                    if let error = coaching.lastError ?? operation.error {
                        VStack(alignment: .leading, spacing: 8) {
                            PhosphorLabel("Needs attention", icon: "exclamationmark.circle").font(.headline)
                            Text(error).font(.subheadline).textSelection(.enabled)
                        }.vocaSurface()
                    }
                    DisclosureGroup("Privacy and capture") {
                        Text("Photos are taken only when you request a cue. Microphone capture requires everyone’s consent. The band keeps its blue microphone indicator on while listening. Its Bluetooth link is not encrypted.")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary).padding(.top, 12)
                    }
                    Button { showSetup = false; showDiagnostics = true } label: {
                        HStack { Text("Advanced controls"); Spacer(); PhosphorIcon("chevron.right", size: 16) }
                            .font(.subheadline).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
                .scrollDismissesKeyboard(.interactively)
                .alert("Use this audio output?", isPresented: audioApprovalPresentation(inSettings: true), presenting: pendingAudioOutput) { output in
                    audioApprovalActions(output)
                } message: { output in
                    Text("Play cues through \(output.name)? Voca will remember this output.")
                }
                .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSetup = false } } }
        }
    }

    private func audioApprovalPresentation(inSettings: Bool) -> Binding<Bool> {
        Binding(get: { showAudioApproval && showSetup == inSettings && !showDiagnostics },
                set: { showAudioApproval = $0 })
    }

    @ViewBuilder private func audioApprovalActions(_ output: AudioRouteApproval.Output) -> some View {
        Button("Use this output") {
            do {
                try audio.confirmOutput(id: output.id)
                declinedAudioOutputs.remove(output.id)
            } catch { operation.error = error.localizedDescription }
        }
        Button("Not now", role: .cancel) { declinedAudioOutputs.insert(output.id) }
    }

    private func presentAudioApproval(automatically: Bool = false) {
        guard let output = audio.outputNeedingApproval,
              !automatically || !declinedAudioOutputs.contains(output.id) else { return }
        pendingAudioOutput = output
        showAudioApproval = true
    }

    private func refreshAudioOutput() {
        let names = camera.connectedGlassesNames
        audio.refreshGlassesConnection(connected: !names.isEmpty, names: names)
        if showAudioApproval, pendingAudioOutput?.id != audio.outputNeedingApproval?.id {
            showAudioApproval = false
            return
        }
        guard scenePhase == .active, camera.ready, !showPractice,
              activeTab == 0 || showSetup, reviewingEpisode == nil, !showDiagnostics, !coaching.busy else { return }
        presentAudioApproval(automatically: true)
    }

    @ViewBuilder private var glassesActions: some View {
        Button("Reconnect") { run(cameraTimeout: true) { try await camera.start() } }
            .buttonStyle(VocaSecondaryButton()).disabled(operation.busy)
        Button("Register") { run(cameraTimeout: true) { try await camera.register() } }
            .buttonStyle(VocaSecondaryButton()).disabled(operation.busy)
            .accessibilityLabel("Register glasses with Meta AI")
    }

    private func prepareSoftware() {
        guard !operation.busy else { return }
        run {
            setupStatus = "Preparing guidance on your iPhone…"
            pipecat.start(audio: audio)
            if (try? await models.executor.activeProfile()) == nil {
                do { try await models.load(modelID: "gemma4E4B") }
                catch is CancellationError { throw CancellationError() }
                catch {
                    setupStatus = "E4B could not become ready. Preparing E2B fallback…"
                    try await models.load(modelID: "gemma4E2B")
                }
            }
            for _ in 0..<100 {
                if pipecat.ready { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard pipecat.ready else { throw PipecatSpeech.Failure.notReady }
            softwareReady = true
            await coaching.configure()
            guard coaching.isConfigured else {
                operation.error = coaching.lastError
                return
            }
            setupStatus = "Guidance is ready. Connect your devices when they’re available."
        }
    }

    private func connectAssignedBand() {
        guard let number = Int(draftBandNumber), (1...999).contains(number) else {
            operation.error = "Enter the assigned band number from its bag (1–999), then connect again."
            return
        }
        Task {
            tapTask?.cancel(); tapGate.reset(); tapCalibration.reset()
            await listening.stop(band: band)
            band.disconnect()
            if bandNumber != String(number) { rememberBandDetails = false }
            bandNumber = String(number)
            do { try band.connect(assignedNumber: number) }
            catch { operation.error = error.localizedDescription }
        }
    }

    private func restoreTapMapping() {
        tapTask?.cancel(); tapGate.reset()
        guard band.verified, let info = band.info, info.number == Int(bandNumber),
              tapCalibration.restore(for: info), let seconds = tapCalibration.settlingInterval else {
            tapCalibration.reset()
            return
        }
        tapGate.enableVerifiedMapping(settlingInterval: seconds)
    }

    private func startTapCalibration() {
        guard band.verified else { return }
        tapTask?.cancel(); tapGate.reset()
        tapCalibration.startSingle(at: Date())
    }

    private func enableTapMapping() {
        guard band.verified, let info = band.info, info.number == Int(bandNumber),
              tapCalibration.finishDouble(at: Date()), tapCalibration.save(for: info),
              let seconds = tapCalibration.settlingInterval,
              tapGate.enableVerifiedMapping(settlingInterval: seconds) else { return }
        setupStatus = "Tap calibration saved for band \(bandNumber)."
    }

    private func prepareFeedbackCapture() async {
        await coaching.stop(voice: pipecat, executor: models.executor)
        captureStartTask?.cancel(); await captureStartTask?.value
        await listening.stop(band: band, message: "Listening paused for your correction")
    }

    private func receiveTap(milliseconds: UInt32, code: UInt8) {
        guard band.verified else { return }
        let received = ProcessInfo.processInfo.systemUptime
        let calibrating = tapCalibration.phase == .single || tapCalibration.phase == .double
        if code == 1, !calibrating, !tapGate.mappingVerified {
            cueRequestError = "Set up single-tap cues in device settings first. Get cue works while you check the band's tap timing."
        }
        tapCalibration.receive(milliseconds: milliseconds, code: code, at: Date())
        if code == 2, !calibrating { enableMemoryListening() }
        tapTask?.cancel()
        guard let deadline = tapGate.receive(milliseconds: milliseconds, code: code, at: Date(), ready: cueReady) else { return }
        tapTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            if tapGate.consume(at: Date(), ready: cueReady) { requestCue(trace: CueTrace(origin: "band", began: received)) }
        }
    }

    private func requestCue(trace: CueTrace = CueTrace()) {
        guard !preparingCue, !stoppingCue, !coaching.busy, !operation.busy else { return }
        cueRequestError = nil
        operation.error = nil
        activeTab = 0
        guard UIApplication.shared.applicationState == .active, !showPractice, reviewingEpisode == nil, tasteEpisode == nil else { return }
        if !coaching.isConfigured {
            preparingCue = true
            Task {
                await coaching.configure()
                preparingCue = false
                guard coaching.isConfigured else {
                    cueRequestError = coaching.lastError ?? "Cue history could not be opened. Try Get cue again."
                    return
                }
                requestCue(trace: trace)
            }
            return
        }
        guard cueReady else {
            if !memory.loaded || !memory.pendingDeletionIDs.isEmpty {
                cueRequestError = "Memory needs attention before a new cue. Open Memory to finish loading or deleting saved details."
            } else if !camera.ready {
                cueRequestError = "Your glasses are reconnecting. Once they’re ready, try Get cue again."
            } else if !audio.routeIsValid {
                cueRequestError = "Choose an audio output for your cue."
                if audio.outputNeedingApproval != nil { presentAudioApproval() }
            } else if !softwareReady || !pipecat.ready {
                cueRequestError = "Guidance is getting ready. Try Get cue when Ready appears."
                prepareSoftware()
            }
            return
        }
        tapTask?.cancel(); tapGate.cancelPending()
        preparingCue = true
        cuePreparationTask = Task {
            defer { preparingCue = false; cuePreparationTask = nil }
            trace.mark("dialogueStarted")
            let snapshot = await listening.cueSnapshot(memories: memory.snapshot())
            trace.mark("dialogueReady")
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            if listening.active, snapshot.dialogue.isEmpty {
                cueRequestError = "I couldn’t catch recent, clear speech. Keep listening and tap again after a sentence, or stop listening for a scene-based cue."
                return
            }
            coaching.request(models: models, camera: camera, voice: pipecat, snapshot: snapshot, trace: trace)
        }
    }

    private func stopSessionWork() {
        cuePreparationTask?.cancel()
        tapTask?.cancel(); tapGate.cancelPending()
        guard !stoppingCue else { return }
        stoppingCue = true
        Task {
            await coaching.stop(voice: pipecat, executor: models.executor)
            stoppingCue = false
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
