import Foundation

/// Trap-free integer arithmetic.
///
/// This module counts observations on a hot instrumentation path and converts
/// floating-point estimator output back to integers. Both are reachable trap sites:
///
/// - `Int(someDouble)` traps on NaN, on ±infinity, and on any finite value outside
///   `Int.min ... Int.max`. `HyperLogLog`'s raw estimate is `α·m²/Σ2^-r`, and Σ is zero
///   for an all-zero register bank — a brand-new estimator. That is `+inf`, on the very
///   first read.
/// - `a % b` and `a / b` trap on `b == 0`, and additionally on `Int.min / -1`, which
///   overflows because `-Int.min` is not representable.
/// - `+` and `*` trap on overflow. A counter incremented once per telemetry event will
///   not realistically reach `Int.max`, but "realistically" is not a proof, and the cost
///   of a proof here is one `addingReportingOverflow`.
///
/// Every ceiling below is derived from `Int.max` / `Int.min` rather than a 64-bit literal.
extension Int {
    /// Rounds a `Double` to the nearest integer, saturating at the `Int` bounds.
    /// NaN maps to 0 — it is the only value with no defensible saturation target, and 0
    /// is the identity for every counter in this module.
    public static func saturating(rounding value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let rounded = value.rounded()
        // `Double(Int.max)` rounds *up* to 2^63 exactly, so `>=` is the correct comparison:
        // any Double at or above it is unrepresentable as an Int.
        if rounded >= Double(Int.max) { return .max }
        if rounded <= Double(Int.min) { return .min }
        return Int(rounded)
    }

    /// Truncates a `Double` toward zero, saturating at the `Int` bounds.
    public static func saturating(truncating value: Double) -> Int {
        Int.saturating(rounding: value.rounded(.towardZero))
    }

    /// `self + other`, clamped instead of trapped.
    @inline(__always)
    public func saturatingAdding(_ other: Int) -> Int {
        let (result, overflowed) = addingReportingOverflow(other)
        guard overflowed else { return result }
        return other > 0 ? .max : .min
    }

    /// `self * other`, clamped instead of trapped.
    @inline(__always)
    public func saturatingMultiplied(by other: Int) -> Int {
        let (result, overflowed) = multipliedReportingOverflow(by: other)
        guard overflowed else { return result }
        // Sign of the true product decides the saturation end. Neither operand can be 0
        // here, because a product involving 0 cannot overflow.
        return (self > 0) == (other > 0) ? .max : .min
    }

    /// `self / divisor`, or `nil` for the two inputs on which `/` traps.
    @inline(__always)
    public func safelyDivided(by divisor: Int) -> Int? {
        guard divisor != 0 else { return nil }
        guard !(self == .min && divisor == -1) else { return nil }
        return self / divisor
    }

    /// `self % divisor`, or `nil` for the two inputs on which `%` traps.
    @inline(__always)
    public func safeRemainder(dividingBy divisor: Int) -> Int? {
        guard divisor != 0 else { return nil }
        guard !(self == .min && divisor == -1) else { return nil }
        return self % divisor
    }

    /// Clamps into a closed range. Returns `range.lowerBound` for an inverted range rather
    /// than trapping on `ClosedRange`'s own precondition.
    @inline(__always)
    public func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    /// Clamps into `lower...upper`, tolerating `upper < lower` by preferring `lower`.
    @inline(__always)
    public func clamped(lower: Int, upper: Int) -> Int {
        guard upper >= lower else { return lower }
        return Swift.min(Swift.max(self, lower), upper)
    }
}
