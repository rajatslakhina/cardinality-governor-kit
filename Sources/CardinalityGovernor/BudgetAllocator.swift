import Foundation

/// How a single global distinct-value budget is split across the open dimensions.
public struct BudgetAllocation: Sendable, Equatable {
    /// Distinct values each open key may keep identity for.
    public let perKey: [DimensionKey: Int]
    /// Sum of `perKey`. Equals the requested total exactly whenever there is at least one
    /// open key — see `BudgetAllocator.allocate`.
    public let total: Int
    /// True when the declared floors could not all be honoured because they sum to more
    /// than the budget. Surfaced rather than silently absorbed: it means the schema is
    /// asking for more than the app is willing to pay for, which is a decision for a
    /// human, not for a rounding rule.
    public let floorsWereInfeasible: Bool

    public static let empty = BudgetAllocation(perKey: [:], total: 0, floorsWereInfeasible: false)

    public func allocation(for key: DimensionKey) -> Int { perKey[key] ?? 0 }
}

/// Largest-remainder (Hamilton) apportionment of a fixed budget.
///
/// ## Why apportionment and not just division
///
/// The budget is a whole number of series and so is every share of it, which makes this
/// the apportionment problem, not a division problem. Three alternatives were considered
/// and rejected:
///
/// - **Equal split.** A `deviceTier` key with three possible values does not need 200
///   slots, and a `locale` key with 200 real values is crippled by getting three. Equal
///   split is the allocation that ignores every piece of evidence the sketches collected.
/// - **Proportional with independent rounding.** Round each share and the total drifts off
///   the budget — usually over it, which is the direction that costs money. The budget
///   stops being a budget.
/// - **Greedy first-come.** Whichever key reports first takes what it wants. Same
///   arrival-order pathology that `SpaceSavingSketch` exists to avoid, one layer up.
///
/// Largest-remainder gives each key its exact proportional share floored, then hands the
/// leftover units to the keys with the largest discarded fractions. The result sums to the
/// budget *exactly* — an invariant `BudgetAllocatorTests` checks over randomised inputs.
///
/// Known limitation, accepted deliberately: largest-remainder is subject to the Alabama
/// paradox — growing the total budget can reduce an individual key's allocation. Divisor
/// methods (Sainte-Laguë, D'Hondt) avoid it but do not sum exactly without their own
/// iteration. Exact-sum matters here and cross-budget monotonicity does not, because the
/// budget is a constant the app ships with rather than something that moves under a key.
public enum BudgetAllocator {

    /// Inputs are clamped into a range where every intermediate is exactly representable
    /// as a `Double` (well under 2^53), so the proportional step cannot lose a unit to
    /// floating-point drift and break the exact-sum invariant.
    public static let budgetRange: ClosedRange<Int> = 0...(1 << 20)

    public static func allocate(
        total requestedTotal: Int,
        demands: [DimensionKey: Int],
        floors: [DimensionKey: Int]
    ) -> BudgetAllocation {
        let total = requestedTotal.clamped(to: budgetRange)
        // Sorted for determinism: dictionary iteration order is not stable across
        // processes, and an allocation that depends on it is not reproducible.
        let keys = Set(demands.keys).union(floors.keys).sorted()
        guard !keys.isEmpty else { return .empty }

        let clampedFloors = keys.reduce(into: [DimensionKey: Int]()) { result, key in
            result[key] = (floors[key] ?? 0).clamped(to: budgetRange)
        }
        let floorSum = clampedFloors.values.reduce(0) { $0.saturatingAdding($1) }

        if floorSum > total {
            // Infeasible: honour proportionality only, and say so.
            let shares = largestRemainder(
                units: total,
                weights: keys.reduce(into: [DimensionKey: Int]()) { result, key in
                    result[key] = (demands[key] ?? 0).clamped(to: budgetRange)
                },
                orderedKeys: keys
            )
            return BudgetAllocation(perKey: shares, total: total, floorsWereInfeasible: true)
        }

        let discretionary = total - floorSum
        let shares = largestRemainder(
            units: discretionary,
            weights: keys.reduce(into: [DimensionKey: Int]()) { result, key in
                // Demand above the floor is what the discretionary pool is competing for.
                // A key already covered by its floor exerts no pull on the remainder.
                let demand = (demands[key] ?? 0).clamped(to: budgetRange)
                result[key] = max(0, demand - (clampedFloors[key] ?? 0))
            },
            orderedKeys: keys
        )

        var perKey: [DimensionKey: Int] = [:]
        for key in keys {
            perKey[key] = (clampedFloors[key] ?? 0).saturatingAdding(shares[key] ?? 0)
        }
        let sum = perKey.values.reduce(0) { $0.saturatingAdding($1) }
        return BudgetAllocation(perKey: perKey, total: sum, floorsWereInfeasible: false)
    }

    /// Distributes exactly `units` across `orderedKeys` in proportion to `weights`.
    ///
    /// Postcondition: the returned values are non-negative and sum to exactly
    /// `max(0, units)`.
    static func largestRemainder(
        units: Int,
        weights: [DimensionKey: Int],
        orderedKeys: [DimensionKey]
    ) -> [DimensionKey: Int] {
        guard !orderedKeys.isEmpty else { return [:] }
        let unitsToGive = max(0, units)
        guard unitsToGive > 0 else {
            return orderedKeys.reduce(into: [DimensionKey: Int]()) { $0[$1] = 0 }
        }

        let weightSum = orderedKeys.reduce(0) { $0.saturatingAdding(max(0, weights[$1] ?? 0)) }

        // No evidence to apportion on — every key wants zero. Round-robin is the only
        // defensible fallback, and it is deterministic because `orderedKeys` is sorted.
        guard weightSum > 0 else {
            var shares = orderedKeys.reduce(into: [DimensionKey: Int]()) { $0[$1] = 0 }
            for offset in 0..<unitsToGive {
                // `orderedKeys` is non-empty, so the modulo cannot divide by zero.
                let key = orderedKeys[offset % orderedKeys.count]
                shares[key] = (shares[key] ?? 0).saturatingAdding(1)
            }
            return shares
        }

        var shares: [DimensionKey: Int] = [:]
        var remainders: [(key: DimensionKey, fraction: Double)] = []
        var assigned = 0

        for key in orderedKeys {
            let weight = max(0, weights[key] ?? 0)
            // All three operands are within `budgetRange`, so this product is well under
            // 2^41 and exact in `Double`.
            let exact = Double(unitsToGive) * Double(weight) / Double(weightSum)
            let base = max(0, Int.saturating(truncating: exact))
            shares[key] = base
            assigned = assigned.saturatingAdding(base)
            remainders.append((key: key, fraction: exact - Double(base)))
        }

        // `assigned ≤ unitsToGive` because each `base` floors its exact share and the
        // exact shares sum to `unitsToGive`. Clamped anyway: relying on a floating-point
        // argument for a loop bound is how you get an unbounded loop.
        let leftover = (unitsToGive - assigned).clamped(lower: 0, upper: orderedKeys.count)

        remainders.sort { lhs, rhs in
            lhs.fraction == rhs.fraction ? lhs.key < rhs.key : lhs.fraction > rhs.fraction
        }
        for entry in remainders.prefix(leftover) {
            shares[entry.key] = (shares[entry.key] ?? 0).saturatingAdding(1)
        }

        return shares
    }
}
