import XCTest
@testable import CardinalityGovernor

/// Tests for the parts of the system whose behaviour only exists *across* window
/// boundaries. Every test in this file was written because the corresponding property was
/// asserted in prose and contradicted by the code: the suite had no test that exercised a
/// *changing* allocation, so nothing caught it.
final class WindowSemanticsTests: XCTestCase {

    private let locale = DimensionKey("locale")

    // MARK: Demand must be windowed, not accumulated

    /// HyperLogLog has no eviction. Feeding a lifetime estimate to the allocator makes
    /// demand a monotone ratchet: a key that saw one burst of distinct values never gives
    /// the slots back, and every other key starves for the life of the process.
    ///
    /// This fails against a governor that reads `estimators[key].estimateInterval` directly.
    func testAKeyThatStopsBeingDiverseGivesItsSlotsBack() {
        var schema = DimensionSchema()
        schema.declare(DimensionKey("bursty"), .open(floor: 2))
        schema.declare(DimensionKey("steady"), .open(floor: 2))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 64, jointSeriesBudget: 4096)
        )

        // Window 1: `bursty` sees 2000 distinct values, `steady` sees 4.
        for index in 0..<2_000 {
            governor.admit(LabelSet([
                DimensionKey("bursty"): "b\(index)",
                DimensionKey("steady"): "s\(index % 4)",
            ]))
        }
        let afterBurst = governor.rollWindow().allocation.allocation(for: DimensionKey("bursty"))

        // Two quiet windows: `bursty` now sees 2 values, `steady` still sees 4. Two,
        // because demand is deliberately a two-window maximum — one quiet window must not
        // be enough to strip a key.
        for _ in 0..<2 {
            for index in 0..<2_000 {
                governor.admit(LabelSet([
                    DimensionKey("bursty"): "b\(index % 2)",
                    DimensionKey("steady"): "s\(index % 4)",
                ]))
            }
            _ = governor.rollWindow()
        }
        let afterQuiet = governor.snapshot.allocation.allocation(for: DimensionKey("bursty"))

        XCTAssertGreaterThan(afterBurst, afterQuiet, "a lifetime estimator would hold the burst allocation forever")
    }

    /// The mirror image: one quiet window on its own must NOT strip a key, or every
    /// briefly-idle dimension re-earns its survivors from scratch and the promotion grace
    /// window is pointless.
    func testASingleQuietWindowDoesNotStripAKey() {
        var schema = DimensionSchema()
        schema.declare(DimensionKey("bursty"), .open(floor: 2))
        schema.declare(DimensionKey("steady"), .open(floor: 2))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 64, jointSeriesBudget: 4096)
        )

        for index in 0..<2_000 {
            governor.admit(LabelSet([
                DimensionKey("bursty"): "b\(index)",
                DimensionKey("steady"): "s\(index % 4)",
            ]))
        }
        let afterBurst = governor.rollWindow().allocation.allocation(for: DimensionKey("bursty"))

        for index in 0..<2_000 {
            governor.admit(LabelSet([
                DimensionKey("bursty"): "b\(index % 2)",
                DimensionKey("steady"): "s\(index % 4)",
            ]))
        }
        let afterOneQuietWindow = governor.rollWindow().allocation.allocation(for: DimensionKey("bursty"))

        XCTAssertEqual(afterOneQuietWindow, afterBurst, "demand is a two-window maximum, so one quiet window carries")
    }

    // MARK: The sketch must follow the allocation

    /// A sketch sized once at construction caps the effective per-key budget at
    /// `min(allocation, initialAllocation × sketchOverprovision)`.
    ///
    /// The symptom is subtle, which is why it survived review: the survivor set still
    /// *fills*. `admitIfSlotAvailable` hands out free slots live on the admission path, so
    /// the count reaches the allocation either way. What changes is **which values get
    /// them**. A sketch too small to rank the whole value space can only nominate its own
    /// capacity worth of candidates at the window boundary; every slot past that is filled
    /// by whoever arrived first and then held indefinitely, because a live observation
    /// keeps refreshing it. Arrival-order selection is the exact pathology this module
    /// exists to remove, reintroduced one layer down.
    ///
    /// So the test makes frequency and arrival order disagree on purpose: the coldest
    /// values are emitted first in every window, and the assertion is that survivors are
    /// the true top-k by frequency rather than the first-k by arrival.
    func testSurvivorsAreChosenByFrequencyEvenAfterAKeysAllocationGrows() {
        var schema = DimensionSchema()
        // Eight keys at the minimum floor, so the first allocation is an even split and
        // every sketch starts small.
        for index in 0..<8 {
            schema.declare(DimensionKey("k\(index)"), .open(floor: 1))
        }
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 64, jointSeriesBudget: 4096)
        )

        let distinctValues = 200
        let initialAllocation = governor.snapshot.allocation.allocation(for: DimensionKey("k0"))

        // `hot0` is the most frequent and `hot199` the least — but they are emitted
        // coldest-first, so anything selecting by arrival order picks precisely the wrong
        // values.
        func observeOneWindow() {
            for index in stride(from: distinctValues - 1, through: 0, by: -1) {
                let repeats = distinctValues - index
                for _ in 0..<repeats {
                    var labels = LabelSet()
                    labels.set(DimensionKey("k0"), "hot\(index)")
                    for other in 1..<8 { labels.set(DimensionKey("k\(other)"), "c\(other)") }
                    governor.admit(labels)
                }
            }
        }

        // Three windows: one to grow the allocation off the even split, two more for the
        // survivor set to settle on the true heavy hitters.
        for _ in 0..<3 {
            observeOneWindow()
            _ = governor.rollWindow()
        }

        let allocation = governor.snapshot.allocation.allocation(for: DimensionKey("k0"))
        let survivors = Set(governor.survivingValues(for: DimensionKey("k0")))
        let trueTopK = Set((0..<allocation).map { "hot\($0)" })

        XCTAssertGreaterThan(
            allocation, initialAllocation,
            "k0 carries all the diversity, so its allocation must grow past the initial even split"
        )
        XCTAssertEqual(survivors.count, allocation, "the survivor set should be full")

        // The load-bearing assertion. Verified non-vacuous by deleting the `resize` call
        // in `rollWindow()` and watching exactly this line fail: with a frozen sketch the
        // slots past its capacity are held by cold, early-arriving values.
        XCTAssertEqual(
            survivors, trueTopK,
            "survivors must be the top \(allocation) by frequency, not the first \(allocation) by arrival"
        )
    }

    // MARK: Overflow dispositions

    /// `dispositions` and `labels` are two views of one decision. Reporting `.kept` for a
    /// key whose label reads `__overflow__` makes the result self-contradictory, and any
    /// "how many values kept their identity" counter built on it is wrong by exactly the
    /// overflow volume.
    func testOverflowDispositionsAgreeWithLabels() {
        var schema = DimensionSchema()
        schema.declare(DimensionKey("a"), .closed(["x", "y", "z"]))
        schema.declare(DimensionKey("b"), .closed(["p", "q", "r"]))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 16, jointSeriesBudget: 3)
        )

        var sawOverflow = false
        for first in ["x", "y", "z"] {
            for second in ["p", "q", "r"] {
                let result = governor.admit(LabelSet([DimensionKey("a"): first, DimensionKey("b"): second]))
                guard result.labels == LabelSet([
                    DimensionKey("a"): ReservedValue.overflow,
                    DimensionKey("b"): ReservedValue.overflow,
                ]) else { continue }

                sawOverflow = true
                for key in result.dispositions.keys {
                    XCTAssertEqual(
                        result.dispositions[key], .collapsedToOverflow,
                        "\(key) reads __overflow__ in labels but not in dispositions"
                    )
                }
            }
        }

        XCTAssertTrue(sawOverflow, "9 combinations into a budget of 3 must overflow")
        XCTAssertLessThanOrEqual(governor.snapshot.trackedSeries, 3)
        XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 9))
    }

    // MARK: ProgressView trap sites

    /// `SafeProgress` exists because `ProgressView(value:total:)` traps on a non-finite or
    /// negative fraction and `total` is derived from a host-configurable budget. It lives
    /// in the core module rather than beside the view precisely so this test runs on every
    /// platform in CI, not only the ones that have SwiftUI.
    func testSafeProgressNeverProducesAValueProgressViewWouldTrapOn() {
        let hostile: [(Double, Double)] = [
            (0, 0),                          // zero budget — the configurable case
            (1, 0),
            (-5, 10),                        // negative value
            (.nan, 10),
            (10, .nan),
            (.infinity, 10),
            (10, .infinity),
            (-.infinity, -.infinity),
            (10, -10),                       // negative total
            (.greatestFiniteMagnitude, 1),
            (5, 10),                         // the ordinary case, for contrast
        ]

        for (value, total) in hostile {
            let safe = SafeProgress.clamped(value: value, total: total)
            XCTAssertTrue(safe.total.isFinite, "total \(total) -> \(safe.total)")
            XCTAssertGreaterThan(safe.total, 0, "total \(total) -> \(safe.total)")
            XCTAssertTrue(safe.value.isFinite, "value \(value) -> \(safe.value)")
            XCTAssertGreaterThanOrEqual(safe.value, 0, "value \(value) -> \(safe.value)")
            XCTAssertLessThanOrEqual(safe.value, safe.total, "value \(value) -> \(safe.value)")
        }

        XCTAssertEqual(SafeProgress.clamped(value: 5, total: 10).value, 5, "ordinary input must pass through unchanged")
        XCTAssertEqual(SafeProgress.clamped(value: 5, total: 10).total, 10)
    }

    // MARK: The joint cap's time semantics

    /// The joint cap is a *lifetime* cap while every per-key budget is windowed. That
    /// asymmetry is intentional — a backend bills for every series it has ever had to
    /// store — but it is surprising enough that it needs pinning, so that changing it is a
    /// deliberate act rather than a silent one.
    func testTheJointCapIsALifetimeCapNotAWindowedOne() {
        var schema = DimensionSchema()
        schema.declare(DimensionKey("a"), .closed(["x", "y", "z"]))
        var governor = CardinalityGovernor(
            schema: schema,
            configuration: .init(distinctValueBudget: 16, jointSeriesBudget: 3)
        )

        for value in ["x", "y", "z"] {
            governor.admit(LabelSet([DimensionKey("a"): value]))
        }
        let trackedBefore = governor.snapshot.trackedSeries
        XCTAssertEqual(trackedBefore, 3, "2 real series plus __overflow__ at a budget of 3")

        // Rolling the window must NOT release joint slots. A windowed joint cap would let
        // an app cycle through unlimited series over time while reporting compliance.
        _ = governor.rollWindow()
        _ = governor.rollWindow()

        XCTAssertEqual(governor.snapshot.trackedSeries, trackedBefore, "rolling a window must not release joint slots")

        let afterRoll = governor.admit(LabelSet([DimensionKey("a"): "z"]))
        XCTAssertEqual(
            afterRoll.labels[DimensionKey("a")], ReservedValue.overflow,
            "a combination that overflowed before the roll must still overflow after it"
        )
        XCTAssertEqual(governor.snapshot.conservation, .conserved(total: 4))
    }

    // MARK: Named trap sites

    /// `SpaceSavingSketch.Counter.lowerBound` uses `subtractingReportingOverflow` rather
    /// than negating `error` to reuse the saturating add, because negating `Int.min` is
    /// itself a trap. The README claims every named trap site has a test that hits it, so
    /// this is that test.
    func testCounterLowerBoundDoesNotTrapAtIntMin() {
        // `0 - Int.min` overflows. The property reports 0 on overflow rather than
        // saturating to `Int.max`, which is the right call: this is a *lower* bound on a
        // frequency, and `Int.max` would be a wildly confident claim derived from an
        // arithmetic accident. Reaching this branch at all means `error` is corrupt.
        let counter = SpaceSavingSketch.Counter(value: "x", count: 0, error: .min)
        XCTAssertEqual(counter.lowerBound, 0, "must not trap, and must not invent confidence")

        // The other overflow direction, and the ordinary floor.
        XCTAssertEqual(SpaceSavingSketch.Counter(value: "x", count: .min, error: .max).lowerBound, 0)
        XCTAssertEqual(SpaceSavingSketch.Counter(value: "x", count: 5, error: 100).lowerBound, 0)

        let ordinary = SpaceSavingSketch.Counter(value: "y", count: 100, error: 10)
        XCTAssertEqual(ordinary.lowerBound, 90)
        XCTAssertEqual(ordinary.upperBound, 100)
    }

    func testSaturatingSubtractionClampsAtBothEnds() {
        XCTAssertEqual(Int.min.saturatingSubtracting(1), .min)
        XCTAssertEqual(Int.max.saturatingSubtracting(-1), .max)
        XCTAssertEqual(Int.min.saturatingSubtracting(.max), .min)
        XCTAssertEqual(Int.max.saturatingSubtracting(.min), .max)
        XCTAssertEqual(7.saturatingSubtracting(5), 2, "ordinary subtraction must be unchanged")
    }

    // MARK: Sketch resize

    /// `resize` is the riskiest code in the sketch: the shrink path throws away the heap
    /// array and rebuilds both it and the `value -> position` index from scratch. A repo
    /// whose thesis is "a validator only ever shown to return `[]` is not evidence" cannot
    /// ship a heap rebuild whose only coverage is incidental.
    func testResizeShrinkKeepsTheStrongestCountersAndPreservesTheInvariant() {
        var sketch = SpaceSavingSketch(capacity: 128)
        for value in 0..<100 {
            for _ in 0..<(100 - value) { sketch.observe("v\(value)") }
        }
        XCTAssertEqual(sketch.validate(), [])

        sketch.resize(capacity: 8)

        XCTAssertEqual(sketch.validate(), [], "the heap invariant and the index must survive a rebuild")
        XCTAssertEqual(sketch.heap.count, 8)
        XCTAssertEqual(
            Set(sketch.ranked().map(\.value)), Set((0..<8).map { "v\($0)" }),
            "shrinking must keep the strongest counters, not an arbitrary eight"
        )
        // The index must still address the heap correctly, or every later `observe` writes
        // to the wrong counter.
        for counter in sketch.heap {
            XCTAssertNotNil(sketch.estimate(counter.value))
        }
    }

    func testResizeGrowKeepsEveryCounter() {
        var sketch = SpaceSavingSketch(capacity: 8)
        for value in 0..<8 { sketch.observe("v\(value)") }
        let before = Set(sketch.ranked().map(\.value))

        sketch.resize(capacity: 64)

        XCTAssertEqual(sketch.validate(), [])
        XCTAssertEqual(Set(sketch.ranked().map(\.value)), before, "growing must not discard anything")
        XCTAssertEqual(sketch.capacity, 64)
    }

    func testResizeToZeroIsSafe() {
        var sketch = SpaceSavingSketch(capacity: 16)
        for value in 0..<16 { sketch.observe("v\(value)") }

        sketch.resize(capacity: 0)

        XCTAssertEqual(sketch.validate(), [])
        XCTAssertEqual(sketch.heap.count, 0)
        XCTAssertEqual(sketch.ranked(), [])
        // And it must still accept observations without trapping.
        sketch.observe("after")
        XCTAssertEqual(sketch.validate(), [])
    }
}
