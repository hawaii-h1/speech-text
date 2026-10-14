// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// Settings › Speech to text and Settings › AI Rewrite: the same question setup asks —
// on this Mac, or an online service — answered with the same two cards, and under them
// the choices as rows that say what each one is. A row commits a choice only when it can
// work: a service without a key opens for its key instead of being selected, so a tap in
// Settings never leaves the next dictation failing.

/// Where a step runs: on this Mac, or at an online service.
enum EnginePlace: Hashable {
    case thisMac, online
}

/// The two cards at the top of both pages. Which one is open is the page's own state; the
/// card holding what is in use says so.
struct EnginePlaceCards: View {
    @Binding var place: EnginePlace
    let inUse: EnginePlace
    let macFacts: String
    let onlineFacts: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SetupChoiceCard(glyph: .mac, name: "On this Mac", badge: inUse == .thisMac ? "In use" : nil,
                            facts: macFacts, isSelected: place == .thisMac) { place = .thisMac }
            SetupChoiceCard(glyph: .cloud, name: "Online service", badge: inUse == .online ? "In use" : nil,
                            facts: onlineFacts, isSelected: place == .online) { place = .online }
        }
        .padding(4)
    }
}

/// A choice under its service's row — a model, or the key — indented to the row's text.
private struct NestedUnderRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
    }
}

private func hasKey(_ service: Provider) -> Bool {
    guard let key = service.descriptor.apiKey else { return true }
    return !APIKeyStore.shared.value(for: key.settingsKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func keyBinding(_ service: Provider) -> Binding<String> {
    let name = service.descriptor.apiKey?.settingsKey ?? ""
    return Binding(get: { APIKeyStore.shared.value(for: name) },
                   set: { APIKeyStore.shared.set($0, for: name) })
}

/// "Recommended for your M1 Pro, 32 GB".
func macDescription(_ caps: SystemCapabilities) -> String {
    let chip = caps.chipName.replacingOccurrences(of: "Apple ", with: "")
    return "\(chip), \(Int(caps.memoryGB.rounded())) GB"
}

// MARK: - Words for the choices

/// What each local speech model is, in the words of someone choosing one.
func speechModelLine(_ model: LocalSTTModel) -> String {
    switch model.id {
    case "openai_whisper-large-v3-v20240930": "As accurate as Turbo, about 30% slower. Needs 24 GB of memory."
    case parakeetV3ModelID: "Great for English and Ukrainian, and the quickest to answer."
    case "openai_whisper-large-v3-v20240930_turbo_632MB": "Great for English and Ukrainian. Slower to answer than Parakeet."
    case "openai_whisper-small_216MB": "Great for English. Makes mistakes in Ukrainian."
    case "openai_whisper-base": "Good for English. Makes mistakes in Ukrainian."
    case "openai_whisper-tiny": "Many mistakes. Only for a quick test."
    default: model.summary
    }
}

func speechModelName(_ model: LocalSTTModel) -> String {
    model.id == "openai_whisper-large-v3-v20240930_turbo_632MB" ? "Whisper Turbo" : model.displayName
}

/// An online speech model's name in a row, without the catalogue's picker suffix
/// ("— live text"), which the line under it says in words.
func onlineSpeechModelName(_ model: STTModelDescriptor) -> String {
    model.displayName.components(separatedBy: " — ").first ?? model.displayName
}

func onlineSpeechModelLine(_ model: STTModelDescriptor) -> String {
    switch model.id {
    case "whisper-large-v3-turbo": "Fast and accurate. Text appears when you stop."
    case "whisper-large-v3": "A little more careful on hard audio, a little slower."
    case "scribe_v2": "Text appears when you stop."
    case elevenLabsRealtimeModel: "Words appear as you speak."
    case "gpt-transcribe": "Text appears when you stop."
    case "gpt-4o-mini-transcribe": "Cheaper, a little less accurate."
    case openAIRealtimeSTTModel: "Words appear as you speak."
    default: model.isRealtime ? "Words appear as you speak." : "Text appears when you stop."
    }
}

/// What each online speech service is good at.
func onlineSpeechServiceLine(_ service: Provider) -> String {
    switch service {
    case .groq: "Fast Whisper. Text appears when you stop."
    case .elevenLabs: "Strongest on accents and noise. Can show words as you speak."
    case .openAI: "Can show words as you speak. Its key works for AI Rewrite too."
    default: service.displayName
    }
}

/// A chat model's name in a row, without the catalogue's picker notes ("(fastest)",
/// "— balanced"), which the line under it says in words.
func chatModelName(_ model: ChatModelDescriptor) -> String {
    let name = model.displayName.components(separatedBy: " — ").first ?? model.displayName
    return name.replacingOccurrences(of: #" \((fastest|preview)\)$"#, with: "", options: .regularExpression)
}

func chatModelLine(_ model: ChatModelDescriptor) -> String {
    switch model.id {
    case "openai/gpt-oss-120b": "Clean text in about a second."
    case "openai/gpt-oss-20b": "The fastest, a little less careful."
    case "qwen/qwen3.8-27b", "minimaxai/minimax-m2.7": "A preview — Groq may withdraw it."
    case "claude-sonnet-5": "Fast, and writes well."
    case "claude-opus-5": "Writes best. Slower, and costs more."
    case "claude-haiku-4-5": "The fastest."
    case "gpt-5.6-luna": "The fastest."
    case "gpt-5.6-terra": "Balanced."
    case "gpt-5.6-sol": "The flagship. Slower, and costs more."
    default: ""
    }
}

func onlineAIServiceLine(_ service: Provider) -> String {
    switch service {
    case .groq: "Fast, with a free plan. Its key works for speech too."
    case .anthropic: "Claude. Careful writing, paid."
    case .openAI: "ChatGPT's models, paid. Its key works for speech too."
    default: service.displayName
    }
}

/// What each local chat model is, in a line.
func aiModelLine(_ model: LocalLLMModel, heavy: Bool) -> String {
    let line = switch model.id {
    case "gemma4:12b": "Clean text in 2–4 seconds."
    case "qwen3.8:27b": "Writes best, but takes 5–14 seconds."
    case "qwen3.5:9b": "A step behind Gemma 4 12B, a little lighter."
    case "qwen3.5:4b": "Works, with some mistakes."
    case "qwen3.5:2b": "Many mistakes in Ukrainian. Not recommended."
    case "qwen3.5:0.8b": "Not recommended for Ukrainian."
    case "gemma4:26b": "Fast and clean."
    case "gemma4:31b": "Strong writing, slower."
    case "qwen3.6:35b-a3b": "Big-model knowledge at small-model speed."
    case "gpt-oss:120b": "OpenAI's open model."
    case "qwen3.5:122b": "The largest model for a Mac."
    default: model.summary
    }
    guard heavy else { return line }
    return "\(line) Needs \(Int((Double(model.memoryFloorBytes) / 1_073_741_824).rounded())) GB of memory."
}

/// Apple's recogniser, as a row beside the downloaded models.
let appleDictationLine = "Built into macOS, nothing to download. Words appear as you speak, but not every language works on-device — Ukrainian among them."

// MARK: - Speech to text

struct SpeechEngineSettings: View {
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.localSTTModel) private var localModelID = Provider.local.defaultSpeechModel
    // Each service's stored model, observed so the rows follow a pick.
    @AppStorage(SettingsKeys.groqModel) private var groqModel = Provider.groq.defaultSpeechModel
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = Provider.elevenLabs.defaultSpeechModel
    @AppStorage(SettingsKeys.openAISTTModel) private var openAIModel = Provider.openAI.defaultSpeechModel

    @State private var place: EnginePlace
    /// A service opened for its key without being selected.
    @State private var opened: Provider?
    @State private var store = LocalModelStore.shared
    @State private var capabilities = SystemCapabilities.current()
    /// A model being downloaded to be used: the engine switches to it once it is usable,
    /// never before — a dictation meanwhile would fail.
    @State private var waitingFor: String?
    /// The model in use, about to be removed — asked first.
    @State private var removing: LocalSTTModel?

    init() {
        let stored = STTProviderType(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) ?? "") ?? .apple
        _place = State(initialValue: Self.place(of: stored))
    }

    private static func place(of engine: STTProviderType) -> EnginePlace {
        engine == .apple || engine == .local ? .thisMac : .online
    }

    private var engine: STTProviderType { STTProviderType(rawValue: sttProvider) ?? .apple }

    var body: some View {
        EnginePlaceCards(
            place: $place, inUse: Self.place(of: engine),
            macFacts: capabilities.isAppleSilicon
                ? "Private and free. Your voice stays on your Mac, and works offline."
                : "Private and free, but slow on this Mac.",
            onlineFacts: "Works on any Mac. Needs internet and an account; your recording is sent to the service.")

        switch place {
        case .thisMac: thisMac
        case .online: online
        }
    }

    // MARK: On this Mac

    private var recommended: LocalSTTModel? { recommendedLocalSTTModel(for: capabilities) }
    private var bestQuality: LocalSTTModel? { bestQualityLocalSTTModel(for: capabilities) }

    private var thisMac: some View {
        SettingsGroup(title: "Models on this Mac", trailing: AnyView(
            Text("For your \(macDescription(capabilities))")
                .font(.system(size: 11.5))
                .foregroundStyle(SetupColor.label2)), inset: 5) {
            ForEach(localSTTModels) { model in
                localRow(model)
            }
            SetupRow(title: "Apple Dictation", subtitle: "Built in", detail: appleDictationLine,
                     isSelected: engine == .apple) { sttProvider = STTProviderType.apple.rawValue }
            HStack {
                Text(store.hasAnyModel
                     ? "\(ByteCountFormatter.string(fromByteCount: store.installedBytes, countStyle: .file)) of models on this Mac"
                     : "No models downloaded yet")
                Spacer()
                if store.hasAnyModel {
                    Button("Show in Finder") {
                        let url = LocalModelStore.modelsDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(SetupColor.label2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            store.refresh()
            capabilities = SystemCapabilities.current()
        }
        .onChange(of: waitingIsUsable) { _, usable in
            guard usable, let id = waitingFor else { return }
            waitingFor = nil
            localModelID = id
            sttProvider = STTProviderType.local.rawValue
        }
        .confirmationDialog("Remove \(removing.map(speechModelName) ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let model = removing { remove(model) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It is the model in use. Dictation switches to \(fallbackName) until you pick another.")
        }
    }

    private var waitingIsUsable: Bool {
        waitingFor.map { store.state(for: $0).isUsable } ?? false
    }

    /// What a removed model in use gives way to: another one on this Mac, else Apple's.
    private var fallback: LocalSTTModel? {
        localSTTModels.first { $0.id != removing?.id && store.state(for: $0.id).isUsable }
    }

    private var fallbackName: String { fallback.map(speechModelName) ?? "Apple Dictation" }

    private func remove(_ model: LocalSTTModel) {
        let inUse = engine == .local && localModelID == model.id
        let next = fallback
        store.remove(model)
        guard inUse else { return }
        if let next {
            localModelID = next.id
        } else {
            sttProvider = STTProviderType.apple.rawValue
        }
    }

    private func localRow(_ model: LocalSTTModel) -> some View {
        let state = store.state(for: model.id)
        let badge: SetupBadge? = if recommended?.id == model.id {
            SetupBadge(text: "Recommended", kind: .recommended)
        } else if bestQuality?.id == model.id {
            SetupBadge(text: "Best quality", kind: .quality)
        } else if !localModelFitsMemory(model.memoryFloorBytes, capabilities) {
            SetupBadge(text: "Too heavy for this Mac", kind: .warn)
        } else {
            nil
        }
        return SetupRow(title: speechModelName(model), subtitle: model.downloadSizeDescription, badge: badge,
                        detail: speechModelLine(model),
                        isSelected: engine == .local && localModelID == model.id,
                        action: { pickLocal(model) }) {
            HStack(spacing: 8) {
                switch state {
                case .notInstalled:
                    Text("Not downloaded").rowNote()
                case .downloading(let fraction):
                    SetupProgressBar(fraction: fraction).frame(maxWidth: 160)
                    Text("Downloading · \(Int(fraction * 100))%" + (waitingFor == model.id ? " — used once it's ready" : ""))
                        .rowNote()
                    Button("Cancel") {
                        store.cancelInstall(model)
                        if waitingFor == model.id { waitingFor = nil }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                case .optimizing:
                    SetupProgressBar(fraction: nil).frame(maxWidth: 160)
                    Text("Getting ready for your Mac — first time only").rowNote()
                case .installed:
                    Text("✓ Downloaded").rowNote(ok: true)
                    Button("Remove") {
                        if engine == .local && localModelID == model.id { removing = model } else { remove(model) }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                case .failed(let message):
                    Text(message).rowNote(bad: true).lineLimit(2)
                    Button("Retry") { store.install(model) }.buttonStyle(SetupInlineLinkStyle())
                }
            }
            .padding(.top, 4)
        }
    }

    /// Choosing a model that is not on this Mac yet downloads it, and the engine switches
    /// to it once it is usable (`waitingFor`) — not before, since a dictation during the
    /// download would fail. Settings closed first, nothing switches; the row is tapped again.
    private func pickLocal(_ model: LocalSTTModel) {
        let state = store.state(for: model.id)
        guard state.isUsable else {
            if !state.isBusy { store.install(model) }
            waitingFor = model.id
            return
        }
        waitingFor = nil
        localModelID = model.id
        sttProvider = STTProviderType.local.rawValue
    }

    // MARK: Online

    private var online: some View {
        SettingsGroup(title: "Online services", inset: 5) {
            // Every cloud engine, not only the ones setup offers a card for; a card only
            // lends its words.
            ForEach(STTProviderType.allCases.filter { $0.vendor.descriptor.apiKey != nil }) { engine in
                serviceRow(SetupCards.speechCard(reopening: engine)
                    ?? SpeechServiceCard(service: engine.vendor, engine: engine, title: engine.vendor.displayName,
                                         subtitle: "", detail: "", promisesLiveWords: false))
            }
        }
    }

    private func storedModel(_ service: Provider) -> String {
        switch service {
        case .groq: groqModel
        case .elevenLabs: elevenLabsModel
        case .openAI: openAIModel
        default: service.defaultSpeechModel
        }
    }

    private func setStoredModel(_ id: String, for service: Provider) {
        switch service {
        case .groq: groqModel = id
        case .elevenLabs: elevenLabsModel = id
        case .openAI: openAIModel = id
        default: break
        }
    }

    @ViewBuilder
    private func serviceRow(_ card: SpeechServiceCard) -> some View {
        let selected = engine == card.engine
        let keyed = hasKey(card.service)
        SetupRow(title: card.title, subtitle: card.subtitle.isEmpty ? nil : card.subtitle,
                 badge: keyed ? nil : SetupBadge(text: "No key", kind: selected ? .warn : .quality),
                 detail: onlineSpeechServiceLine(card.service), isSelected: selected) {
            if keyed { sttProvider = card.engine.rawValue } else { opened = card.service }
        }
        if selected || opened == card.service {
            NestedUnderRow {
                ForEach(sttModels(of: card.service)) { model in
                    SetupRow(title: onlineSpeechModelName(model),
                             badge: model.id == card.service.defaultSpeechModel
                                ? SetupBadge(text: "Recommended", kind: .recommended) : nil,
                             detail: onlineSpeechModelLine(model),
                             isSelected: storedModel(card.service) == model.id, compact: true) {
                        setStoredModel(model.id, for: card.service)
                        if keyed { sttProvider = card.engine.rawValue }
                    }
                }
                // The provider's own note (what its server is asked to leave out) and the
                // selected model's (how a realtime stream falls back), from the catalogue.
                let note = [card.service.descriptor.speechModel?.caption,
                            sttModel(vendor: card.service, id: storedModel(card.service)).settingsNote]
                    .compactMap { $0 }.joined(separator: " ")
                if !note.isEmpty {
                    Text(note).rowNote()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
                SettingsKeyField(service: card.service, value: keyBinding(card.service), showsHeader: false)
                    .padding(.top, 6)
                if !selected && keyed {
                    Button("Use \(card.title)") { sttProvider = card.engine.rawValue }
                        .buttonStyle(SetupButtonStyle(kind: .primary, height: 28))
                        .padding(.top, 6)
                } else if !keyed {
                    Text(selected
                         ? "Dictations fail until you add a key."
                         : "Add a key to use \(card.title).")
                        .rowNote(bad: selected)
                }
            }
        }
    }
}

// MARK: - AI Rewrite

struct AIEngineSettings: View {
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.ollamaModel) private var ollamaModel = ""
    @AppStorage(SettingsKeys.groqLLMModel) private var groqModel = Provider.groq.defaultChatModel
    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = Provider.anthropic.defaultChatModel
    @AppStorage(SettingsKeys.openAIModel) private var openAIModel = Provider.openAI.defaultChatModel
    @AppStorage(SettingsKeys.ollamaBaseURL) private var baseURL = ""

    @State private var place: EnginePlace
    @State private var opened: Provider?
    @State private var manager = OllamaModelManager.shared
    @State private var capabilities = SystemCapabilities.current()
    @State private var showHeavyModels = false

    init() {
        let stored = LLMProviderType(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) ?? "") ?? .groq
        _place = State(initialValue: stored == .ollama ? .thisMac : .online)
    }

    private var pick: LLMProviderType { LLMProviderType(rawValue: llmProvider) ?? .groq }

    var body: some View {
        EnginePlaceCards(
            place: $place, inUse: pick == .ollama ? .thisMac : .online,
            macFacts: "Private and free, through Ollama — a free app you install once.",
            onlineFacts: "Fast on any Mac. Needs internet and an account; your text is sent to the service.")

        switch place {
        case .thisMac: thisMac
        case .online: online
        }
    }

    // MARK: On this Mac (Ollama)

    private var recommended: LocalLLMModel? { recommendedLocalLLMModel(for: capabilities) }
    private var bestQuality: LocalLLMModel? { bestQualityLocalLLMModel(for: capabilities) }

    private var thisMac: some View {
        SettingsGroup(title: "Models in Ollama", trailing: AnyView(
            Text("For your \(macDescription(capabilities))")
                .font(.system(size: 11.5))
                .foregroundStyle(SetupColor.label2)), inset: 5) {
            switch manager.isRunning {
            case nil:
                HStack(spacing: 8) { SetupSpinner(); Text("Looking for Ollama…").rowNote() }
                    .padding(10)
                    .task { await manager.refresh() }
            case .some(false):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ollama isn't running")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SetupColor.label)
                    // Ollama is a separate app the user installs — this one cannot install
                    // it without downloading an executable. After that, models are one click.
                    Text("AI Rewrite on this Mac runs through Ollama, a free app. Install it once, then pick a model here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SetupColor.label2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Get Ollama…") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                            .buttonStyle(SetupButtonStyle(kind: .primary, height: 28))
                        Button("Check Again") { Task { await manager.refresh() } }
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                    }
                }
                .padding(10)
            case .some(true):
                let fitting = localLLMModels.filter { localModelFitsMemory($0.memoryFloorBytes, capabilities) }
                let heavy = localLLMModels.filter { !localModelFitsMemory($0.memoryFloorBytes, capabilities) }
                ForEach(fitting) { ollamaRow($0, heavy: false) }
                ForEach(otherInstalled) { model in
                    SetupRow(title: model.name,
                             subtitle: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file),
                             detail: "Already in Ollama.", isSelected: pick == .ollama && ollamaModel == model.name) {
                        useOllama(model.name)
                    }
                }
                if !heavy.isEmpty {
                    Button(showHeavyModels ? "Hide models too heavy for this Mac"
                                           : "Show \(heavy.count) models too heavy for this Mac") {
                        withAnimation(.easeOut(duration: 0.2)) { showHeavyModels.toggle() }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    if showHeavyModels { ForEach(heavy) { ollamaRow($0, heavy: true) } }
                }
            }
            HStack(spacing: 8) {
                Text("Ollama address").rowNote()
                TextField("", text: $baseURL, prompt: Text(ollamaDefaultBaseURL).foregroundStyle(SetupColor.label3))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { Task { await manager.refresh() } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// Anything the user pulled into Ollama outside the catalogue: the daemon is theirs.
    private var otherInstalled: [OllamaInstalledModel] {
        manager.installed.filter { installed in
            !localLLMModels.contains { $0.id == installed.name || "\($0.id):latest" == installed.name }
        }
    }

    private func useOllama(_ id: String) {
        ollamaModel = id
        llmProvider = LLMProviderType.ollama.rawValue
    }

    private func ollamaRow(_ model: LocalLLMModel, heavy: Bool) -> some View {
        let installed = manager.isInstalled(model.id)
        let outdated = manager.version.map { !ollamaVersion($0, isAtLeast: model.minimumOllamaVersion) } ?? false
        let badge: SetupBadge? = if recommended?.id == model.id {
            SetupBadge(text: "Recommended", kind: .recommended)
        } else if bestQuality?.id == model.id {
            SetupBadge(text: "Best quality", kind: .quality)
        } else if heavy {
            SetupBadge(text: "Too heavy for this Mac", kind: .warn)
        } else {
            nil
        }
        return SetupRow(title: model.displayName, subtitle: model.downloadSizeDescription, badge: badge,
                        detail: aiModelLine(model, heavy: heavy),
                        isSelected: pick == .ollama && ollamaModel == model.id,
                        action: {
                            if installed { useOllama(model.id) }
                            else if !outdated, manager.pulls[model.id] == nil {
                                manager.pull(model.id) { Task { @MainActor in useOllama(model.id) } }
                            }
                        }) {
            HStack(spacing: 8) {
                if let fraction = manager.pulls[model.id] {
                    SetupProgressBar(fraction: fraction).frame(maxWidth: 160)
                    Text("Downloading · \(Int(fraction * 100))%").rowNote()
                    Button("Cancel") { manager.cancel(model.id) }.buttonStyle(SetupInlineLinkStyle())
                } else if installed {
                    Text("✓ Downloaded").rowNote(ok: true)
                } else if outdated {
                    Text("Needs Ollama \(model.minimumOllamaVersion) or newer").rowNote(bad: true)
                    Button("Update Ollama…") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                        .buttonStyle(SetupInlineLinkStyle())
                } else if let error = manager.errors[model.id] {
                    Text(error).rowNote(bad: true).lineLimit(2)
                } else {
                    Text("Not downloaded").rowNote()
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Online

    private var online: some View {
        SettingsGroup(title: "Online services", inset: 5) {
            ForEach(LLMProviderType.allCases.filter { $0.needsAPIKey }) { pick in
                serviceRow(SetupCards.ai.first { $0.pick == pick }
                    ?? AIServiceCard(service: pick.vendor, pick: pick, title: pick.vendor.displayName,
                                     subtitle: "", recommended: false))
            }
        }
    }

    private func storedModel(_ pick: LLMProviderType) -> String {
        switch pick {
        case .groq: groqModel
        case .anthropic: anthropicModel
        case .openai: openAIModel
        case .ollama: ollamaModel
        }
    }

    private func setStoredModel(_ id: String, for pick: LLMProviderType) {
        switch pick {
        case .groq: groqModel = id
        case .anthropic: anthropicModel = id
        case .openai: openAIModel = id
        case .ollama: ollamaModel = id
        }
    }

    @ViewBuilder
    private func serviceRow(_ card: AIServiceCard) -> some View {
        let selected = pick == card.pick
        let keyed = hasKey(card.service)
        SetupRow(title: card.title, subtitle: card.subtitle.isEmpty ? nil : card.subtitle,
                 badge: keyed ? nil : SetupBadge(text: "No key", kind: selected ? .warn : .quality),
                 detail: onlineAIServiceLine(card.service), isSelected: selected) {
            if keyed { llmProvider = card.pick.rawValue } else { opened = card.service }
        }
        if selected || opened == card.service {
            NestedUnderRow {
                ForEach(chatModels(of: card.pick), id: \.id) { model in
                    SetupRow(title: chatModelName(model),
                             badge: model.id == card.service.defaultChatModel
                                ? SetupBadge(text: "Recommended", kind: .recommended) : nil,
                             detail: chatModelLine(model).isEmpty ? nil : chatModelLine(model),
                             isSelected: storedModel(card.pick) == model.id, compact: true) {
                        setStoredModel(model.id, for: card.pick)
                        if keyed { llmProvider = card.pick.rawValue }
                    }
                }
                SettingsKeyField(service: card.service, value: keyBinding(card.service), showsHeader: false)
                    .padding(.top, 6)
                if !selected && keyed {
                    Button("Use \(card.title)") { llmProvider = card.pick.rawValue }
                        .buttonStyle(SetupButtonStyle(kind: .primary, height: 28))
                        .padding(.top, 6)
                } else if !keyed {
                    Text(selected
                         ? "AI Rewrite pastes your words as said until you add a key."
                         : "Add a key to use \(card.title).")
                        .rowNote(bad: selected)
                }
            }
        }
    }
}

private extension Text {
    func rowNote(ok: Bool = false, bad: Bool = false) -> some View {
        font(.system(size: 11, weight: ok ? .medium : .regular))
            .foregroundStyle(ok ? SetupColor.ok : bad ? SetupColor.danger : SetupColor.label2)
    }
}
