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
    @State private var errorMessage: String?

    @MainActor
    public init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settingsDraft())
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

    // Sign-in is an immediate action (opens the browser now), so it's a button
    // rather than a draft-backed toggle that would only take effect on Apply.
    private var claudeSection: some View {
        Section("Claude") {
            ForEach(model.claudeAccounts) { account in
                ClaudeAccountRow(account: account, model: model)
            }
            LabeledContent("Account") {
                if model.signingInClaude {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in…").foregroundStyle(.secondary)
                    }
                } else {
                    Button(model.claudeAccounts.isEmpty ? "Add account…" : "Add another…") {
                        model.addClaudeAccount()
                    }
                }
            }
            if let err = model.claudeSignInError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Text("Sign in with Claude to show live 5-hour and weekly limits — the app mints its own token, so macOS never prompts. Point an account at its logs folder to also show $ cost (there's no cost API; it's read from local logs).")
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
        errorMessage = nil
    }
}

/// One signed-in Claude account: an editable name and a typed cost-logs path (both
/// committed on blur/Enter, never per-keystroke — per-keystroke would re-hit the
/// usage endpoint on every character).
struct ClaudeAccountRow: View {
    let account: ClaudeAccountSummary
    let model: AppModel
    @State private var draftName: String = ""
    @State private var draftLogs: String = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var logsFocused: Bool

    /// The custom name as edited ("" = no custom name → falls back to the email).
    private var currentName: String { account.name ?? "" }
    /// The logs path as typed (tilde-abbreviated), "" = cost off.
    private var currentLogs: String {
        account.logsDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                // Email is the placeholder — an empty field means "use the email".
                TextField(account.email ?? "Name", text: $draftName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                if let email = account.email, account.name != nil {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Remove", role: .destructive) { model.removeClaudeAccount(account.key) }
            }
            HStack(spacing: 6) {
                Text("Cost logs").font(.caption).foregroundStyle(.secondary)
                TextField("~/.claude   (blank = cost off)", text: $draftLogs)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .focused($logsFocused)
                    .onSubmit(commitLogs)
                    .onChange(of: logsFocused) { _, focused in if !focused { commitLogs() } }
                Button("~/.claude") { draftLogs = "~/.claude"; commitLogs() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .onAppear { draftName = currentName; draftLogs = currentLogs }
        .onChange(of: account) { _, _ in
            if !nameFocused { draftName = currentName }
            if !logsFocused { draftLogs = currentLogs }
        }
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or literally the email, means "no custom name" → store nothing.
        let newName = (trimmed.isEmpty ||
                       trimmed.caseInsensitiveCompare(account.email ?? "\u{0}") == .orderedSame) ? "" : trimmed
        guard newName != currentName else { return }   // only when actually changed
        draftName = newName                            // reflect the normalization
        model.renameClaudeAccount(account.key, to: newName)
    }

    private func commitLogs() {
        let trimmed = draftLogs.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        guard expanded != account.logsDir else { return }
        model.setClaudeAccountLogs(account.key, dir: expanded)
    }
}
