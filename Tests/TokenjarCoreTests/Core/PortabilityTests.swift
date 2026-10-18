import Foundation
import Testing
@testable import TokenjarCore

struct PortabilityTests {
    /// JSONSerialization hands back JSON true and false as NSNumber too, so 1 and true look alike without this check.
    @Test func jsonBooleansAreToldApartFromNumbers() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(#"{"t":true,"f":false,"one":1,"zero":0,"half":0.5}"#.utf8)) as? [String: NSNumber])
        for key in ["t", "f"] { #expect(isJSONBoolean(try #require(object[key])), "\(key)") }
        for key in ["one", "zero", "half"] { #expect(!isJSONBoolean(try #require(object[key])), "\(key)") }
    }
}
