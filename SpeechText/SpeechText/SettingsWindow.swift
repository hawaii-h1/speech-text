// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - The Settings window

/// The Settings window: the setup window's frame — a glass rim with the green glow under
/// it — around a white card that holds a category sidebar and the page it picks. Like the
/// setup window it draws its own frame, so it is borderless and its traffic lights are
/// part of the drawing.
///
/// It is a window of our own rather than SwiftUI's `Settings` scene, because that scene
/// always wears a system title bar. `SpeechTextApp` keeps an empty `Settings` scene and
/// points the app menu's Settings… (⌘,) here instead.
@MainActor
final class SettingsWindow: NSWindow {
    static let size = NSSize(width: 820, height: 600)

    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        title = "SpeechText Settings"
        let host = NSHostingView(rootView: SettingsView(window: SetupWindowRef(self)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        // A clear window's shadow follows what is drawn, which exists only after a pass.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    override func close() {
        super.close()
        onClose()
    }

    /// ⌘W and ⌘M, which a borderless window does not get from a title bar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            if key == "w" { close(); return true }
            if key == "m" { miniaturize(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Categories

/// The sidebar's entries, in the order the sidebar lists them.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, speech, formatting, ai, apiKeys, permissions

    var id: String { rawValue }

    /// Three runs in the sidebar: the app itself; what happens to a dictation, in the
    /// order it happens; and what the app needs from the user and from macOS.
    static let groups: [[SettingsCategory]] = [
        [.general, .appearance],
        [.speech, .formatting, .ai],
        [.apiKeys, .permissions],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .speech: "Speech"
        case .formatting: "Formatting"
        // What the step does rather than what runs it: "AI" alone named the technology.
        case .ai: "AI Rewrite"
        case .apiKeys: "API Keys"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .speech: "waveform"
        case .formatting: "textformat"
        case .ai: "sparkles"
        case .apiKeys: "key"
        case .permissions: "lock.shield"
        }
    }

    /// The line under the page's title.
    var lead: String {
        switch self {
        case .general: "Your shortcuts, how SpeechText starts, and how it stays up to date."
        case .appearance: "How the recording overlay and the Record Window look."
        case .speech: "Turns what you say into text. Runs for every dictation."
        case .formatting: "Small fixes made to every transcript before it is pasted."
        case .ai: "Optional. Turns what you dictate into an email, a list, a translation — for the AI Recording shortcut and the ✨ toggle in the Record Window. What you say is the prompt: the model picks the matching preset and rewrites the text."
        case .apiKeys: "Only the keys your current choices use are shown."
        case .permissions: "What macOS lets SpeechText do."
        }
    }
}

// MARK: - Colours

enum SettingsColor {
    /// The card: white, as asked; the setup card's own dark grey in Dark Mode, where a
    /// white card would glare.
    static let background = Color.setup(0xFFFFFF, dark: 0x2A2A2C)
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory
    let window: SetupWindowRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupTrafficLights(onClose: { window.window?.close() },
                               onMinimize: { window.window?.miniaturize(nil) })
                .padding(.leading, 6)
                .padding(.top, 6)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsCategory.groups.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsCategory.groups[index]) { category in
                            SettingsSidebarItem(category: category, isSelected: selection == category) {
                                selection = category
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

private struct SettingsSidebarItem: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// The AI entry lights violet, as the setup window's AI step does.
    private var tint: SetupTint { category == .ai ? .violet : .green }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? AnyShapeStyle(LinearGradient(colors: tint.glyph, startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(SetupColor.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? .clear : SetupColor.panelBorder, lineWidth: 0.5))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: category.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isSelected ? tint.glyphInk : SetupColor.label2)
                    }
                Text(category.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SetupColor.label : SetupColor.label2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? SetupColor.panel : hovering ? SetupColor.panel.opacity(0.6) : .clear)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? SetupColor.panelBorder : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Page parts

/// A run of related settings on a grey panel, the way the setup window groups its rows.
/// `inset` is smaller for a radio list, whose `SetupRow`s carry their own padding.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    var inset: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SetupColor.label2)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, inset)
                .padding(.vertical, inset < 14 ? inset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(SetupColor.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SetupColor.panelBorder, lineWidth: 1))
        }
    }
}

/// One setting: its name and what it does on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SetupColor.label2)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 11)
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail, control: { EmptyView() })
    }
}

/// A hairline between two rows of a group.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SetupColor.separator).frame(height: 1)
    }
}

/// An explanation that belongs to the row above it but is too long to sit beside a control.
struct SettingsNote: View {
    let text: String
    var tone: Color = SetupColor.label2

    init(_ text: String, tone: Color = SetupColor.label2) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tone)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The switch the setup window uses: macOS' own, in the page's colour.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// "Ready" / "Needs an API key" beside a group's title.
struct SettingsStatus: View {
    let text: String
    let ok: Bool

    var body: some View {
        Text(ok ? "✓ \(text)" : "⚠︎ \(text)")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(ok ? SetupColor.ok : SetupColor.warn)
    }
}

/// An API key: which account it belongs to, where to get one, and the field — drawn like
/// the setup window's key field, with the value hidden.
struct SettingsKeyField: View {
    let service: SetupService
    @Binding var value: String
    var uses: String?
    /// The current choices use this key: its row says whether it is filled in.
    var inUse = false
    @FocusState private var focused: Bool
    @Environment(\.setupTint) private var tint

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.account)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(inUse ? SetupColor.label : SetupColor.label2)
                if inUse {
                    SettingsStatus(text: hasValue ? "Added" : "Needed", ok: hasValue)
                }
                Spacer(minLength: 0)
                Button(service.linkTitle) { NSWorkspace.shared.open(service.keysPage) }
                    .buttonStyle(SetupInlineLinkStyle())
                    .pointingHandCursor()
            }
            SecureField("", text: $value, prompt: Text("Paste your key here").foregroundStyle(SetupColor.label3))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .accessibilityLabel("\(service.account) key")
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(shape.fill(SetupColor.control))
                .overlay(shape.strokeBorder(focused ? tint.accent : SetupColor.panelBorder, lineWidth: focused ? 1.5 : 1))
                .background(shape.fill(tint.glow.opacity(focused ? 0.25 : 0)).padding(-3))
            if let uses {
                SettingsNote(uses)
            }
        }
        .padding(.vertical, 12)
    }

    private var hasValue: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A permission, drawn like the setup window's: an icon that turns green once granted.
struct SettingsPermissionRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 11)
                .fill(granted
                      ? AnyShapeStyle(LinearGradient(colors: SetupTint.green.glyph, startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(SetupColor.control))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(granted ? .clear : SetupColor.panelBorder, lineWidth: 1))
                .overlay(Image(systemName: symbol).font(.system(size: 16))
                    .foregroundStyle(granted ? SetupColor.phosphor : SetupColor.label2))
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupColor.label)
                Text(detail).font(.system(size: 12)).foregroundStyle(SetupColor.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if granted {
                Text("✓ Allowed").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SetupColor.ok).fixedSize()
            } else {
                control
            }
        }
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.3), value: granted)
    }
}

// MARK: - Skin previews

/// A radio row with a picture on its right — `SetupRow`'s look, for a choice that is
/// easier seen than described.
struct SettingsPreviewRow<Preview: View>: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview
    @Environment(\.setupTint) private var tint
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                if isSelected {
                    Circle().fill(tint.accent)
                    Circle().fill(tint.card).frame(width: 6, height: 6)
                } else {
                    Circle().strokeBorder(SetupColor.label3, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupColor.label)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(SetupColor.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            preview
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? tint.accent.opacity(0.6) : SetupColor.panelBorder, lineWidth: 1)
                }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? SetupColor.control : hovering ? SetupColor.control.opacity(0.6) : .clear)
                .shadow(color: .black.opacity(isSelected ? 0.05 : 0), radius: 1, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? SetupColor.panelBorder : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The inline recording overlay in a skin, in miniature, over a patch of desktop — the
/// surface the skin is mostly seen on. Built from the overlay's own parts at their real
/// size and scaled down, so the picture cannot drift from the thing it shows.
struct SkinPreview: View {
    let skin: AppSkin
    /// The accent picked in the Colour row, so the picture follows it; a skin that keeps
    /// its own colours ignores it, as the overlay does.
    var accentHex = AccentColor.neutral

    private var accent: Color {
        AccentColor.meter(skin.supportsAccent ? accentHex : AccentColor.neutral)
    }

    static let size = CGSize(width: 168, height: 64)

    /// Each skin as large as the patch allows, up to three quarters: at one shared scale
    /// the techno strip, less than half the minimal one's width, came out a speck.
    private var scale: CGFloat {
        let strip = skin.overlayStripSize
        return min((Self.size.width - 24) / strip.width, (Self.size.height - 16) / strip.height, 0.75)
    }

    /// A frozen syllable: loud in the middle, quieter at the ends.
    private static let levels: [CGFloat] = [0.15, 0.3, 0.5, 0.4, 0.7, 0.9, 0.65, 0.8,
                                            1.0, 0.7, 0.55, 0.75, 0.45, 0.3, 0.4, 0.2]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE4ECF2), Color(hex: 0xC6D3DE)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            strip
                .scaleEffect(scale)
                .frame(width: skin.overlayStripSize.width * scale,
                       height: skin.overlayStripSize.height * scale)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // A picture, not a control: the moulded ✕ inside would otherwise take the click.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // The overlay is drawn light whatever the window is, as it is over most desktops.
        .environment(\.colorScheme, .light)
        .animation(.easeInOut(duration: 0.25), value: accentHex)
    }

    @ViewBuilder
    private var strip: some View {
        switch skin {
        case .minimal: minimal
        case .techno: techno
        }
    }

    /// `RecordingOverlayView.minimalStrip`, still: glass capsule, microphone, bars, ✕.
    private var minimal: some View {
        let size = skin.overlayStripSize
        return HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.opacity(0.55))
                .frame(width: 24, height: 24)
            HStack(spacing: 6) {
                ForEach(Self.levels.indices, id: \.self) { index in
                    Capsule().fill(accent)
                        .frame(width: 4, height: 4 + 22 * Self.levels[index])
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.35))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// `RecordingOverlayView.technoStrip`, still: the dot-matrix glass and the moulded ✕.
    private var techno: some View {
        let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return HStack(spacing: 6) {
            ZStack {
                glass.fill(TechnoSkin.screen)
                PixelMatrix(levels: Self.levels, rows: 8, mode: .level)
                InnerShadow(shape: glass, width: 6.6, blur: 3.3)
                InnerShadow(shape: glass, width: 4, blur: 2, offset: CGSize(width: 0, height: -1))
            }
            .frame(width: 100, height: 56)
            .clipShape(glass)
            ButtonRail {
                PlasticButton(systemImage: "xmark", action: {})
            }
        }
        .frame(width: skin.overlayStripSize.width, height: skin.overlayStripSize.height)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}
