import XCTest
@testable import CardinalityGovernor

final class HyperLogLogTests: XCTestCase {

    private let hasher = FNV1a64()

    // MARK: The property that makes it a *distinct*-count estimator

    /// Ten thousand observations of one value must estimate ~1, not ~10,000.
    ///
    /// This is the test that separates a real HyperLogLog from a counter with extra steps.
    /// An implementation that incremented on every `observe` — rather than taking the
    /// maximum rank per register — passes an accuracy test on distinct input and fails
    /// only here.
    func testRepeatedObservationsOfOneValueEstimateOne() {
        var estimator = HyperLogLog(precision: 12)
        let onlyHash = hasher.hash("the-one-value")
        for _ in 0..<10_000 { estimator.observe(hash: onlyHash) }

        XCTAssertEqual(estimator.estimatedCardinality, 1)
    }

    func testAccuracyIsWithinThreeStandardErrors() {
        var estimator = HyperLogLog(precision: 12)   // 4096 registers, ~1.625% std. error
        let trueCardinality = 50_000
        for index in 0..<trueCardinality {
            estimator.observe(hash: hasher.hash("value-\(index)"))
        }

        let estimate = Double(estimator.estimatedCardinality)
        let relativeError = abs(estimate - Double(trueCardinality)) / Double(trueCardinality)
        XCTAssertLessThan(
            relativeError, 3 * estimator.relativeErrorBound,
            "estimate \(estimate) is \(relativeError) off a true cardinality of \(trueCardinality)"
        )
    }

    func testSmallCardinalitiesUseLinearCountingAndStayAccurate() {
        // The raw estimator is badly biased below ~2.5m; this is the range where the
        // small-range correction has to take over, and it is the range a real dimension
        // (a dozen locales, five variants) actually lives in.
        for trueCardinality in [1, 5, 20, 100] {
            var estimator = HyperLogLog(precision: 10)
            for index in 0..<trueCardinality {
                estimator.observe(hash: hasher.hash("small-\(trueCardinality)-\(index)"))
            }
            let estimate = estimator.estimatedCardinality
            let tolerance = max(2, trueCardinality / 5)
            XCTAssertLessThanOrEqual(
                abs(estimate - trueCardinality), tolerance,
                "estimated \(estimate) for a true cardinality of \(trueCardinality)"
            )
        }
    }

    // MARK: Trap sites

    func testEmptyEstimatorReportsZeroInsteadOfTrapping() {
        // An all-zero register bank makes the harmonic sum equal `m`, and `log(m/m) == 0`.
        // Reached on the very first read of a freshly constructed estimator.
        let estimator = HyperLogLog(precision: 10)
        XCTAssertEqual(estimator.estimatedCardinality, 0)
        XCTAssertEqual(estimator.estimateInterval.lowerBound, 0)
        XCTAssertEqual(estimator.estimateInterval.upperBound, 0)
    }

    func testFullySaturatedRegistersDoNotTrap() {
        // The pathological opposite: every register at its maximum, so the harmonic sum
        // underflows towards zero and the raw estimate races towards infinity. `Int(raw)`
        // would trap; the saturating conversion must not.
        let estimator = HyperLogLog(precision: 10, registers: [UInt8](repeating: 255, count: 1024))
        let estimate = estimator.estimatedCardinality
        XCTAssertGreaterThanOrEqual(estimate, 0)
        XCTAssertGreaterThanOrEqual(estimator.estimateInterval.upperBound, estimator.estimateInterval.lowerBound)
    }

    func testAllZeroHashIsHandled() {
        // hash == 0 puts the value in register 0 with an all-zero remainder, which makes
        // `leadingZeroBitCount` return 64 — above every rank the register can hold.
        var estimator = HyperLogLog(precision: 10)
        estimator.observe(hash: 0)
        XCTAssertEqual(estimator.estimatedCardinality, 1)
        XCTAssertEqual(estimator.validRegisterCeiling, 55)
    }

    func testAllOnesHashIsHandled() {
        var estimator = HyperLogLog(precision: 10)
        estimator.observe(hash: .max)
        XCTAssertEqual(estimator.estimatedCardinality, 1)
    }

    // MARK: Configuration

    func testPrecisionIsClampedIntoTheSupportedRange() {
        XCTAssertEqual(HyperLogLog(precision: 0).precision, HyperLogLog.precisionRange.lowerBound)
        XCTAssertEqual(HyperLogLog(precision: 99).precision, HyperLogLog.precisionRange.upperBound)
        XCTAssertEqual(HyperLogLog(precision: 10).registerCount, 1024)
    }

    func testMismatchedRegisterArrayIsNormalised() {
        XCTAssertEqual(HyperLogLog(precision: 10, registers: []).registerCount, 1024)
        XCTAssertEqual(
            HyperLogLog(precision: 10, registers: [UInt8](repeating: 3, count: 99_999)).registerCount,
            1024
        )
    }

    func testIntervalBracketsThePointEstimate() {
        var estimator = HyperLogLog(precision: 10)
        for index in 0..<2_000 { estimator.observe(hash: hasher.hash("i\(index)")) }

        let point = estimator.estimatedCardinality
        let interval = estimator.estimateInterval
        XCTAssertLessThanOrEqual(interval.lowerBound, point)
        XCTAssertGreaterThanOrEqual(interval.upperBound, point)
        XCTAssertGreaterThan(estimator.relativeErrorBound, 0)
    }

    func testEstimatorIsDeterministicAcrossSeparateInstances() {
        // Two independently constructed estimators over the same values. Not "call the
        // same estimator twice", which would hold even against a random hash.
        func build() -> HyperLogLog {
            var estimator = HyperLogLog(precision: 10)
            for index in 0..<5_000 { estimator.observe(hash: hasher.hash("d\(index)")) }
            return estimator
        }
        XCTAssertEqual(build().registers, build().registers)
    }
}
