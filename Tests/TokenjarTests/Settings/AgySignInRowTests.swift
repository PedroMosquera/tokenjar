import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AgySignInRowTests {
    /// A failed check keeps the last snapshot, so an account that worked once still has one after agy signs out.
    private let worked = UsageSnapshot(accountID: "agy", provider: .antigravity, windows: [], fetchedAt: Date(timeIntervalSince1970: 1_791_660_000), source: "agy CLI")

    @Test func aSignedOutAccountThatWorkedBeforeSaysSoInsteadOfSignedIn() {
        #expect(AgySignInRow.make(status: AccountStatus(snapshot: worked, error: .notSignedIn)) == .signedOut)
    }

    @Test func aSignedOutAccountThatNeverWorkedHasAgyAlready() {
        #expect(AgySignInRow.make(status: AccountStatus(error: .notSignedIn)) == .signedOut)
    }

    @Test func aMissingCLIOffersTheInstallEvenWithOldData() {
        #expect(AgySignInRow.make(status: AccountStatus(snapshot: worked, error: .cliNotFound("agy"))) == .install)
    }

    @Test func anAccountNeverCheckedOffersTheInstall() {
        #expect(AgySignInRow.make(status: AccountStatus()) == .install)
    }

    @Test func aPassingFailureKeepsTheSignedInRow() {
        #expect(AgySignInRow.make(status: AccountStatus(snapshot: worked)) == .signedIn)
        #expect(AgySignInRow.make(status: AccountStatus(snapshot: worked, error: .timeout)) == .signedIn)
    }
}
