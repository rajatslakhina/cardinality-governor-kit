import Foundation

/// A 64-bit hash that is stable **across processes**.
///
/// Deliberately not `Swift.Hasher`. `Hasher` is seeded per process, so the same input
/// produces different values in two runs of the same binary. Three things in this module
/// depend on cross-process stability:
///
/// 1. `LabelFingerprint` — a diagnostic emitted today must resolve against a catalog
///    published by a previous launch, otherwise the interning scheme is pointless.
/// 2. `HyperLogLog` register assignment — an estimate is only comparable to another
///    estimate if both used the same bucket function.
/// 3. The test suite — and this is the subtle one. A test that hashes a value twice
///    *inside one process* and asserts the results match **passes against `Hasher`**,
///    because `Hasher` is stable within a process. It looks like a determinism test and
///    checks nothing. `FingerprintTests` pins golden constants instead.
public protocol StableHasher: Sendable {
    func hash(_ value: String) -> UInt64
}

/// FNV-1a over UTF-8, run through a splitmix64 finalizer.
///
/// FNV-1a alone has poor avalanche in the high bits, which matters here because
/// `HyperLogLog` takes its register index from exactly those bits — an unfinalized FNV-1a
/// clusters short similar strings ("en_US", "en_GB") into the same register and quietly
/// under-counts. The finalizer costs three multiplies and fixes the distribution.
///
/// Rejected alternatives: SipHash (what `Hasher` uses — needs a seed we would then have to
/// pin and version, and we get no security benefit because nothing here is adversarial);
/// CRC64 (fast with hardware support, but poor as a general-purpose bucket function);
/// SHA-256 truncated (cryptographically fine, ~50x slower on a hot instrumentation path
/// for a property nobody needs).
public struct FNV1a64: StableHasher {
    public init() {}

    public func hash(_ value: String) -> UInt64 {
        var accumulator: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            accumulator ^= UInt64(byte)
            // `&*` is required, not stylistic: FNV-1a is defined modulo 2^64 and `*`
            // would trap on the first multiplication.
            accumulator = accumulator &* 0x0000_0100_0000_01B3
        }
        return Self.splitmix64Finalize(accumulator)
    }

    /// The splitmix64 finalizer (Steele, Lea & Flood 2014). All arithmetic wraps by
    /// definition, hence `&+` / `&*`.
    @inline(__always)
    static func splitmix64Finalize(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A deterministic pseudo-random source, used by the demo scenario driver and by tests.
///
/// Not `SystemRandomNumberGenerator`: a scenario a reviewer runs twice must produce the
/// same numbers twice, and a property test that fails must be replayable from its seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        return FNV1a64.splitmix64Finalize(state &- 0x9E37_79B9_7F4A_7C15)
    }

    /// Uniform in `0..<upperBound`. Returns 0 when `upperBound <= 0` rather than trapping
    /// on the modulo — callers derive bounds from collection counts, and an empty
    /// collection is a legitimate state everywhere in this module.
    public mutating func nextIndex(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}
