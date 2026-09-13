// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Request

/// Everything the confirmation panel needs to describe one pending delivery.
struct SendConfirmation {
    let channel: DeliveryChannel
    /// Every address that matched, best first. More than one means the user picks.
    let candidates: [RecipientCandidate]
    let subject: String
    let body: String
}

// MARK: - View

/// The gate in front of every send.
///
/// Dictation mangles names and speech-to-text has no idea whether it heard "Ані" or
/// "Ганні", so the app never sends on the model's say-so alone. The panel shows the
/// resolved address and the exact body, and the send only happens on ⌘⏎.
struct SendConfirmationView: View {
    let confirmation: SendConfirmation
    let onSend: @MainActor (RecipientCandidate, String, String) -> Void
    let onPasteInstead: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.minimal.rawValue

    @State private var selection: RecipientCandidate
    @State private var subject: String
    @State private var messageText: String

    init(confirmation: SendConfirmation,
         onSend: @escaping @MainActor (RecipientCandidate, String, String) -> Void,
         onPasteInstead: @escaping @MainActor (String) -> Void,
         onCancel: @escaping @MainActor () -> Void) {
        self.confirmation = confirmation
        self.onSend = onSend
        self.onPasteInstead = onPasteInstead
        self.onCancel = onCancel
        _selection = State(initialValue: confirmation.candidates[0])
        _subject = State(initialValue: confirmation.subject)
        _messageText = State(initialValue: confirmation.body)
    }

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .minimal }
    private var accent: Color { skin == .techno ? TechnoSkin.aiPhosphor : Semantic.ai }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            recipientField
            if confirmation.channel.usesSubject { subjectField }
            bodyField
            Text(outcomeNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(18)
        .frame(width: 460)
        .background(.regularMaterial)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: confirmation.channel.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent)
            Text("Send via \(confirmation.channel.displayName)")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("To")
            // One match reads as a statement; several must read as a choice, because
            // picking the wrong one is the failure this whole panel exists to prevent.
            if confirmation.candidates.count == 1 {
                HStack(spacing: 6) {
                    Text(selection.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(selection.detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Picker("", selection: $selection) {
                    ForEach(confirmation.candidates) { candidate in
                        Text("\(candidate.displayName) — \(candidate.detailLine)").tag(candidate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var subjectField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Subject")
            TextField("", text: $subject)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Message")
            TextEditor(text: $messageText)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.background.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Paste instead") { onPasteInstead(messageText) }
                .help("Skip sending and paste the text where the cursor was.")

            Button {
                onSend(selection, subject, messageText)
            } label: {
                Text(sendButtonTitle)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    // MARK: Copy

    /// Named honestly: a deep-link channel cannot send, it can only stage.
    private var sendButtonTitle: String {
        switch confirmation.channel {
        case .imessage, .mail: "Send  ⌘⏎"
        case .telegram, .whatsapp: "Open  ⌘⏎"
        }
    }

    private var outcomeNote: String {
        switch confirmation.channel {
        case .imessage:
            return "Sends immediately through Messages — it can't be recalled after a couple of minutes."
        case .mail:
            let client = MessageDelivery.defaultMailClient()
            return client?.bundleID == "com.apple.mail"
                ? "Sends immediately through Mail — email can't be unsent."
                : "Opens a draft in \(client?.name ?? "your mail app"); you send it from there."
        case .telegram:
            return "Telegram opens the chat with this text in the input field. Telegram never sends from a link — press ⏎ there."
        case .whatsapp:
            return "WhatsApp opens the chat with this text in the input field. Press ⏎ there to send."
        }
    }
}

// MARK: - Panel

/// Unlike the recording overlays this panel *wants* focus — it is a keyboard-driven
/// decision, so it is a real key window rather than a `.nonactivatingPanel`.
final class SendConfirmationPanelWindow: NSPanel {

    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        contentView = rootView
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        setContentSize(rootView.fittingSize)
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
