import SwiftUI
import AppKit

// MARK: - Panel Window

final class DirectRecordingPanelWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        title = "VoicePeter Recorder"
        isMovableByWindowBackground = true
        center()
    }
}

// MARK: - Panel State

private enum RecordingPanelState: Equatable {
    case ready
    case recording
    case transcribing
    case result(String)
}

// MARK: - Panel View

struct DirectRecordingPanelView: View {
    @Bindable var speechEngine: SpeechEngine
    var appState: AppState
    let onDismiss: () -> Void

    @State private var panelState: RecordingPanelState = .ready
    @State private var statusMessage: String?
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = "en-US"
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = "apple"

    private var providerType: STTProviderType {
        STTProviderType(rawValue: sttProvider) ?? .apple
    }

    var body: some View {
        VStack(spacing: 16) {
            switch panelState {
            case .ready:
                readyView
            case .recording:
                recordingView
            case .transcribing:
                transcribingView
            case .result(let text):
                resultView(text: text)
            }
        }
        .padding(20)
        .frame(width: 380, height: 320)
        .background(.ultraThinMaterial)
        .onChange(of: speechEngine.isTranscribing) { _, isTranscribing in
            if !isTranscribing && panelState == .transcribing {
                transitionToResult()
            }
        }
    }

    // MARK: - Ready State

    @ViewBuilder
    private var readyView: some View {
        Spacer()

        Image(systemName: "mic.circle.fill")
            .font(.system(size: 64))
            .foregroundStyle(.blue)

        Text("Tap to start recording")
            .font(.headline)

        Picker("Language", selection: $selectedLanguage) {
            ForEach(supportedLanguages) { lang in
                Text(lang.displayName).tag(lang.localeIdentifier)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 250)

        Spacer()

        Button(action: startRecording) {
            Label("Start Recording", systemImage: "mic.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    // MARK: - Recording State

    @ViewBuilder
    private var recordingView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text("Recording...")
                .font(.headline)
                .foregroundStyle(.red)
        }

        ScrollView {
            if providerType.supportsLiveText {
                Text(speechEngine.liveText.isEmpty ? "Listening..." : speechEngine.liveText)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Recording audio... Transcription will begin when you stop.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 150)
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        HStack(spacing: 12) {
            Button("Cancel") {
                cancelRecording()
            }
            .buttonStyle(.bordered)

            Button(action: stopRecording) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    // MARK: - Transcribing State

    @ViewBuilder
    private var transcribingView: some View {
        Spacer()
        ProgressView()
            .scaleEffect(1.5)
        Text("Transcribing with \(providerType.displayName)...")
            .font(.headline)

        if let errorMessage = speechEngine.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Spacer()
        Button("Cancel") {
            cancelRecording()
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Result State

    @ViewBuilder
    private func resultView(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        if let statusMessage {
            Text(statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 12) {
            Button("Paste at cursor") {
                onDismiss()
                appState.pasteTextToTarget(text)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                statusMessage = "Copied!"
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Send to Peter") {
                statusMessage = "Sending..."
                WebhookService.send(text: text) { result in
                    switch result {
                    case .success:
                        statusMessage = "Sent!"
                    case .failure(let error):
                        statusMessage = error.localizedDescription
                    }
                }
            }
        }

        Button(action: resetToReady) {
            Label("Record Again", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Actions

    private func startRecording() {
        speechEngine.startRecording(locale: selectedLanguage)
        panelState = .recording
    }

    private func stopRecording() {
        speechEngine.stopRecording()

        if providerType == .apple {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                transitionToResult()
            }
        } else {
            panelState = .transcribing
        }
    }

    private func transitionToResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let error = speechEngine.errorMessage {
                statusMessage = error
            }
            panelState = .ready
        } else {
            panelState = .result(text)
        }
    }

    private func cancelRecording() {
        speechEngine.stopRecording()
        panelState = .ready
    }

    private func resetToReady() {
        statusMessage = nil
        panelState = .ready
    }
}
