import SwiftUI
import TokenjarCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    /// Cards grow with their content up to this height, then scroll; header and footer stay put.
    var maxCardsHeight: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader()
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if let configError = model.configError {
                ConfigErrorBanner(message: configError)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            if model.accounts.isEmpty {
                EmptyAccounts()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.accounts) { account in
                            AccountCard(account: account)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxCardsHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
                .padding(.horizontal, 14)
            PopoverFooter()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: 360)
    }
}

private struct ConfigErrorBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.multicolor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct EmptyAccounts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("Add an account in Settings, or sign in to Claude Code, Codex or OpenCode and refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { model.showSettings() }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }
}
