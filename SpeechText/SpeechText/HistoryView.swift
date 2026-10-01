// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - History

/// The main window's History: every dictation, grouped by day, with search and filters. A
/// row opens in place to show what was said beside what AI Rewrite made of it, with the
/// prompt it chose; a failed one retries from the audio kept for a week. Built in Home's
/// parts — the hairline tables, the app marks, the tags — so the two read as one window.
struct HistoryView: View {
    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var expanded: UUID?
    /// The days opened past their first `HistoryDaySection.shown` dictations.
    @State private var openDays: Set<Date> = []
    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

    private var history: TranscriptionHistory { .shared }

    var body: some View {
        let records = history.records
        let days = HistoryDay.group(records, filter: filter, query: query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                header(records)
                Section {
                    if days.isEmpty {
                        empty(nothingAtAll: records.isEmpty)
                            .padding(.top, 26)
                    }
                    ForEach(days) { day in
                        HistoryDaySection(day: day, expanded: $expanded,
                                          showsAll: Binding(get: { openDays.contains(day.id) },
                                                            set: { if $0 { openDays.insert(day.id) } else { openDays.remove(day.id) } }))
                            .padding(.top, 26)
                    }
                    if !records.isEmpty { footer.padding(.top, 34) }
                } header: {
                    toolbar(records)
                }
            }
            .frame(maxWidth: HomeView.columnWidth)
            .padding(.horizontal, 48)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background {
            // ⌘F finds, as it does in every list on the Mac.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .confirmationDialog("Clear all of History?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                expanded = nil
                history.clear()
            }
        } message: {
            Text("Every dictation and the audio kept for a retry are deleted. This can't be undone.")
        }
    }

    // MARK: Title

    private func header(_ records: [TranscriptionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(MainColor.ink)
                Spacer(minLength: 12)
                if !records.isEmpty {
                    Text(records.count == 1 ? "1 dictation" : "\(HomeFormat.integer(records.count)) dictations")
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink3)
                        .monospacedDigit()
                }
            }
            Text(MainPage.history.lead)
                .font(.system(size: 14))
                .foregroundStyle(MainColor.ink2)
        }
        .padding(.bottom, 20)
    }

    // MARK: Search and filters

    /// Pinned under the title while the days scroll past.
    private func toolbar(_ records: [TranscriptionRecord]) -> some View {
        HStack(spacing: 14) {
            HistorySearchField(query: $query, focused: $searchFocused)
                .frame(maxWidth: 340)
            Spacer(minLength: 0)
            HistoryFilterSwitch(filter: $filter, counts: Dictionary(uniqueKeysWithValues: HistoryFilter.allCases.map { f in
                (f, records.filter { f.includes($0) && HistorySearch.matches($0, query: query) }.count)
            }))
        }
        .padding(.vertical, 10)
        .background(MainColor.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MainColor.separator).frame(height: 1)
        }
    }

    // MARK: Nothing to show

    @ViewBuilder
    private func empty(nothingAtAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if nothingAtAll {
                Text("Nothing dictated yet. Press \(shortcutText(for: .inline)) in any app, speak, and press it again — every dictation is kept here.")
            } else if query.isEmpty {
                Text("No \(filter == .edits ? "edits" : filter == .failed ? "failed dictations" : "dictations rewritten by AI") yet.")
            } else {
                Text("Nothing matches “\(query)”\(filter == .all ? "" : " in \(filter.title)").")
            }
            if !nothingAtAll {
                HStack(spacing: 8) {
                    if !query.isEmpty {
                        Button("Clear search") { query = "" }
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                    }
                    if filter != .all {
                        Button("Show all") { filter = .all }
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                    }
                }
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(MainColor.ink2)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MainColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    // MARK: Foot

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("History keeps your last 300 dictations on this Mac. The audio of one that failed is kept for 7 days, for a retry.")
                .font(.system(size: 12.5))
                .foregroundStyle(MainColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            HistoryQuietButton(title: "Clear History…", symbol: "trash", destructive: true) { confirmingClear = true }
        }
    }
}

// MARK: - Search field

private struct HistorySearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MainColor.ink3)
            TextField("Search what you said", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(MainColor.ink)
                .focused(focused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(MainColor.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(shape.fill(MainColor.panel))
        .overlay(shape.strokeBorder(focused.wrappedValue ? MainColor.okInk.opacity(0.55) : MainColor.panelBorder,
                                    lineWidth: focused.wrappedValue ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focused.wrappedValue)
    }
}

/// The filters as the intro card's tabs are drawn: a capsule switch, each with its count.
private struct HistoryFilterSwitch: View {
    @Binding var filter: HistoryFilter
    let counts: [HistoryFilter: Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HistoryFilter.allCases) { item in
                button(item)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.ink.opacity(0.06)))
    }

    private func button(_ item: HistoryFilter) -> some View {
        let selected = filter == item
        let count = counts[item] ?? 0
        return Button { filter = item } label: {
            HStack(spacing: 5) {
                Text(item.title)
                    .foregroundStyle(selected ? MainColor.ink : MainColor.ink2)
                Text(HomeFormat.integer(count))
                    .monospacedDigit()
                    .foregroundStyle(item == .failed && count > 0 ? MainColor.problem : MainColor.ink3)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MainColor.card)
                        .shadow(color: Color(hex: 0x182C20).opacity(0.12), radius: 1.5, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(hex: 0x182C20).opacity(0.12), lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - A day

/// A day's name, what it came to, and its dictations in one hairline table — Home's Recent,
/// a day at a time. A busy day shows its latest few and keeps the rest behind Show all, so
/// the days after it are a short scroll away; a search or a filter that leaves a few shows
/// them all.
private struct HistoryDaySection: View {
    let day: HistoryDay
    @Binding var expanded: UUID?
    @Binding var showsAll: Bool

    /// Enough for a morning's dictations, and about a screen.
    static let shown = 8

    private var records: [TranscriptionRecord] {
        // Never fold away the dictation that is open.
        let openIndex = day.records.firstIndex { $0.id == expanded } ?? 0
        guard !showsAll, day.records.count > Self.shown + 2, openIndex < Self.shown else { return day.records }
        return Array(day.records.prefix(Self.shown))
    }

    var body: some View {
        let records = records
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day.title())
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(MainColor.ink)
                if let subtitle = day.subtitle() {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink3)
                }
                Spacer(minLength: 12)
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink3)
                    .monospacedDigit()
            }
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Rectangle().fill(MainColor.separator).frame(height: 1) }
                    HistoryRow(record: record, isExpanded: expanded == record.id) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            expanded = expanded == record.id ? nil : record.id
                        }
                    }
                }
                if records.count < day.records.count || (showsAll && day.records.count > Self.shown + 2) {
                    Rectangle().fill(MainColor.separator).frame(height: 1)
                    HistoryShowAllRow(hidden: day.records.count - records.count, showsAll: showsAll) {
                        withAnimation(.easeOut(duration: 0.2)) { showsAll.toggle() }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var summary: String {
        let count = day.records.count
        let words = day.words
        return (count == 1 ? "1 dictation" : "\(count) dictations")
            + (words > 0 ? " · \(HomeFormat.integer(words)) \(words == 1 ? "word" : "words")" : "")
    }
}

/// The foot of a busy day: how many more there are, or a way to fold them back.
private struct HistoryShowAllRow: View {
    let hidden: Int
    let showsAll: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(showsAll ? "Show fewer" : "Show all · \(hidden) more")
                Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering ? MainColor.okInk : MainColor.ink2)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(hovering ? MainColor.panel : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - A dictation

/// One dictation: closed, Home's Recent row with its time; open, everything History knows
/// about it under the row.
private struct HistoryRow: View {
    let record: TranscriptionRecord
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @State private var copied = false

    private var entry: HomeRecentEntry { HomeRecentEntry(record) }

    var body: some View {
        let entry = entry
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: toggle) {
                    HStack(spacing: 14) {
                        HomeEntryMark(entry: entry)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.text)
                                .font(.system(size: entry.status == .success ? 14 : 13))
                                .foregroundStyle(entry.status == .success ? MainColor.ink : MainColor.ink2)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text(entry.place).fontWeight(.medium).foregroundStyle(MainColor.ink)
                                Text("·")
                                Text(HistoryFormat.clock(record.date)).monospacedDigit()
                                if let length = HistoryFormat.length(record.duration) {
                                    Text("·")
                                    Text(length).monospacedDigit()
                                }
                                HomeEntryTags(tags: entry.tags)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(MainColor.ink2)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")

                quickAction(entry)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering || isExpanded ? MainColor.ink2 : MainColor.ink3)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .onTapGesture(perform: toggle)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 14)

            if isExpanded {
                HistoryDetail(record: record)
                    .transition(.opacity)
            }
        }
        .background(hovering || isExpanded ? MainColor.panel : .clear)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if !record.deliveredText.isEmpty {
                Button("Copy") { HistoryClipboard.copy(record.deliveredText) }
            }
            if record.refinement?.succeeded == true, !record.text.isEmpty, record.text != record.deliveredText {
                Button(record.refinement?.isSelectionEdit == true ? "Copy Instruction" : "Copy What You Said") {
                    HistoryClipboard.copy(record.text)
                }
            }
            if record.isRetryable {
                Button("Retry") { Task { @MainActor in await HistoryRetry.shared.retry(record.id) } }
            }
            Divider()
            Button("Delete", role: .destructive) { TranscriptionHistory.shared.delete(record) }
        }
    }

    /// What the row offers on the right: Retry for a closed failure, Copy otherwise — on
    /// hover, and always while the row is open. Copy stays in the row when it opens, so
    /// the text beside it keeps its width and does not reflow.
    @ViewBuilder
    private func quickAction(_ entry: HomeRecentEntry) -> some View {
        if entry.status != .success {
            if entry.canRetry && !isExpanded { HomeRetryButton(id: record.id) }
        } else {
            HomeCopyButton(text: record.deliveredText, copied: $copied)
                .opacity(hovering || isExpanded || copied ? 1 : 0)
        }
    }
}

enum HistoryClipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - What History knows about it

/// An open row: what was said beside what AI Rewrite made of it, with the prompt it chose;
/// what went wrong and the way to retry; where it went, what heard it, and the actions.
private struct HistoryDetail: View {
    let record: TranscriptionRecord
    @State private var copiedSaid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch record.status {
            case .failed: problem(record.errorMessage ?? "Transcription failed.", danger: true)
            case .empty: problem("Nothing was heard in this recording — a muted microphone, or the shortcut pressed with nothing said.", danger: false)
            case .success: texts
            }
            if hasCopies {
                facts
                actions
            } else {
                // Nothing to copy: Delete keeps to the facts' line rather than a row of its own.
                HStack(alignment: .center, spacing: 12) {
                    facts
                    Spacer(minLength: 8)
                    deleteButton
                }
            }
        }
        .padding(.leading, 58)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    // MARK: The texts

    @ViewBuilder
    private var texts: some View {
        if let refinement = record.refinement {
            let edit = refinement.isSelectionEdit
            if edit {
                (Text("Instruction  ").foregroundStyle(MainColor.ink3)
                 + Text(record.text.isEmpty ? "None — polished" : record.text).foregroundStyle(MainColor.ink))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 10) {
                HistoryTextPane(title: edit ? "Selected text" : "Dictated", symbol: edit ? "text.cursor" : "waveform",
                                text: refinement.inputText, ai: false, model: edit ? nil : engine)
                if refinement.succeeded {
                    HistoryTextPane(title: edit ? "Rewritten" : "AI output", symbol: "sparkles",
                                    text: refinement.outputText, ai: true,
                                    note: edit ? "Replaced the selection" : "Pasted",
                                    model: modelName(refinement))
                } else {
                    HistoryTextPane(title: edit ? "Rewritten" : "AI output", symbol: "sparkles",
                                    text: "", ai: true, model: modelName(refinement),
                                    failure: (edit ? "Didn't work — the selection was left as it was." : "Didn't work — the dictated text was pasted instead.")
                                        + (refinement.errorMessage.map { "\n\($0)" } ?? ""))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HistoryTextPane(title: "Dictated", symbol: "waveform", text: record.text, ai: false, note: "Pasted", model: engine)
        }
    }

    /// What heard it: "ElevenLabs · Ukrainian".
    private var engine: String {
        [HistoryFormat.engine(record.provider), HistoryFormat.language(record.locale)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func modelName(_ refinement: TranscriptionRecord.Refinement) -> String {
        let name = LLMProviderType(rawValue: refinement.provider)
            .flatMap { listedChatModel(provider: $0, id: refinement.model)?.displayName }
        return HomeEngines.plainName(name ?? refinement.model)
    }

    // MARK: A failure

    private func problem(_ message: String, danger: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(danger ? MainColor.problem : MainColor.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.isRetryable
                     ? "The audio is kept until \(HistoryFormat.audioKeptUntil(record)), for a retry with the settings you have now."
                     : "The audio is no longer kept, so this one can't be retried.")
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if record.isRetryable {
                HomeRetryButton(id: record.id, title: "Retry", height: 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(danger ? MainColor.problem.opacity(0.07) : MainColor.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(danger ? MainColor.problem.opacity(0.18) : MainColor.panelBorder, lineWidth: 1))
    }

    // MARK: Where, when, what heard it

    private var facts: some View {
        var parts: [String] = [HistoryFormat.full(record.date)]
        if let length = HistoryFormat.length(record.duration) { parts.append(length) }
        // A success names its engine under what it heard; anything else names it here.
        if record.status != .success || record.refinement?.isSelectionEdit == true { parts.append(engine) }
        if let origin = record.originApp, let destination = record.destinationApp, origin != destination {
            parts.append("started in \(origin), pasted into \(destination)")
        }
        let context = record.refinement?.context?.summary
        return VStack(alignment: .leading, spacing: 4) {
            Text(parts.joined(separator: "  ·  "))
            if let context, !context.isEmpty {
                (Text("AI Rewrite was told it was for ") + Text(context).foregroundStyle(MainColor.ink2))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(record.refinement?.context?.promptBlock ?? "")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(MainColor.ink3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    /// What was pasted is copied from the row's own Copy, which stays in place while the
    /// row is open; only what was said, when it differs, has a button down here.
    private var hasCopies: Bool { saidText != nil }

    private var actions: some View {
        HStack(spacing: 8) {
            if let said = saidText {
                HomeCopyButton(text: said, title: record.refinement?.isSelectionEdit == true ? "Copy instruction" : "Copy what you said",
                               copied: $copiedSaid, height: 28)
            }
            Spacer(minLength: 8)
            deleteButton
        }
    }

    private var deleteButton: some View {
        HistoryQuietButton(title: "Delete", symbol: "trash", destructive: true) {
            withAnimation(.easeOut(duration: 0.2)) { TranscriptionHistory.shared.delete(record) }
        }
    }

    /// What reached the app: the rewrite, or what was said when there was none — and for
    /// an edit that failed, nothing new.
    private var pastedText: String {
        guard let refinement = record.refinement, refinement.isSelectionEdit else { return record.deliveredText }
        return refinement.succeeded ? refinement.outputText : ""
    }

    /// What was said, when it is not already what the Copy button copies.
    private var saidText: String? {
        guard record.status == .success, !record.text.isEmpty, record.text != pastedText,
              record.refinement != nil else { return nil }
        return record.text
    }
}

/// A text with its name above it and what produced it below: what was said on white with
/// the engine that heard it, AI Rewrite's on its violet with the model that ran it — the
/// prompt it chose is the row's tag, just above.
private struct HistoryTextPane: View {
    let title: String
    let symbol: String
    let text: String
    let ai: Bool
    var note: String?
    var model: String?
    var failure: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ai ? MainColor.aiInk : MainColor.okInk)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MainColor.ink)
                if let note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MainColor.ink3)
                }
                Spacer(minLength: 6)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.problem)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text.isEmpty ? "No text" : text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(text.isEmpty ? MainColor.ink3 : MainColor.ink)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let model {
                Text(model)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MainColor.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(ai ? MainColor.aiSoft : MainColor.card))
        .overlay(shape.strokeBorder(ai ? MainColor.ai.opacity(0.22) : MainColor.panelBorder, lineWidth: 1))
    }
}

/// A button that stays out of the way until pointed at: Delete, Clear History…
struct HistoryQuietButton: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering ? (destructive ? MainColor.problem : MainColor.ink) : MainColor.ink2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(hovering ? (destructive ? MainColor.problemSoft : MainColor.panel) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
