// swift-tools-version:5.9
// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

/// llama.cpp, as ggml-org's own prebuilt `llama.xcframework` — no source, no package graph
/// of its own. One build is pinned and moved deliberately: every build is a prerelease, and
/// the C API changes between them. Its module is `llama`, imported by `LocalLlamaRuntime.swift`
/// alone, which only the SpeechTextLLM service and the SpeechTextEvaluation tool compile.
/// To move the pin, change the build and the checksum together (`swift package compute-checksum`
/// on the downloaded zip, or the release asset's `sha256:` digest) and rerun the rewrite evaluation.
let package = Package(
    name: "LlamaBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaBinary", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11696/llama-b11696-xcframework.zip",
            checksum: "556dfee9c19b62a6db6fb625d0f20d09ccca030ee3f75cf39ac09d0f25e5fe3d"
        ),
    ]
)
