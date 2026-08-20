import XCTest
@testable import CardinalityGovernor

final class GovernorTests: XCTestCase {

    private let flow = DimensionKey("flow")
    private let locale = DimensionKey("locale")

    private func standardSchema() -> DimensionSchema {
        var schema = DimensionSchema()
        schema.declare(flow, .closed(["home", "search", "cart"]))
        schema.declare(locale, .open(floor: 4))
        return schema
    }

    // MARK: Schema enforcement

    func testValueOutsideAClosedDomainCollapsesToInvalidAndIsStillCounted() {
        var governor = CardinalityGovernor(schema: standardSchema())
        let result = governor.admit(LabelSet([flow: "checkout", locale: "en_US"]))

        XCTAssertEqual(result.labels[flow], ReservedValue.invalid)
        XCTAssertEqual(result.dispositions[flow], .collapsedToInvalid)
        // Not dropped. A schema violation is a bug you must be able to see; it is not a
        // licence to corrupt the metric by removing the sample.
        XCTAssertEqual(governor.snapshot.totalAdmitted, 1)
        XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 1))
    }

    func testForgedReservedValuesAreTreatedAsInvalid() {
        var governor = CardinalityGovernor(schema: standardSchema())

        for sentinel in [ReservedValue.other, ReservedValue.invalid, ReservedValue.unset, ReservedValue.overflow] {
            let result = governor.admit(LabelSet([flow: "home", locale: sentinel]))
            XCTAssertEqual(
                result.labels[locale], ReservedValue.invalid,
                "a caller supplying \(sentinel) must not be able to forge a collapse"
            )
            XCTAssertEqual(result.dispositions[locale], .collapsedToInvalid)
        }
        XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 4))
    }

    func testUndeclaredKeysAreDroppedAndCounted() {
        var governor = CardinalityGovernor(schema: standardSchema())
        let leaked = DimensionKey("searchQuery")

        for index in 0..<50 {
            governor.admit(LabelSet([flow: "search", locale: "en_US", leaked: "query-\(index)"]))
        }

        let snapshot = governor.snapshot
        // The key never becomes a label — 50 unique query strings would otherwise be
        // 50 series and 50 pieces of user text in a telemetry backend.
        XCTAssertNil(snapshot.seriesCounts.keys.first { $0[leaked] != nil })
        XCTAssertEqual(snapshot.undeclaredKeyDrops[leaked], 50)
        XCTAssertEqual(snapshot.conservation, .conserved(total: 50))
        XCTAssertEqual(snapshot.trackedSeries, 1)
    }

    func testMissingDeclaredKeyBecomesTheUnsetSentinel() {
        var governor = CardinalityGovernor(schema: standardSchema())
        let result = governor.admit(LabelSet([flow: "home"]))

        XCTAssertEqual(result.labels[locale], ReservedValue.unset)
        XCTAssertEqual(result.dispositions[locale], .unset)
        // `__unset__` is distinct from `__other__`: "nobody told us" and "too many values"
        // are different diagnoses with different fixes.
        XCTAssertNotEqual(result.labels[locale], ReservedValue.other)
    }

    func testSchemaRejectsReservedValuesInAClosedDomain() {
        var schema = DimensionSchema()
        schema.declare(flow, .closed(["home", ReservedValue.other]))

        guard case .closed(let allowed) = schema.domains[flow] else {
            return XCTFail("flow should still be declared")
        }
        XCTAssertEqual(allowed, ["home"])
        XCTAssertFalse(schema.declarationWarnings.isEmpty)
    }

    func testSchemaRefusesAnEmptyClosedDomain() {
        var schema = DimensionSchema()
        schema.declare(flow, .closed([]))
        XCTAssertNil(schema.domains[flow])
        XCTAssertFalse(schema.declarationWarnings.isEmpty)
    }

    func testSchemaClampsAnOutOfRangeFloorAndSaysSo() {
        var schema = DimensionSchema()
        schema.declare(locale, .open(floor: -10))
        XCTAssertEqual(schema.floor(for: locale), DimensionSchema.floorRange.lowerBound)
        XCTAssertTrue(schema.declarationWarnings.contains { $0.contains("clamped") })
    }

    // MARK: Joint-space enforcement

    /// Per-key budgets bound the marginals. Only the joint cap bounds the product — and
    /// the product is the bill.
    func testJointBudgetCapsSeriesEvenWhenEveryKeyIsWithinItsOwnBudget() {
        var schema = DimensionSchema()
        for index in 0..<4 {
            schema.declare(DimensionKey("k\(index)"), .open(floor: 8))
        }
        // 4 keys × 8 values each = 32 distinct values, but 8⁴ = 4096 combinations.
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 32, jointSeriesBudget: 100)
        )
        var generator = SplitMix64(seed: 4242)

        for _ in 0..<20_000 {
            var labels = LabelSet()
            for index in 0..<4 {
                labels.set(DimensionKey("k\(index)"), "v\(generator.nextIndex(upperBound: 8))")
            }
            governor.admit(labels)
        }

        let snapshot = governor.snapshot
        XCTAssertLessThanOrEqual(snapshot.trackedSeries, 100)
        // Exact, not `> 1_000`. A loose lower bound passes against an off-by-one in the
        // per-key factor, which is how the original undercount survived: four open keys at
        // 8 allocated slots each is 8 real values plus `__other__`, `__unset__` and
        // `__invalid__` — 11 per key, 11⁴ = 14_641 — plus one for the all-`__overflow__`
        // set, which belongs to no key's domain. The joint budget is 100.
        XCTAssertEqual(
            snapshot.jointSpaceUpperBound, 14_642,
            "the joint space is two orders of magnitude past the joint budget — that is the point"
        )
        XCTAssertGreaterThan(snapshot.jointOverflowObservations, 0)
        XCTAssertEqual(snapshot.conservation, .conserved(total: 20_000))
    }

    func testOverflowUsesASingleSeriesAndCannotItselfGrow() {
        var schema = DimensionSchema()
        schema.declare(locale, .open(floor: 2))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 2, jointSeriesBudget: 2)
        )
        var generator = SplitMix64(seed: 5)

        for _ in 0..<5_000 { governor.admit(LabelSet([locale: "x\(generator.next())"])) }

        let snapshot = governor.snapshot
        XCTAssertLessThanOrEqual(snapshot.trackedSeries, 2)
        let overflowSeries = snapshot.seriesCounts.keys.filter { $0[locale] == ReservedValue.overflow }
        XCTAssertLessThanOrEqual(overflowSeries.count, 1, "overflow must collapse into one series, not many")
        XCTAssertEqual(snapshot.conservation, .conserved(total: 5_000))
    }

    /// Regression: the joint cap, checked at every budget from 1 to 12 and at the exact
    /// boundary rather than only in bulk.
    ///
    /// The original implementation was off by one here — the last free slot went to a real
    /// series, the next observation overflowed, and materialising `__overflow__` to receive
    /// it took the tally to `budget + 1`. The enforcement mechanism broke the limit it
    /// existed to enforce, and it only showed up because a test asserted the bound instead
    /// of asserting "roughly bounded".
    func testJointCapHoldsExactlyAtEveryBudgetIncludingTheBoundary() {
        for budget in 1...12 {
            var schema = DimensionSchema()
            schema.declare(locale, .open(floor: 64))
            var governor = CardinalityGovernor(
                schema: schema,
                configuration: .init(distinctValueBudget: 64, jointSeriesBudget: budget)
            )

            for index in 0..<200 {
                governor.admit(LabelSet([locale: "v\(index)"]))
                XCTAssertLessThanOrEqual(
                    governor.snapshot.trackedSeries, budget,
                    "budget \(budget) exceeded after \(index + 1) observations"
                )
            }
            XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 200))
        }
    }

    func testJointBudgetOfZeroIsClampedToOne() {
        // A budget of zero would ask for a conserved tally with nowhere to tally.
        let configuration = CardinalityGovernor.Configuration(jointSeriesBudget: 0)
        XCTAssertEqual(configuration.jointSeriesBudget, 1)
        XCTAssertEqual(CardinalityGovernor.Configuration(jointSeriesBudget: -50).jointSeriesBudget, 1)
    }

    func testFingerprintCatalogNeverOutgrowsTheJointBudget() {
        var schema = DimensionSchema()
        schema.declare(locale, .open(floor: 4))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 8, jointSeriesBudget: 16)
        )
        var generator = SplitMix64(seed: 11)

        for _ in 0..<10_000 { governor.admit(LabelSet([locale: "z\(generator.next())"])) }

        XCTAssertLessThanOrEqual(governor.snapshot.fingerprintCatalog.count, 16)
    }

    // MARK: Degenerate configurations

    func testEmptySchemaDoesNotTrap() {
        var governor = CardinalityGovernor(schema: DimensionSchema())
        let result = governor.admit(LabelSet([DimensionKey("anything"): "value"]))

        XCTAssertEqual(result.undeclaredKeys, [DimensionKey("anything")])
        XCTAssertTrue(result.labels.isEmpty)
        XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 1))
        XCTAssertEqual(governor.snapshot.keys, [])
    }

    func testZeroBudgetsCollapseEverythingWithoutCrashing() {
        var schema = DimensionSchema()
        schema.declare(locale, .open(floor: 1))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 0, jointSeriesBudget: 0)
        )

        for index in 0..<500 { governor.admit(LabelSet([locale: "v\(index)"])) }
        governor.rollWindow()

        XCTAssertEqual(governor.snapshot.totalAdmitted, 500)
        XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 500))
    }

    func testRollingAWindowOnAnUntouchedGovernorIsSafe() {
        var governor = CardinalityGovernor(schema: standardSchema())
        let report = governor.rollWindow()
        XCTAssertEqual(report.observationsInWindow, 0)
        XCTAssertEqual(report.seriesAtRoll, 0)
        XCTAssertEqual(governor.snapshot.windowIndex, 1)
    }

    // MARK: Reporting

    func testCollapseRateIsNilRatherThanZeroWhenNothingWasObserved() {
        let governor = CardinalityGovernor(schema: standardSchema())
        let stats = governor.snapshot.keys.first { $0.key == locale }
        // Reporting 0% for a key that was never exercised reads as "healthy" and is a lie.
        XCTAssertNil(stats?.collapseRate)
    }

    func testDemandEstimateDrivesReallocationAcrossWindows() {
        var schema = DimensionSchema()
        schema.declare(DimensionKey("wide"), .open(floor: 2))
        schema.declare(DimensionKey("narrow"), .open(floor: 2))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 64, jointSeriesBudget: 4_096)
        )
        var generator = SplitMix64(seed: 808)

        for _ in 0..<8_000 {
            var labels = LabelSet()
            labels.set(DimensionKey("wide"), "w\(generator.nextIndex(upperBound: 500))")
            labels.set(DimensionKey("narrow"), "n\(generator.nextIndex(upperBound: 3))")
            governor.admit(labels)
        }
        let report = governor.rollWindow()

        // The initial apportionment is floor-driven and equal. After one window of
        // evidence, the wide key must hold a decisively larger share.
        XCTAssertGreaterThan(
            report.allocation.allocation(for: DimensionKey("wide")),
            report.allocation.allocation(for: DimensionKey("narrow"))
        )
        XCTAssertEqual(report.allocation.total, 64)
    }
}
