import XCTest
@testable import CardinalityGovernor

/// The anti-flapping rule, which is the least obvious part of the design and the easiest
/// to delete by accident during a "simplification".
final class SurvivorSetTests: XCTestCase {

    private func counter(_ value: String, count: Int, error: Int = 0) -> SpaceSavingSketch.Counter {
        .init(value: value, count: count, error: error)
    }

    // MARK: The separation rule

    func testChallengerInsideTheErrorIntervalIsRefused() {
        var set = SurvivorSet(capacity: 2, graceWindows: 2)

        // Window 1: two free slots, filled by the two strongest.
        _ = set.reconcile(
            candidates: [
                counter("A", count: 100, error: 0),
                counter("C", count: 99, error: 5),      // true frequency ∈ [94, 99]
                counter("B", count: 96, error: 8),      // true frequency ∈ [88, 96]
            ],
            newCapacity: 2
        )
        XCTAssertEqual(set.values, ["A", "C"])

        // Window 2: B's point estimate now *beats* C's — but their intervals still
        // overlap, so on the evidence available they are indistinguishable.
        let report = set.reconcile(
            candidates: [
                counter("A", count: 100, error: 0),
                counter("B", count: 100, error: 8),     // ∈ [92, 100]
                counter("C", count: 99, error: 5),      // ∈ [94, 99]
            ],
            newCapacity: 2
        )

        XCTAssertEqual(set.values, ["A", "C"], "a slot changed hands on noise")
        XCTAssertEqual(report.promoted, [])
        XCTAssertEqual(report.demoted, [])
        XCTAssertEqual(report.refusedForInsufficientSeparation, ["B"])
    }

    func testChallengerBeyondTheErrorIntervalIsPromoted() {
        var set = SurvivorSet(capacity: 2, graceWindows: 2)
        _ = set.reconcile(
            candidates: [counter("A", count: 100), counter("C", count: 99, error: 5)],
            newCapacity: 2
        )
        XCTAssertEqual(set.values, ["A", "C"])

        // D's *lower* bound (190) clears C's *upper* bound (99) outright. That is a real
        // ranking change, not sampling noise, and it must be acted on.
        let report = set.reconcile(
            candidates: [
                counter("D", count: 200, error: 10),
                counter("A", count: 100),
                counter("C", count: 99, error: 5),
            ],
            newCapacity: 2
        )

        XCTAssertEqual(set.values, ["A", "D"])
        XCTAssertEqual(report.promoted, ["D"])
        XCTAssertEqual(report.demoted, ["C"])
    }

    /// Ten windows of two statistically indistinguishable values swapping point estimates.
    /// A "recompute top-k every window" implementation produces ten flaps here.
    func testTenWindowsOfNoiseProduceZeroFlaps() {
        var set = SurvivorSet(capacity: 1, graceWindows: 2)
        _ = set.reconcile(candidates: [counter("incumbent", count: 500, error: 40)], newCapacity: 1)
        XCTAssertEqual(set.values, ["incumbent"])

        var flaps = 0
        for window in 0..<10 {
            // The incumbent is genuinely live every window. Observation has to be stated
            // explicitly rather than inferred from the candidate list, because those are
            // two different facts: the sketch's opinion of a value and whether the value
            // actually arrived. Omitting this makes the incumbent expire on grace, which
            // is a *different* correct behaviour and not what this test is about.
            set.touch("incumbent")
            let incumbentCount = 500 + (window % 2 == 0 ? -6 : 6)
            let challengerCount = 500 + (window % 2 == 0 ? 6 : -6)
            let report = set.reconcile(
                candidates: [
                    counter("incumbent", count: incumbentCount, error: 40),
                    counter("challenger", count: challengerCount, error: 40),
                ].sorted { $0.count > $1.count },
                newCapacity: 1
            )
            flaps += report.promoted.count + report.demoted.count
        }

        XCTAssertEqual(flaps, 0, "the survivor set flapped \(flaps) times on pure noise")
        XCTAssertEqual(set.values, ["incumbent"])
    }

    // MARK: Grace period

    func testUnobservedIncumbentSurvivesGraceThenExpires() {
        var set = SurvivorSet(capacity: 2, graceWindows: 2)
        _ = set.reconcile(candidates: [counter("periodic", count: 50)], newCapacity: 2)
        XCTAssertTrue(set.contains("periodic"))

        // Two quiet windows: still held. A nightly job is not a dead dimension value.
        for window in 0..<2 {
            let report = set.reconcile(candidates: [], newCapacity: 2)
            XCTAssertTrue(set.contains("periodic"), "expired after \(window + 1) quiet window(s)")
            XCTAssertEqual(report.expired, [])
        }

        // Third: gone.
        let report = set.reconcile(candidates: [], newCapacity: 2)
        XCTAssertFalse(set.contains("periodic"))
        XCTAssertEqual(report.expired, ["periodic"])
    }

    func testReappearingBeforeExpiryResetsTheGraceCounter() {
        var set = SurvivorSet(capacity: 2, graceWindows: 2)
        _ = set.reconcile(candidates: [counter("periodic", count: 50)], newCapacity: 2)

        for _ in 0..<6 {
            _ = set.reconcile(candidates: [], newCapacity: 2)              // quiet
            set.touch("periodic")                                          // it arrived
            _ = set.reconcile(candidates: [counter("periodic", count: 50)], newCapacity: 2)
        }
        XCTAssertTrue(set.contains("periodic"))
    }

    /// The grace period is about the *value*, not about the sketch's opinion of it.
    ///
    /// Deriving observation from the candidate list breaks this in both directions, and
    /// this test pins the harder direction: a value the sketch has evicted under pressure
    /// is still live, and must keep its slot. Against the candidate-derived version it
    /// expires on the third window.
    func testAValueEvictedFromTheSketchButStillArrivingKeepsItsSlot() {
        var set = SurvivorSet(capacity: 2, graceWindows: 2)
        set.touch("hot")
        _ = set.admitIfSlotAvailable("hot")
        _ = set.reconcile(candidates: [counter("hot", count: 50)], newCapacity: 2)
        XCTAssertTrue(set.contains("hot"))

        // Four windows in which "hot" arrives on every admission but never appears in the
        // ranked candidates — exactly what a sketch under heavy eviction pressure reports.
        for window in 0..<4 {
            set.touch("hot")
            let report = set.reconcile(candidates: [counter("noise\(window)", count: 5)], newCapacity: 2)
            XCTAssertEqual(report.expired, [], "expired a live value on window \(window)")
        }
        XCTAssertTrue(set.contains("hot"))
    }

    /// And the easier direction: a value that has genuinely stopped arriving must expire
    /// even though a sketch under no pressure still lists it forever — `decay()` floors
    /// counts at 1 and never removes a counter, so the candidate list is not evidence of
    /// life. Against the candidate-derived version this value never expires at all.
    func testAValueStillInTheSketchButNoLongerArrivingDoesExpire() {
        var set = SurvivorSet(capacity: 2, graceWindows: 2)
        set.touch("stale")
        _ = set.admitIfSlotAvailable("stale")
        _ = set.reconcile(candidates: [counter("stale", count: 50)], newCapacity: 2)

        var expired: [String] = []
        for _ in 0..<3 {
            // Still ranked by the sketch every window; never actually observed.
            expired += set.reconcile(candidates: [counter("stale", count: 1)], newCapacity: 2).expired
        }
        XCTAssertEqual(expired, ["stale"], "a value that stopped arriving must expire regardless of the sketch")

        // Note it is then immediately re-promoted from the same candidate list into the
        // slot it just vacated, and that is correct: expiry and promotion answer different
        // questions. Expiry asks "is this still arriving?"; promotion asks "is this among
        // the strongest values the sketch knows?". A residual counter can make the second
        // true while the first is false, and the visible consequence — `expired` and
        // `promoted` both naming the same value in one report — is the honest rendering of
        // that. It is not churn: the slot never changes hands.
        XCTAssertTrue(set.contains("stale"))
    }

    func testZeroGraceWindowsExpiresImmediately() {
        var set = SurvivorSet(capacity: 2, graceWindows: 0)
        _ = set.reconcile(candidates: [counter("a", count: 10)], newCapacity: 2)
        let report = set.reconcile(candidates: [], newCapacity: 2)
        XCTAssertEqual(report.expired, ["a"])
    }

    // MARK: Capacity changes

    func testShrinkingCapacityDemotesTheWeakestFirst() {
        var set = SurvivorSet(capacity: 4, graceWindows: 2)
        _ = set.reconcile(
            candidates: [
                counter("strong", count: 900),
                counter("mid", count: 500),
                counter("weak", count: 100),
                counter("weakest", count: 10),
            ],
            newCapacity: 4
        )
        XCTAssertEqual(set.count, 4)

        let report = set.reconcile(
            candidates: [
                counter("strong", count: 900),
                counter("mid", count: 500),
                counter("weak", count: 100),
                counter("weakest", count: 10),
            ],
            newCapacity: 2
        )

        XCTAssertEqual(set.values, ["strong", "mid"])
        XCTAssertEqual(report.demoted, ["weak", "weakest"])
    }

    func testGrowingCapacityFillsFromTheStrongestChallengers() {
        var set = SurvivorSet(capacity: 1, graceWindows: 2)
        let candidates = [
            counter("a", count: 900),
            counter("b", count: 500),
            counter("c", count: 100),
        ]
        _ = set.reconcile(candidates: candidates, newCapacity: 1)
        XCTAssertEqual(set.values, ["a"])

        let report = set.reconcile(candidates: candidates, newCapacity: 3)
        XCTAssertEqual(set.values, ["a", "b", "c"])
        XCTAssertEqual(report.promoted, ["b", "c"])
    }

    func testZeroCapacityDemotesEveryoneWithoutTrapping() {
        var set = SurvivorSet(capacity: 2, graceWindows: 1)
        _ = set.reconcile(candidates: [counter("a", count: 5), counter("b", count: 4)], newCapacity: 2)
        _ = set.reconcile(candidates: [counter("a", count: 5), counter("b", count: 4)], newCapacity: 0)
        XCTAssertEqual(set.count, 0)
    }

    func testNegativeCapacityIsClampedToZero() {
        var set = SurvivorSet(capacity: -7, graceWindows: -3)
        XCTAssertEqual(set.capacity, 0)
        XCTAssertEqual(set.graceWindows, 0)
        _ = set.reconcile(candidates: [counter("a", count: 1)], newCapacity: -1)
        XCTAssertEqual(set.count, 0)
    }

    // MARK: Free-slot admission

    func testFreeSlotsAreClaimedImmediatelyButFullSetsAreNot() {
        var set = SurvivorSet(capacity: 2, graceWindows: 1)
        XCTAssertTrue(set.admitIfSlotAvailable("a"))
        XCTAssertTrue(set.admitIfSlotAvailable("b"))
        // Full: a contested slot may only change hands at a window boundary.
        XCTAssertFalse(set.admitIfSlotAvailable("c"))
        XCTAssertEqual(set.values, ["a", "b"])
    }

    func testReservedValuesCanNeverTakeASlot() {
        var set = SurvivorSet(capacity: 4, graceWindows: 1)
        for sentinel in ReservedValue.all.sorted() {
            XCTAssertFalse(set.admitIfSlotAvailable(sentinel))
        }
        XCTAssertEqual(set.count, 0)

        // Nor via reconciliation — otherwise `__other__` would compete for a real slot.
        _ = set.reconcile(candidates: ReservedValue.all.sorted().map { counter($0, count: 999) }, newCapacity: 4)
        XCTAssertEqual(set.count, 0)
    }

    /// Determinism has to be checked across *different histories that should converge*,
    /// not by calling one pure function twice. `run()` sorts its output, so a version of
    /// this test that fed identical input in identical order would assert `f(x) == f(x)`
    /// and would still pass with both tie-break comparators deleted outright.
    ///
    /// Here the two sets reach the same state by opposite routes: members admitted in
    /// opposite orders, and the tied candidate array presented reversed. Any dependence on
    /// arrival order — the pathology this whole module exists to remove — separates them.
    func testReconciliationIsDeterministicAcrossOppositeInsertionOrders() {
        let names = (0..<10).map { "v\($0)" }

        func run(reversed: Bool) -> (SurvivorSet.Reconciliation, [String]) {
            var set = SurvivorSet(capacity: 3, graceWindows: 2)
            for name in (reversed ? names.reversed() : names) {
                _ = set.admitIfSlotAvailable(name)
            }
            let ranked = names.enumerated().map { counter($0.element, count: 100 - $0.offset) }
            _ = set.reconcile(candidates: reversed ? ranked.reversed() : ranked, newCapacity: 3)

            // Every candidate tied, so only the tie-break can decide — which is exactly
            // where an order dependence would hide.
            let tied = names.map { counter($0, count: 50) }
            let result = set.reconcile(candidates: reversed ? tied.reversed() : tied, newCapacity: 2)
            return (result, set.members.keys.sorted())
        }

        let forward = run(reversed: false)
        let backward = run(reversed: true)
        XCTAssertEqual(forward.0, backward.0)
        XCTAssertEqual(forward.1, backward.1, "the surviving membership must not depend on arrival order")
    }
}
