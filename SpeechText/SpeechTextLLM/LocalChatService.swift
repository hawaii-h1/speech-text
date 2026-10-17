// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The SpeechTextLLM service: llama.cpp in a process of its own, answering the app over
/// XPC (`LocalChatServiceProtocol`). One model in memory, one completion at a time —
/// `LocalLlamaRuntime` is an actor and runs its jobs in order.
///
/// Idle, the service exits: the weights are mapped from disk and the KV cache is
/// gigabytes, which a menu bar app has no business holding between dictations. launchd
/// starts it again on the next message, and the next rewrite pays the load.
final class LocalChatService: NSObject, LocalChatServiceProtocol, @unchecked Sendable {
    static let shared = LocalChatService()

    /// As long as Ollama kept a model loaded by default.
    static let idleExitSeconds: TimeInterval = 300

    private let runtime = LocalLlamaRuntime()
    private let lock = NSLock()
    private var running = 0
    private var idleTimer: DispatchSourceTimer?

    func complete(_ request: Data, reply: @escaping (Data?, String?) -> Void) {
        guard let request = try? JSONDecoder().decode(LocalChatRequest.self, from: request) else {
            reply(nil, "The request could not be read."); return
        }
        begin()
        Task {
            defer { self.end() }
            do {
                let load = try await self.load(request)
                let completion = try await runtime.complete(system: request.system, user: request.user,
                                                            maxTokens: request.maxTokens)
                let response = LocalChatResponse(
                    reply: completion.reply, promptTokens: completion.promptTokens,
                    outputTokens: completion.outputTokens, loadSeconds: load,
                    promptSeconds: completion.promptSeconds, generationSeconds: completion.generationSeconds,
                    finished: completion.finished)
                reply(try JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func prewarm(_ request: Data, reply: @escaping (String?) -> Void) {
        guard let request = try? JSONDecoder().decode(LocalChatRequest.self, from: request) else {
            reply("The request could not be read."); return
        }
        begin()
        Task {
            defer { self.end() }
            do {
                _ = try await self.load(request)
                try await runtime.cache(systems: request.prefixes ?? [])
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func cancel() { runtime.cancel() }

    func unload(reply: @escaping () -> Void) {
        Task { await runtime.unload(); reply() }
    }

    /// Refuses a model the Mac cannot hold: the weights plus room for the context and
    /// macOS. A load past that does not fail — it pages, and the rewrite takes minutes.
    private func load(_ request: LocalChatRequest) async throws -> Double {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: request.modelPath))?[.size] as? UInt64 ?? 0
        guard bytes > 0 else { throw LlamaError.loadFailed(request.modelPath) }
        let headroom: UInt64 = 3 * 1_073_741_824
        guard ProcessInfo.processInfo.physicalMemory >= bytes + headroom else { throw LocalChatServiceError.notEnoughMemory }
        return try await runtime.load(path: request.modelPath, family: request.family,
                                      contextLength: request.contextLength)
    }

    // MARK: - Idle exit

    private func begin() {
        lock.withLock {
            running += 1
            idleTimer?.cancel()
            idleTimer = nil
        }
    }

    private func end() {
        lock.withLock {
            running -= 1
            guard running == 0 else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + Self.idleExitSeconds)
            timer.setEventHandler { [weak self] in
                guard let self, self.lock.withLock({ self.running == 0 }) else { return }
                // Freed first: ggml asserts at exit while Metal still holds a model.
                self.runtime.unloadNow()
                exit(0)
            }
            idleTimer = timer
            timer.resume()
        }
    }
}

enum LocalChatServiceError: LocalizedError {
    case notEnoughMemory

    var errorDescription: String? {
        "This Mac doesn't have the memory for this model. Choose a smaller one in Settings › AI Rewrite."
    }
}

final class LocalChatServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LocalChatServiceProtocol.self)
        connection.exportedObject = LocalChatService.shared
        connection.resume()
        return true
    }
}
