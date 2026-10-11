import Testing
@testable import Tokenjar

struct RefreshIntervalTests {
    @Test func oneMinuteIsSingular() {
        #expect(RefreshInterval.label(1) == "1 minute")
        #expect(RefreshInterval.label(10) == "10 minutes")
        #expect(RefreshInterval.label(30) == "30 minutes")
    }

    @Test func theInheritedChoiceNamesWhereItComesFrom() {
        #expect(RefreshInterval.inheritedLabel(globalMinutes: 10) == "Same as General (10 minutes)")
        #expect(RefreshInterval.inheritedLabel(globalMinutes: 1) == "Same as General (1 minute)")
    }
}
