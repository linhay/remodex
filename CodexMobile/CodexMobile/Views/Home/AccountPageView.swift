import SwiftUI

struct AccountPageView: View {
    let connectionPhase: CodexConnectionPhase
    let securityLabel: String?
    let hasAccounts: Bool
    let hasSavedRelaySession: Bool
    let accounts: [CodexRelayAccountProfile]
    let activeRelayAccountID: String?
    let isConnected: Bool
    let accountMessage: String?
    let openingAccountID: String?
    let accentColor: Color
    let lastConnectedText: (CodexRelayAccountProfile) -> String?
    let onToggleConnection: () -> Void
    let onAddAccount: () -> Void
    let onScanNewQRCode: () -> Void
    let onOpenAccount: (String) -> Void
    let onRenameAccount: (CodexRelayAccountProfile) -> Void
    let onDeleteAccount: (CodexRelayAccountProfile) -> Void

    var body: some View {
        HomeEmptyStateView(
            connectionPhase: connectionPhase,
            securityLabel: securityLabel,
            showsHeroSection: ContentAccountHomePresentationPolicy.showsHeroSection(
                hasAccounts: hasAccounts
            ),
            showsPrimaryAction: hasAccounts,
            onToggleConnection: onToggleConnection
        ) {
            VStack(spacing: 12) {
                if !hasAccounts {
                    SettingsButton("Add Account", action: onAddAccount)
                }

                if connectionPhase == .connecting || (hasSavedRelaySession && !isConnected) {
                    Button("Scan New QR Code", action: onScanNewQRCode)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .buttonStyle(.plain)
                }

                if hasAccounts {
                    accountListSection
                }
            }
        }
    }

    private var accountListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let accountMessage = accountMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !accountMessage.isEmpty {
                Text(accountMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 8) {
                ForEach(accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    private func accountRow(_ account: CodexRelayAccountProfile) -> some View {
        let isCurrent = activeRelayAccountID == account.id
        let isConnectedCurrent = isCurrent && isConnected
        let isOpening = openingAccountID == account.id

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if isCurrent {
                        badge("Current", tint: accentColor)
                    }
                    if isConnectedCurrent {
                        badge("Connected", tint: .green)
                    }
                    if isOpening {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Opening")
                                .font(AppFont.caption(weight: .semibold))
                        }
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accentColor.opacity(0.12))
                        )
                    }
                }

                Text(account.relayURL)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let lastConnectedText = lastConnectedText(account) {
                    Text(lastConnectedText)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }

                if let lastError = account.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !lastError.isEmpty {
                    Text(lastError)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Menu {
                Button("Rename") {
                    onRenameAccount(account)
                }
                Button("Delete", role: .destructive) {
                    onDeleteAccount(account)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? accentColor.opacity(0.12) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCurrent ? accentColor : Color(.separator), lineWidth: isCurrent ? 1.5 : 1)
        )
        .opacity(isOpening ? 0.92 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.row.\(account.id)")
        .onTapGesture {
            onOpenAccount(account.id)
        }
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}
