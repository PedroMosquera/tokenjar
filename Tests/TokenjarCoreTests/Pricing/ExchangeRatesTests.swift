import Foundation
import Testing
@testable import TokenjarCore

struct ExchangeRatesTests {
    static let ecb = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
    <gesmes:subject>Reference rates</gesmes:subject>
    <Cube><Cube time="2026-10-30"><Cube currency="USD" rate="1.0870"/><Cube currency="JPY" rate="162.50"/><Cube currency="GBP" rate="0.8400"/></Cube></Cube>
    </gesmes:Envelope>
    """.utf8)

    @Test func parsesTheDateAndEveryRate() throws {
        let rates = try ExchangeRates.parse(Self.ecb)
        #expect(rates.date == "2026-10-30")
        #expect(rates.perEUR == ["USD": 1.087, "JPY": 162.5, "GBP": 0.84])
    }

    @Test func convertsFromUSDThroughTheEuro() throws {
        let rates = try ExchangeRates.parse(Self.ecb)
        #expect(rates.perUSD("USD") == 1)
        #expect(abs(rates.perUSD("EUR")! - 0.919963) < 1e-6)
        #expect(abs(rates.perUSD("GBP")! - 0.772769) < 1e-6)
        #expect(abs(rates.perUSD("JPY")! - 149.494) < 1e-3)
        #expect(rates.perUSD("CHF") == nil)
        #expect(abs(rates.convert(usd: 100, to: "EUR")! - 91.9963) < 1e-3)
    }

    @Test func aBodyWithoutUSDOrADateDoesNotParse() {
        let noDate = Data(#"<Cube><Cube><Cube currency="USD" rate="1.0870"/></Cube></Cube>"#.utf8)
        let noUSD = Data(#"<Cube><Cube time="2026-10-30"><Cube currency="JPY" rate="162.50"/></Cube></Cube>"#.utf8)
        for body in [noDate, noUSD] {
            #expect {
                try ExchangeRates.parse(body)
            } throws: { error in
                guard case FetchError.parse = error else { return false }
                return true
            }
        }
    }
}
