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
    @State private var memory = MemoryStore()
    @State private var reviewingEpisode: Episode?
    @State private var showPractice = false
    @State private var waveTrigger = 0
    @State private var selectedModel = "gemma4E4B"
    @State private var expectedSHA256 = ""
    @State private var importingModel = false
    @State private var checkingModel = false
    @State private var audio = NativeAudio()
    @State private var pipecat = PipecatSpeech()
    @State private var listening = BandListening()
    @State private var showCaptureConsent = false
    @AppStorage("assignedBandNumber") private var bandNumber = "18"
    @State private var showSetup = false
    @State private var showDiagnostics = false
    @State private var activeTab = 0
    @State private var softwareReady = false
    @State private var sessionEnabled = false
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
                            Button { showSetup = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                                .accessibilityLabel("Open device setup")
                        }
                    }
            }.tabItem { Label("Session", systemImage: "waveform") }.tag(0)
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Make the next conversation yours.").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text("Practice a new approach, or look back at a cue and what helped.")
                            .foregroundStyle(VocaTheme.secondary)
                        Button("Start spoken practice") {
                            Task {
                                await coaching.stop(voice: pipecat, executor: models.executor)
                                await listening.stop(band: band)
                                showPractice = true
                            }
                        }.buttonStyle(VocaPrimaryButton()).disabled(!softwareReady || !pipecat.ready || operation.busy)
                        if !softwareReady || !pipecat.ready {
                            Button("Prepare on-device guidance") { prepareSoftware() }.buttonStyle(.bordered)
                            Text("Practice uses a simulated scenario. Glasses are optional.").font(.subheadline).foregroundStyle(VocaTheme.secondary)
                        }
                        NavigationLink("Your style") { TasteProfileView(store: coaching.taste, episodes: coaching.episodes) }.disabled(!coaching.taste.loaded)
                        Text("Cue history").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        if coaching.episodes.isEmpty {
                            Text("Your cues and feedback will appear here. Request a cue to begin.")
                            Button("Start a session") { activeTab = 0 }.buttonStyle(.bordered)
                        }
                        ForEach(coaching.episodes.reversed()) { episode in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(episode.decision.context.requestedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                                cueCard(episode)
                                Button("Review this conversation") {
                                    Task {
                                        await coaching.stop(voice: pipecat, executor: models.executor)
                                        reviewingEpisode = episode
                                    }
                                }.buttonStyle(.bordered).disabled(operation.busy)
                            }
                        }
                        if let error = coaching.lastError { Text(error).foregroundStyle(VocaTheme.secondary) }
                    }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }.background(VocaTheme.background)
            }.tabItem { Label("Review", systemImage: "text.bubble") }.tag(1)
            NavigationStack {
                MemoryView(store: memory) { sourceID in
                    try await deleteEvidence(sourceID)
                }
            }.tabItem { Label("Memory", systemImage: "person.text.rectangle") }.tag(2)
        }
    }
    private var presentedTabs: some View {
        tabs
        .tint(VocaTheme.foreground)
        .foregroundStyle(VocaTheme.foreground)
        .sheet(item: $tasteEpisode) { episode in TasteFeedbackView(episode: episode, store: coaching.taste) }
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
        .disabled(checkingModel)
    }
    var body: some View {
        presentedTabs
        .task { await initializeSession() }
        .onChange(of: band.info == nil) { _, disconnected in
            if disconnected { tapTask?.cancel(); tapGate.reset(); tapCalibration.reset() }
        }
        .onChange(of: coaching.busy) { _, busy in
            if !busy { Task { softwareReady = (try? await models.executor.activeProfile()) != nil } }
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
        }
    }
    private func initializeSession() async {
            do { try camera.configure() } catch { operation.error = error.localizedDescription }
            await coaching.configure()
            do {
                try memory.load()
                try await memory.finishPendingDeletions { try await deleteEvidence($0) }
            } catch { operation.error = "Memory needs attention. Open Memory to retry pending deletions, or restart Voca; existing data is preserved." }
            draftBandNumber = bandNumber
            band.onTap = { milliseconds, code in receiveTap(milliseconds: milliseconds, code: code) }
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
        showPractice = false
        reviewingEpisode = nil
        sessionEnabled = false
        tapTask?.cancel()
        tapGate.cancelPending()
        camera.suspendForBackground()
        pipecat.stop()
        audio.deactivate()
        Task {
            await coaching.stop(voice: pipecat, executor: models.executor)
            await listening.stop(band: band)
        }
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
                            activeTab = 0
        waveTrigger += 1
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
                                        Task {
                    await coaching.feedback(verdict, episode: episode)
                    if [.helpful, .unhelpful].contains(verdict), coaching.lastError == nil {
                        tasteEpisode = coaching.episodes.first { $0.id == episode.id }
                    }
                }
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
        sessionEnabled && memory.loaded && memory.pendingDeletionIDs.isEmpty && !showPractice && reviewingEpisode == nil && coaching.isConfigured && softwareReady && camera.ready && pipecat.ready && audio.routeIsValid && !coaching.busy && !operation.busy
    }

    private var goalTitle: String {
        switch coaching.goal {
        case .enter: "Start a conversation"
        case .deepen: "Go deeper"
        case .explain: "Explain a point"
        }
    }

    private var sessionScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Label(cueReady ? "Ready for a cue" : coaching.busy ? "Working on your cue" : "Session not ready",
                          systemImage: cueReady ? "checkmark.circle" : "circle.dashed")
                        .font(.subheadline)
                    Spacer()
                    Text("On this iPhone").font(.caption).foregroundStyle(VocaTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text(coaching.busy ? "A little space to find your words." : "Be here.\nFind your words.")
                        .font(.largeTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    CueWave(trigger: waveTrigger)
                    if coaching.busy { GuidanceOrb() }
                    Text(coaching.busy ? coaching.status : cueReady ?
                         (tapGate.mappingVerified ? "Tap band \(bandNumber) once for a short spoken cue." : "Ask for a cue below. Set up band taps when your devices are ready.") :
                         "A small prompt for the conversation in front of you. Prepare your devices to begin.")
                        .font(.body).foregroundStyle(VocaTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !coaching.busy, let episode = coaching.episodes.last, episode.cue != nil { cueCard(episode) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("What would help?").font(.headline).accessibilityAddTraits(.isHeader)
                    Menu {
                        Picker("Conversation goal", selection: $coaching.goal) {
                            Text("Start a conversation").tag(Goal.enter)
                            Text("Go deeper").tag(Goal.deepen)
                            Text("Explain a point").tag(Goal.explain)
                        }
                    } label: {
                        HStack(alignment: .top) {
                            Text(goalTitle).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.bordered).accessibilityLabel("Conversation goal").accessibilityValue(goalTitle)
                    if coaching.goal == .explain {
                        Text("The point you want to explain").font(.subheadline)
                        TextField("For example, my garden project", text: $coaching.knownPoint, axis: .vertical)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("The point you want to explain")
                    }
                    if coaching.goal == .deepen {
                        Text("Going deeper uses approved memories or attributable dialogue. Add a story in Memory, or explain a point instead.")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                    }
                }
                if coaching.busy {
                    Button("Stop cue", role: .cancel) { stopSessionWork() }.buttonStyle(VocaPrimaryButton())
                } else if cueReady {
                    if band.info != nil && !tapGate.mappingVerified {
                        Button("Enable band tap cues") { showTapCalibration = true; showSetup = true }.buttonStyle(.bordered)
                    }
                    Button { requestCue() } label: { Label("Give me a cue", systemImage: "sparkle") }
                        .buttonStyle(VocaPrimaryButton())
                } else {
                    Button("Prepare session") { showSetup = true; prepareSoftware() }.buttonStyle(VocaPrimaryButton())
                }
                if let error = coaching.lastError ?? operation.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                    Button("Open setup") { showSetup = true }.buttonStyle(.bordered)
                }
                Text("A photo only when you ask. Microphone capture stays off until you choose to start it.")
                    .font(.footnote).foregroundStyle(VocaTheme.secondary)
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(VocaTheme.background)
    }

    private func cueCard(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(episode.delivery == .completed ? "Your cue" : "Cue not delivered").font(.subheadline)
                Spacer()
                Text(episode.decision.context.requestedAt, style: .time).font(.caption).foregroundStyle(VocaTheme.secondary)
            }
            if let cue = episode.cue {
                Text(cue.text).font(.title2.weight(.medium)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(cue.actualProfile.modelID == .gemma4E4B ? "Guided by E4B · on device" : "Guided by E2B fallback · on device")
                    .font(.caption).foregroundStyle(VocaTheme.secondary)
            }
            if episode.delivery == .completed {
                Text("Did this help?").font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { feedbackButtons(episode) }
                    VStack(alignment: .leading, spacing: 12) { feedbackButtons(episode) }
                }
                if let feedback = episode.feedback {
                    Text(feedback.verdict == .helpful ? "Saved as helpful" : feedback.verdict == .unhelpful ? "Saved as unhelpful" : "Saved as not tried")
                        .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                }
            } else {
                Text(coaching.failureReasons[episode.id] ?? (episode.cue == nil ? "This attempt ended before speech. A detailed reason was not saved for this older attempt." : "Only a fully spoken cue can be rated."))
                    .font(.subheadline).foregroundStyle(VocaTheme.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private func feedbackButtons(_ episode: Episode) -> some View {
        ForEach([FeedbackVerdict.helpful, .unhelpful, .notTried], id: \.self) { verdict in
            Button(verdict == .helpful ? "Helpful" : verdict == .unhelpful ? "Unhelpful" : "Not tried") {
                Task {
                    await coaching.feedback(verdict, episode: episode)
                    if [.helpful, .unhelpful].contains(verdict), coaching.lastError == nil {
                        tasteEpisode = coaching.episodes.first { $0.id == episode.id }
                    }
                }
            }.buttonStyle(.bordered).controlSize(.large)
                .accessibilityAddTraits(episode.feedback?.verdict == verdict ? .isSelected : [])
        }
    }

    private var setupSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("A moment to connect.").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    DeviceConnectionVisual(connected: camera.ready && band.info != nil, connecting: operation.busy)
                    Text(setupStatus).foregroundStyle(VocaTheme.secondary)
                    ReadinessRow(title: "On-device guidance", detail: softwareReady ? "Ready on this iPhone" : operation.busy ? "Loading on-device guidance…" : "Prepares with your session", ready: softwareReady)
                    ReadinessRow(title: "Voice", detail: pipecat.ready ? "Ready on your iPhone" : operation.busy ? "Preparing speech" : "Starts with your session", ready: pipecat.ready)
                    ReadinessRow(title: "Ray-Ban Meta", detail: camera.ready ? "Camera ready · photos only on request" : "Charging or unavailable? You can finish setup later.", ready: camera.ready)
                    if !camera.ready {
                        Button("Connect glasses") { run(cameraTimeout: true) { try await camera.start() } }.buttonStyle(.bordered)
                        Button("Register with Meta AI") { run(cameraTimeout: true) { try await camera.register() } }.buttonStyle(.bordered)
                    }
                    ReadinessRow(title: "Band \(bandNumber)", detail: band.status, ready: band.info != nil)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Assigned band number")
                        TextField("18", text: $draftBandNumber).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Assigned band number")
                    }
                    Text("Use the number on your bag. Close other band clients, then double-tap to open its connection window.")
                        .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                    Button(band.info == nil ? "Connect band \(bandNumber)" : "Switch band") {
                        connectAssignedBand()
                    }.buttonStyle(.bordered)
                    ReadinessRow(title: "Private audio output", detail: audio.status, ready: audio.routeIsValid)
                    if !audio.routeIsValid {
                        HStack {
                            Text("Choose audio output")
                            Spacer()
                            AudioOutputPicker().frame(width: 44, height: 44)
                        }
                        Text("Current output: \(audio.currentOutput.isEmpty ? "Not available" : audio.currentOutput)")
                            .font(.subheadline)
                        Text("Select your glasses, then confirm the output. Voca won’t speak privately to an unconfirmed device.")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                        Button("Confirm glasses output") {
                            do { try audio.confirmGlassesRoute() } catch { operation.error = error.localizedDescription }
                        }.buttonStyle(.bordered)
                    }
                    DisclosureGroup("Set up single-tap cues", isExpanded: $showTapCalibration) {
                        Text(tapCalibration.status).fixedSize(horizontal: false, vertical: true)
                        switch tapCalibration.phase {
                        case .idle:
                            Button("Begin tap check") { tapGate.disableMapping(); tapCalibration.startSingle(at: Date()) }.buttonStyle(.bordered)
                        case .single:
                            Button("Continue to double tap") { _ = tapCalibration.startDouble(at: Date()) }.buttonStyle(.bordered)
                        case .double:
                            Button("Finish tap check") { enableTapMapping() }.buttonStyle(.bordered)
                        case .complete:
                            Label("Single tap requests one cue", systemImage: "checkmark.circle")
                            Button("Check taps again") { tapGate.disableMapping(); tapCalibration.startSingle(at: Date()) }.buttonStyle(.bordered)
                        }
                    }
                    if let error = coaching.lastError ?? operation.error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline) }
                    Button(softwareReady ? "Finish setup" : "Prepare on-device guidance") {
                        if softwareReady { sessionEnabled = true; showSetup = false } else { prepareSoftware() }
                    }.buttonStyle(VocaPrimaryButton())
                    Button("Advanced controls") { showSetup = false; showDiagnostics = true }.buttonStyle(.bordered)
                    Text("The band’s Bluetooth link is not encrypted. Microphone capture requires everyone’s consent and keeps the blue indicator on.")
                        .font(.footnote).foregroundStyle(VocaTheme.secondary)
                }.padding(24)
            }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSetup = false } } }
        }
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
            softwareReady = true; sessionEnabled = true
            if band.info == nil { connectAssignedBand() }
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
            bandNumber = String(number)
            do { try band.connect(assignedNumber: number) }
            catch { operation.error = error.localizedDescription }
        }
    }

    private func enableTapMapping() {
        guard band.info != nil, tapCalibration.finishDouble(at: Date()),
              let seconds = tapCalibration.settlingInterval,
              tapGate.enableVerifiedMapping(settlingInterval: seconds) else { return }
        setupStatus = "Single-tap cues enabled for band \(bandNumber)."
    }

    private func receiveTap(milliseconds: UInt32, code: UInt8) {
        tapCalibration.receive(milliseconds: milliseconds, code: code, at: Date())
        tapTask?.cancel()
        guard let deadline = tapGate.receive(milliseconds: milliseconds, code: code, at: Date(), ready: cueReady) else { return }
        tapTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            if tapGate.consume(at: Date(), ready: cueReady) { requestCue() }
        }
    }

    private func requestCue() {
        guard cueReady else { showSetup = true; return }
        tapTask?.cancel(); tapGate.cancelPending()
        activeTab = 0
        waveTrigger += 1
        coaching.request(models: models, camera: camera, voice: pipecat, snapshot: memory.snapshot())
    }

    private func stopSessionWork() {
        tapTask?.cancel(); tapGate.cancelPending()
        Task { await coaching.stop(voice: pipecat, executor: models.executor) }
    }

    private func run(cameraTimeout: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        operation.run(timeout: cameraTimeout ? .seconds(25) : nil, onTimeout: {
            let stage = camera.status
            camera.stop()
            return "Meta AI did not finish: \(stage) Close and reopen Voca, then retry Start glasses camera."
        }, action)
    }
}
