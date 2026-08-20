import XCTest
@testable import CardinalityGovernor

/// Every assertion here corresponds to an input that makes the *unguarded* expression
/// trap. These are not style checks.
final class SaturatingArithmeticTests: XCTestCase {

    func testDoubleConversionSurvivesEveryTrappingInput() {
        // `Int(Double.nan)` traps.
        XCTAssertEqual(Int.saturating(rounding: .nan), 0)
        // `Int(Double.infinity)` traps.
        XCTAssertEqual(Int.saturating(rounding: .infinity), .max)
        XCTAssertEqual(Int.saturating(rounding: -.infinity), .min)
        // `Int(1e300)` traps.
        XCTAssertEqual(Int.saturating(rounding: 1e300), .max)
        XCTAssertEqual(Int.saturating(rounding: -1e300), .min)
        // Exactly at the boundary: `Double(Int.max)` rounds up to 2^63, which is not
        // representable as an Int, so it must saturate rather than convert.
        XCTAssertEqual(Int.saturating(rounding: Double(Int.max)), .max)
        XCTAssertEqual(Int.saturating(rounding: Double(Int.min)), .min)
    }

    func testDoubleConversionIsExactInsideTheSafeRange() {
        XCTAssertEqual(Int.saturating(rounding: 0), 0)
        XCTAssertEqual(Int.saturating(rounding: 2.4), 2)
        XCTAssertEqual(Int.saturating(rounding: 2.6), 3)
        XCTAssertEqual(Int.saturating(rounding: -2.6), -3)
        XCTAssertEqual(Int.saturating(truncating: 2.9), 2)
        XCTAssertEqual(Int.saturating(truncating: -2.9), -2)
    }

    func testDivisionGuardsBothTrappingCases() {
        // `x / 0` traps.
        XCTAssertNil((10).safelyDivided(by: 0))
        XCTAssertNil((10).safeRemainder(dividingBy: 0))
        // `Int.min / -1` traps: the true quotient is `-Int.min`, which is unrepresentable.
        XCTAssertNil(Int.min.safelyDivided(by: -1))
        XCTAssertNil(Int.min.safeRemainder(dividingBy: -1))
        // Everything else behaves like `/` and `%`.
        XCTAssertEqual((10).safelyDivided(by: 3), 3)
        XCTAssertEqual((10).safeRemainder(dividingBy: 3), 1)
        XCTAssertEqual(Int.max.safelyDivided(by: -1), -Int.max)
    }

    func testAdditionAndMultiplicationSaturateInBothDirections() {
        XCTAssertEqual(Int.max.saturatingAdding(1), .max)
        XCTAssertEqual(Int.min.saturatingAdding(-1), .min)
        XCTAssertEqual((5).saturatingAdding(-8), -3)

        XCTAssertEqual(Int.max.saturatingMultiplied(by: 2), .max)
        XCTAssertEqual(Int.max.saturatingMultiplied(by: -2), .min)
        XCTAssertEqual(Int.min.saturatingMultiplied(by: -2), .max)
        XCTAssertEqual((6).saturatingMultiplied(by: -7), -42)
        XCTAssertEqual((0).saturatingMultiplied(by: Int.max), 0)
    }

    func testClampToleratesAnInvertedRange() {
        // `ClosedRange` itself would trap on `5...1`; this overload must not.
        XCTAssertEqual((3).clamped(lower: 5, upper: 1), 5)
        XCTAssertEqual((3).clamped(lower: 0, upper: 10), 3)
        XCTAssertEqual((-3).clamped(to: 0...10), 0)
        XCTAssertEqual((30).clamped(to: 0...10), 10)
    }
}
