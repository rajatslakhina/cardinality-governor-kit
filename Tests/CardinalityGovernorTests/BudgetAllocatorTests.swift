import XCTest
@testable import CardinalityGovernor

final class BudgetAllocatorTests: XCTestCase {

    private func key(_ name: String) -> DimensionKey { DimensionKey(name) }

    // MARK: The exact-sum invariant

    /// Randomised property test: the allocation must sum to the budget **exactly**, for
    /// any mix of demands and floors.
    ///
    /// This is the invariant that independent rounding breaks — and it breaks by one or
    /// two units, which is precisely the size of error that never shows up in a
    /// hand-written example and always shows up in production.
    func testAllocationSumsToTheBudgetExactly() {
        var generator = SplitMix64(seed: 0xF00D)

        for trial in 0..<400 {
            let keyCount = 1 + generator.nextIndex(upperBound: 6)
            let keys = (0..<keyCount).map { key("k\($0)") }
            let budget = generator.nextIndex(upperBound: 2_000)

            var demands: [DimensionKey: Int] = [:]
            var floors: [DimensionKey: Int] = [:]
            for dimension in keys {
                demands[dimension] = generator.nextIndex(upperBound: 900)
                floors[dimension] = generator.nextIndex(upperBound: 40)
            }

            let allocation = BudgetAllocator.allocate(total: budget, demands: demands, floors: floors)
            let sum = allocation.perKey.values.reduce(0, +)

            XCTAssertEqual(
                sum, budget,
                "trial \(trial): \(keyCount) keys, budget \(budget), allocated \(sum)"
            )
            XCTAssertEqual(allocation.total, budget)
            for dimension in keys {
                XCTAssertGreaterThanOrEqual(allocation.allocation(for: dimension), 0)
            }
        }
    }

    func testFloorsAreHonouredWhenTheyFit() {
        let allocation = BudgetAllocator.allocate(
            total: 100,
            // `rare` has almost no demand and would be starved by pure proportionality.
            demands: [key("busy"): 900, key("rare"): 1],
            floors: [key("busy"): 5, key("rare"): 20]
        )

        XCTAssertGreaterThanOrEqual(allocation.allocation(for: key("rare")), 20)
        XCTAssertGreaterThanOrEqual(allocation.allocation(for: key("busy")), 5)
        XCTAssertEqual(allocation.total, 100)
        XCTAssertFalse(allocation.floorsWereInfeasible)
    }

    func testDemandDrivesTheDiscretionaryPool() {
        let allocation = BudgetAllocator.allocate(
            total: 200,
            demands: [key("locale"): 400, key("tier"): 3],
            floors: [key("locale"): 10, key("tier"): 10]
        )

        // `locale`'s demand dwarfs `tier`'s, so it must take the overwhelming majority of
        // the 180 discretionary slots — an equal split would give each 90.
        XCTAssertGreaterThan(allocation.allocation(for: key("locale")), 150)
        XCTAssertLessThan(allocation.allocation(for: key("tier")), 50)
        XCTAssertEqual(allocation.total, 200)
    }

    func testInfeasibleFloorsAreReportedRatherThanSilentlyExceeded() {
        let allocation = BudgetAllocator.allocate(
            total: 10,
            demands: [key("a"): 50, key("b"): 50],
            floors: [key("a"): 40, key("b"): 40]
        )

        XCTAssertTrue(allocation.floorsWereInfeasible)
        // The budget still holds. Honouring the floors would have doubled the bill.
        XCTAssertEqual(allocation.total, 10)
        XCTAssertEqual(allocation.perKey.values.reduce(0, +), 10)
    }

    // MARK: Degenerate inputs

    func testEmptyKeySetReturnsAnEmptyAllocation() {
        let allocation = BudgetAllocator.allocate(total: 500, demands: [:], floors: [:])
        XCTAssertEqual(allocation, .empty)
        XCTAssertEqual(allocation.allocation(for: key("missing")), 0)
    }

    func testZeroBudgetAllocatesNothingToEveryone() {
        let allocation = BudgetAllocator.allocate(
            total: 0,
            demands: [key("a"): 10, key("b"): 10],
            floors: [key("a"): 5, key("b"): 5]
        )
        XCTAssertEqual(allocation.total, 0)
        XCTAssertEqual(allocation.allocation(for: key("a")), 0)
        XCTAssertEqual(allocation.allocation(for: key("b")), 0)
    }

    func testNegativeInputsAreClampedInsteadOfPropagating() {
        let allocation = BudgetAllocator.allocate(
            total: -100,
            demands: [key("a"): -50],
            floors: [key("a"): -10]
        )
        XCTAssertEqual(allocation.total, 0)
        XCTAssertEqual(allocation.allocation(for: key("a")), 0)
    }

    func testZeroDemandFallsBackToDeterministicRoundRobin() {
        // No evidence at all — every key wants nothing. The result must still sum exactly
        // and must not depend on dictionary iteration order.
        let keys = ["a", "b", "c", "d", "e"].map(key)
        let allocation = BudgetAllocator.allocate(
            total: 7,
            demands: keys.reduce(into: [DimensionKey: Int]()) { $0[$1] = 0 },
            floors: keys.reduce(into: [DimensionKey: Int]()) { $0[$1] = 0 }
        )

        XCTAssertEqual(allocation.total, 7)
        // 7 units over 5 keys, round-robin from the sorted key order.
        XCTAssertEqual(allocation.allocation(for: key("a")), 2)
        XCTAssertEqual(allocation.allocation(for: key("b")), 2)
        XCTAssertEqual(allocation.allocation(for: key("c")), 1)
        XCTAssertEqual(allocation.allocation(for: key("d")), 1)
        XCTAssertEqual(allocation.allocation(for: key("e")), 1)
    }

    func testAllocationIsIndependentOfDictionaryConstructionOrder() {
        // Swift's `Dictionary` iteration order is not stable across processes, so an
        // allocator that iterated `demands.keys` directly would be non-reproducible. Built
        // twice, in opposite insertion orders, to make the property falsifiable.
        var forward: [DimensionKey: Int] = [:]
        for (index, name) in ["a", "b", "c", "d"].enumerated() { forward[key(name)] = 100 + index }

        var backward: [DimensionKey: Int] = [:]
        for (index, name) in ["a", "b", "c", "d"].enumerated().reversed() { backward[key(name)] = 100 + index }

        let first = BudgetAllocator.allocate(total: 333, demands: forward, floors: [:])
        let second = BudgetAllocator.allocate(total: 333, demands: backward, floors: [:])
        XCTAssertEqual(first, second)
    }

    func testHugeInputsAreClampedIntoTheExactlyRepresentableRange() {
        let allocation = BudgetAllocator.allocate(
            total: .max,
            demands: [key("a"): .max, key("b"): .max],
            floors: [key("a"): .max, key("b"): .max]
        )
        // Clamped to `budgetRange`, and the sum invariant still holds at the ceiling.
        XCTAssertEqual(allocation.total, BudgetAllocator.budgetRange.upperBound)
        XCTAssertEqual(allocation.perKey.values.reduce(0, +), BudgetAllocator.budgetRange.upperBound)
    }

    func testSingleKeyTakesTheWholeBudget() {
        let allocation = BudgetAllocator.allocate(total: 64, demands: [key("only"): 5], floors: [key("only"): 1])
        XCTAssertEqual(allocation.allocation(for: key("only")), 64)
    }
}
