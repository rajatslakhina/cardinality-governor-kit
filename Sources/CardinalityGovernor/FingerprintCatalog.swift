import Foundation

/// A 64-bit stand-in for a whole label set.
public struct LabelFingerprint: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    /// Zero-padded hex, so fingerprints sort and align in logs.
    public var description: String {
        let hex = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

/// Interning for label sets, so that a diagnostic can name a series without re-sending
/// the labels.
///
/// ## The problem this solves
///
/// MetricKit hands you metrics and diagnostics through separate channels. Attaching the
/// full dimension set to every hang report, crash payload and exception diagnostic
/// re-creates the entire cardinality explosion on the diagnostics side — where it is
/// worse, because diagnostic payloads are large and there is no aggregation step to hide
/// behind. Dictionary-encoding the label set into one 64-bit token and publishing the
/// token → labels mapping once is the standard answer, and it works here because the
/// governor has already bounded how many distinct label sets can exist.
///
/// ## Why collisions are detected rather than assumed away
///
/// At a joint budget of 4096 series the birthday probability of a 64-bit collision is
/// about 4×10⁻¹³, so the honest engineering answer is "it will not happen." But "will not
/// happen" is a probability, and the failure mode if it does is silent: two unrelated
/// series merge and neither is ever right again. Detection costs one dictionary lookup
/// that is already being performed, so the catalog detects and resolves instead of
/// asserting. `FingerprintTests` forces the path with an adversarial hasher that returns
/// a constant.
public struct FingerprintCatalog: Sendable {

    /// Bounded — the catalog cannot outgrow the joint series budget it is interning for.
    public private(set) var capacity: Int
    public private(set) var entries: [LabelFingerprint: LabelSet]
    public private(set) var collisionsResolved: Int
    public private(set) var unresolvedCollisions: Int
    /// Registrations refused because the catalog was full. The fingerprint is still
    /// returned and is still correct; only the reverse mapping is missing.
    public private(set) var refusedForCapacity: Int

    /// Rehash attempts before giving up. Each attempt is a fresh splitmix64 of the
    /// previous fingerprint, so eight independent 64-bit draws all colliding is not a case
    /// worth more code than a counter — but the loop is bounded regardless, because an
    /// unbounded "keep trying" loop on the instrumentation path is a hang.
    static let maximumProbes = 8

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.entries = [:]
        self.collisionsResolved = 0
        self.unresolvedCollisions = 0
        self.refusedForCapacity = 0
    }

    public var count: Int { entries.count }

    public func labels(for fingerprint: LabelFingerprint) -> LabelSet? {
        entries[fingerprint]
    }

    /// Returns the fingerprint for `labels`, registering the reverse mapping if there is
    /// room. Idempotent: registering the same label set twice returns the same
    /// fingerprint and does not count as a collision.
    public mutating func register(_ labels: LabelSet, hasher: some StableHasher) -> LabelFingerprint {
        let canonical = labels.canonicalDescription
        var fingerprint = LabelFingerprint(hasher.hash(canonical))

        for probe in 0...Self.maximumProbes {
            switch entries[fingerprint] {
            case .none:
                guard entries.count < capacity else {
                    refusedForCapacity = refusedForCapacity.saturatingAdding(1)
                    return fingerprint
                }
                entries[fingerprint] = labels
                if probe > 0 { collisionsResolved = collisionsResolved.saturatingAdding(1) }
                return fingerprint
            case .some(let existing) where existing == labels:
                return fingerprint
            case .some:
                // A real collision: same fingerprint, different labels. Re-draw.
                fingerprint = LabelFingerprint(FNV1a64.splitmix64Finalize(fingerprint.value ^ UInt64(probe &+ 1)))
            }
        }

        unresolvedCollisions = unresolvedCollisions.saturatingAdding(1)
        return fingerprint
    }

    public mutating func reset(capacity newCapacity: Int? = nil) {
        if let newCapacity { capacity = max(0, newCapacity) }
        entries.removeAll(keepingCapacity: true)
        collisionsResolved = 0
        unresolvedCollisions = 0
        refusedForCapacity = 0
    }
}
