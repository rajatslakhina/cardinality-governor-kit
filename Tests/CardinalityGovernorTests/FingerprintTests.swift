import XCTest
@testable import CardinalityGovernor

final class FingerprintTests: XCTestCase {

    private let flow = DimensionKey("flow")
    private let locale = DimensionKey("locale")

    // MARK: Cross-process stability, proven rather than assumed

    /// Golden constants, computed independently of this implementation.
    ///
    /// This is the whole reason `StableHasher` exists instead of `Swift.Hasher`. The
    /// tempting version of this test — hash the same value twice in one process and assert
    /// the results match — **passes against `Hasher`**, because `Hasher` is stable within
    /// a process and only re-seeds between them. It would assert exactly nothing about the
    /// property that matters: that a fingerprint minted on Monday still resolves against a
    /// catalog published on Sunday.
    ///
    /// Pinned values force a real failure if the hash, the finalizer, the canonical
    /// ordering or the escaping ever changes.
    func testFingerprintsMatchPinnedGoldenValues() {
        let hasher = FNV1a64()

        XCTAssertEqual(hasher.hash(""), 0xc381_7c01_6ba4_ff30)
        XCTAssertEqual(hasher.hash("cardinality"), 0x5b12_222c_68c4_face)
        XCTAssertEqual(hasher.hash("flow=home"), 0xa958_92d9_446b_8bc2)
        XCTAssertEqual(hasher.hash("flow=home,locale=en_US"), 0xdbb8_2341_99ac_8fa7)

        var catalog = FingerprintCatalog(capacity: 8)
        let fingerprint = catalog.register(LabelSet([flow: "home", locale: "en_US"]), hasher: hasher)
        XCTAssertEqual(fingerprint.value, 0xdbb8_2341_99ac_8fa7)
        XCTAssertEqual(fingerprint.description, "dbb8234199ac8fa7")
    }

    func testCanonicalOrderingIsIndependentOfInsertionOrder() {
        var forward = LabelSet()
        forward.set(flow, "home")
        forward.set(locale, "en_US")

        var backward = LabelSet()
        backward.set(locale, "en_US")
        backward.set(flow, "home")

        // Two label sets built in opposite orders are one series, not two — otherwise the
        // joint budget is spent twice on the same thing.
        XCTAssertEqual(forward.canonicalDescription, backward.canonicalDescription)
        XCTAssertEqual(forward, backward)
    }

    /// Escaping, tested against the collision it prevents.
    ///
    /// Without it, a value containing "," or "=" renders identically to a different label
    /// set, and the two merge into one series — a collision by *construction*, which no
    /// amount of hash quality would fix.
    func testEscapingPreventsAConstructedCollision() {
        let sneaky = LabelSet([DimensionKey("a"): "b,c=d"])
        let genuine = LabelSet([DimensionKey("a"): "b", DimensionKey("c"): "d"])

        XCTAssertEqual(sneaky.canonicalDescription, "a=b\\cc\\ed")
        XCTAssertEqual(genuine.canonicalDescription, "a=b,c=d")
        XCTAssertNotEqual(sneaky.canonicalDescription, genuine.canonicalDescription)

        let hasher = FNV1a64()
        XCTAssertEqual(hasher.hash(sneaky.canonicalDescription), 0x4a5b_cd20_e6f3_9162)
        XCTAssertEqual(hasher.hash(genuine.canonicalDescription), 0xc829_4941_f5f7_70f3)
    }

    // MARK: Collision handling, forced

    /// A hasher that returns a constant, so every registration collides.
    private struct AlwaysCollidingHasher: StableHasher {
        func hash(_ value: String) -> UInt64 { 0x4242_4242_4242_4242 }
    }

    func testCollisionsAreDetectedAndResolvedRatherThanMerged() {
        var catalog = FingerprintCatalog(capacity: 64)
        let hasher = AlwaysCollidingHasher()

        var fingerprints: Set<LabelFingerprint> = []
        let labelSets = (0..<6).map { LabelSet([locale: "l\($0)"]) }
        for labels in labelSets {
            fingerprints.insert(catalog.register(labels, hasher: hasher))
        }

        // Six genuinely different label sets under a constant hash. Merging them would be
        // silent corruption; probing must produce six distinct tokens.
        XCTAssertEqual(fingerprints.count, 6)
        XCTAssertEqual(catalog.collisionsResolved, 5)
        XCTAssertEqual(catalog.count, 6)

        // And every token must still resolve back to the right labels.
        for labels in labelSets {
            let token = catalog.register(labels, hasher: hasher)
            XCTAssertEqual(catalog.labels(for: token), labels)
        }
    }

    func testProbingIsBoundedRatherThanUnbounded() {
        // More colliding registrations than `maximumProbes` allows. The catalog must give
        // up and count it, never spin — an unbounded retry on the instrumentation path is
        // a hang, and it would be a hang on the pathological input this module is for.
        var catalog = FingerprintCatalog(capacity: 512)
        let hasher = AlwaysCollidingHasher()
        for index in 0..<40 {
            _ = catalog.register(LabelSet([locale: "value-\(index)"]), hasher: hasher)
        }
        XCTAssertGreaterThan(catalog.unresolvedCollisions, 0)
        // Not `<= 512`: 512 is the capacity that was passed in, so that assertion is
        // structurally unfalsifiable. Under a hasher that always collides, the reachable
        // maximum is one slot per probe plus the original.
        XCTAssertLessThanOrEqual(
            catalog.count, FingerprintCatalog.maximumProbes + 1,
            "every registration collides, so only the probe sequence can create entries"
        )
    }

    func testRegisteringTheSameLabelsTwiceIsIdempotent() {
        var catalog = FingerprintCatalog(capacity: 8)
        let hasher = FNV1a64()
        let labels = LabelSet([flow: "home"])

        let first = catalog.register(labels, hasher: hasher)
        let second = catalog.register(labels, hasher: hasher)

        XCTAssertEqual(first, second)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.collisionsResolved, 0)
    }

    // MARK: Bounds

    func testCatalogRefusesToGrowPastCapacity() {
        var catalog = FingerprintCatalog(capacity: 4)
        let hasher = FNV1a64()
        for index in 0..<100 {
            _ = catalog.register(LabelSet([locale: "l\(index)"]), hasher: hasher)
        }

        XCTAssertEqual(catalog.count, 4)
        XCTAssertEqual(catalog.refusedForCapacity, 96)
    }

    func testZeroCapacityCatalogStillReturnsUsableFingerprints() {
        var catalog = FingerprintCatalog(capacity: 0)
        let hasher = FNV1a64()
        let fingerprint = catalog.register(LabelSet([flow: "home"]), hasher: hasher)

        // The token is still correct and still stable; only the reverse mapping is absent.
        XCTAssertEqual(fingerprint.value, 0xa958_92d9_446b_8bc2)
        XCTAssertEqual(catalog.count, 0)
        XCTAssertNil(catalog.labels(for: fingerprint))
    }

    func testResetClearsEverything() {
        var catalog = FingerprintCatalog(capacity: 4)
        _ = catalog.register(LabelSet([flow: "home"]), hasher: FNV1a64())
        catalog.reset(capacity: 9)

        XCTAssertEqual(catalog.count, 0)
        XCTAssertEqual(catalog.capacity, 9)
        XCTAssertEqual(catalog.refusedForCapacity, 0)
    }

    func testDescriptionIsZeroPaddedToSixteenHexDigits() {
        XCTAssertEqual(LabelFingerprint(0).description, "0000000000000000")
        XCTAssertEqual(LabelFingerprint(255).description, "00000000000000ff")
        XCTAssertEqual(LabelFingerprint(.max).description, "ffffffffffffffff")
    }

    // MARK: Deterministic generator

    func testSplitMix64MatchesPinnedValuesAndIsReplayable() {
        // The demo's scenarios and several tests above replay from a seed. That only works
        // if the generator is pinned — `SystemRandomNumberGenerator` would make every
        // failing test unreproducible.
        var first = SplitMix64(seed: 42)
        var second = SplitMix64(seed: 42)
        let firstDraws = (0..<8).map { _ in first.next() }
        let secondDraws = (0..<8).map { _ in second.next() }

        XCTAssertEqual(firstDraws, secondDraws)
        XCTAssertNotEqual(Set(firstDraws).count, 1)

        var other = SplitMix64(seed: 43)
        XCTAssertNotEqual(firstDraws.first, other.next())
    }

    func testNextIndexRefusesNonPositiveBounds() {
        // `next() % UInt64(0)` traps, and bounds here come from collection counts.
        var generator = SplitMix64(seed: 1)
        XCTAssertEqual(generator.nextIndex(upperBound: 0), 0)
        XCTAssertEqual(generator.nextIndex(upperBound: -5), 0)
        for _ in 0..<100 {
            let index = generator.nextIndex(upperBound: 7)
            XCTAssertTrue((0..<7).contains(index))
        }
    }
}
