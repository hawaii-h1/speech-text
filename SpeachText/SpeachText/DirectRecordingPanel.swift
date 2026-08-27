import SwiftUI
import AppKit

// MARK: - Panel Window

/// The record window is borderless: the shell it draws *is* the window, so a titlebar
/// — even a transparent one — would only sit on top of the moulding and swallow clicks
/// meant for the knob and the text.
final class DirectRecordingPanelWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: DirectRecordingPanelView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        hasShadow = true
        center()
    }

    /// `.nonactivatingPanel` normally refuses key status, but the panel's whole point
    /// is a text area the user can edit.
    override var canBecomeKey: Bool { true }

    /// Borderless windows get no titlebar and this app has no menu bar, so the usual
    /// ways out of a window have to be wired up by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func performClose(_ sender: Any?) {
        close()
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

// MARK: - LCD Text Editor (NSViewRepresentable)

/// The editable text printed on the glass: phosphor on black, no chrome of its own.
struct LCDTextEditor: NSViewRepresentable {
    @Binding var text: String
    let insertionHandler: TextInsertionHandler
    var textColor: Color = Skin.phosphorText

    static let font = NSFont.systemFont(ofSize: 15, weight: .regular)

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LCDTextEditor
        var isUpdating = false

        init(_ parent: LCDTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// The text view is first responder for most of the panel's life, and it eats
        /// Escape — so hand that one command back to the window.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.window?.performClose(nil)
            return true
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
        textView.font = Self.font
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textColor = NSColor(textColor)
        textView.insertionPointColor = NSColor(Skin.phosphor)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Skin.phosphor).withAlphaComponent(0.25),
            .foregroundColor: NSColor.white,
        ]
        insertionHandler.textView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        context.coordinator.parent = self
        let wanted = NSColor(textColor)
        if textView.textColor != wanted {
            textView.textColor = wanted
        }
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

/// The record window: the whole device, drawn at the size the design specifies.
///
/// Everything is positioned against that fixed 362×284 canvas rather than laid out
/// flexibly — the shell is a photograph of a moulding, so the knob and the button rail
/// have to land exactly where the moulding has holes for them.
struct DirectRecordingPanelView: View {
    @Bindable var speechEngine: SpeechEngine
    var appState: AppState
    var autoStartRecording: Bool = true
    let onDismiss: () -> Void

    static let panelSize = CGSize(width: 362, height: 284)

    /// Coordinates lifted straight from the design file. Anything drawn on the glass is
    /// measured from the glass's top-left corner, everything else from the shell's.
    private enum Layout {
        static let screenOrigin = CGPoint(x: 12, y: 12)
        static let screenSize = CGSize(width: 338, height: 259.108)
        static let knobCentre = CGPoint(x: 294.5, y: 56)
        static let railLeft: CGFloat = 304.5

        // On the glass
        static let textOrigin = CGPoint(x: 24, y: 26)
        /// The glass is notched for the knob down to y≈81, so the text column stops
        /// short of it rather than reflowing around a hole that scrolls away.
        static let textWidth: CGFloat = 190
        static let statusOrigin = CGPoint(x: 24, y: 183)
        static let matrixOrigin = CGPoint(x: 4, y: 215)
        static let matrixColumns = 47
        static let matrixRows = 6
    }

    @State private var showCopyCheck = false
    @State private var showSendCheck = false
    @State private var showPasteCheck = false
    @State private var isHoveringPanel = false
    @State private var isHoveringClose = false
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = autoLanguageID
    @AppStorage(SettingsKeys.aiModeInRecordWindow) private var aiMode = false

    /// True while the LLM is rewriting the panel's text.
    @State private var isRefining = false
    @State private var refineTask: Task<Void, Never>?
    /// Which preset the last refinement routed to, shown under the text area.
    @State private var refineStatus: String?
    /// Set when the last refinement failed, so the status line can be shown in red.
    @State private var refineFailed = false

    private let insertionHandler = TextInsertionHandler()

    private var hasWebhook: Bool {
        guard let url = UserDefaults.standard.string(forKey: SettingsKeys.webhookURL) else { return false }
        return !url.isEmpty
    }

    private var hasText: Bool {
        !speechEngine.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool { speechEngine.isTranscribing || isRefining || speechEngine.isStartingEngine }

    private var palette: PixelPalette { aiMode ? .ai : .phosphor }
    private var accent: Color { aiMode ? Skin.aiPhosphor : Skin.phosphor }

    private var displayMode: PixelDisplayMode {
        if speechEngine.isRecording { return .level }
        if isBusy { return .busy }
        return .idle
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShellBackground()

            LCDScreen(size: Layout.screenSize) {
                dotMatrix
                textArea
                statusLine
            }
            .offset(x: Layout.screenOrigin.x, y: Layout.screenOrigin.y)

            TransportKnob(
                systemImage: speechEngine.isRecording ? "pause" : "play",
                tint: aiMode ? Skin.aiPhosphor.opacity(0.95) : .white.opacity(0.92),
                isBusy: isBusy,
                isEnabled: !isBusy,
                help: knobHelp,
                action: toggleRecording
            )
            .offset(
                x: Layout.knobCentre.x - TransportKnob.diameter / 2,
                y: Layout.knobCentre.y - TransportKnob.diameter / 2
            )

            buttonRail

            if isHoveringPanel {
                closeButton.transition(.opacity)
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .clipShape(RoundedRectangle(cornerRadius: Skin.shellRadius, style: .continuous))
        .onHover { isHoveringPanel = $0 }
        .animation(.easeInOut(duration: 0.18), value: isHoveringPanel)
        .onAppear {
            if autoStartRecording {
                // Defer one runloop so the panel renders before the audio engine
                // initializes (engine.prepare() can block the main thread ~200-500ms).
                DispatchQueue.main.async {
                    speechEngine.startRecording(locale: resolvedLocale())
                }
            }
        }
        .onDisappear {
            refineTask?.cancel()
        }
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

    // MARK: - Glass contents

    /// The equaliser along the bottom edge. It runs wider than the glass; `LCDScreen`
    /// clips it, so the dots stop at the rounded corners the way the design shows.
    private var dotMatrix: some View {
        PixelWaveform(
            levels: speechEngine.barLevels,
            columns: Layout.matrixColumns,
            rows: Layout.matrixRows,
            mode: displayMode,
            palette: palette
        )
        .offset(x: Layout.matrixOrigin.x, y: Layout.matrixOrigin.y)
    }

    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            LCDTextEditor(
                text: $speechEngine.editedText,
                insertionHandler: insertionHandler,
                textColor: aiMode ? Skin.aiText : Skin.phosphorText
            )

            // While the first segment is still being spoken there is nothing in the
            // editor yet; showing the partial transcript here is the only feedback
            // that the words are landing.
            if !hasText, let ghost = ghostText {
                Text(ghost)
                    .font(Font(LCDTextEditor.font))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle((aiMode ? Skin.aiText : Skin.phosphorText).opacity(0.45))
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: Layout.textWidth,
            height: Layout.statusOrigin.y - Layout.textOrigin.y - 6,
            alignment: .topLeading
        )
        .offset(x: Layout.textOrigin.x, y: Layout.textOrigin.y)
    }

    private var ghostText: String? {
        let live = speechEngine.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        if speechEngine.isRecording { return "Listening…" }
        if speechEngine.isStartingEngine { return "Starting…" }
        if speechEngine.isTranscribing { return "Transcribing…" }
        return nil
    }

    @ViewBuilder
    private var statusLine: some View {
        if let text = statusText {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusTint)
                .lineLimit(2)
                .frame(width: 250, alignment: .leading)
                .offset(x: Layout.statusOrigin.x, y: Layout.statusOrigin.y)
                .allowsHitTesting(false)
        }
    }

    private var statusText: String? {
        if let error = speechEngine.errorMessage { return error }
        if isRefining { return "Rewriting with AI…" }
        return refineStatus
    }

    private var statusTint: Color {
        if speechEngine.errorMessage != nil || refineFailed { return Skin.danger }
        if isRefining { return Skin.aiText }
        return Skin.phosphorText.opacity(0.55)
    }

    // MARK: - Controls

    private var knobHelp: String {
        if isBusy { return "Working…" }
        if speechEngine.isRecording { return "Pause and transcribe" }
        if speechEngine.isPaused { return "Resume recording" }
        return "Start recording"
    }

    private func toggleRecording() {
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
        if speechEngine.isRecording {
            withAnimation(spring) { speechEngine.pauseRecording() }
        } else if speechEngine.isPaused {
            withAnimation(spring) { speechEngine.resumeRecording(locale: resolvedLocale()) }
        } else {
            withAnimation(spring) { speechEngine.startRecording(locale: resolvedLocale()) }
        }
    }

    private var railButtonCount: Int { hasWebhook ? 4 : 3 }

    private var railHeight: CGFloat {
        CGFloat(railButtonCount) * PlasticButton.size + CGFloat(railButtonCount - 1) * 4 + 8
    }

    /// The rail hangs from its bottom edge. A fourth button needs another 34pt, and it
    /// borrows them from below: the knob is directly overhead, whereas the dot matrix
    /// underneath is decoration and can lose a few unlit dots at its right edge.
    private var railBottom: CGFloat { hasWebhook ? 232 : 219 }

    private var buttonRail: some View {
        ButtonRail {
            PlasticButton(
                systemImage: "sparkles",
                isOn: aiMode,
                accent: Skin.aiPhosphor,
                help: aiMode
                    ? "AI mode on — dictation is rewritten using your prompt presets"
                    : "AI mode off — text is inserted as transcribed",
                action: toggleAIMode
            )

            PlasticButton(
                systemImage: showPasteCheck ? "checkmark" : "text.insert",
                isOn: showPasteCheck,
                isEnabled: hasText,
                help: "Insert at the cursor in the app you came from",
                action: pasteAtCursor
            )

            PlasticButton(
                systemImage: showCopyCheck ? "checkmark" : "doc.on.doc",
                isOn: showCopyCheck,
                isEnabled: hasText,
                help: "Copy to the clipboard",
                action: copyToClipboard
            )

            if hasWebhook {
                PlasticButton(
                    systemImage: showSendCheck ? "checkmark" : "paperplane",
                    isOn: showSendCheck,
                    isEnabled: hasText,
                    help: "Send to your webhook",
                    action: sendToWebhook
                )
            }
        }
        .offset(x: Layout.railLeft, y: railBottom - railHeight)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isHoveringClose ? 1 : 0.6))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(isHoveringClose ? 0.7 : 0.45)))
        }
        .buttonStyle(.plain)
        .help("Close (the transcription is kept in History)")
        .onHover { hovering in
            isHoveringClose = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringClose)
        .offset(x: 13, y: 13)
    }

    // MARK: - Actions

    private func toggleAIMode() {
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
            refineFailed = false
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(speechEngine.editedText, forType: .string)
        flash($showCopyCheck)
    }

    private func sendToWebhook() {
        WebhookService.send(text: speechEngine.editedText) { _ in }
        flash($showSendCheck)
    }

    private func pasteAtCursor() {
        appState.pasteTextToTarget(speechEngine.editedText)
        flash($showPasteCheck)
    }

    private func flash(_ binding: Binding<Bool>) {
        binding.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            binding.wrappedValue = false
        }
    }

    // MARK: - LLM Refinement

    /// Sends the whole text area through the LLM and replaces it with the result.
    private func runRefinement() {
        let source = speechEngine.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !isRefining else { return }
        guard TextRefinementService.isConfigured else {
            refineStatus = "Set an LLM API key in Settings to use AI mode"
            refineFailed = true
            return
        }

        refineTask?.cancel()
        isRefining = true
        refineStatus = nil
        refineFailed = false
        // Anchor the entry for the segment that triggered this pass. The input recorded
        // below is the whole text area, which may span several segments and manual edits.
        let recordID = speechEngine.lastRecordID
        refineTask = Task { @MainActor in
            do {
                let result = try await TextRefinementService.refine(source)
                guard !Task.isCancelled else { return }
                speechEngine.editedText = result.text
                refineStatus = result.presetName.map { "AI · \($0)" } ?? "AI"
                refineFailed = false
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
                refineFailed = true
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
}
