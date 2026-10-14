// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

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
