import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

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

    @Test func aSpendLimitReadsAsSpentOfTheLimit() {
        #expect(Format.moneySpent(477.15, of: 3000, locale: us) == "$477 of $3,000 spent")
        #expect(Format.moneySpent(12.4, of: 50, locale: us) == "$12.40 of $50.00 spent")
    }

    @Test func todaysSpendNamesItsBudget() {
        let utc = TimeZone(identifier: "UTC")!
        func line(_ spent: Double, _ budget: Double, recommended: Bool = false, from: Date? = nil) -> String {
            let day = DailySpend(
                spent: spent, budget: budget, isRecommended: recommended, currency: "USD", dayStart: .distantPast, dayEnd: .distantFuture, countedFrom: from
            )
            return Format.dailySpend(day, locale: us, timeZone: utc)
        }
        #expect(line(79, 100) == "$79 of $100 daily budget")
        #expect(line(79.4, 133.2, recommended: true) == "$79 of $133 recommended for today")
        #expect(line(175, 133) == "$175 of $133 daily budget · $42 over")
        // Under $100 a day the cents carry the information, as with a $200 monthly limit.
        #expect(line(4.27, 6.14, recommended: true) == "$4.27 of $6.14 recommended for today")
        #expect(line(7.5, 6.14) == "$7.50 of $6.14 daily budget · $1.36 over")
        #expect(line(12, 100, from: DateParsing.iso8601("2026-10-13T09:14:00Z")) == "$12 of $100 daily budget · since 9:14\u{202F}AM")
    }

    /// Rounding must never call a window empty while it has use, or full while it has room.
    @Test func percentNeverRoundsToAnEdgeItHasNotReached() {
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(0.04) == "<1%")
        #expect(Format.percent(0.6) == "<1%")
        #expect(Format.percent(1) == "1%")
        #expect(Format.percent(42.4) == "42%")
        #expect(Format.percent(99.6) == "99%")
        #expect(Format.percent(100) == "100%")
        #expect(Format.percent(112) == "112%")
    }

    @Test func durationsDropAZeroTrailingUnit() {
        #expect(Format.duration(259_200) == "3d")
        #expect(Format.duration(7_200) == "2h")
        #expect(Format.duration(6_480) == "1h 48m")
        #expect(Format.duration(3 * 86_400 + 4 * 3_600 + 59) == "3d 4h")
        #expect(Format.duration(12 * 60) == "12m")
        #expect(Format.duration(30) == "<1m")
    }

    /// VoiceOver reads "48m" as meters, so accessibility text spells the units out.
    @Test func spokenDurationsSpellTheUnitsOut() {
        #expect(Format.spokenDuration(6_480) == "1 hour, 48 minutes")
        #expect(Format.spokenDuration(47 * 60) == "47 minutes")
        #expect(Format.spokenDuration(2 * 86_400 + 4 * 3_600 + 10 * 60) == "2 days, 4 hours")
        #expect(Format.spokenDuration(20) == "less than a minute")
    }
}
