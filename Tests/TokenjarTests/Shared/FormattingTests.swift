import Foundation
import Testing
@testable import Tokenjar

struct FormattingTests {
    private let us = Locale(identifier: "en_US")
    private let decimalComma = Locale(identifier: "de_DE")

    /// Requests and money follow the locale, so token counts beside them must too, or "1.506" and "164.6M" share a row.
    @Test func tokensUseTheLocaleDecimalSeparator() {
        #expect(Format.tokens(1_506, locale: decimalComma) == "1,5k")
        #expect(Format.tokens(164_612_345, locale: decimalComma) == "164,6M")
        #expect(Format.tokens(2_345_678_901, locale: decimalComma) == "2,3B")
        #expect(Format.tokens(164_612_345, locale: us) == "164.6M")
        #expect(Format.tokens(999, locale: us) == "999")
    }

    @Test func tokensPickTheUnitAfterRounding() {
        #expect(Format.tokens(999_949, locale: us) == "999.9k")
        #expect(Format.tokens(999_950, locale: us) == "1.0M")
        #expect(Format.tokens(999_960_000, locale: us) == "1.0B")
    }

    @Test func wholeAmountsDropTheCents() {
        #expect(Format.money(30, locale: us) == "$30")
        #expect(Format.money(0, locale: us) == "$0")
        #expect(Format.money(12.4, locale: us) == "$12.40")
        #expect(Format.money(1_234.6, locale: us) == "$1,235")
    }

    @Test func anAmountAndItsLimitShareOnePrecision() {
        #expect(Format.moneyUsed(12.4, of: 100, locale: us) == "$12.40 used of $100.00")
        #expect(Format.moneyUsed(150.3, of: 200, locale: us) == "$150 used of $200")
        #expect(Format.moneyUsed(20, of: 100, locale: us) == "$20 used of $100")
    }
}
