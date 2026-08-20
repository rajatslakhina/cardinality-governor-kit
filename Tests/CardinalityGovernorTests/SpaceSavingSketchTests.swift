import XCTest
@testable import CardinalityGovernor

final class SpaceSavingSketchTests: XCTestCase {

    // MARK: The algorithm's actual contract

    func testCountsAreExactWhileUnderCapacity() {
        var sketch = SpaceSavingSketch(capacity: 8)
        for _ in 0..<5 { sketch.observe("a") }
        for _ in 0..<3 { sketch.observe("b") }

        // No eviction has happened, so no counter carries inherited error and both bounds
        // must equal the true frequency.
        XCTAssertEqual(sketch.estimate("a")?.lowerBound, 5)
        XCTAssertEqual(sketch.estimate("a")?.upperBound, 5)
        XCTAssertEqual(sketch.estimate("b")?.lowerBound, 3)
        XCTAssertEqual(sketch.estimate("b")?.upperBound, 3)
        XCTAssertNil(sketch.estimate("never-seen"))
    }

    /// The Space-Saving guarantee, checked against exact counts rather than restated.
    ///
    /// This is the test that would fail if the eviction step forgot to inherit the
    /// predecessor's count as `error` — the single most likely bug in the implementation,
    /// and one that no "does it compile / does it return something" test would catch.
    func testErrorIntervalBracketsTrueFrequencyUnderHeavyEviction() {
        var generator = SplitMix64(seed: 0xA11CE)
        var sketch = SpaceSavingSketch(capacity: 16)
        var exact: [String: Int] = [:]

        // 600 distinct values into 16 counters: eviction on almost every observation.
        for _ in 0..<20_000 {
            // Zipf-ish: low indices are far more frequent, which is the distribution
            // heavy-hitter sketches are designed for.
            let skewed = min(generator.nextIndex(upperBound: 600), generator.nextIndex(upperBound: 600))
            let value = "v\(skewed)"
            sketch.observe(value)
            exact[value, default: 0] += 1
        }

        XCTAssertEqual(sketch.totalObservations, 20_000)
        XCTAssertLessThanOrEqual(sketch.monitoredCount, 16)

        for counter in sketch.ranked() {
            let trueCount = exact[counter.value] ?? 0
            XCTAssertLessThanOrEqual(
                counter.lowerBound, trueCount,
                "lower bound \(counter.lowerBound) exceeded true frequency \(trueCount) for \(counter.value)"
            )
            XCTAssertGreaterThanOrEqual(
                counter.upperBound, trueCount,
                "upper bound \(counter.upperBound) below true frequency \(trueCount) for \(counter.value)"
            )
        }
    }

    func testTheMostFrequentValueIsAlwaysRetained() {
        var generator = SplitMix64(seed: 0xBEEF)
        var sketch = SpaceSavingSketch(capacity: 8)

        for step in 0..<10_000 {
            // "hot" is 20% of the stream; everything else is a one-off.
            sketch.observe(step % 5 == 0 ? "hot" : "cold-\(generator.next())")
        }

        // Space-Saving cannot evict a value whose count exceeds the minimum counter, and
        // a value at 20% of a 10k stream is far above it.
        XCTAssertNotNil(sketch.estimate("hot"))
        XCTAssertEqual(sketch.ranked(limit: 1).first?.value, "hot")
    }

    // MARK: Structural invariant — and proof the validator can fail

    func testHeapInvariantSurvivesRandomOperations() {
        var generator = SplitMix64(seed: 7)
        var sketch = SpaceSavingSketch(capacity: 32)

        for step in 0..<30_000 {
            sketch.observe("v\(generator.nextIndex(upperBound: 400))")
            if step % 5_000 == 0 {
                XCTAssertEqual(sketch.validate(), [], "invariant broken at step \(step)")
                sketch.decay()
                XCTAssertEqual(sketch.validate(), [], "invariant broken after decay at step \(step)")
            }
        }
        XCTAssertEqual(sketch.validate(), [])
    }

    /// The validator, tested against a deliberately broken sketch.
    ///
    /// Without this, `validate() == []` in the test above is unfalsifiable — a validator
    /// that unconditionally returned `[]` would pass every other test in this file.
    func testValidatorRejectsABrokenHeap() {
        let corrupt = SpaceSavingSketch(
            capacity: 4,
            heap: [
                .init(value: "a", count: 9, error: 0),   // parent larger than child:
                .init(value: "b", count: 1, error: 0),   // heap property violated here
                .init(value: "c", count: 5, error: 0),
            ],
            index: ["a": 0, "b": 1, "c": 2],
            totalObservations: 15
        )

        let violations = corrupt.validate()
        XCTAssertFalse(violations.isEmpty, "validator failed to detect a broken heap")
        XCTAssertTrue(violations.contains(.heapPropertyBroken(parent: 0, child: 1)))
    }

    func testValidatorRejectsADesyncedIndex() {
        let corrupt = SpaceSavingSketch(
            capacity: 4,
            heap: [
                .init(value: "a", count: 1, error: 0),
                .init(value: "b", count: 2, error: 0),
            ],
            index: ["a": 1, "b": 0],   // swapped
            totalObservations: 3
        )

        let violations = corrupt.validate()
        XCTAssertTrue(
            violations.contains(.indexPointsAtWrongValue(value: "a", position: 1, found: "b")),
            "validator failed to detect a desynced index: \(violations)"
        )
    }

    func testValidatorRejectsAnOutOfBoundsIndexEntry() {
        let corrupt = SpaceSavingSketch(
            capacity: 4,
            heap: [.init(value: "a", count: 1, error: 0)],
            index: ["a": 0, "ghost": 7],
            totalObservations: 1
        )
        XCTAssertTrue(corrupt.validate().contains(.indexPointsOutOfBounds(value: "ghost", position: 7)))
    }

    // MARK: Edge cases that would otherwise crash

    func testZeroCapacityAcceptsObservationsWithoutTrapping() {
        // `heap[0]` on an empty heap is the crash this guards. Capacity can legitimately
        // reach zero when the budget allocator gives a key nothing.
        var sketch = SpaceSavingSketch(capacity: 0)
        for step in 0..<1_000 { sketch.observe("v\(step)") }

        XCTAssertEqual(sketch.monitoredCount, 0)
        XCTAssertEqual(sketch.totalObservations, 1_000)
        XCTAssertEqual(sketch.evictionFloor, 0)
        XCTAssertEqual(sketch.ranked(), [])
        XCTAssertEqual(sketch.validate(), [])
    }

    func testNegativeAndOversizedCapacityAreClamped() {
        XCTAssertEqual(SpaceSavingSketch(capacity: -5).capacity, 0)
        XCTAssertEqual(SpaceSavingSketch(capacity: .max).capacity, SpaceSavingSketch.capacityRange.upperBound)
    }

    func testRankedRejectsNonPositiveLimits() {
        var sketch = SpaceSavingSketch(capacity: 4)
        sketch.observe("a")
        XCTAssertEqual(sketch.ranked(limit: 0), [])
        XCTAssertEqual(sketch.ranked(limit: -3), [])
        XCTAssertEqual(sketch.ranked(limit: 99).count, 1)
    }

    func testDecayOnAnEmptySketchIsSafe() {
        var sketch = SpaceSavingSketch(capacity: 4)
        sketch.decay()
        XCTAssertEqual(sketch.validate(), [])
        XCTAssertEqual(sketch.monitoredCount, 0)
    }

    // MARK: Determinism

    /// Ties must break the same way regardless of the order values arrived in.
    ///
    /// Written as a differential test between two *insertion orders* rather than two calls
    /// on one sketch: calling `ranked()` twice on the same instance would pass even if the
    /// tie-break were deleted entirely, since `Array.sorted` is deterministic within a
    /// single sort of a single array.
    func testTieBreakIsIndependentOfArrivalOrder() {
        var forward = SpaceSavingSketch(capacity: 8)
        for value in ["a", "b", "c", "d"] {
            for _ in 0..<3 { forward.observe(value) }
        }

        var reversed = SpaceSavingSketch(capacity: 8)
        for value in ["d", "c", "b", "a"] {
            for _ in 0..<3 { reversed.observe(value) }
        }

        XCTAssertEqual(forward.ranked().map(\.value), ["a", "b", "c", "d"])
        XCTAssertEqual(forward.ranked().map(\.value), reversed.ranked().map(\.value))
    }

    func testDecayHalvesCountsAndPreservesOrdering() {
        var sketch = SpaceSavingSketch(capacity: 4)
        for _ in 0..<100 { sketch.observe("big") }
        for _ in 0..<10 { sketch.observe("small") }

        sketch.decay()

        XCTAssertEqual(sketch.estimate("big")?.upperBound, 50)
        XCTAssertEqual(sketch.estimate("small")?.upperBound, 5)
        XCTAssertEqual(sketch.totalObservations, 0)
        // Halving keeps relative order — which is the whole reason decay is not a reset.
        XCTAssertEqual(sketch.ranked().map(\.value), ["big", "small"])
    }

    func testDecayNeverDropsACounterBelowOne() {
        var sketch = SpaceSavingSketch(capacity: 4)
        sketch.observe("once")
        for _ in 0..<10 { sketch.decay() }
        // Floored at 1: a counter that decayed to 0 would sort as the eviction victim
        // forever and could never recover, which is a slow leak of survivor slots.
        XCTAssertEqual(sketch.estimate("once")?.upperBound, 1)
        XCTAssertEqual(sketch.validate(), [])
    }
}
