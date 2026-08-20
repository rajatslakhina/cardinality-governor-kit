import XCTest
@testable import CardinalityGovernor

final class GovernorServiceTests: XCTestCase {

    private let locale = DimensionKey("locale")

    private func schema() -> DimensionSchema {
        var schema = DimensionSchema()
        schema.declare(DimensionKey("flow"), .closed(["home", "search"]))
        schema.declare(locale, .open(floor: 4))
        return schema
    }

    /// Real concurrent writers.
    ///
    /// A "concurrency test" that awaits a single task proves nothing about isolation; this
    /// one runs eight tasks that all mutate the governor, and asserts that not one of the
    /// 8,000 observations was lost or double-counted. Without actor isolation the tally
    /// races and this fails.
    func testConcurrentWritersLoseNoObservations() async {
        let service = GovernorService(
            schema: schema(),
            configuration: .init(distinctValueBudget: 8, jointSeriesBudget: 32)
        )
        let writers = 8
        let perWriter = 1_000
        // Hoisted out of the task closure: capturing `self` would pull the non-Sendable
        // `XCTestCase` across an isolation boundary, and Swift 6 rejects it — correctly.
        let localeKey = locale
        let flowKey = DimensionKey("flow")

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    var generator = SplitMix64(seed: UInt64(writer) &+ 1)
                    for _ in 0..<perWriter {
                        var labels = LabelSet()
                        labels.set(flowKey, generator.next() % 2 == 0 ? "home" : "search")
                        labels.set(localeKey, "loc-\(generator.nextIndex(upperBound: 200))")
                        await service.admit(labels)
                    }
                }
            }
        }

        let snapshot = await service.snapshot()
        let conservation = await service.conservation()
        XCTAssertEqual(snapshot.totalAdmitted, writers * perWriter)
        XCTAssertEqual(conservation, .conserved(total: writers * perWriter))
        XCTAssertLessThanOrEqual(snapshot.trackedSeries, 32)
    }

    /// Window rolls interleaved with writes. Reallocation replaces every survivor set
    /// mid-stream, so this is where a torn read would show up as a lost tally.
    func testConcurrentWritesInterleavedWithWindowRollsStayConserved() async {
        let service = GovernorService(
            schema: schema(),
            configuration: .init(distinctValueBudget: 6, jointSeriesBudget: 16)
        )

        let localeKey = locale

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<6 {
                group.addTask {
                    var generator = SplitMix64(seed: UInt64(writer) &+ 100)
                    for _ in 0..<500 {
                        await service.admit(LabelSet([localeKey: "v-\(generator.nextIndex(upperBound: 400))"]))
                    }
                }
            }
            group.addTask {
                for _ in 0..<20 {
                    await service.rollWindow()
                    await Task.yield()
                }
            }
        }

        let conservation = await service.conservation()
        XCTAssertEqual(conservation, .conserved(total: 3_000))
    }

    func testBatchAdmissionMatchesIndividualAdmission() async {
        let batched = GovernorService(schema: schema(), configuration: .init(distinctValueBudget: 8))
        let individual = GovernorService(schema: schema(), configuration: .init(distinctValueBudget: 8))

        var generator = SplitMix64(seed: 31)
        let events = (0..<2_000).map { _ in
            LabelSet([DimensionKey("flow"): "home", locale: "l\(generator.nextIndex(upperBound: 50))"])
        }

        let batchedResults = await batched.admit(batch: events)
        var individualResults: [AdmissionResult] = []
        for event in events {
            individualResults.append(await individual.admit(event))
        }

        // The batch path is a throughput optimisation, not a different policy. If these
        // diverge, one of them is wrong.
        XCTAssertEqual(batchedResults.map(\.labels), individualResults.map(\.labels))
        let batchedSeries = await batched.snapshot().trackedSeries
        let individualSeries = await individual.snapshot().trackedSeries
        XCTAssertEqual(batchedSeries, individualSeries)
    }

    func testSnapshotIsAValueAndDoesNotAliasLiveState() async {
        let service = GovernorService(schema: schema())
        await service.admit(LabelSet([locale: "en_US"]))
        let early = await service.snapshot()

        for index in 0..<100 { await service.admit(LabelSet([locale: "l\(index)"])) }

        // `GovernorSnapshot` is a struct of value types; the earlier copy must still read
        // 1, not 101.
        let latest = await service.snapshot()
        XCTAssertEqual(early.totalAdmitted, 1)
        XCTAssertEqual(latest.totalAdmitted, 101)
    }
}
