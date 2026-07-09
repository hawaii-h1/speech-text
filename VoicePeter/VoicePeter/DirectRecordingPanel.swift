import SwiftUI
import AppKit

// MARK: - Panel Window

final class DirectRecordingPanelWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        title = ""
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        center()
    }
}

// MARK: - Text Insertion Handler

final class TextInsertionHandler {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView, !text.isEmpty else { return }
        let range = textView.selectedRange()

        // Add a space before the new text if the character before cursor is not whitespace
        var prefix = ""
        if range.location > 0 {
            let charBefore = (textView.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1))
            if let scalar = charBefore.unicodeScalars.first,
               !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                prefix = " "
            }
        }

        textView.insertText(prefix + text, replacementRange: range)
    }
}

// MARK: - Cursor Text Editor (NSViewRepresentable)

struct CursorTextEditor: NSViewRepresentable {
    @Binding var text: String
    let insertionHandler: TextInsertionHandler

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CursorTextEditor
        var isUpdating = false

        init(_ parent: CursorTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textColor = .labelColor
        insertionHandler.textView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            context.coordinator.isUpdating = true
            let range = textView.selectedRange()
            textView.string = text
            let safeLoc = min(range.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
            context.coordinator.isUpdating = false
        }
    }
}

// MARK: - Panel View

struct DirectRecordingPanelView: View {
    @Bindable var speechEngine: SpeechEngine
    var appState: AppState
    var autoStartRecording: Bool = true
    let onDismiss: () -> Void

    @State private var isHoveringCopy = false
    @State private var isHoveringSend = false
    @State private var isHoveringRecord = false
    @State private var showCopyCheck = false
    @State private var showSendCheck = false
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID

    private let insertionHandler = TextInsertionHandler()

    private var hasWebhook: Bool {
        guard let url = UserDefaults.standard.string(forKey: SettingsKeys.webhookURL) else { return false }
        return !url.isEmpty
    }

    private var hasText: Bool {
        !speechEngine.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @State private var langLabel: String = ""
    @State private var keyboardObserverID: UUID?

    private func refreshLangLabel() {
        let locale = resolvedLocale()
        langLabel = locale.components(separatedBy: "-").first.map { $0.uppercased() } ?? "?"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            contentArea
            controlsBar
        }
        .frame(width: 380, height: 260)
        .background(.ultraThinMaterial)
        .onAppear {
            refreshLangLabel()
            keyboardObserverID = KeyboardChangeObserver.shared.addHandler { refreshLangLabel() }
            if autoStartRecording {
                // Defer one runloop so the panel renders before the audio engine
                // initializes (engine.prepare() can block the main thread ~200-500ms).
                DispatchQueue.main.async {
                    speechEngine.startRecording(locale: resolvedLocale())
                }
            }
        }
        .onDisappear {
            if let id = keyboardObserverID { KeyboardChangeObserver.shared.removeHandler(id: id) }
        }
        .onChange(of: selectedLanguage) { refreshLangLabel() }
        .onChange(of: speechEngine.pendingInsertionText) { _, newValue in
            if let text = newValue, !text.isEmpty {
                insertionHandler.insert(text)
                speechEngine.pendingInsertionText = nil
            }
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            // Toolbar with action buttons
            HStack(spacing: 8) {
                languageIndicator
                Spacer()
                copyButton
                if hasWebhook {
                    webhookSendButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Text editor
            CursorTextEditor(
                text: $speechEngine.editedText,
                insertionHandler: insertionHandler
            )
            .padding(4)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 32) // space so text doesn't hide behind buttons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Copy Button

    @ViewBuilder
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(speechEngine.editedText, forType: .string)
            showCopyCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showCopyCheck = false
            }
        } label: {
            Image(systemName: showCopyCheck ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showCopyCheck ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                )
                .scaleEffect(isHoveringCopy ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringCopy = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringCopy)
        .animation(.easeInOut(duration: 0.2), value: showCopyCheck)
    }

    // MARK: - Controls Bar

    @ViewBuilder
    private var controlsBar: some View {
        VStack(spacing: 6) {
            if let errorMessage = speechEngine.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            ZStack {
                recordButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .offset(y: 4) // buttons overlap ~30% onto the text area edge
    }

    // MARK: - Language Indicator

    @ViewBuilder
    private var languageIndicator: some View {
        Text(langLabel)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.5), lineWidth: 1)
            )
    }

    // MARK: - Webhook Send Button

    @ViewBuilder
    private var webhookSendButton: some View {
        Button {
            WebhookService.send(text: speechEngine.editedText) { _ in }
            showSendCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSendCheck = false
            }
        } label: {
            Image(systemName: showSendCheck ? "checkmark" : "paperplane")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showSendCheck ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                )
                .scaleEffect(isHoveringSend ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringSend = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringSend)
        .animation(.easeInOut(duration: 0.2), value: showSendCheck)
    }

    // MARK: - Record Button

    private var isExpanded: Bool {
        speechEngine.isRecording || speechEngine.isTranscribing
    }

    @ViewBuilder
    private var recordButton: some View {
        Button {
            let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
            if speechEngine.isRecording {
                withAnimation(spring) { speechEngine.pauseRecording() }
            } else if speechEngine.isTranscribing {
                // do nothing while transcribing
            } else if speechEngine.isPaused {
                withAnimation(spring) { speechEngine.resumeRecording(locale: resolvedLocale()) }
            } else {
                withAnimation(spring) { speechEngine.startRecording(locale: resolvedLocale()) }
            }
        } label: {
            ZStack {
                if speechEngine.isRecording {
                    // Live waveform
                    WaveformBarsView(
                        barLevels: speechEngine.barLevels,
                        isLoading: false,
                        barWidth: 3,
                        spacing: 2,
                        minBarHeight: 4,
                        maxBarHeight: 28,
                        barColor: .white
                    )
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                } else if speechEngine.isTranscribing {
                    // Loading dot animation
                    WaveformBarsView(
                        barLevels: speechEngine.barLevels,
                        isLoading: true,
                        barWidth: 3,
                        spacing: 2,
                        minBarHeight: 4,
                        maxBarHeight: 28,
                        barColor: .white
                    )
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                } else {
                    // Round mic icon
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .frame(width: isExpanded ? 160 : 48, height: 48)
            .background(
                Capsule()
                    .fill(.red.opacity(isExpanded ? 0.85 : 1.0))
                    .shadow(color: .red.opacity(isHoveringRecord ? 0.5 : 0.25), radius: isHoveringRecord ? 10 : 4, y: 2)
            )
            .overlay(
                Capsule()
                    .fill(.white.opacity(isHoveringRecord ? 0.12 : 0))
            )
            .scaleEffect(isHoveringRecord ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHoveringRecord = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringRecord)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: speechEngine.isTranscribing)
    }

}
