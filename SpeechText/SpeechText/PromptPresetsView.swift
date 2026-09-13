import SwiftUI

/// Editor for the prompt presets the LLM routes between.
struct PromptPresetsView: View {
    let onClose: () -> Void

    @State private var presets: [PromptPreset] = PromptPresetStore.load()
    @State private var selection: PromptPreset.ID?
    @State private var defaultID: UUID?
    @State private var showResetConfirm = false

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return presets.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                presetList
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)
                detailPane
                    .frame(minWidth: 340)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear {
            defaultID = PromptPresetStore.defaultPreset(in: presets)?.id
            selection = presets.first?.id
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt Presets")
                .font(.headline)
            Text("""
            The model reads every preset's “When to use” and picks the one that matches \
            what you asked for while dictating, then applies its instructions. Make the \
            “When to use” lines describe distinct situations so they don't overlap.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - List

    @ViewBuilder
    private var presetList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(presets) { preset in
                    HStack(spacing: 6) {
                        Text(preset.name.isEmpty ? "Untitled" : preset.name)
                            .lineLimit(1)
                        Spacer()
                        if preset.id == defaultID {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Default preset")
                        }
                    }
                    .tag(preset.id)
                }
                .onMove { from, to in
                    presets.move(fromOffsets: from, toOffset: to)
                    persist()
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Button {
                    let new = PromptPreset(name: "New preset", whenToUse: "", instructions: "")
                    presets.append(new)
                    selection = new.id
                    persist()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a preset")

                Button {
                    guard let index = selectedIndex, presets.count > 1 else { return }
                    let removed = presets.remove(at: index)
                    if removed.id == defaultID {
                        defaultID = presets.first?.id
                        if let id = defaultID { PromptPresetStore.setDefaultPreset(id) }
                    }
                    selection = presets.first?.id
                    persist()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedIndex == nil || presets.count <= 1)
                .help("Delete the selected preset")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let index = selectedIndex {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labeled("Name") {
                        TextField("", text: binding(index, \.name))
                            .textFieldStyle(.roundedBorder)
                    }

                    labeled("When to use", hint: "How the model recognises that this preset fits the dictation.") {
                        TextEditor(text: binding(index, \.whenToUse))
                            .font(.system(size: 12))
                            .frame(height: 78)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    }

                    labeled("Instructions", hint: "What the model does to the text once this preset is picked.") {
                        TextEditor(text: binding(index, \.instructions))
                            .font(.system(size: 12))
                            .frame(minHeight: 150)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    }

                    Toggle("Use as the default preset", isOn: Binding(
                        get: { presets[index].id == defaultID },
                        set: { isOn in
                            guard isOn else { return }
                            defaultID = presets[index].id
                            PromptPresetStore.setDefaultPreset(presets[index].id)
                        }
                    ))
                    .help("Applied when no other preset clearly matches what you dictated.")
                }
                .padding(14)
            }
        } else {
            Text("Select a preset")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(
        _ title: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Restore Defaults") { showResetConfirm = true }
                .confirmationDialog(
                    "Replace all presets with the built-in ones?",
                    isPresented: $showResetConfirm
                ) {
                    Button("Restore Defaults", role: .destructive) {
                        PromptPresetStore.resetToDefaults()
                        presets = PromptPresetStore.builtInDefaults
                        defaultID = PromptPresetStore.defaultPreset(in: presets)?.id
                        selection = presets.first?.id
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your custom presets will be deleted.")
                }

            Spacer()

            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func binding(_ index: Int, _ keyPath: WritableKeyPath<PromptPreset, String>) -> Binding<String> {
        Binding(
            get: { index < presets.count ? presets[index][keyPath: keyPath] : "" },
            set: {
                guard index < presets.count else { return }
                presets[index][keyPath: keyPath] = $0
                persist()
            }
        )
    }

    private func persist() {
        PromptPresetStore.save(presets)
    }
}

// MARK: - Window

final class PromptPresetsWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Prompt Presets"
        isReleasedWhenClosed = false
        center()
        contentView = NSHostingView(rootView: PromptPresetsView(onClose: { [weak self] in
            self?.close()
        }))
    }
}
