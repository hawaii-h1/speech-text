// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - Speech (local models)

/// The Settings rows for the local speech tier: what this Mac is, which model it should
/// run, and one button per model to install, cancel or remove it.
///
/// Kept out of `MenuBarView.swift` so the onboarding flow can reuse the same rows rather
/// than growing a second copy of the install logic.
struct LocalSpeechModelsView: View {
    @Binding var selectedModelID: String
    @State private var store = LocalModelStore.shared
    @State private var capabilities = SystemCapabilities.current()

    private var recommended: LocalSTTModel? { recommendedLocalSTTModel(for: capabilities) }
    private var bestQuality: LocalSTTModel? { bestQualityLocalSTTModel(for: capabilities) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(capabilities.summary) · \(MacTier(capabilities).displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Recommended: \(localSTTRecommendationReason(for: capabilities))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(localSTTModels) { model in
            LocalSpeechModelRow(
                model: model,
                state: store.state(for: model.id),
                isSelected: selectedModelID == model.id,
                badge: ModelBadge(isRecommended: recommended?.id == model.id,
                                  isBestQuality: bestQuality?.id == model.id && bestQuality?.id != recommended?.id,
                                  isTooHeavy: !localModelFitsMemory(model.memoryFloorBytes, capabilities)),
                onSelect: { selectedModelID = model.id },
                onInstall: {
                    store.install(model)
                    // Installing is choosing: a user who clicks Download expects that model
                    // to be the one used, not to discover the picker still points elsewhere.
                    selectedModelID = model.id
                },
                onCancel: { store.cancelInstall(model) },
                onRemove: { store.remove(model) }
            )
        }

        if !store.hasAnyModel {
            Label("Download a model before dictating — until then recordings fail and are kept in History for a retry.",
                  systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !store.isInstalled(selectedModelID) {
            Label("The selected model isn't installed. Pick an installed one or download it.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            Text("Models are stored in Application Support · \(ByteCountFormatter.string(fromByteCount: store.installedBytes, countStyle: .file)) used")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show in Finder") {
                let url = LocalModelStore.modelsDirectory
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
            .disabled(!store.hasAnyModel)
        }
        .onAppear {
            store.refresh()
            capabilities = SystemCapabilities.current()
        }
    }
}

private struct LocalSpeechModelRow: View {
    let model: LocalSTTModel
    let state: LocalModelStore.InstallState
    let isSelected: Bool
    let badge: ModelBadge
    let onSelect: () -> Void
    let onInstall: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!state.isUsable)
            .help(state.isUsable ? "Use this model" : "Download it first")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                    Text(model.downloadSizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    badge
                }
                Text(model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let fraction) = state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
                if state == .optimizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Optimising for this Mac — first time only, can take several minutes. You can already dictate; the first result waits for this to finish.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            switch state {
            case .notInstalled, .failed:
                Button("Download", action: onInstall)
                    .controlSize(.small)
            case .downloading:
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            case .installed, .optimizing:
                Button("Remove", role: .destructive, action: onRemove)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Text (Ollama)

/// What Settings knows about the local Ollama daemon. Observed by the view; refreshed
/// on appear rather than polled, because a background poll of a port that is usually
/// closed would be work done for nobody.
@Observable
@MainActor
final class OllamaModelManager {
    static let shared = OllamaModelManager()

    private(set) var isRunning: Bool?
    private(set) var version: String?
    private(set) var installed: [OllamaInstalledModel] = []
    private(set) var pulls: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func refresh() async {
        version = await OllamaService.version()
        let running = version != nil
        isRunning = running
        installed = running ? ((try? await OllamaService.installedModels()) ?? []) : []
    }

    /// Ollama names a pulled `qwen3:8b` exactly that, but an untagged pull becomes
    /// `name:latest` — compare both ways so neither spelling reads as missing.
    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.name == id || $0.name == "\(id):latest" }
    }

    func pull(_ id: String, then select: @escaping () -> Void) {
        guard pulls[id] == nil else { return }
        pulls[id] = 0
        errors[id] = nil
        tasks[id] = Task { [weak self] in
            do {
                try await OllamaService.pull(model: id) { fraction in
                    Task { @MainActor [weak self] in
                        guard self?.pulls[id] != nil else { return }
                        self?.pulls[id] = fraction
                    }
                }
                await self?.finish(id, error: nil)
                select()
            } catch is CancellationError {
                await self?.finish(id, error: nil)
            } catch {
                await self?.finish(id, error: error.localizedDescription)
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    private func finish(_ id: String, error: String?) async {
        pulls[id] = nil
        tasks[id] = nil
        errors[id] = error
        await refresh()
    }
}

struct OllamaModelsView: View {
    @Binding var selectedModelID: String
    @AppStorage(SettingsKeys.ollamaBaseURL) private var baseURL = ""
    @State private var manager = OllamaModelManager.shared
    @State private var capabilities = SystemCapabilities.current()

    private var recommended: LocalLLMModel? { recommendedLocalLLMModel(for: capabilities) }
    private var bestQuality: LocalLLMModel? { bestQualityLocalLLMModel(for: capabilities) }
    /// Models too heavy for this Mac stay reachable but folded away: listing a 81 GB model
    /// first on an 8 GB MacBook Neo buries the three that actually fit.
    @State private var showHeavyModels = false

    private var fittingModels: [LocalLLMModel] {
        localLLMModels.filter { localModelFitsMemory($0.memoryFloorBytes, capabilities) }
    }
    private var heavyModels: [LocalLLMModel] {
        localLLMModels.filter { !localModelFitsMemory($0.memoryFloorBytes, capabilities) }
    }

    /// Catalogue models first, then anything else the user already pulled — the daemon
    /// is theirs, and a model they chose outside this app is still a valid choice.
    private var otherInstalled: [OllamaInstalledModel] {
        manager.installed.filter { installed in
            !localLLMModels.contains { $0.id == installed.name || "\($0.id):latest" == installed.name }
        }
    }

    var body: some View {
        switch manager.isRunning {
        case nil:
            HStack {
                ProgressView().controlSize(.small)
                Text("Looking for Ollama…").font(.caption).foregroundStyle(.secondary)
            }
            .task { await manager.refresh() }
        case .some(false):
            VStack(alignment: .leading, spacing: 6) {
                Label("Ollama isn't running on this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                // Ollama is a separate app the user installs — this one cannot install it
                // for them without shipping or downloading an executable, which is exactly
                // what the project decided not to do. After that, models are one click.
                Text("Local AI runs through Ollama, a free app that manages the models. Install it once, then download a model here with one click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Get Ollama…") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                    }
                    Button("Check Again") { Task { await manager.refresh() } }
                }
                .controlSize(.small)
            }
        case .some(true):
            Text("\(capabilities.summary) · \(MacTier(capabilities).displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if recommended == nil {
                Text("Not enough free memory or disk for any of the suggested models.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(fittingModels) { model in catalogRow(model) }

            if !heavyModels.isEmpty {
                DisclosureGroup("Models too heavy for this Mac (\(heavyModels.count))", isExpanded: $showHeavyModels) {
                    ForEach(heavyModels) { model in catalogRow(model) }
                }
                .font(.caption)
            }

            ForEach(otherInstalled) { model in
                ollamaRow(id: model.name, title: model.name, detail: "Already in Ollama.",
                          size: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file),
                          badge: ModelBadge())
            }

            if selectedModelID.isEmpty || !manager.isInstalled(selectedModelID) {
                Label("Download or pick a model — until then AI mode pastes the raw transcription.",
                      systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        TextField("Ollama address", text: $baseURL, prompt: Text(ollamaDefaultBaseURL))
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await manager.refresh() } }
    }

    private func catalogRow(_ model: LocalLLMModel) -> some View {
        let outdated = manager.version.map { !ollamaVersion($0, isAtLeast: model.minimumOllamaVersion) } ?? false
        return ollamaRow(id: model.id, title: model.displayName, detail: model.summary,
                  size: model.downloadSizeDescription,
                  requiredUpdate: outdated ? model.minimumOllamaVersion : nil,
                  badge: ModelBadge(isRecommended: recommended?.id == model.id,
                                    isBestQuality: bestQuality?.id == model.id && bestQuality?.id != recommended?.id,
                                    isTooHeavy: !localModelFitsMemory(model.memoryFloorBytes, capabilities)))
    }

    @ViewBuilder
    private func ollamaRow(id: String, title: String, detail: String, size: String,
                           requiredUpdate: String? = nil, badge: ModelBadge) -> some View {
        let installed = manager.isInstalled(id)
        HStack(alignment: .top, spacing: 8) {
            Button { selectedModelID = id } label: {
                Image(systemName: selectedModelID == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedModelID == id ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!installed)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    Text(size).font(.caption).foregroundStyle(.secondary)
                    badge
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let requiredUpdate {
                    Text("Needs Ollama \(requiredUpdate) or newer — this Mac has \(manager.version ?? "an older one"). An older Ollama downloads the model and then cannot run it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = manager.pulls[id] {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                }
                if let error = manager.errors[id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if manager.pulls[id] != nil {
                Button("Cancel") { manager.cancel(id) }.controlSize(.small)
            } else if !installed, requiredUpdate != nil {
                Button("Update Ollama…") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                }
                .controlSize(.small)
            } else if !installed {
                Button("Download") {
                    manager.pull(id) { Task { @MainActor in selectedModelID = id } }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Badge

/// The one tag a model row carries. Recommended and best quality are the tier's two
/// picks; "too heavy" is a warning, not a lock — someone with a Mac that runs nothing
/// else may know better than a RAM floor.
private struct ModelBadge: View {
    var isRecommended = false
    var isBestQuality = false
    var isTooHeavy = false

    var body: some View {
        if isRecommended {
            tag("Recommended", Color.accentColor)
        } else if isBestQuality {
            tag("Best quality", .purple)
        } else if isTooHeavy {
            tag("Too heavy for this Mac", .orange)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}
