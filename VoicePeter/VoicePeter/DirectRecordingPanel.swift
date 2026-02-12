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
        title = "Record"
        isMovableByWindowBackground = true
        center()
    }
}

// MARK: - Panel State

private enum RecordingPanelState: Equatable {
    case recording
    case transcribing
    case result(String)
}

// MARK: - Panel View

struct DirectRecordingPanelView: View {
    @Bindable var speechEngine: SpeechEngine
    var appState: AppState
    let onDismiss: () -> Void

    @State private var panelState: RecordingPanelState = .recording
    @State private var statusMessage: String?
    @AppStorage(SettingsKeys.selectedLanguage) private var selectedLanguage = "en-US"
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = "apple"

    private var providerType: STTProviderType {
        STTProviderType(rawValue: sttProvider) ?? .apple
    }

    var body: some View {
        VStack(spacing: 16) {
            headerView

            switch panelState {
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
        .onAppear {
            startRecording()
        }
        .onChange(of: speechEngine.isTranscribing) { _, isTranscribing in
            if !isTranscribing && panelState == .transcribing {
                transitionToResult()
            }
        }
        .onChange(of: selectedLanguage) { _, newLang in
            guard panelState == .recording, speechEngine.isRecording else { return }
            speechEngine.stopRecording()
            speechEngine.startRecording(locale: newLang)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack {
            if panelState == .recording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            } else if panelState == .transcribing {
                Text("Transcribing...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Result")
                    .font(.headline)
            }

            Spacer()

            Picker("", selection: $selectedLanguage) {
                ForEach(supportedLanguages) { lang in
                    Text(lang.displayName).tag(lang.localeIdentifier)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .labelsHidden()
        }
    }

    // MARK: - Recording State

    @ViewBuilder
    private var recordingView: some View {
        WaveformBarsView(
            barLevels: speechEngine.barLevels,
            isLoading: false,
            minBarHeight: 4,
            maxBarHeight: 36
        )
        .frame(height: 50)

        ScrollView {
            if providerType.supportsLiveText {
                Text(speechEngine.liveText.isEmpty ? "Listening..." : speechEngine.liveText)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Recording audio...")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 120)
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

        WaveformBarsView(
            barLevels: speechEngine.barLevels,
            isLoading: true
        )
        .frame(height: 50)

        Text("Transcribing with \(providerType.displayName)...")
            .font(.subheadline)
            .foregroundStyle(.secondary)

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

        Button(action: recordAgain) {
            Label("Record Again", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Actions

    private func startRecording() {
        statusMessage = nil
        speechEngine.startRecording(locale: selectedLanguage)
        panelState = .recording
    }

    private func stopRecording() {
        speechEngine.stopRecording()
        panelState = .transcribing
    }

    private func transitionToResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let error = speechEngine.errorMessage {
                statusMessage = error
            }
            panelState = .recording
            speechEngine.startRecording(locale: selectedLanguage)
        } else {
            panelState = .result(text)
        }
    }

    private func cancelRecording() {
        speechEngine.stopRecording()
        onDismiss()
    }

    private func recordAgain() {
        statusMessage = nil
        startRecording()
    }
}
