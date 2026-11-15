import SwiftUI
import VocaCore

struct MemoryView: View {
    @Bindable var store: MemoryStore
    var listeningStatus = "Microphone off"
    var listeningActive = false
    var listeningBusy = false
    var captureEnabled = false
    var bandConnected = false
    var startListening: () -> Void = {}
    var stopListening: () async -> Void = {}
    let invalidate: @MainActor (String) async throws -> Void
    @State private var text = ""
    @State private var approved = false
    @State private var message: String?
    @State private var formError: String?
    @State private var addingMemory = false
    @State private var deleting: MemoryEntry?
    @State private var saving = false
    @State private var clearingSuggestions = false
    @FocusState private var editing: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var memories: [MemoryEntry] { store.records.filter { $0.kind == .personalMemory } }
    private var excerpts: [MemoryEntry] { store.records.filter { $0.kind == .dialogue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                listeningCard
                if let error = store.loadError {
                    VStack(alignment: .leading, spacing: 12) {
                        PhosphorLabel(error, icon: "exclamationmark.circle")
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        if !store.loaded {
                            Button(saving ? "Loading…" : "Retry loading") {
                                saving = true
                                Task {
                                    defer { saving = false }
                                    do {
                                        try store.load()
                                        try await store.finishPendingDeletions(invalidate: invalidate)
                                        message = "Memories loaded."
                                    } catch {
                                        message = store.loaded
                                            ? "Associated history could not be removed. Retry deletion below: \(error.localizedDescription)"
                                            : "Memories could not load. Try again: \(error.localizedDescription)"
                                    }
                                    UIAccessibility.post(notification: .announcement, argument: message)
                                }
                            }.buttonStyle(VocaSecondaryButton()).disabled(saving)
                        }
                    }
                }
                if store.loaded, !store.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("To approve").font(.headline).accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 12)
                            Text(store.suggestions.count, format: .number).font(.subheadline.monospacedDigit())
                                .foregroundStyle(VocaTheme.secondary)
                            Menu {
                                Button("Discard all suggestions", role: .destructive) { clearingSuggestions = true }
                            } label: {
                                PhosphorIcon("ellipsis").frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel("Suggestion options").disabled(saving)
                        }
                        Text("Speakers aren’t identified. Approve only details that are accurate and yours to share.")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVStack(spacing: 16) {
                            ForEach(store.suggestions) { suggestion in
                                MemorySuggestionCard(suggestion: suggestion) { accept, confirmed in
                                    do {
                                        if accept { try store.approveSuggestion(id: suggestion.id, confirmed: confirmed) }
                                        else { try store.rejectSuggestion(id: suggestion.id) }
                                        message = accept ? "Memory saved." : "Suggestion discarded."
                                        UIAccessibility.post(notification: .announcement, argument: message)
                                    } catch { message = error.localizedDescription }
                                }
                            }
                        }.disabled(saving)
                    }
                }
                if let message {
                    PhosphorLabel(message, icon: "info.circle").font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if !store.pendingDeletionIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        PhosphorLabel("Deletion needs to finish", icon: "exclamationmark.circle").font(.headline)
                        Text("The memory is gone. Its saved cues and learning still need to be removed.")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                        Button("Retry deletion") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await store.finishPendingDeletions(invalidate: invalidate); message = "Deletion complete." }
                                catch { message = "Associated history could not be removed. Retry deletion: \(error.localizedDescription)" }
                            }
                        }.buttonStyle(VocaSecondaryButton()).disabled(saving)
                    }.vocaSurface()
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Saved").font(.headline).accessibilityAddTraits(.isHeader)
                    if memories.isEmpty {
                        VocaEmptyState(symbol: "leaf", title: "No saved memories", detail: "Add an interest or a detail you’d like to share.")
                        Button("Add a memory") { addingMemory = true }
                            .buttonStyle(VocaSecondaryButton()).disabled(!store.loaded || saving)
                    }
                    ForEach(memories.reversed()) { entry in entryView(entry) }
                }
                if !excerpts.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Excerpts used in your reviews. These are not shareable personal memories.")
                                .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                            ForEach(excerpts.reversed()) { entry in entryView(entry) }
                        }.padding(.top, 16)
                    } label: {
                        Text("Conversation excerpts").font(.headline).frame(minHeight: 44)
                    }
                }
                DisclosureGroup("How your memories are kept") {
                    Text("Saved only on this iPhone and excluded from backups. Deleting an entry also removes reviews, cues, and learned updates that depend on it. Practice dialogue never becomes a personal memory.")
                        .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }.font(.subheadline).padding(.bottom, 8)
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
            .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingMemory = true } label: {
                        PhosphorIcon("plus").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Add a memory").disabled(!store.loaded || saving)
                }
            }
            .sheet(isPresented: $addingMemory) { addMemorySheet }
            .confirmationDialog("Discard all unapproved suggestions?", isPresented: $clearingSuggestions, titleVisibility: .visible) {
                Button("Stop listening and discard suggestions", role: .destructive) {
                    saving = true
                    Task {
                        defer { saving = false }
                        await stopListening()
                        do { try store.clearSuggestions(); message = "Unapproved suggestions discarded." }
                        catch { message = error.localizedDescription }
                    }
                }
            } message: { Text("Your approved memories stay saved.") }
            .confirmationDialog("Delete this entry and associated history?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    if let entry = deleting {
                        Button("Delete entry and associated history", role: .destructive) {
                            deleting = nil; saving = true
                            Task {
                                defer { saving = false }
                                do { try await store.delete(sourceID: entry.id, invalidate: invalidate); message = "Entry and associated history deleted." }
                                catch { message = "Deletion could not finish. Retry deletion to remove associated history: \(error.localizedDescription)" }
                            }
                        }
                    }
                    Button("Keep entry", role: .cancel) { deleting = nil }
                } message: { Text("This also removes any dependent cues, feedback learning, and reviews. This cannot be undone.") }
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                HStack(spacing: 12) {
                    PhosphorIcon(listeningActive ? "mic.fill" : "mic")
                        .foregroundStyle(listeningActive ? VocaTheme.foreground : VocaTheme.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Band listening").font(.subheadline.weight(.medium))
                        Text(listeningStatus).font(.caption).foregroundStyle(VocaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    if !listeningBusy {
                        Button(action: startListening) { PhosphorIcon("play.fill") }
                            .buttonStyle(VocaSecondaryButton())
                            .accessibilityLabel(captureEnabled ? "Resume listening" : "Start listening")
                            .disabled(!bandConnected || !store.loaded || saving)
                    }
                    if listeningBusy || captureEnabled {
                        Button { Task { await stopListening() } } label: { PhosphorIcon("stop.fill") }
                            .buttonStyle(VocaSecondaryButton()).accessibilityLabel("Stop listening")
                    }
                }
            }
            Text("Double-tap your band to listen. Get everyone’s consent; nearby voices are included.")
                .font(.caption).foregroundStyle(VocaTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("About listening") {
                Text("Useful details collect below for your approval before they can be used in a cue. Full transcripts are temporary; audio is never saved. The band’s blue light stays on while listening.")
                    .font(.footnote).foregroundStyle(VocaTheme.secondary).padding(.top, 8)
                if !bandConnected {
                    Text("Your assigned band reconnects when nearby. Check its connection in Settings.")
                        .font(.footnote).foregroundStyle(VocaTheme.secondary).padding(.top, 8)
                }
            }.font(.caption).foregroundStyle(VocaTheme.secondary)
        }.vocaSurface()
    }

    private var addMemorySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your memory").font(.headline)
                        TextField("I’m learning to grow herbs", text: $text, axis: .vertical)
                            .lineLimit(3...7).focused($editing)
                            .padding(16).background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VocaTheme.secondary, lineWidth: 1))
                            .accessibilityLabel("Your memory, up to 240 characters")
                        Text("\(text.count) / 240 characters").font(.caption.monospacedDigit()).foregroundStyle(VocaTheme.secondary)
                    }
                    Toggle("Use this memory in my cues", isOn: $approved)
                    Text("Save only a detail about yourself that you approve sharing.")
                        .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                    if let formError {
                        PhosphorLabel(formError, icon: "exclamationmark.circle").font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Save memory") {
                        do {
                            guard approved else { throw MemoryStore.Failure.confirmation }
                            try store.addMemory(text: text)
                            text = ""; approved = false; editing = false; formError = nil
                            message = "Memory saved on this iPhone."; addingMemory = false
                            UIAccessibility.post(notification: .announcement, argument: message)
                        } catch {
                            formError = error.localizedDescription
                            editing = true
                            UIAccessibility.post(notification: .announcement, argument: formError)
                        }
                    }.buttonStyle(VocaPrimaryButton()).disabled(!store.loaded || saving)
                }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Add memory").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addingMemory = false } } }
        }
    }

    private func entryView(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.evidence.text).font(.body).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    PhosphorLabel(entry.kind == .personalMemory ? "Approved by you" : entry.evidence.speaker == "wearer" ? "Your words" : entry.evidence.speaker == "other" ? "Someone else’s words" : "Speaker unknown",
                          icon: entry.kind == .personalMemory ? "checkmark" : "quote.bubble")
                    if let date = entry.evidence.utteredAt {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    } else if entry.kind == .dialogue { Text("Time unknown") }
                }.font(.caption).foregroundStyle(VocaTheme.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button("Delete entry", role: .destructive) { deleting = entry }
                } label: {
                    PhosphorIcon("ellipsis").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Options for \(entry.evidence.text)").disabled(saving)
            }
            if entry.capturedSource != nil {
                Text("From band audio · original speaker unknown · confirmed by you")
                    .font(.caption).foregroundStyle(VocaTheme.secondary)
            }
        }.vocaSurface()
    }
}

private struct MemorySuggestionCard: View {
    let suggestion: MemorySuggestion
    let decide: (Bool, Bool) -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                PhosphorIcon("quote.bubble")
                Text(suggestion.capturedAt, format: .dateTime.month().day().hour().minute())
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(VocaTheme.secondary)
            Text(suggestion.text).font(.body.weight(.medium)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if suggestion.hasGap {
                Text("Capture may be incomplete; check this detail.")
                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { suggestionActions.fixedSize() }
                VStack(alignment: .leading, spacing: 12) { suggestionActions }
            }
        }.vocaSurface()
            .offset(x: reducedMotion ? 0 : offset)
            .simultaneousGesture(DragGesture(minimumDistance: 24)
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                        offset = min(120, max(-120, value.translation.width))
                    }
                }
                .onEnded { value in
                    let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                    if horizontal && value.translation.width < -100 { decide(false, false) }
                    if horizontal && value.translation.width > 100 { decide(true, true) }
                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.2)) { offset = 0 }
                })
            .accessibilityAction(named: "Discard suggestion") { decide(false, false) }
            .accessibilityAction(named: "Approve memory") { decide(true, true) }
    }

    @ViewBuilder private var suggestionActions: some View {
        Button { decide(true, true) } label: {
            PhosphorLabel("Approve", icon: "checkmark")
        }.buttonStyle(VocaPrimaryButton()).accessibilityLabel("Approve memory")
            .accessibilityHint("Confirms this detail is accurate and yours to share in a cue.")
        Button("Discard") { decide(false, false) }
            .buttonStyle(VocaSecondaryButton()).accessibilityLabel("Discard suggestion")
    }
}
