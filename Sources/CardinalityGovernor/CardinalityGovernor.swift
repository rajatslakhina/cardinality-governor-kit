import Foundation

// MARK: - Results

/// What happened to one dimension's value during admission.
///
/// Deliberately carries no payload. The observed value is never copied out of the
/// governor, because the values this module is defending against — search queries, file
/// names, user-supplied identifiers — are exactly the ones that must not be handed to a
/// telemetry pipeline. Counting how many values collapsed is enough to act on; knowing
/// *which* string it was is what turns a cardinality bug into a privacy incident.
public enum ValueDisposition: Sendable, Equatable, CustomStringConvertible {
    /// The value kept its own identity.
    case kept
    /// The caller did not supply this declared key.
    case unset
    /// The value lost its identity to the per-key distinct-value budget.
    case collapsedToOther
    /// The value was outside a closed domain, or was a forged reserved value.
    case collapsedToInvalid
    /// The whole label set lost its identity to the joint series budget, so this key's
    /// value — whatever its per-key fate would otherwise have been — is not in the
    /// exported series.
    ///
    /// It replaces every other disposition on an overflowed result, including `.unset` and
    /// `.collapsedToInvalid`, because `dispositions` describes what was *exported* and
    /// under overflow nothing per-key was. The per-key lifetime counters
    /// (`KeyStatistics.collapsedToInvalid` and friends) are unaffected and still describe
    /// the value itself; the two answer different questions on purpose.
    case collapsedToOverflow

    public var description: String {
        switch self {
        case .kept: return "kept"
        case .unset: return "unset"
        case .collapsedToOther: return "→ __other__"
        case .collapsedToInvalid: return "→ __invalid__"
        case .collapsedToOverflow: return "→ __overflow__"
        }
    }
}

public struct AdmissionResult: Sendable, Equatable {
    /// The label set actually recorded, after any collapse.
    public let labels: LabelSet
    /// The 64-bit token a diagnostic should carry instead of the labels.
    public let fingerprint: LabelFingerprint
    public let dispositions: [DimensionKey: ValueDisposition]
    /// True when the *joint* series budget was exhausted and the whole label set
    /// collapsed, rather than an individual dimension.
    public let jointSpaceOverflowed: Bool
    /// Keys the caller supplied that the schema does not declare. Dropped, not admitted:
    /// an undeclared key has no budget, and a dimension with no budget is unbounded.
    public let undeclaredKeys: [DimensionKey]
}

public struct KeyStatistics: Sendable, Equatable {
    public let key: DimensionKey
    public let isOpen: Bool
    /// Distinct values this key may keep identity for, this window.
    public let allocation: Int
    /// Values currently holding a slot.
    public let survivors: Int
    /// HyperLogLog's estimate of how many distinct values were actually seen.
    public let estimatedDistinctValues: Int
    public let estimatedDistinctInterval: (lowerBound: Int, upperBound: Int)
    public let observations: Int
    public let collapsedToOther: Int
    public let collapsedToInvalid: Int

    /// Share of this key's observations that lost their attribution. `nil` when nothing
    /// was observed — a rate over zero samples is not zero, it is undefined, and
    /// reporting it as `0%` reads as "healthy" for a key that was never exercised.
    public var collapseRate: Double? {
        guard observations > 0 else { return nil }
        return Double(collapsedToOther.saturatingAdding(collapsedToInvalid)) / Double(observations)
    }

    public static func == (lhs: KeyStatistics, rhs: KeyStatistics) -> Bool {
        lhs.key == rhs.key
            && lhs.isOpen == rhs.isOpen
            && lhs.allocation == rhs.allocation
            && lhs.survivors == rhs.survivors
            && lhs.estimatedDistinctValues == rhs.estimatedDistinctValues
            && lhs.estimatedDistinctInterval == rhs.estimatedDistinctInterval
            && lhs.observations == rhs.observations
            && lhs.collapsedToOther == rhs.collapsedToOther
            && lhs.collapsedToInvalid == rhs.collapsedToInvalid
    }
}

public struct GovernorSnapshot: Sendable {
    public let totalAdmitted: Int
    public let keys: [KeyStatistics]
    public let seriesCounts: [LabelSet: Int]
    public let trackedSeries: Int
    public let jointSeriesBudget: Int
    public let jointOverflowObservations: Int
    public let undeclaredKeyDrops: [DimensionKey: Int]
    public let fingerprintCatalog: FingerprintCatalog
    public let allocation: BudgetAllocation
    public let windowIndex: Int

    /// The invariant, evaluated live. Exposed on the snapshot so a caller — including the
    /// demo UI — audits the real tallies rather than a number the governor asserts about
    /// itself.
    public var conservation: ConservationAuditor.Finding {
        ConservationAuditor.audit(admitted: totalAdmitted, seriesCounts: seriesCounts)
    }

    /// What the joint space *could* reach given the current per-key allocations. Almost
    /// always far larger than `jointSeriesBudget`, which is the entire reason the joint
    /// budget exists as a separate mechanism.
    public let jointSpaceUpperBound: Int
}

public struct WindowReport: Sendable, Equatable {
    public let windowIndex: Int
    public let allocation: BudgetAllocation
    public let reconciliations: [DimensionKey: SurvivorSet.Reconciliation]
    public let observationsInWindow: Int
    public let seriesAtRoll: Int
}

// MARK: - Governor

/// A cardinality budget for a telemetry label space.
///
/// ## Two budgets, and why one does not imply the other
///
/// The insight the API is shaped around: **per-key budgets bound each marginal; they say
/// nothing about the joint.** Budget four dimensions at eight distinct values each and you
/// have authorised 32 values — and 8⁴ = 4096 series, which is the number the backend
/// bills. Teams reason about the first number and pay for the second.
///
/// So there are two mechanisms, and they fail differently on purpose:
///
/// - `Configuration.distinctValueBudget` is apportioned across open keys by
///   `BudgetAllocator`, and enforced per key by `SurvivorSet`. Exceeding it collapses one
///   dimension's value to `__other__`.
/// - `Configuration.jointSeriesBudget` caps the number of distinct label sets tracked at
///   all. Exceeding it collapses the *entire* label set to `__overflow__`.
///
/// Both conserve the observation count. Neither drops a sample. See `ConservationAuditor`
/// for why that is the load-bearing property rather than a nicety.
///
/// ## Value semantics on purpose
///
/// This is a `struct` with `mutating` methods and no concurrency of its own. The policy —
/// which is the part that is hard to get right — is a pure function of state and input,
/// so it can be driven deterministically in tests and replayed from a seed. Concurrency
/// lives in `GovernorService`, a thin actor wrapper that can be reviewed on its own. The
/// alternative (an actor holding the policy) makes every policy test `async`, makes
/// replay awkward, and buries the reentrancy question inside the algorithm instead of
/// beside it.
public struct CardinalityGovernor: Sendable {

    public struct Configuration: Sendable, Equatable {
        // `let`, not `var`: every value below is range-clamped in `init`, and a settable
        // property would let a caller write a budget of `-1` past the clamp and turn a
        // configuration mistake into a division or an allocation bug three layers down.
        /// Total distinct values apportioned across all open keys.
        public let distinctValueBudget: Int
        /// Hard cap on distinct label sets tracked, `__overflow__` included — the bound on
        /// the joint space, **for the lifetime of this governor** rather than per window.
        ///
        /// This is deliberate and it is the one place where the module's time semantics are
        /// asymmetric, so it is worth being explicit rather than leaving it to be
        /// discovered. Per-key budgets are windowed: a dimension value that stops appearing
        /// releases its slot, because the question there is "what is worth attributing
        /// *now*". The joint cap is not, because the question there is different — a
        /// backend bills for every distinct series it has ever had to store, and a series
        /// that stops receiving observations does not stop existing or stop costing money.
        /// A windowed joint cap would let an app cycle through unlimited series over time
        /// while reporting that it never exceeded its budget.
        ///
        /// The practical consequence: once `jointSeriesBudget - 1` real series have been
        /// materialised, every genuinely new combination collapses to `__overflow__` for
        /// the rest of the process. Pinned by
        /// `testTheJointCapIsALifetimeCapNotAWindowedOne`.
        ///
        /// Clamped to at least 1, and that is not a rounding convenience. Conservation
        /// requires every observation to land in *some* series, so there must always be at
        /// least one series to land in. A budget of 1 is expressible and means "track
        /// nothing but the overflow bucket"; a budget of 0 is not, because it would ask
        /// for a tally with nowhere to tally.
        public let jointSeriesBudget: Int
        /// Sketch capacity is `allocation * overprovision`, so the sketch can see
        /// candidates that are not currently survivors — otherwise a challenger could
        /// never accumulate the evidence needed to win a slot.
        public let sketchOverprovision: Int
        /// HyperLogLog precision. 10 → 1024 registers → ~3.25% standard error.
        public let hyperLogLogPrecision: Int
        /// Windows an unobserved survivor keeps its slot.
        public let promotionGraceWindows: Int

        public init(
            distinctValueBudget: Int = 64,
            jointSeriesBudget: Int = 512,
            sketchOverprovision: Int = 4,
            hyperLogLogPrecision: Int = 10,
            promotionGraceWindows: Int = 2
        ) {
            self.distinctValueBudget = distinctValueBudget.clamped(to: BudgetAllocator.budgetRange)
            self.jointSeriesBudget = jointSeriesBudget.clamped(
                lower: 1,
                upper: BudgetAllocator.budgetRange.upperBound
            )
            self.sketchOverprovision = sketchOverprovision.clamped(lower: 1, upper: 64)
            self.hyperLogLogPrecision = hyperLogLogPrecision.clamped(to: HyperLogLog.precisionRange)
            self.promotionGraceWindows = promotionGraceWindows.clamped(lower: 0, upper: 64)
        }

        public static let `default` = Configuration()
    }

    // MARK: State

    public let schema: DimensionSchema
    public let configuration: Configuration

    private let hasher: any StableHasher

    private var sketches: [DimensionKey: SpaceSavingSketch]
    private var estimators: [DimensionKey: HyperLogLog]
    /// Last window's distinct-value estimate per open key. Kept so demand can be a
    /// two-window maximum rather than a lifetime accumulation — see `rollWindow()`.
    private var previousWindowDemand: [DimensionKey: Int]
    private var survivors: [DimensionKey: SurvivorSet]

    private var observations: [DimensionKey: Int]
    private var collapsedToOther: [DimensionKey: Int]
    private var collapsedToInvalid: [DimensionKey: Int]
    private var undeclaredKeyDrops: [DimensionKey: Int]

    private var seriesCounts: [LabelSet: Int]
    private var catalog: FingerprintCatalog

    private(set) public var allocation: BudgetAllocation
    private(set) public var totalAdmitted: Int
    private(set) public var jointOverflowObservations: Int
    private(set) public var windowIndex: Int
    private var observationsThisWindow: Int

    /// The single label set every joint-overflow observation is tallied into. Built once
    /// so overflow itself cannot add series.
    private let overflowLabels: LabelSet

    public init(
        schema: DimensionSchema,
        configuration: Configuration = .default,
        hasher: some StableHasher = FNV1a64()
    ) {
        self.schema = schema
        self.configuration = configuration
        self.hasher = hasher

        var overflow = LabelSet()
        for key in schema.declaredKeys {
            overflow.set(key, ReservedValue.overflow)
        }
        // A schema with no declared keys still needs a distinct overflow series, otherwise
        // it is the empty label set and indistinguishable from a legitimate no-label
        // observation.
        if schema.declaredKeys.isEmpty {
            overflow.set(DimensionKey("__series__"), ReservedValue.overflow)
        }
        self.overflowLabels = overflow

        let openKeys = schema.openKeys
        let floors = openKeys.reduce(into: [DimensionKey: Int]()) { $0[$1] = schema.floor(for: $1) }
        // The first window has no demand evidence yet, so the initial apportionment is
        // driven by the declared floors alone. `rollWindow` replaces it with HyperLogLog
        // demand as soon as there is any.
        let initial = BudgetAllocator.allocate(
            total: configuration.distinctValueBudget,
            demands: floors,
            floors: floors
        )
        self.allocation = initial

        self.sketches = [:]
        self.estimators = [:]
        self.survivors = [:]
        for key in openKeys {
            let slots = initial.allocation(for: key)
            sketches[key] = SpaceSavingSketch(
                capacity: slots.saturatingMultiplied(by: configuration.sketchOverprovision)
            )
            estimators[key] = HyperLogLog(precision: configuration.hyperLogLogPrecision)
            survivors[key] = SurvivorSet(capacity: slots, graceWindows: configuration.promotionGraceWindows)
        }

        self.previousWindowDemand = [:]
        self.observations = [:]
        self.collapsedToOther = [:]
        self.collapsedToInvalid = [:]
        self.undeclaredKeyDrops = [:]
        self.seriesCounts = [:]
        self.catalog = FingerprintCatalog(capacity: configuration.jointSeriesBudget)
        self.totalAdmitted = 0
        self.jointOverflowObservations = 0
        self.windowIndex = 0
        self.observationsThisWindow = 0
    }

    // MARK: Admission

    /// Governs one observation's labels. Never fails, never drops the observation.
    @discardableResult
    public mutating func admit(_ labels: LabelSet) -> AdmissionResult {
        totalAdmitted = totalAdmitted.saturatingAdding(1)
        observationsThisWindow = observationsThisWindow.saturatingAdding(1)

        var governed = LabelSet()
        var dispositions: [DimensionKey: ValueDisposition] = [:]

        for key in schema.declaredKeys {
            guard let domain = schema.domains[key] else { continue }
            let supplied = labels[key]

            guard let raw = supplied else {
                governed.set(key, ReservedValue.unset)
                dispositions[key] = .unset
                continue
            }

            observations[key] = (observations[key] ?? 0).saturatingAdding(1)

            // A caller supplying a reserved sentinel would be able to forge a collapse and
            // make the ledger unauditable, so a forged sentinel is itself invalid.
            guard !ReservedValue.isReserved(raw) else {
                governed.set(key, ReservedValue.invalid)
                dispositions[key] = .collapsedToInvalid
                collapsedToInvalid[key] = (collapsedToInvalid[key] ?? 0).saturatingAdding(1)
                continue
            }

            switch domain {
            case .closed(let allowed):
                if allowed.contains(raw) {
                    governed.set(key, raw)
                    dispositions[key] = .kept
                } else {
                    governed.set(key, ReservedValue.invalid)
                    dispositions[key] = .collapsedToInvalid
                    collapsedToInvalid[key] = (collapsedToInvalid[key] ?? 0).saturatingAdding(1)
                }

            case .open:
                // Hashed into a local first: `estimators[key]?.observe(hash: hasher.hash(raw))`
                // is an exclusivity violation, because reading `self.hasher` overlaps the
                // exclusive access the subscript mutation holds on `self`.
                let hashedValue = hasher.hash(raw)
                sketches[key]?.observe(raw)
                estimators[key]?.observe(hash: hashedValue)

                if survivors[key]?.contains(raw) == true {
                    survivors[key]?.touch(raw)
                    governed.set(key, raw)
                    dispositions[key] = .kept
                } else if survivors[key]?.admitIfSlotAvailable(raw) == true {
                    // Free slots fill immediately; only contested slots wait for a window
                    // boundary. See `SurvivorSet` for why the asymmetry is deliberate.
                    governed.set(key, raw)
                    dispositions[key] = .kept
                } else {
                    governed.set(key, ReservedValue.other)
                    dispositions[key] = .collapsedToOther
                    collapsedToOther[key] = (collapsedToOther[key] ?? 0).saturatingAdding(1)
                }
            }
        }

        var undeclared: [DimensionKey] = []
        for key in labels.pairs.keys.sorted() where schema.domains[key] == nil {
            undeclared.append(key)
            undeclaredKeyDrops[key] = (undeclaredKeyDrops[key] ?? 0).saturatingAdding(1)
        }

        // Joint-space enforcement. A label set that is not already tracked may only be
        // created if there is room; otherwise the whole set collapses. Note the order:
        // this runs *after* per-key collapse, so a new series here is genuinely a new
        // combination of already-budgeted values.
        //
        // One slot is permanently reserved for `__overflow__`. Without the reservation the
        // cap is off by one in the worst possible way: the last free slot goes to a real
        // series, the *next* observation overflows, and materialising `__overflow__` to
        // receive it pushes the tally to `budget + 1` — the enforcement mechanism breaking
        // the limit it exists to enforce. Found by
        // `testJointCapHoldsExactlyAtEveryBudgetIncludingTheBoundary`, which asserts the
        // bound after *every* observation at *every* budget from 1 to 12 rather than
        // asserting "roughly bounded" once.
        var overflowed = false
        if seriesCounts[governed] == nil {
            let realSeriesCapacity = configuration.jointSeriesBudget - 1
            let overflowIsMaterialised = seriesCounts[overflowLabels] != nil
            let realSeriesTracked = seriesCounts.count - (overflowIsMaterialised ? 1 : 0)
            if realSeriesTracked >= realSeriesCapacity {
                governed = overflowLabels
                overflowed = true
                jointOverflowObservations = jointOverflowObservations.saturatingAdding(1)
                // Every disposition has to be rewritten, not just the label set. Leaving
                // them as `.kept` while `labels` reads `__overflow__` makes the result
                // self-contradictory, and any "how many values kept their identity"
                // counter built on `dispositions` is then wrong by exactly the overflow
                // volume. Asserted by `testOverflowDispositionsAgreeWithLabels`.
                for key in dispositions.keys {
                    dispositions[key] = .collapsedToOverflow
                }
            }
        }

        seriesCounts[governed] = (seriesCounts[governed] ?? 0).saturatingAdding(1)
        let fingerprint = catalog.register(governed, hasher: hasher)

        return AdmissionResult(
            labels: governed,
            fingerprint: fingerprint,
            dispositions: dispositions,
            jointSpaceOverflowed: overflowed,
            undeclaredKeys: undeclared
        )
    }

    // MARK: Window boundary

    /// Re-apportions the budget from observed demand and reconciles every survivor set.
    ///
    /// Nothing about admission changes mid-window: the allocation a call site sees is
    /// fixed for the whole window, which is what makes a window's tallies internally
    /// consistent.
    @discardableResult
    public mutating func rollWindow() -> WindowReport {
        let openKeys = schema.openKeys
        let floors = openKeys.reduce(into: [DimensionKey: Int]()) { $0[$1] = schema.floor(for: $1) }
        // Demand is the *upper* end of HyperLogLog's interval: under-allocating a key
        // costs attribution that cannot be recovered later, while over-allocating costs
        // slots that the joint budget caps anyway.
        // Demand is the max over the current window and the previous one. A raw lifetime
        // estimator is a monotone ratchet: HyperLogLog has no eviction, so a key that saw
        // one burst of 100k distinct values at hour 1 still demands 100k at hour 12 and
        // permanently starves every other key. `SpaceSavingSketch.decay()` already gives
        // the heavy-hitter side windowed semantics; leaving the demand side unwindowed
        // means the two sketches feeding one allocator disagree about what time is.
        //
        // Two windows rather than one, because a single quiet window should not crater a
        // key's allocation and force its survivors to re-earn their slots.
        let demands = openKeys.reduce(into: [DimensionKey: Int]()) { result, key in
            let thisWindow = estimators[key]?.estimateInterval.upperBound ?? 0
            result[key] = max(thisWindow, previousWindowDemand[key] ?? 0)
        }

        allocation = BudgetAllocator.allocate(
            total: configuration.distinctValueBudget,
            demands: demands,
            floors: floors
        )

        var reconciliations: [DimensionKey: SurvivorSet.Reconciliation] = [:]
        for key in openKeys {
            let slots = allocation.allocation(for: key)
            // Above the guard on purpose. The guard is currently unreachable, but the
            // entire windowed-demand mechanism must not be gated behind a check about two
            // unrelated dictionaries — a refactor that let it fire would silently restore
            // the lifetime ratchet with no test failing.
            previousWindowDemand[key] = estimators[key]?.estimateInterval.upperBound ?? 0
            estimators[key] = HyperLogLog(precision: configuration.hyperLogLogPrecision)

            guard var sketch = sketches[key], var survivorSet = survivors[key] else { continue }

            let candidates = sketch.ranked(limit: slots.saturatingMultiplied(by: configuration.sketchOverprovision))
            reconciliations[key] = survivorSet.reconcile(candidates: candidates, newCapacity: slots)

            sketch.decay()
            // The sketch has to follow the allocation. Sizing it once at construction and
            // never again caps the effective per-key budget at
            // `min(allocation, initialAllocation × overprovision)` — so a key whose
            // allocation grows can never fill its new slots from `ranked(limit:)`, its
            // extra survivors go unobserved, expire, and get refilled by *arrival order*
            // on the admission path. That is precisely the pathology this whole module
            // exists to avoid, reintroduced one layer down. Asserted by
            // `testSurvivorsAreChosenByFrequencyEvenAfterAKeysAllocationGrows`.
            sketch.resize(capacity: slots.saturatingMultiplied(by: configuration.sketchOverprovision))
            sketches[key] = sketch
            survivors[key] = survivorSet
        }

        let report = WindowReport(
            windowIndex: windowIndex,
            allocation: allocation,
            reconciliations: reconciliations,
            observationsInWindow: observationsThisWindow,
            seriesAtRoll: seriesCounts.count
        )

        windowIndex = windowIndex.saturatingAdding(1)
        observationsThisWindow = 0
        return report
    }

    // MARK: Inspection

    /// The values of `key` that currently keep their own identity, sorted.
    ///
    /// Exposed because "which values survived" is the question a team actually asks when a
    /// dashboard goes strange, and because a survivor set that churns under a stationary
    /// input is a bug you cannot see from the counts alone.
    public func survivingValues(for key: DimensionKey) -> [String] {
        (survivors[key]?.members.keys).map { $0.sorted() } ?? []
    }

    public var snapshot: GovernorSnapshot {
        let keyStats: [KeyStatistics] = schema.declaredKeys.map { key in
            let isOpen = schema.openKeys.contains(key)
            let estimator = estimators[key]
            // The estimator is reset at every window boundary, so reading it directly
            // renders `0 ±0` for every open dimension in any snapshot taken immediately
            // after a roll — which is exactly when a dashboard re-reads. Report the same
            // two-window maximum the allocator uses, so the number on screen is the number
            // the budget was computed from.
            let carried = previousWindowDemand[key] ?? 0
            let liveInterval = estimator?.estimateInterval
            let reportedInterval: (lowerBound: Int, upperBound: Int)? = liveInterval.map {
                (max($0.lowerBound, carried), max($0.upperBound, carried))
            }
            return KeyStatistics(
                key: key,
                isOpen: isOpen,
                allocation: isOpen ? allocation.allocation(for: key) : closedDomainSize(key),
                survivors: survivors[key]?.count ?? closedDomainSize(key),
                estimatedDistinctValues: estimator.map { max($0.estimatedCardinality, carried) }
                    ?? closedDomainSize(key),
                estimatedDistinctInterval: reportedInterval
                    ?? (closedDomainSize(key), closedDomainSize(key)),
                observations: observations[key] ?? 0,
                collapsedToOther: collapsedToOther[key] ?? 0,
                collapsedToInvalid: collapsedToInvalid[key] ?? 0
            )
        }

        return GovernorSnapshot(
            totalAdmitted: totalAdmitted,
            keys: keyStats,
            seriesCounts: seriesCounts,
            trackedSeries: seriesCounts.count,
            jointSeriesBudget: configuration.jointSeriesBudget,
            jointOverflowObservations: jointOverflowObservations,
            undeclaredKeyDrops: undeclaredKeyDrops,
            fingerprintCatalog: catalog,
            allocation: allocation,
            windowIndex: windowIndex,
            jointSpaceUpperBound: schema.jointSpaceUpperBound(openAllocation: allocation.perKey)
        )
    }

    private func closedDomainSize(_ key: DimensionKey) -> Int {
        if case .closed(let allowed) = schema.domains[key] { return allowed.count }
        return 0
    }
}
