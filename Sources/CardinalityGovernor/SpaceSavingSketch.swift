import Foundation

/// Bounded-memory heavy hitters (Metwally, Agrawal & El Abbadi, 2005 — "Space-Saving").
///
/// ## Why a sketch at all
///
/// Deciding *which* values of an open dimension keep their own series requires knowing
/// which values are frequent. The obvious implementations are both wrong:
///
/// - **Arrival order** ("first N values win") makes the surviving series a function of
///   when the app launched. Two devices running the same build report different series,
///   and a value that is 90% of traffic loses to one that fired once at startup.
/// - **Exact counting** ("count everything, keep the top N at window end") is unbounded
///   memory over exactly the input we are trying to defend against — an unbounded
///   dimension. The defence would allocate proportionally to the attack.
///
/// Space-Saving keeps `capacity` counters regardless of stream length, and gives a
/// *two-sided* guarantee per monitored value: `count - error ≤ trueFrequency ≤ count`.
/// That interval is not a curiosity here; `SurvivorSet` uses it to require that a
/// challenger beat an incumbent by more than the sketch's own uncertainty before it may
/// take the slot, which is what stops series from flapping on noise.
///
/// ## Why an indexed binary heap
///
/// Every eviction needs the minimum counter. Canonical Space-Saving uses a Stream-Summary
/// — a list of count-buckets, each holding a doubly-linked list of values — which reaches
/// O(1) for every operation. This implementation uses an indexed binary min-heap at
/// O(log n) instead, because at the capacities this module operates at (tens to low
/// thousands of counters), a flat `[Counter]` array plus one dictionary beats a pointer
/// structure on cache behaviour and allocation churn, and it is roughly a third of the
/// code to get right. The trade is explicit: at a capacity where log n stops being small,
/// Stream-Summary is the correct implementation and this one should be replaced.
struct SpaceSavingSketch: Sendable {

    struct Counter: Sendable, Equatable {
        var value: String
        /// Upper bound on the true frequency.
        var count: Int
        /// Overestimate carried in from the evicted predecessor. The true frequency is at
        /// least `count - error`.
        var error: Int

        /// `count - error`, floored at zero. Written with `subtractingReportingOverflow`
        /// rather than `count - error` because negating `error` to reuse the saturating
        /// add would itself trap at `Int.min`.
        var lowerBound: Int {
            let (result, overflowed) = count.subtractingReportingOverflow(error)
            guard !overflowed else { return 0 }
            return Swift.max(0, result)
        }

        var upperBound: Int { count }
    }

    /// Capacity is clamped so that `2*i + 1` in the heap walk cannot overflow: with
    /// `i < capacity ≤ 2^20`, the largest child index computed is under 2^21, which is
    /// representable even where `Int` is 32-bit.
    static let capacityRange: ClosedRange<Int> = 0...(1 << 20)

    private(set) var capacity: Int
    /// Binary min-heap on `count`. `heap[0]` is the eviction candidate.
    private(set) var heap: [Counter]
    /// `value -> position in heap`. Kept in lockstep by `swapAt`.
    private(set) var index: [String: Int]
    /// Every observation, including those that were never monitored.
    private(set) var totalObservations: Int

    init(capacity: Int) {
        self.capacity = capacity.clamped(to: Self.capacityRange)
        self.heap = []
        self.index = [:]
        self.totalObservations = 0
        heap.reserveCapacity(self.capacity)
    }

    /// Testing seam: builds a sketch in an arbitrary — including deliberately corrupt —
    /// state, so `validate()` can be shown to *fail* rather than only shown to pass.
    init(capacity: Int, heap: [Counter], index: [String: Int], totalObservations: Int) {
        self.capacity = capacity.clamped(to: Self.capacityRange)
        self.heap = heap
        self.index = index
        self.totalObservations = totalObservations
    }

    var monitoredCount: Int { heap.count }

    // MARK: - Observation

    mutating func observe(_ value: String) {
        totalObservations = totalObservations.saturatingAdding(1)

        if let position = index[value], heap.indices.contains(position) {
            heap[position].count = heap[position].count.saturatingAdding(1)
            siftDown(from: position)
            return
        }

        if heap.count < capacity {
            heap.append(Counter(value: value, count: 1, error: 0))
            index[value] = heap.count - 1
            siftUp(from: heap.count - 1)
            return
        }

        // Over capacity. `capacity == 0` lands here with an empty heap — the guard is
        // load-bearing, not decorative.
        guard let victim = heap.first else { return }
        index.removeValue(forKey: victim.value)
        heap[0] = Counter(
            value: value,
            count: victim.count.saturatingAdding(1),
            error: victim.count
        )
        index[value] = 0
        siftDown(from: 0)
    }

    /// Re-caps the sketch, preserving the strongest counters.
    ///
    /// Growing keeps every counter and simply raises the ceiling. Shrinking keeps the top
    /// `capacity` by count and discards the rest — which loses information, but losing the
    /// *weakest* counters is the same thing `observe(_:)` already does under pressure, so
    /// it introduces no bias the structure did not already have.
    ///
    /// `totalObservations` is deliberately preserved across a resize: it is a lifetime
    /// count of everything this sketch has seen, monitored or not, and a resize is a
    /// capacity change rather than a new sketch.
    mutating func resize(capacity newCapacity: Int) {
        let clamped = min(max(newCapacity, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
        guard clamped != capacity else { return }
        capacity = clamped

        guard heap.count > clamped else { return }
        // `ranked()` returns strongest-first, so a prefix is the top-k.
        let kept = Array(ranked().prefix(clamped))
        heap = kept
        index = [:]
        for (position, counter) in kept.enumerated() { index[counter.value] = position }
        rebuildHeap()
    }

    /// Resets counts while keeping the monitored set, so a value that was frequent last
    /// window starts the next one as an incumbent rather than as a stranger.
    ///
    /// Counts decay rather than zero: halving preserves the *relative* ordering that the
    /// promotion rule reads. Note it does **not** make a value fall out on its own —
    /// counts floor at 1 and no counter is ever removed — so this is not, and must not be
    /// mistaken for, evidence of liveness. `SurvivorSet` tracks that separately, from live
    /// observation. Zeroing instead of halving would make every window a fresh
    /// arrival-order race, which is the exact failure this sketch exists to avoid.
    mutating func decay() {
        for position in heap.indices {
            // `max(0, …) / 2` cannot trap: the dividend is non-negative and the divisor is
            // a non-zero constant, so neither the divide-by-zero nor the `Int.min / -1`
            // case is reachable. Counts are never negative in practice — the `max(0,)` is
            // there so that remains true even if a test injects a corrupt counter.
            heap[position].count = Swift.max(1, Swift.max(0, heap[position].count) / 2)
            heap[position].error = Swift.max(0, heap[position].error) / 2
        }
        totalObservations = 0
        rebuildHeap()
    }

    // MARK: - Queries

    /// `nil` when the value is not monitored — which, given the Space-Saving guarantee,
    /// means its true frequency is at most the smallest monitored count.
    func estimate(_ value: String) -> (lowerBound: Int, upperBound: Int)? {
        guard let position = index[value], heap.indices.contains(position) else { return nil }
        return (heap[position].lowerBound, heap[position].upperBound)
    }

    /// The smallest monitored count — the ceiling on any unmonitored value's frequency.
    var evictionFloor: Int { heap.first?.count ?? 0 }

    /// Monitored counters, highest first. Ties break on value ascending so the ordering is
    /// total and reproducible; without that, two runs over the same stream can disagree
    /// about which of two equal-count values survives.
    func ranked(limit: Int? = nil) -> [Counter] {
        let sorted = heap.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.value < rhs.value : lhs.count > rhs.count
        }
        guard let limit else { return sorted }
        guard limit > 0 else { return [] }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Invariant

    enum InvariantViolation: Equatable, CustomStringConvertible {
        case heapPropertyBroken(parent: Int, child: Int)
        case indexSizeMismatch(indexCount: Int, heapCount: Int)
        case indexPointsOutOfBounds(value: String, position: Int)
        case indexPointsAtWrongValue(value: String, position: Int, found: String)
        case negativeError(position: Int)
        case overCapacity(heapCount: Int, capacity: Int)

        var description: String {
            switch self {
            case .heapPropertyBroken(let parent, let child):
                return "heap property broken between \(parent) and \(child)"
            case .indexSizeMismatch(let indexCount, let heapCount):
                return "index has \(indexCount) entries for \(heapCount) heap slots"
            case .indexPointsOutOfBounds(let value, let position):
                return "index[\(value)] = \(position) is out of bounds"
            case .indexPointsAtWrongValue(let value, let position, let found):
                return "index[\(value)] = \(position) but heap holds \(found)"
            case .negativeError(let position):
                return "counter \(position) has negative error"
            case .overCapacity(let heapCount, let capacity):
                return "heap holds \(heapCount) counters for capacity \(capacity)"
            }
        }
    }

    /// Full structural check. Exposed rather than kept private so the test suite can
    /// construct a corrupt sketch and assert this returns a violation — a validator that
    /// has only ever been shown to return `[]` is not evidence of anything.
    func validate() -> [InvariantViolation] {
        var violations: [InvariantViolation] = []

        if heap.count > capacity {
            violations.append(.overCapacity(heapCount: heap.count, capacity: capacity))
        }
        if index.count != heap.count {
            violations.append(.indexSizeMismatch(indexCount: index.count, heapCount: heap.count))
        }

        for (value, position) in index.sorted(by: { $0.key < $1.key }) {
            guard heap.indices.contains(position) else {
                violations.append(.indexPointsOutOfBounds(value: value, position: position))
                continue
            }
            if heap[position].value != value {
                violations.append(
                    .indexPointsAtWrongValue(value: value, position: position, found: heap[position].value)
                )
            }
        }

        for position in heap.indices {
            if heap[position].error < 0 {
                violations.append(.negativeError(position: position))
            }
            let left = position * 2 + 1
            let right = position * 2 + 2
            if heap.indices.contains(left), heap[left].count < heap[position].count {
                violations.append(.heapPropertyBroken(parent: position, child: left))
            }
            if heap.indices.contains(right), heap[right].count < heap[position].count {
                violations.append(.heapPropertyBroken(parent: position, child: right))
            }
        }

        return violations
    }

    // MARK: - Heap mechanics

    private mutating func rebuildHeap() {
        guard heap.count > 1 else { return }
        // Floyd's heapify. `heap.count / 2 - 1` is safe: count > 1 here.
        for position in stride(from: heap.count / 2 - 1, through: 0, by: -1) {
            siftDown(from: position)
        }
    }

    private mutating func siftUp(from start: Int) {
        var position = start
        while position > 0 {
            let parent = (position - 1) / 2
            guard heap.indices.contains(parent), heap.indices.contains(position) else { return }
            if heap[parent].count <= heap[position].count { return }
            swapAt(parent, position)
            position = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var position = start
        let count = heap.count
        while true {
            // Safe from overflow: `position < count ≤ capacity ≤ 2^20` (see `capacityRange`).
            let left = position * 2 + 1
            let right = position * 2 + 2
            var smallest = position
            if left < count, heap[left].count < heap[smallest].count { smallest = left }
            if right < count, heap[right].count < heap[smallest].count { smallest = right }
            if smallest == position { return }
            swapAt(position, smallest)
            position = smallest
        }
    }

    private mutating func swapAt(_ lhs: Int, _ rhs: Int) {
        guard heap.indices.contains(lhs), heap.indices.contains(rhs), lhs != rhs else { return }
        heap.swapAt(lhs, rhs)
        index[heap[lhs].value] = lhs
        index[heap[rhs].value] = rhs
    }
}
