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
    @State private var isHoveringAI = false
    @State private var showCopyCheck = false
    @State private var showSendCheck = false
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @AppStorage(SettingsKeys.aiModeInRecordWindow) private var aiMode = false

    /// True while the LLM is rewriting the panel's text.
    @State private var isRefining = false
    @State private var refineTask: Task<Void, Never>?
    /// Which preset the last refinement routed to, shown under the text area.
    @State private var refineStatus: String?

    private static let aiAccent = Color(red: 0.55, green: 0.36, blue: 0.96)

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
            refineTask?.cancel()
        }
        .onChange(of: selectedLanguage) { refreshLangLabel() }
        .onChange(of: speechEngine.pendingInsertionText) { _, newValue in
            if let text = newValue, !text.isEmpty {
                insertionHandler.insert(text)
                speechEngine.pendingInsertionText = nil
                if aiMode {
                    // insertText() drives the text view's delegate, which writes back
                    // into editedText — refine on the next runloop so we see it.
                    DispatchQueue.main.async { runRefinement() }
                }
            }
        }
    }

    // MARK: - LLM Refinement

    /// Sends the whole text area through the LLM and replaces it with the result.
    private func runRefinement() {
        let source = speechEngine.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !isRefining else { return }
        guard TextRefinementService.isConfigured else {
            refineStatus = "Set an LLM API key in Settings to use AI mode"
            return
        }

        refineTask?.cancel()
        isRefining = true
        refineStatus = nil
        // Anchor the entry for the segment that triggered this pass. The input recorded
        // below is the whole text area, which may span several segments and manual edits.
        let recordID = speechEngine.lastRecordID
        refineTask = Task { @MainActor in
            do {
                let result = try await TextRefinementService.refine(source)
                guard !Task.isCancelled else { return }
                speechEngine.editedText = result.text
                refineStatus = result.presetName.map { "AI · \($0)" } ?? "AI"
                if let recordID {
                    TranscriptionHistory.shared.recordRefinement(
                        id: recordID, input: source, output: result.text,
                        presetName: result.presetName,
                        provider: result.provider, model: result.model
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The raw transcription stays in the text area — nothing is lost.
                refineStatus = "AI failed: \(error.localizedDescription)"
                if let recordID {
                    let type = LLMConfiguration.providerType
                    TranscriptionHistory.shared.recordRefinementFailure(
                        id: recordID, input: source, error: error.localizedDescription,
                        provider: type.rawValue, model: LLMConfiguration.model(for: type)
                    )
                }
            }
            isRefining = false
            refineTask = nil
        }
    }

    // MARK: - AI Toggle Button

    @ViewBuilder
    private var aiToggleButton: some View {
        Button {
            aiMode.toggle()
            // Turning it on with text already dictated should act on that text now,
            // otherwise the toggle would appear to do nothing.
            if aiMode, !speechEngine.isRecording, !speechEngine.isTranscribing {
                runRefinement()
            } else if !aiMode {
                refineTask?.cancel()
                refineTask = nil
                isRefining = false
                refineStatus = nil
            }
        } label: {
            Group {
                if isRefining {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(aiMode ? .white : .secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(aiMode ? AnyShapeStyle(Self.aiAccent) : AnyShapeStyle(.ultraThinMaterial))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            )
            .scaleEffect(isHoveringAI ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .help(aiMode
              ? "AI mode on — dictation is rewritten by the LLM using your prompt presets"
              : "AI mode off — text is inserted as transcribed")
        .onHover { hovering in
            isHoveringAI = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringAI)
        .animation(.easeInOut(duration: 0.2), value: aiMode)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            // Toolbar with action buttons
            HStack(spacing: 8) {
                languageIndicator
                Spacer()
                aiToggleButton
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
            } else if isRefining {
                Text("Processing with AI…")
                    .font(.caption)
                    .foregroundStyle(Self.aiAccent)
                    .lineLimit(1)
            } else if let refineStatus {
                Text(refineStatus)
                    .font(.caption)
                    .foregroundStyle(refineStatus.hasPrefix("AI ·") || refineStatus == "AI"
                                     ? AnyShapeStyle(Color.secondary)
                                     : AnyShapeStyle(Color.red))
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
        speechEngine.isRecording || speechEngine.isTranscribing || isRefining
    }

    @ViewBuilder
    private var recordButton: some View {
        Button {
            let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
            if speechEngine.isRecording {
                withAnimation(spring) { speechEngine.pauseRecording() }
            } else if speechEngine.isTranscribing || isRefining {
                // do nothing while transcribing or refining
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
                } else if speechEngine.isTranscribing || isRefining {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isRefining)
    }

}
