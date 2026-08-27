import SwiftUI
import AppKit

// MARK: - Debug Log View

struct DebugLogView: View {
    @State private var debugLog = DebugLog.shared
    @State private var autoScroll = true
    @State private var filterText = ""

    private var filteredEntries: [DebugLog.Entry] {
        if filterText.isEmpty { return debugLog.entries }
        let query = filterText.lowercased()
        return debugLog.entries.filter {
            $0.category.lowercased().contains(query) ||
            $0.message.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 650, minHeight: 400)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "ladybug")
                .foregroundStyle(.secondary)
            Text("Debug Log")
                .font(.headline)

            TextField("Filter...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button("Copy") {
                let text: String
                if filterText.isEmpty {
                    text = debugLog.formatted()
                } else {
                    let df = DateFormatter()
                    df.dateFormat = "HH:mm:ss.SSS"
                    text = filteredEntries.map {
                        "\(df.string(from: $0.timestamp)) [\($0.category)] \($0.message)"
                    }.joined(separator: "\n")
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

            Button("Clear") {
                debugLog.clear()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    @ViewBuilder
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(formatTime(entry.timestamp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 85, alignment: .leading)

                    Text(entry.category)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(categoryColor(entry.category))
                        .frame(width: 90, alignment: .leading)

                    Text(entry.message)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: debugLog.entries.count) {
                if autoScroll, let last = filteredEntries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: date)
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "Engine":   .blue
        case "App":      .purple
        case "Groq":     .orange
        case "Audio":    .green
        case "Paste":    .pink
        default:         .secondary
        }
    }
}

// MARK: - Debug Log Window

final class DebugLogWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "SpeachText Debug Log"
        contentView = NSHostingView(rootView: DebugLogView())
        isReleasedWhenClosed = false
        center()
    }
}
