import SwiftUI
import TokenjarCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    /// Cards grow with their content up to this height, then scroll; header and footer stay put. Under a lower
    /// `popoverMaxHeight` the cards give up the difference, as the only part of the stack that can shrink.
    var maxCardsHeight: CGFloat = 540
    @StateObject private var burnUps = BurnUpSamples()

    /// Cards sit this far in and pad their content by `cardPadding`, so the header icon, the card content and the
    /// footer's first icon share one leading edge.
    static let cardMargin: CGFloat = 10
    static let cardPadding: CGFloat = 12
    private static let contentEdge = cardMargin + cardPadding
    private static let dividerInset: CGFloat = 14
    /// SF Symbols start their ink this far inside their frame at the header's and footer's sizes, where the cards'
    /// logos and text start right on the edge, so a leading symbol is pulled left by this much.
    static let symbolBearing: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader()
                .padding(.horizontal, Self.contentEdge)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if let configError = model.configError {
                // While edits are off, fixing the file and reloading is the way out, as on Settings' banner.
                ConfigErrorBanner(message: configError, file: model.canEditConfig ? nil : model.settingsProblem?.file)
                    .padding(.horizontal, Self.cardMargin)
                    .padding(.bottom, 10)
            }
            Divider()
                .padding(.horizontal, Self.dividerInset)
            if model.accounts.isEmpty {
                // With no settings loaded, "Add an account" would contradict the banner: the accounts exist, unread.
                if model.settingsProblem?.nothingLoaded != true { EmptyAccounts() }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.accounts) { account in
                            AccountCard(account: account, burnUps: burnUps)
                        }
                    }
                    .padding(Self.cardMargin)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxCardsHeight)
            }
            Divider()
                .padding(.horizontal, Self.dividerInset)
            // The footer's buttons pad their labels by 8 pt for the hover highlight.
            PopoverFooter()
                .padding(.leading, Self.contentEdge - 8 - Self.symbolBearing)
                .padding(.trailing, Self.contentEdge - 8)
                .padding(.vertical, 6)
        }
        .frame(width: 360)
        .frame(maxHeight: model.popoverMaxHeight)
    }
}

private struct ConfigErrorBanner: View {
    @Environment(AppModel.self) private var model
    var message: String
    /// The settings file at fault, offered with Reveal in Finder and Reload; nil shows the message alone.
    var file: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let file {
                HStack(spacing: 6) {
                    Button("Reveal in Finder") { model.revealConfigFile(file) }
                    Button("Reload") { model.loadConfig() }
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(PopoverView.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct EmptyAccounts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("Add an account to see its usage limits here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { model.showSettings() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}
