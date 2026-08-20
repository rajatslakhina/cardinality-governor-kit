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
            _ = set.reconcile(candidates: [counter("periodic", count: 50)], newCapacity: 2)
        }
        XCTAssertTrue(set.contains("periodic"))
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

    func testReconciliationIsDeterministicAcrossIndependentInstances() {
        func run() -> SurvivorSet.Reconciliation {
            var set = SurvivorSet(capacity: 3, graceWindows: 2)
            _ = set.reconcile(candidates: (0..<10).map { counter("v\($0)", count: 100 - $0) }, newCapacity: 3)
            return set.reconcile(candidates: (0..<10).map { counter("v\($0)", count: 50) }, newCapacity: 2)
        }
        XCTAssertEqual(run(), run())
    }
}
