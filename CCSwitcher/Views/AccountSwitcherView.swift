import SwiftUI

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAddConfirm = false
    @State private var authCode = ""
    @State private var isSubmittingCode = false
    @State private var showingAddRelay = false
    @State private var relayName = ""
    @State private var relayBaseURL = ""
    @State private var relayToken = ""
    @State private var relayTestResult: ClaudeService.RelayTestResult?
    @State private var isTestingRelay = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if appState.accounts.isEmpty {
                    emptyState
                } else {
                    ForEach(appState.accounts) { account in
                        accountRow(account)
                    }
                }

                addAccountButtons
            }
            .padding(16)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No Accounts")
                .font(.headline)

            Text("Add your current Claude Code account to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            // Provider icon
            Image(systemName: account.isRelay ? "network" : account.provider.iconName)
                .font(.title2)
                .foregroundStyle(account.isActive ? .brand : .secondary)
                .frame(width: 32, height: 32)

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.displayName)
                        .font(.subheadline.weight(.medium))

                    if account.isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green, in: Capsule())
                    }
                }

                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let sub = account.subscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(account.isRelay ? "Relay" : account.provider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Actions
            if !account.isActive {
                Button("Switch") {
                    Task { await appState.switchTo(account) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.brand)
                .disabled(appState.isLoading)
            }

            if !account.isRelay {
                Button {
                    appState.startReauthenticate(account)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Re-authenticate (fix stale token)")
            }

            Button {
                Task { await appState.removeAccount(account) }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(account.isActive ? .cardFillStrong : .clear)
                .strokeBorder(account.isActive ? .cardBorderBrand : .cardBorderNeutral, lineWidth: 1)
        )
    }

    // MARK: - Add Account Buttons

    private func submitCode() {
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !isSubmittingCode else { return }
        isSubmittingCode = true
        appState.loginTask = Task {
            await appState.submitAuthCode(code)
            isSubmittingCode = false
            // Clear the field once the login left the pending state (success or cancel)
            if !appState.isLoggingIn { authCode = "" }
        }
    }

    @ViewBuilder
    private var addAccountButtons: some View {
        if appState.isLoggingIn {
            // Native OAuth: authorize in browser, then paste the code shown
            VStack(spacing: 8) {
                Text("Finish sign-in in your browser")
                    .font(.caption.weight(.medium))
                Text("Authorize in the page we opened, copy the code it shows, then paste it below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Paste authorization code", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(isSubmittingCode)
                    .onSubmit { submitCode() }

                HStack(spacing: 8) {
                    Button("Cancel") {
                        authCode = ""
                        appState.cancelLogin()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reopen Page") {
                        appState.reopenAuthPage()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        submitCode()
                    } label: {
                        if isSubmittingCode {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Complete Login")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                    .controlSize(.small)
                    .disabled(isSubmittingCode || authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorderBrand, lineWidth: 1)
            )
        } else if showingAddRelay {
            relayForm
        } else if showingAddConfirm {
            // Inline confirmation for "Add Current"
            VStack(spacing: 8) {
                Text("This will capture the currently logged-in Claude Code account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation { showingAddConfirm = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Add Account") {
                        showingAddConfirm = false
                        Task { await appState.addAccount() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorderBrand, lineWidth: 1)
            )
        } else {
            VStack(spacing: 8) {
                // Primary: Login new account via browser
                Button {
                    appState.startLoginNewAccount()
                } label: {
                    Label("Login New Account", systemImage: "person.badge.plus")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)

                // Secondary: Capture already-logged-in account
                Button {
                    withAnimation { showingAddConfirm = true }
                } label: {
                    Label("Add Current Account", systemImage: "plus.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    withAnimation { showingAddRelay = true }
                } label: {
                    Label("Add Relay Station", systemImage: "network")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Relay Form

    private var relayForm: some View {
        VStack(spacing: 8) {
            Text("Add Relay Station")
                .font(.caption.weight(.medium))

            TextField("Name (e.g. xtoken claude0.18)", text: $relayName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("Base URL (e.g. https://api.xtokenmirror.com)", text: $relayBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            TextField("Token (sk-...)", text: $relayToken)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if let result = relayTestResult {
                Text((result.ok ? "✓ " : "✗ ") + result.message)
                    .font(.caption2)
                    .foregroundStyle(result.ok ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    withAnimation { showingAddRelay = false }
                    clearRelayForm()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    isTestingRelay = true
                    relayTestResult = nil
                    Task {
                        relayTestResult = await appState.testRelay(baseURL: relayBaseURL, token: relayToken)
                        isTestingRelay = false
                    }
                } label: {
                    if isTestingRelay {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTestingRelay || relayBaseURL.isEmpty || relayToken.isEmpty)

                Button("Save") {
                    if appState.addRelayAccount(name: relayName, baseURL: relayBaseURL, token: relayToken) {
                        withAnimation { showingAddRelay = false }
                        clearRelayForm()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .controlSize(.small)
                .disabled(relayName.isEmpty || relayBaseURL.isEmpty || relayToken.isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.cardFillStrong)
                .strokeBorder(.cardBorderBrand, lineWidth: 1)
        )
    }

    private func clearRelayForm() {
        relayName = ""
        relayBaseURL = ""
        relayToken = ""
        relayTestResult = nil
    }
}
