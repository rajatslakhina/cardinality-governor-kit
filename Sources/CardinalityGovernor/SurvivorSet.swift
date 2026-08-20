import Foundation

/// The set of values of one open dimension that currently keep their own series.
///
/// ## The failure this prevents
///
/// Recomputing "top k by frequency" at every window boundary looks correct and is not.
/// Two values whose true frequencies differ by less than the sketch's own error will
/// swap places on noise, so the winner flips every window. Downstream, that is not a
/// cosmetic problem: the backend sees series `locale=de_DE` appear, vanish for a window,
/// and reappear — three disjoint segments where there was one continuous signal. Every
/// rate calculation across the gap is wrong, and every alert on it fires.
///
/// So promotion is deliberately asymmetric:
///
/// - **A free slot is filled immediately**, on the admission path, because there is no
///   incumbent to protect and making a new value wait a full window for a slot nobody
///   wants is pure lost attribution.
/// - **A contested slot only changes hands when the challenger's *lower* bound exceeds
///   the incumbent's *upper* bound** — that is, when the two are separated by more than
///   `SpaceSavingSketch`'s uncertainty. Anything closer is noise and is refused.
/// - **An incumbent that stops appearing keeps its slot for `graceWindows` windows**,
///   because a genuinely periodic value (a nightly sync, a weekly locale) is not the same
///   thing as a dead one, and evicting it on the first quiet window recreates the flapping
///   from the other direction.
public struct SurvivorSet: Sendable, Equatable {

    /// Survivor value -> consecutive windows in which it was not observed.
    public private(set) var members: [String: Int]
    /// Survivors actually seen on the admission path since the last reconciliation.
    ///
    /// This exists because the obvious alternative is wrong in both directions. Deriving
    /// "was it observed?" from the sketch's ranked candidate list — which is what this
    /// type did originally — means (a) a survivor that has genuinely stopped appearing is
    /// still listed by a sketch under no pressure, because `decay()` floors counts at 1
    /// and never removes a counter, so it never expires and `expired` is dead in practice;
    /// and (b) a value observed thousands of times but evicted from the sketch under
    /// pressure accrues misses and is expired *while live*. The grace window is a claim
    /// about the value, not about the sketch's opinion of the value.
    private var observedThisWindow: Set<String>
    public private(set) var capacity: Int
    public let graceWindows: Int

    public init(capacity: Int, graceWindows: Int = 2) {
        self.members = [:]
        self.observedThisWindow = []
        self.capacity = max(0, capacity)
        self.graceWindows = max(0, graceWindows)
    }

    public var values: Set<String> { Set(members.keys) }
    public var count: Int { members.count }

    public func contains(_ value: String) -> Bool { members[value] != nil }

    public var hasFreeSlot: Bool { members.count < capacity }

    /// Claims a free slot on the admission path. Returns `false` when the set is full —
    /// contested slots are only resolved at a window boundary, never mid-window.
    @discardableResult
    mutating func admitIfSlotAvailable(_ value: String) -> Bool {
        guard !ReservedValue.isReserved(value) else { return false }
        if members[value] != nil {
            observedThisWindow.insert(value)
            return true
        }
        guard members.count < capacity else { return false }
        members[value] = 0
        observedThisWindow.insert(value)
        return true
    }

    /// Records that a survivor was seen this window.
    ///
    /// The write lands in `observedThisWindow` rather than in `members`, because
    /// `reconcile` rewrites every `members` value in step 1 — a `touch` that wrote there
    /// would be unconditionally overwritten before anything read it, making this method
    /// dead code on the hot admission path.
    mutating func touch(_ value: String) {
        if members[value] != nil { observedThisWindow.insert(value) }
    }

    public struct Reconciliation: Sendable, Equatable {
        /// Values that gained a slot this window.
        public var promoted: [String] = []
        /// Values that lost a slot to a challenger or to a shrinking allocation.
        public var demoted: [String] = []
        /// Values evicted for going unobserved past the grace period.
        public var expired: [String] = []
        /// Challengers that out-ranked an incumbent on the point estimate but **not** by
        /// more than the sketch's error interval. This list is the anti-flapping rule
        /// doing its job, and it is exported so the behaviour is observable rather than
        /// something you have to take on faith.
        public var refusedForInsufficientSeparation: [String] = []

        public init() {}
    }

    /// Window-boundary reconciliation against the sketch's ranked counters.
    ///
    /// `candidates` must be ordered by descending frequency estimate — `SpaceSavingSketch.ranked()`
    /// guarantees a total order, which is what makes this function's output reproducible.
    mutating func reconcile(
        candidates: [SpaceSavingSketch.Counter],
        newCapacity: Int
    ) -> Reconciliation {
        var report = Reconciliation()
        capacity = max(0, newCapacity)

        // Live observation, not sketch membership. See `observedThisWindow`.
        let observed = observedThisWindow
        var bounds: [String: (lowerBound: Int, upperBound: Int)] = [:]
        for candidate in candidates {
            bounds[candidate.value] = (candidate.lowerBound, candidate.upperBound)
        }

        // 1. Age out incumbents that went unobserved past their grace period.
        for value in members.keys.sorted() {
            guard let missed = members[value] else { continue }
            if observed.contains(value) {
                members[value] = 0
            } else if missed >= graceWindows {
                members.removeValue(forKey: value)
                report.expired.append(value)
            } else {
                members[value] = missed.saturatingAdding(1)
            }
        }

        // 2. Shrink to capacity, dropping the weakest incumbents first. An incumbent with
        //    no current estimate (unobserved, still inside its grace period) sorts as
        //    weakest — it is the one with the least evidence behind it.
        if members.count > capacity {
            let weakestFirst = members.keys.sorted { lhs, rhs in
                let lhsUpper = bounds[lhs]?.upperBound ?? -1
                let rhsUpper = bounds[rhs]?.upperBound ?? -1
                return lhsUpper == rhsUpper ? lhs < rhs : lhsUpper < rhsUpper
            }
            let excess = members.count - capacity
            for value in weakestFirst.prefix(excess) {
                members.removeValue(forKey: value)
                report.demoted.append(value)
            }
        }

        // 3. Fill free slots from the strongest unseated challengers.
        var challengers = candidates.filter { members[$0.value] == nil && !ReservedValue.isReserved($0.value) }
        while members.count < capacity, !challengers.isEmpty {
            let challenger = challengers.removeFirst()
            members[challenger.value] = 0
            report.promoted.append(challenger.value)
        }

        // 4. Contest the remaining challengers against the weakest incumbent. Bounded by
        //    the number of challengers — each iteration consumes exactly one, so this
        //    cannot spin even if every comparison succeeds.
        // An incumbent that was observed this window but is absent from the ranked
        // candidates has *unknown* strength, not zero strength — the sketch evicted it
        // under pressure, which is a statement about the sketch's capacity, not about the
        // value. Contesting it would be the maximal case of the thing the separation rule
        // exists to prevent: a swap decided by no evidence at all. So it is not a contest
        // target while any ranked incumbent exists.
        //
        // Held as an exclusion set rather than a snapshot of the contestable members,
        // because members change under the loop: each swap removes an incumbent and adds
        // the challenger, and a precomputed membership list goes stale on the first swap.
        let unranked = observed.subtracting(bounds.keys)
        for challenger in challengers {
            guard capacity > 0 else { break }
            guard let weakest = weakestIncumbent(bounds: bounds, excluding: unranked) else {
                report.refusedForInsufficientSeparation.append(challenger.value)
                continue
            }
            let incumbentUpper = bounds[weakest]?.upperBound ?? -1
            // Strict separation beyond the sketch's error interval, or no swap.
            guard challenger.lowerBound > incumbentUpper else {
                report.refusedForInsufficientSeparation.append(challenger.value)
                continue
            }
            members.removeValue(forKey: weakest)
            report.demoted.append(weakest)
            members[challenger.value] = 0
            report.promoted.append(challenger.value)
        }

        // The window is over: everything observed during it has now been accounted for.
        observedThisWindow.removeAll(keepingCapacity: true)

        report.promoted.sort()
        report.demoted.sort()
        report.expired.sort()
        report.refusedForInsufficientSeparation.sort()
        return report
    }

    private func weakestIncumbent(
        bounds: [String: (lowerBound: Int, upperBound: Int)],
        excluding unranked: Set<String>
    ) -> String? {
        members.keys.lazy.filter { !unranked.contains($0) }.min { lhs, rhs in
            let lhsUpper = bounds[lhs]?.upperBound ?? -1
            let rhsUpper = bounds[rhs]?.upperBound ?? -1
            return lhsUpper == rhsUpper ? lhs < rhs : lhsUpper < rhsUpper
        }
    }
}
