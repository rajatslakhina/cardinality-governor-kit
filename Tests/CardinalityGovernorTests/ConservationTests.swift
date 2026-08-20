import XCTest
@testable import CardinalityGovernor

/// The module's headline claim — "collapsing a label never drops an observation" — and
/// the proof that the checker enforcing it can actually fail.
final class ConservationTests: XCTestCase {

    private let locale = DimensionKey("locale")

    private func openSchema(floor: Int = 4) -> DimensionSchema {
        var schema = DimensionSchema()
        schema.declare(locale, .open(floor: floor))
        return schema
    }

    // MARK: The auditor itself must be falsifiable

    /// A validator that has only ever been shown to return "OK" is not evidence.
    ///
    /// This feeds the auditor the exact tally a *broken* governor would produce — one that
    /// drops the observation instead of collapsing the label, which is what every
    /// "sample it away" implementation does — and asserts it is caught.
    func testAuditorDetectsAnImplementationThatDropsObservations() {
        var droppingTally: [LabelSet: Int] = [:]
        droppingTally[LabelSet([locale: "en_US"])] = 700
        // 1000 admitted, only 700 tallied: 300 observations silently vanished.
        let finding = ConservationAuditor.audit(admitted: 1_000, seriesCounts: droppingTally)

        XCTAssertFalse(finding.isConserved)
        XCTAssertEqual(finding, .leaked(admitted: 1_000, tallied: 700))
        XCTAssertTrue(finding.description.contains("LEAKED"))
    }

    func testAuditorDetectsDoubleCounting() {
        var inflatedTally: [LabelSet: Int] = [:]
        inflatedTally[LabelSet([locale: "en_US"])] = 600
        inflatedTally[LabelSet([locale: ReservedValue.other])] = 600
        let finding = ConservationAuditor.audit(admitted: 1_000, seriesCounts: inflatedTally)

        XCTAssertFalse(finding.isConserved)
        XCTAssertEqual(finding, .inflated(admitted: 1_000, tallied: 1_200))
    }

    func testAuditorAcceptsAnExactTally() {
        var tally: [LabelSet: Int] = [:]
        tally[LabelSet([locale: "en_US"])] = 700
        tally[LabelSet([locale: ReservedValue.other])] = 300
        XCTAssertEqual(
            ConservationAuditor.audit(admitted: 1_000, seriesCounts: tally),
            .conserved(total: 1_000)
        )
    }

    func testEmptyStateIsConserved() {
        XCTAssertEqual(ConservationAuditor.audit(admitted: 0, seriesCounts: [:]), .conserved(total: 0))
    }

    // MARK: End to end

    /// Twenty thousand observations of an *unbounded* dimension — the exact input the
    /// module exists to survive — and not one of them may be lost.
    func testConservationHoldsUnderUnboundedCardinality() {
        var governor = CardinalityGovernor(
            schema: openSchema(),
            configuration: .init(distinctValueBudget: 16, jointSeriesBudget: 32)
        )
        var generator = SplitMix64(seed: 0xC0FFEE)

        for step in 0..<20_000 {
            // Every value distinct: the worst case, and the one a search-query label
            // actually produces.
            governor.admit(LabelSet([locale: "q-\(generator.next())"]))
            if step % 2_500 == 0 { governor.rollWindow() }
        }

        let snapshot = governor.snapshot
        XCTAssertEqual(snapshot.totalAdmitted, 20_000)
        XCTAssertEqual(snapshot.conservation, .conserved(total: 20_000))
        XCTAssertLessThanOrEqual(snapshot.trackedSeries, 32)
    }

    /// The collapse must be *complete*: with one open dimension, everything that did not
    /// keep its identity has to land in `__other__`, and the arithmetic has to close.
    func testCollapsedObservationsLandInOtherRatherThanNowhere() {
        var governor = CardinalityGovernor(
            schema: openSchema(floor: 4),
            configuration: .init(distinctValueBudget: 4, jointSeriesBudget: 64)
        )

        // 4 slots, 40 distinct values, 10 observations each.
        for round in 0..<10 {
            for value in 0..<40 {
                governor.admit(LabelSet([locale: "loc-\(value)-\(round % 1)"]))
            }
        }

        let snapshot = governor.snapshot
        let otherSeries = LabelSet([locale: ReservedValue.other])
        let collapsedTally = snapshot.seriesCounts[otherSeries] ?? 0
        let keyStats = snapshot.keys.first { $0.key == locale }

        XCTAssertEqual(snapshot.totalAdmitted, 400)
        XCTAssertEqual(snapshot.conservation, .conserved(total: 400))
        XCTAssertGreaterThan(collapsedTally, 0, "nothing collapsed — the budget was not enforced")
        XCTAssertEqual(collapsedTally, keyStats?.collapsedToOther,
                       "the __other__ series must account for exactly the collapsed observations")
        // 4 survivors + the __other__ series.
        XCTAssertEqual(snapshot.trackedSeries, 5)
        XCTAssertEqual(keyStats?.survivors, 4)
    }

    func testConservationSurvivesEverySimultaneousFailureMode() {
        // Closed-domain violations, forged sentinels, undeclared keys, per-key collapse
        // and joint-space overflow, all in one stream.
        var schema = DimensionSchema()
        schema.declare(DimensionKey("flow"), .closed(["home", "search"]))
        schema.declare(DimensionKey("variant"), .open(floor: 2))
        schema.declare(locale, .open(floor: 2))

        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 6, jointSeriesBudget: 12)
        )
        var generator = SplitMix64(seed: 99)

        for step in 0..<10_000 {
            var labels = LabelSet()
            switch step % 5 {
            case 0: labels.set(DimensionKey("flow"), "home")
            case 1: labels.set(DimensionKey("flow"), "not-a-declared-flow")
            case 2: labels.set(DimensionKey("flow"), ReservedValue.other)   // forged
            case 3: labels.set(DimensionKey("undeclared"), "leak-\(generator.next())")
            default: break                                                  // flow unset
            }
            labels.set(DimensionKey("variant"), "v\(generator.nextIndex(upperBound: 30))")
            labels.set(locale, "l-\(generator.next())")
            governor.admit(labels)

            if step % 1_000 == 0 { governor.rollWindow() }
        }

        let snapshot = governor.snapshot
        XCTAssertEqual(snapshot.totalAdmitted, 10_000)
        XCTAssertEqual(snapshot.conservation, .conserved(total: 10_000))
        XCTAssertLessThanOrEqual(snapshot.trackedSeries, 12)
        XCTAssertGreaterThan(snapshot.jointOverflowObservations, 0)
        XCTAssertGreaterThan(snapshot.undeclaredKeyDrops[DimensionKey("undeclared")] ?? 0, 0)
    }
}
