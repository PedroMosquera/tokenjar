import Foundation

/// ECB euro foreign-exchange reference rates: units of each currency per one euro.
public struct ExchangeRates: Codable, Hashable, Sendable {
    /// The ECB's Cube `time`, "yyyy-MM-dd".
    public var date: String
    public var perEUR: [String: Double]

    public init(date: String, perEUR: [String: Double]) {
        self.date = date
        self.perEUR = perEUR
    }

    /// Reads the ECB `eurofxref-daily.xml` body. Throws `FetchError.parse` without a dated Cube or a USD rate.
    public static func parse(_ data: Data) throws -> ExchangeRates {
        let reader = CubeReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard let date = reader.date, let usd = reader.rates["USD"], usd > 0 else {
            throw FetchError.parse("ECB rates: no dated Cube or no USD rate")
        }
        return ExchangeRates(date: date, perEUR: reader.rates)
    }

    public func perUSD(_ code: String) -> Double? {
        if code == "USD" { return 1 }
        guard let usd = perEUR["USD"], usd > 0 else { return nil }
        if code == "EUR" { return 1 / usd }
        return perEUR[code].map { $0 / usd }
    }

    public func convert(usd: Double, to code: String) -> Double? {
        perUSD(code).map { usd * $0 }
    }
}

private final class CubeReader: NSObject, XMLParserDelegate {
    var date: String?
    var rates: [String: Double] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Cube" else { return }
        if let time = attributeDict["time"] {
            date = time
        } else if let code = attributeDict["currency"], let rate = attributeDict["rate"].flatMap(Double.init) {
            rates[code] = rate
        }
    }
}
