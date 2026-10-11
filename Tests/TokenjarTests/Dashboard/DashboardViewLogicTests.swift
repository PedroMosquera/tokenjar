import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct TopProjectsCostColumnTests {
    private let us = Locale(identifier: "en_US")

    @Test func oneRowWithCentsGivesTheWholeColumnCents() {
        #expect(TopProjectsTable.costColumn([351, 0.26], locale: us) == ["$351.00", "$0.26"])
    }

    @Test func aColumnOfWholeOrLargeAmountsDropsTheCents() {
        #expect(TopProjectsTable.costColumn([351, 120, 4], locale: us) == ["$351", "$120", "$4"])
    }

    @Test func unpricedRowsStayEmptyAndDoNotSetThePrecision() {
        #expect(TopProjectsTable.costColumn([210, nil], locale: us) == ["$210", nil])
    }
}
