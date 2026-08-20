import Foundation

/// Distinct-value estimation in fixed memory (Flajolet, Fusy, Gandouet & Meunier, 2007).
///
/// The governor needs to answer "how many distinct values has this key actually taken?"
/// *before* it decides how to apportion budget — and it must answer without keeping the
/// values, because keeping them is the unbounded allocation the module exists to prevent.
///
/// `SpaceSavingSketch` cannot answer this. It knows the top-k by frequency; it has no idea
/// whether the tail it evicted was 12 values or 120,000. Those two cases want completely
/// different budgets, so demand estimation and heavy-hitter tracking are genuinely two
/// problems and this module carries two sketches.
///
/// At `precision = 10` that is 1024 one-byte registers — 1 KB per open dimension — for a
/// standard error of roughly 3.25%. Registers are `UInt8`, which is enough for any rank a
/// 64-bit hash can produce.
struct HyperLogLog: Sendable {

    /// Below `p = 4` the bias corrections stop being defined; above `p = 16` the register
    /// bank (64 KB per key) stops being a reasonable thing to carry inside a client app.
    static let precisionRange: ClosedRange<Int> = 4...16

    let precision: Int
    private(set) var registers: [UInt8]

    init(precision: Int) {
        let clamped = precision.clamped(to: Self.precisionRange)
        self.precision = clamped
        // `1 << clamped` with `clamped ≤ 16` is at most 65536 — no shift overflow.
        self.registers = [UInt8](repeating: 0, count: 1 << clamped)
    }

    /// Testing seam: lets a test hand-place registers, including states the estimator must
    /// survive (all zero, all saturated).
    init(precision: Int, registers: [UInt8]) {
        let clamped = precision.clamped(to: Self.precisionRange)
        self.precision = clamped
        let expected = 1 << clamped
        if registers.count == expected {
            self.registers = registers
        } else {
            var padded = Array(registers.prefix(expected))
            padded.append(contentsOf: [UInt8](repeating: 0, count: expected - padded.count))
            self.registers = padded
        }
    }

    var registerCount: Int { registers.count }

    /// The largest rank a register can legitimately hold: `1 + (64 - precision)` bits of
    /// remainder. Also the clamp that keeps the `UInt8` conversion in `observe` total —
    /// an all-zero remainder reports 64 leading zeros, which is above this ceiling.
    var validRegisterCeiling: Int { 64 - precision + 1 }

    /// Takes an already-hashed value rather than a `String`.
    ///
    /// The hash function is the governor's, not the estimator's: register assignment and
    /// label fingerprinting must agree about what "the same value" means, and a test that
    /// wants a pathological hash distribution should be able to supply one directly.
    mutating func observe(hash: UInt64) {
        // Register index: the top `precision` bits.
        let bucket = Int(truncatingIfNeeded: hash >> UInt64(64 - precision))
        guard registers.indices.contains(bucket) else { return }

        // Rank: 1 + the number of leading zeros in the remaining `64 - precision` bits.
        // Shifting the used bits off the top leaves them left-aligned, so
        // `leadingZeroBitCount` reads the right window. An all-zero remainder gives 64,
        // which the clamp folds down to the maximum representable rank.
        let remainder = hash << UInt64(precision)
        let maximumRank = 64 - precision + 1
        // `maximumRank ≤ 61` for `precision ≥ 4`, so the `UInt8` conversion cannot trap.
        let rank = UInt8(min(remainder.leadingZeroBitCount + 1, maximumRank))
        if rank > registers[bucket] {
            registers[bucket] = rank
        }
    }

    /// The standard relative error, `1.04 / sqrt(m)`. Reported alongside every estimate so
    /// the budget allocator's inputs carry their own uncertainty instead of pretending to
    /// be exact.
    var relativeErrorBound: Double {
        let m = Double(registers.count)
        guard m > 0 else { return 1.0 }
        return 1.04 / m.squareRoot()
    }

    /// Bias-corrected distinct-count estimate.
    ///
    /// Every division and every `Double -> Int` conversion below is a trap site on a
    /// brand-new estimator, which is the state this is *most* likely to be called in:
    /// an all-zero register bank makes the harmonic sum `m`, and `zeroCount == m` makes
    /// `log(m/m) = 0`, so the answer is 0 — but only because the guards say so.
    var estimatedCardinality: Int {
        let m = registers.count
        guard m > 0 else { return 0 }

        var harmonicSum = 0.0
        var zeroCount = 0
        for register in registers {
            harmonicSum += exp2(-Double(register))
            if register == 0 { zeroCount += 1 }
        }

        guard harmonicSum > 0, harmonicSum.isFinite else { return 0 }

        let mDouble = Double(m)
        let raw = Self.alpha(registerCount: m) * mDouble * mDouble / harmonicSum
        guard raw.isFinite else { return 0 }

        // Small-range correction. HyperLogLog's raw estimator is badly biased below about
        // 2.5m; linear counting over the empty registers is the standard replacement, and
        // it is exactly what the "one distinct value" case needs to report 1 rather than
        // several hundred.
        if raw <= 2.5 * mDouble, zeroCount > 0 {
            let linearCounting = mDouble * log(mDouble / Double(zeroCount))
            guard linearCounting.isFinite else { return 0 }
            return max(0, Int.saturating(rounding: linearCounting))
        }

        // No large-range correction: that term exists to undo 32-bit hash collisions
        // around 2^32, and this estimator is fed 64-bit hashes.
        return max(0, Int.saturating(rounding: raw))
    }

    /// The estimate widened by the standard error, so a caller can reason about the worst
    /// case rather than the point estimate.
    var estimateInterval: (lowerBound: Int, upperBound: Int) {
        let point = Double(estimatedCardinality)
        let spread = point * relativeErrorBound
        let lower = max(0, Int.saturating(rounding: point - spread))
        let upper = max(lower, Int.saturating(rounding: point + spread))
        return (lower, upper)
    }

    static func alpha(registerCount m: Int) -> Double {
        switch m {
        case 16: return 0.673
        case 32: return 0.697
        case 64: return 0.709
        default:
            guard m > 0 else { return 0.7213 }
            return 0.7213 / (1.0 + 1.079 / Double(m))
        }
    }
}
