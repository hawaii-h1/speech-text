import SwiftUI
import AppKit

struct ResultPanelView: View {
    let text: String
    let onCopy: () -> Void
    let onSendToPeter: () -> Void
    let onDismiss: () -> Void

    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            // Transcribed text
            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(8)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    statusMessage = "Copied"
                    dismissAfterDelay()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Send to Peter") {
                    statusMessage = "Sending..."
                    WebhookService.send(text: text) { result in
                        switch result {
                        case .success:
                            statusMessage = "Sent"
                            dismissAfterDelay()
                        case .failure(let error):
                            statusMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 400, height: 220)
        .background(.ultraThinMaterial)
    }

    private func dismissAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onDismiss()
        }
    }
}

final class ResultPanelWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        title = "VoicePeter"
        center()
    }
}
