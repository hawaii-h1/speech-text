// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - First run

/// The steps of the setup window, in order. The raw values are what `onboardingStep`
/// stores, so a window closed half-way opens where it was left.
enum OnboardingStep: String, CaseIterable, Comparable {
    case welcome
    case speech
    case ai
    case permissions
    case tryIt = "try"
    case done

    /// The five the step bar names; Done is the Try it step's second state, not a stop.
    static let named: [OnboardingStep] = [.welcome, .speech, .ai, .permissions, .tryIt]

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .speech: "Speech"
        case .ai: "AI"
        case .permissions: "Permissions"
        case .tryIt, .done: "Try it"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.index < rhs.index }
}

/// Whether the setup window opens at launch.
///
/// Only new users see it. There was no first-run marker before it existed, so an install
/// that predates it is recognised by what it already stored: a login-item registration,
/// or any setting that crosses a rename (which is also how a renamed install is caught,
/// once `adoptPreRenameDefaults()` has carried its settings over). Such a user is marked
/// done and never shown a flow for a setup they finished long ago.
enum OnboardingGate: Equatable {
    case show
    /// An existing install: record setup as done, show nothing.
    case markCompleted
    case skip

    static func decide(completed: Bool?, hasUsedTheAppBefore: Bool) -> OnboardingGate {
        switch completed {
        case true?: .skip
        case false?: .show
        case nil: hasUsedTheAppBefore ? .markCompleted : .show
        }
    }
}

// MARK: - The online services setup offers

/// A card on setup's Speech step: the service, the engine choosing it saves, and its words.
struct SpeechServiceCard {
    let service: Provider
    let engine: STTProviderType
    let title: String
    let subtitle: String
    let detail: String
    /// The card promises the words while speaking, so choosing it saves the provider's
    /// realtime model; otherwise the stored model is left as it is.
    let promisesLiveWords: Bool

    /// The model choosing the card saves, or nil to leave the stored one.
    var savedModel: String? {
        promisesLiveWords ? sttModels(of: service).first(where: \.isRealtime)?.id : nil
    }
}

/// A card on setup's AI step: the service, the AI Rewrite pick choosing it saves, and its words.
struct AIServiceCard {
    let service: Provider
    let pick: LLMProviderType
    let title: String
    let subtitle: String
    let recommended: Bool
}

/// Which online services get a card in setup — the maintainer's choice, not every
/// provider — in card order. Every service setup can hold comes from one of these lists,
/// so the look-ups below find a card; the first card is what a stored value that should
/// never have selected anything else falls back to.
enum SetupCards {
    static let speech: [SpeechServiceCard] = [
        SpeechServiceCard(service: .groq, engine: .groq, title: "Groq", subtitle: "Free plan",
                          detail: "The same key also turns on AI text polish.", promisesLiveWords: false),
        SpeechServiceCard(service: .elevenLabs, engine: .elevenlabs, title: "ElevenLabs", subtitle: "Paid",
                          detail: "Shows your words live as you speak.", promisesLiveWords: true),
        SpeechServiceCard(service: .openAI, engine: .openai, title: "OpenAI", subtitle: "Paid",
                          detail: "Shows your words live too. The same key also turns on AI text polish.",
                          promisesLiveWords: true),
    ]

    static let ai: [AIServiceCard] = [
        AIServiceCard(service: .groq, pick: .groq, title: "Groq", subtitle: "Free plan", recommended: true),
        AIServiceCard(service: .anthropic, pick: .anthropic, title: "Claude", subtitle: "Anthropic · Paid",
                      recommended: false),
        AIServiceCard(service: .openAI, pick: .openai, title: "ChatGPT", subtitle: "OpenAI · Paid", recommended: false),
    ]

    /// The Speech card for a service, else the first.
    static func speech(for service: Provider) -> SpeechServiceCard {
        speech.first { $0.service == service } ?? speech[0]
    }

    /// The AI card for a service, else the first.
    static func ai(for service: Provider) -> AIServiceCard {
        ai.first { $0.service == service } ?? ai[0]
    }

    /// The card setup opens on when run again with this engine stored; nil for an engine
    /// with no card (Apple, the Mac).
    static func speechCard(reopening engine: STTProviderType) -> SpeechServiceCard? {
        speech.first { $0.engine == engine }
    }
}

/// The order Settings › API Keys lists the providers with a key in: the speech step's
/// first, as a dictation runs, then AI Rewrite's only.
enum APIKeyPage {
    static var order: [Provider] {
        Provider.allCases.filter { $0.descriptor.roles.contains(.speech) }
            + Provider.allCases.filter { !$0.descriptor.roles.contains(.speech) }
    }
}

enum KeyVerdict: Equatable {
    case valid
    case invalid
    /// No answer about the key: offline, or the service is down. The user may go on.
    case unreachable
}

// MARK: - The disk image it came in

/// A disk image macOS has mounted, as `hdiutil info -plist` describes it: the `.dmg` file
/// and where its volume is.
struct MountedDiskImage: Equatable {
    let imagePath: String
    let mountPoint: String

    /// Every mounted image that has a volume. An image attached without one (a raw
    /// device, a partition map) has no mount point and is left out.
    static func parse(hdiutilInfo data: Data) -> [MountedDiskImage] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
            else { return nil }
            return MountedDiskImage(imagePath: path, mountPoint: mount)
        }
    }
}

/// Where the running copy of the app is, relative to the disk image it was downloaded in.
///
/// A drag into Applications is a Finder copy, and nothing runs when it finishes — so the
/// app cannot launch itself after one. What it can do is recognise the two states around
/// that copy: opened straight from the image, where it has to move itself first or it
/// stops working the moment the image is ejected. The image, once the app is installed,
/// is the user's to eject and throw away.
enum InstallLocation: Equatable {
    /// Running from inside a mounted image. `image` is nil when that is known only from
    /// App Translocation's path and no mounted image carries the app.
    case inDiskImage(MountedDiskImage?)
    case installed

    /// `appName` is the bundle's name without `.app`. An image counts as this app's when
    /// its file or its volume is named for it ("SpeechText-0.9.0.dmg", "SpeechText 0.9.0"):
    /// looking inside the volume for the app would be a file read on a mounted volume,
    /// which macOS may answer with a privacy prompt — at launch.
    ///
    /// A quarantined app opened from an image does not run from `/Volumes/…`: macOS
    /// translocates it to a random read-only path under `AppTranslocation`, and that path
    /// names no volume. So a translocated app is matched to the image that carries it.
    /// An app run from anywhere else (Xcode's build folder, `~/Applications`) counts as
    /// installed — a development build must never be asked to move.
    static func decide(bundlePath: String, appName: String, images: [MountedDiskImage]) -> InstallLocation {
        func carriesThisApp(_ image: MountedDiskImage) -> Bool {
            [image.imagePath, image.mountPoint].contains {
                ($0 as NSString).lastPathComponent.lowercased().hasPrefix(appName.lowercased())
            }
        }
        func isInside(_ image: MountedDiskImage) -> Bool {
            let mount = image.mountPoint.hasSuffix("/") ? image.mountPoint : image.mountPoint + "/"
            return bundlePath.hasPrefix(mount)
        }
        if let image = images.first(where: isInside) {
            return .inDiskImage(image)
        }
        if bundlePath.contains("/AppTranslocation/") {
            return .inDiskImage(images.first(where: carriesThisApp))
        }
        return .installed
    }
}
