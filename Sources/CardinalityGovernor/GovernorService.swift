import Foundation

/// Concurrency-safe access to a `CardinalityGovernor`.
///
/// ## Why the actor is separate from the policy
///
/// The governor is a `struct` with `mutating` methods and no concurrency of its own; this
/// actor is the only place isolation is discussed. That split is deliberate — a reviewer
/// can read the whole concurrency story in one short file instead of tracing suspension
/// points through a sketch implementation.
///
/// ## Reentrancy
///
/// **No method in this actor contains an `await`.** Every body is a single synchronous
/// mutation of `governor` and returns. There is therefore no suspension point at which
/// another task could observe half-updated state, and the classic actor-reentrancy bug —
/// read state, `await` something, then act on the now-stale read — is *designed out*
/// rather than defended against. That property is worth stating because it is easy to
/// destroy: adding a single `await` inside `admit` would reintroduce it silently, and no
/// compiler diagnostic would fire.
///
/// The corollary is that the governor must never call out to caller-supplied async code.
/// `StableHasher` is deliberately a synchronous protocol for exactly this reason.
public actor GovernorService {

    private var governor: CardinalityGovernor

    public init(
        schema: DimensionSchema,
        configuration: CardinalityGovernor.Configuration = .default,
        hasher: some StableHasher = FNV1a64()
    ) {
        self.governor = CardinalityGovernor(schema: schema, configuration: configuration, hasher: hasher)
    }

    @discardableResult
    public func admit(_ labels: LabelSet) -> AdmissionResult {
        governor.admit(labels)
    }

    /// Bulk admission. Not a convenience — admitting a batch inside one actor hop instead
    /// of N hops is the difference between one context switch and N on a hot path.
    @discardableResult
    public func admit(batch: [LabelSet]) -> [AdmissionResult] {
        batch.map { governor.admit($0) }
    }

    @discardableResult
    public func rollWindow() -> WindowReport {
        governor.rollWindow()
    }

    public func snapshot() -> GovernorSnapshot {
        governor.snapshot
    }

    public func conservation() -> ConservationAuditor.Finding {
        governor.snapshot.conservation
    }
}
