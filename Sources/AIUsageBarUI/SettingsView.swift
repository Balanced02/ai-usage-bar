import AppKit
import Foundation
import SwiftUI
import AIUsageBarCore

/// The explicit, draft-backed Settings window content.
///
/// Edits stay in `draft` until Apply succeeds, so Cancel can always restore the
/// currently running configuration without changing it.
public struct SettingsView: View {
    @Bindable private var model: AppModel
    @State private var draft: SettingsDraft
    @State private var detectedProfiles: [ClaudeProfile]
    @State private var errorMessage: String?

    @MainActor
    public init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settingsDraft())
        _detectedProfiles = State(initialValue: model.automaticClaudeProfiles())
    }

    public var body: some View {
        ScrollView {
            Form {
                generalSection
                claudeSection
                providersSection
                dataLocationsSection
                customProvidersSection
                footerSection
            }
            .formStyle(.grouped)
            .padding(.horizontal)
        }
        .frame(minWidth: 580, minHeight: 600)
    }

    // Connect is an immediate action (it reads the Keychain now), so it's a button
    // rather than a draft-backed toggle that would only take effect on Apply.
    private var claudeSection: some View {
        Section("Claude") {
            LabeledContent("Live limits") {
                if model.claudeConnected {
                    HStack(spacing: 10) {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).labelStyle(.titleAndIcon).font(.callout)
                        Button("Disconnect") { model.disconnectClaude() }
                    }
                } else {
                    Button("Connect…") { model.connectClaude() }
                }
            }
            Text("Reads the token Claude Code already stored in your Keychain to show live 5-hour and weekly limits — macOS asks once. Your account and cost still show without connecting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Picker("Refresh cadence", selection: $draft.cadenceSeconds) {
                Text("30 seconds").tag(30.0)
                Text("45 seconds").tag(45.0)
                Text("1 minute").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
            }

            Picker("Menu bar style", selection: $draft.menuBarStyle) {
                ForEach(MenuBarStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }

            Picker("Monthly budget", selection: $draft.monthlyBudgetUSD) {
                Text("Off").tag(0.0)
                Text("$50").tag(50.0)
                Text("$100").tag(100.0)
                Text("$250").tag(250.0)
                Text("$500").tag(500.0)
                Text("$1000").tag(1000.0)
            }

            Toggle("Notifications", isOn: $draft.notificationsEnabled)
            Toggle("Mask account details", isOn: $draft.maskAccounts)
            Toggle("Launch at login", isOn: $draft.launchAtLogin)
        }
    }

    private var providersSection: some View {
        Section("Providers") {
            Toggle("Codex", isOn: $draft.codexEnabled)
            Toggle("Claude", isOn: $draft.claudeEnabled)
            Toggle("Gemini", isOn: $draft.geminiEnabled)
        }
    }

    private var dataLocationsSection: some View {
        Section("Data locations") {
            dataRootRow(
                label: "Codex data folder",
                url: draft.providerSettings.codexHome,
                choose: chooseCodexFolder,
                reset: { draft.providerSettings.codexHome = nil }
            )

            dataRootRow(
                label: "Gemini data folder",
                url: draft.providerSettings.geminiHome,
                choose: chooseGeminiFolder,
                reset: { draft.providerSettings.geminiHome = nil }
            )

            Divider()

            Text("Automatic Claude profiles")
                .font(.subheadline.weight(.semibold))

            if detectedProfiles.isEmpty {
                Text("No Claude profiles detected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detectedProfiles) { profile in
                    detectedProfileRow(profile)
                }
            }

            Button("Rescan", action: rescanProfiles)

            Divider()

            Text("Manual Claude profiles")
                .font(.subheadline.weight(.semibold))

            if draft.providerSettings.manualClaudeProfiles.isEmpty {
                Text("Add a named profile to use another Claude configuration folder.")
                    .foregroundStyle(.secondary)
            }

            ForEach($draft.providerSettings.manualClaudeProfiles) { profile in
                manualProfileRow(profile)
            }

            Button("Add profile", action: addProfile)
        }
    }

    private var customProvidersSection: some View {
        Section("Custom providers") {
            if draft.providerSettings.customProviders.isEmpty {
                Text("Point at any tool that writes rate-limit JSON to a folder of .jsonl logs — no code.")
                    .foregroundStyle(.secondary)
            }
            ForEach($draft.providerSettings.customProviders) { provider in
                customProviderRow(provider)
            }
            Button("Add custom provider", action: addCustomProvider)
        }
    }

    private var footerSection: some View {
        Section {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: resetFromModel)
                Button("Apply", action: applyDraft)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func customProviderRow(_ provider: Binding<CustomProviderConfig>) -> some View {
        let id = provider.wrappedValue.id
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: provider.name)
            Text(provider.wrappedValue.folder.path)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            TextField("Used-percent path (e.g. rate_limit.used_percent)", text: provider.percentPath)
                .font(.caption.monospaced())
            TextField("Reset path — optional (e.g. rate_limit.resets_at)", text: Binding(
                get: { provider.wrappedValue.resetPath ?? "" },
                set: { provider.wrappedValue.resetPath = $0.isEmpty ? nil : $0 }))
                .font(.caption.monospaced())
            TextField("Window label (e.g. Daily)", text: provider.windowLabel)
            HStack {
                Button("Choose folder") { chooseCustomFolder(id: id) }
                Button("Remove", role: .destructive) {
                    draft.providerSettings.customProviders.removeAll { $0.id == id }
                }
            }
        }
    }

    private func chooseCustomFolder(id: UUID) {
        chooseFolder(title: "Choose provider log folder") { url in
            guard let i = draft.providerSettings.customProviders.firstIndex(where: { $0.id == id }) else { return }
            draft.providerSettings.customProviders[i].folder = url
        }
    }

    private func addCustomProvider() {
        draft.providerSettings.customProviders.append(
            CustomProviderConfig(name: "New provider",
                                 folder: FileManager.default.homeDirectoryForCurrentUser,
                                 percentPath: "rate_limit.used_percent",
                                 resetPath: nil, windowLabel: "Usage"))
    }

    private func dataRootRow(label: String, url: URL?, choose: @escaping () -> Void,
                             reset: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(url?.path ?? "Automatic")
                    .font(.caption.monospaced())
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack {
                    Button("Choose folder", action: choose)
                    if url != nil {
                        Button("Use automatic", action: reset)
                    }
                }
            }
        }
    }

    private func detectedProfileRow(_ profile: ClaudeProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(profile.name)
                if profile.isDefault {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(profile.configDir.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func manualProfileRow(_ profile: Binding<ManualClaudeProfile>) -> some View {
        let id = profile.wrappedValue.id
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: profile.name)
            Text(profile.wrappedValue.configDir.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Button("Choose folder") { chooseClaudeFolder(id: id) }
                Button("Remove", role: .destructive) {
                    draft.providerSettings.manualClaudeProfiles.removeAll { $0.id == id }
                }
            }
        }
    }

    private func chooseCodexFolder() {
        chooseFolder(title: "Choose Codex data folder") { url in
            draft.providerSettings.codexHome = url
        }
    }

    private func chooseGeminiFolder() {
        chooseFolder(title: "Choose Gemini data folder") { url in
            draft.providerSettings.geminiHome = url
        }
    }

    private func chooseClaudeFolder(id: UUID) {
        chooseFolder(title: "Choose Claude profile folder") { url in
            guard let index = draft.providerSettings.manualClaudeProfiles.firstIndex(where: { $0.id == id })
            else { return }
            draft.providerSettings.manualClaudeProfiles[index].configDir = url
        }
    }

    private func chooseFolder(title: String, onChoose: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChoose(url.standardizedFileURL)
    }

    private func addProfile() {
        draft.providerSettings.manualClaudeProfiles.append(
            ManualClaudeProfile(
                name: "New profile",
                configDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            )
        )
    }

    private func rescanProfiles() {
        detectedProfiles = model.automaticClaudeProfiles()
    }

    private func applyDraft() {
        let draftToApply = draft
        Task { @MainActor in
            errorMessage = await model.apply(draftToApply)
            if errorMessage == nil {
                resetFromModel()
            }
        }
    }

    private func resetFromModel() {
        draft = model.settingsDraft()
        detectedProfiles = model.automaticClaudeProfiles()
        errorMessage = nil
    }
}
