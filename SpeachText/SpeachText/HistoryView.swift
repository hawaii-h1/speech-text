import SwiftUI
import AppKit

// MARK: - History View

struct HistoryView: View {
    @State private var history = TranscriptionHistory.shared
    @State private var filterText = ""
    @State private var selection: TranscriptionRecord.ID?
    @State private var retryingIDs: Set<UUID> = []
    @State private var copiedID: UUID?

    private var filteredRecords: [TranscriptionRecord] {
        guard !filterText.isEmpty else { return history.records }
        let query = filterText.lowercased()
        return history.records.filter {
            $0.text.lowercased().contains(query) ||
            ($0.errorMessage?.lowercased().contains(query) ?? false)
        }
    }

    private var selectedRecord: TranscriptionRecord? {
        history.records.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filteredRecords.isEmpty {
                emptyState
            } else {
                recordList
                if let record = selectedRecord {
                    Divider()
                    detailPane(record)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("History")
                .font(.headline)

            TextField("Search...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Text("\(filteredRecords.count) of \(history.records.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Clear All") {
                history.clear()
                selection = nil
            }
            .disabled(history.records.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(history.records.isEmpty ? "No transcriptions yet" : "No matches")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    @ViewBuilder
    private var recordList: some View {
        List(filteredRecords, selection: $selection) { record in
            row(record)
                .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                .tag(record.id)
                .contextMenu {
                    Button("Copy Text") { copy(record) }
                        .disabled(record.text.isEmpty)
                    if record.isRetryable {
                        Button("Retry Transcription") { retry(record) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        if selection == record.id { selection = nil }
                        history.delete(record)
                    }
                }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(_ record: TranscriptionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon(record.status))
                .font(.system(size: 12))
                .foregroundStyle(statusColor(record.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLine(record))
                    .font(.system(size: 12))
                    .foregroundStyle(record.text.isEmpty ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(record.date, style: .time)
                    Text("·")
                    Text(formatDuration(record.duration))
                    Text("·")
                    Text(record.provider)
                    if let locale = record.locale {
                        Text("·")
                        Text(locale)
                    }
                    if let refinement = record.refinement {
                        Text("·")
                        Label(
                            refinement.succeeded ? (refinement.presetName ?? "AI") : "AI failed",
                            systemImage: refinement.succeeded ? "sparkles" : "sparkles.slash"
                        )
                        .foregroundStyle(refinement.succeeded ? Color.purple : Color.orange)
                    }
                    if let delivery = record.delivery {
                        Text("·")
                        Label(delivery.recipientName, systemImage: deliveryIcon(delivery))
                            .foregroundStyle(deliveryTint(delivery))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if retryingIDs.contains(record.id) {
                ProgressView()
                    .controlSize(.small)
            } else if record.isRetryable {
                Button {
                    retry(record)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry transcription with the saved audio")
            }

            Button {
                copy(record)
            } label: {
                Image(systemName: copiedID == record.id ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copiedID == record.id ? Color.green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(record.deliveredText.isEmpty)
            .help("Copy text")
        }
        .padding(.vertical, 2)
    }

    // MARK: Detail

    @ViewBuilder
    private func detailPane(_ record: TranscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if record.isRetryable {
                    Label("Audio saved", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Copy") { copy(record) }
                    .disabled(record.deliveredText.isEmpty)
            }

            if let error = record.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let delivery = record.delivery {
                deliveryHeader(delivery)
            }

            if let refinement = record.refinement {
                refinementHeader(refinement)

                HStack(alignment: .top, spacing: 10) {
                    textPane("Dictated", refinement.inputText, tint: .secondary)
                    textPane(
                        refinement.succeeded ? "AI output (pasted)" : "AI output",
                        refinement.succeeded ? refinement.outputText : "",
                        tint: refinement.succeeded ? .purple : .secondary,
                        placeholder: refinement.succeeded ? "(no text)" : "(failed — the dictated text was pasted)"
                    )
                }
                .frame(height: 150)
            } else {
                ScrollView {
                    Text(record.text.isEmpty ? "(no text)" : record.text)
                        .font(.system(size: 12))
                        .foregroundStyle(record.text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
            }
        }
        .padding(12)
    }

    private func deliveryIcon(_ delivery: TranscriptionRecord.Delivery) -> String {
        switch delivery.outcome {
        case .sent: "paperplane.fill"
        case .composed: "square.and.pencil"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func deliveryTint(_ delivery: TranscriptionRecord.Delivery) -> Color {
        switch delivery.outcome {
        case .sent: .green
        case .composed: .blue
        case .failed: .orange
        }
    }

    /// A message the user believes went out is the one thing history has to be able to
    /// answer for, so the address is shown verbatim — not just the name it matched.
    @ViewBuilder
    private func deliveryHeader(_ delivery: TranscriptionRecord.Delivery) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label(deliveryTitle(delivery), systemImage: deliveryIcon(delivery))
                    .foregroundStyle(deliveryTint(delivery))
                Text("·")
                Text(delivery.address)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11))

            if let error = delivery.errorMessage {
                Text("Pasted at the cursor instead — \(error)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deliveryTitle(_ delivery: TranscriptionRecord.Delivery) -> String {
        switch delivery.outcome {
        case .sent: "Sent to \(delivery.recipientName) on \(delivery.channel)"
        case .composed: "Staged for \(delivery.recipientName) in \(delivery.channel)"
        case .failed: "Could not send to \(delivery.recipientName) on \(delivery.channel)"
        }
    }

    @ViewBuilder
    private func refinementHeader(_ refinement: TranscriptionRecord.Refinement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label(
                    refinement.presetName ?? "AI processing",
                    systemImage: refinement.succeeded ? "sparkles" : "sparkles.slash"
                )
                .foregroundStyle(refinement.succeeded ? Color.purple : Color.orange)
                Text("·")
                Text("\(refinement.provider) / \(refinement.model)")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))

            if let error = refinement.errorMessage {
                Text("Fell back to the dictated text — \(error)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func textPane(_ title: String, _ body: String, tint: Color,
                          placeholder: String = "(no text)") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            ScrollView {
                Text(body.isEmpty ? placeholder : body)
                    .font(.system(size: 12))
                    .foregroundStyle(body.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .background(.quaternary.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    /// Copies what the user actually received, so an AI entry yields the rewritten text.
    private func copy(_ record: TranscriptionRecord) {
        guard !record.deliveredText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.deliveredText, forType: .string)

        copiedID = record.id
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if copiedID == record.id { copiedID = nil }
        }
    }

    private func retry(_ record: TranscriptionRecord) {
        guard let audioURL = history.audioURL(for: record) else {
            history.markRetryFailed(id: record.id, error: "Saved audio is no longer available")
            return
        }

        // Read fresh: a retry honours the *current* settings, not the ones the
        // recording was made with.
        let configuration = RecordingConfiguration.current()

        // Retries always go through a cloud provider — Apple's recognizer has no batch
        // file API — so the key the upload will actually use must be present (the Groq
        // key when Apple or Groq is selected, the ElevenLabs key otherwise).
        if configuration.batchAPIKey.isEmpty {
            let needed = configuration.provider == .elevenlabs ? "an ElevenLabs" : "a Groq"
            history.markRetryFailed(id: record.id,
                                    error: "Retry needs \(needed) API key — add one in Settings.")
            return
        }

        retryingIDs.insert(record.id)
        let recordID = record.id
        let locale = record.locale

        Task {
            do {
                let provider = makeBatchProvider(configuration: configuration)
                let text = try await provider.transcribe(audioFileURL: audioURL, language: locale)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if trimmed.isEmpty {
                        history.markRetryFailed(id: recordID, error: "Retry returned no text")
                    } else {
                        history.markRetrySucceeded(id: recordID, text: trimmed)
                    }
                    retryingIDs.remove(recordID)
                }
            } catch {
                await MainActor.run {
                    history.markRetryFailed(id: recordID, error: error.localizedDescription)
                    retryingIDs.remove(recordID)
                }
            }
        }
    }

    // MARK: Helpers

    private func primaryLine(_ record: TranscriptionRecord) -> String {
        if !record.deliveredText.isEmpty { return record.deliveredText }
        switch record.status {
        case .failed: return record.errorMessage ?? "Transcription failed"
        case .empty:  return "No speech detected"
        case .success: return "(empty)"
        }
    }

    private func statusIcon(_ status: TranscriptionRecord.Status) -> String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .empty:   "waveform.slash"
        case .failed:  "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: TranscriptionRecord.Status) -> Color {
        switch status {
        case .success: .green
        case .empty:   .secondary
        case .failed:  .orange
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total)s"
    }
}

// MARK: - History Window

final class HistoryWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "SpeachText History"
        contentView = NSHostingView(rootView: HistoryView())
        isReleasedWhenClosed = false
        center()
    }
}
