import Testing
@testable import Tokenjar

struct NumericFieldTests {
    @Test func raisingAmberToRedPushesRedUp() {
        #expect(UsageLevels.pushAlong(warn: 96, critical: 95) == UsageLevels.Levels(warn: 96, critical: 97))
        #expect(UsageLevels.pushAlong(warn: 95, critical: 95) == UsageLevels.Levels(warn: 95, critical: 96))
    }

    @Test func amberStopsAt99SoRedCanStillSitAboveIt() {
        #expect(UsageLevels.pushAlong(warn: 100, critical: 95) == UsageLevels.Levels(warn: 99, critical: 100))
    }

    @Test func loweringRedToAmberPushesAmberDown() {
        #expect(UsageLevels.pushAlong(warn: 80, critical: 70, keeping: .critical) == UsageLevels.Levels(warn: 69, critical: 70))
        #expect(UsageLevels.pushAlong(warn: 80, critical: 80, keeping: .critical) == UsageLevels.Levels(warn: 79, critical: 80))
        #expect(UsageLevels.pushAlong(warn: 80, critical: 1, keeping: .critical) == UsageLevels.Levels(warn: 1, critical: 2))
    }

    @Test func levelsAlreadyInOrderAreKept() {
        #expect(UsageLevels.pushAlong(warn: 80, critical: 95) == UsageLevels.Levels(warn: 80, critical: 95))
        #expect(UsageLevels.pushAlong(warn: 80, critical: 95, keeping: .critical) == UsageLevels.Levels(warn: 80, critical: 95))
    }

    @Test func addThresholdOffersAValueNotListedYet() {
        #expect(ThresholdRows.seed(after: []) == 90)
        #expect(ThresholdRows.seed(after: [80, 95]) == 90)
        #expect(ThresholdRows.seed(after: [70, 90]) == 50)
        #expect(ThresholdRows.seed(after: [50, 90]) == 25)
        #expect(ThresholdRows.seed(after: [10, 50, 90]) == 30)
        #expect(ThresholdRows.seed(after: Array(1...100)) == nil)
    }
}
