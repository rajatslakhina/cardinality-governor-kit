#if canImport(SwiftUI)
import SwiftUI
import Observation
import CardinalityGovernor

// MARK: - Scenario

/// A named label-space configuration plus a deterministic event source.
///
/// Scenarios are *supplied by the host app*, not baked in here. The library ships the
/// dashboard and the policy; what a realistic label space looks like is domain knowledge
/// that belongs to whoever is instrumenting the app.
public struct Scenario: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// One sentence a reviewer can read to know what they are looking at.
    public let explanation: String
    public let schema: DimensionSchema
    public let configuration: CardinalityGovernor.Configuration
    /// Deterministic event source. Takes the generator by `inout` so a scenario replays
    /// identically from the same seed.
    public let makeEvent: @Sendable (inout SplitMix64) -> LabelSet

    public init(
        id: String,
        title: String,
        explanation: String,
        schema: DimensionSchema,
        configuration: CardinalityGovernor.Configuration,
        makeEvent: @escaping @Sendable (inout SplitMix64) -> LabelSet
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.schema = schema
        self.configuration = configuration
        self.makeEvent = makeEvent
    }
}

// MARK: - Model

@MainActor
@Observable
public final class GovernorDashboardModel {

    public let scenarios: [Scenario]
    public private(set) var selectedID: String
    public private(set) var snapshot: GovernorSnapshot
    public private(set) var lastWindow: WindowReport?

    private var governor: CardinalityGovernor
    private var random: SplitMix64
    private let seed: UInt64

    /// Events per tap of "Observe". Large enough that the heavy-hitter sketch has
    /// something to say, small enough to stay instant on a phone.
    public static let burstSize = 400

    public var selected: Scenario? {
        scenarios.first { $0.id == selectedID } ?? scenarios.first
    }

    /// Fails soft on an empty scenario list rather than trapping: a host app that ships a
    /// misconfigured catalog should see an empty dashboard, not a crash on launch.
    public init(scenarios: [Scenario], seed: UInt64 = 0x5EED_C0DE_1234_5678) {
        self.scenarios = scenarios
        self.seed = seed
        self.random = SplitMix64(seed: seed)

        let first = scenarios.first
        self.selectedID = first?.id ?? ""

        // Built into a local and assigned from there, rather than `self.snapshot =
        // governor.snapshot`. Under `@Observable` every stored property becomes a computed
        // accessor over macro-generated storage, so reading `governor` back through `self`
        // is a property *access* — illegal until every stored property is initialised.
        // Linux cannot catch this: `canImport(SwiftUI)` is false there and this whole file
        // compiles to an empty module. The macOS CI job caught it on the first run.
        let initialGovernor = CardinalityGovernor(
            schema: first?.schema ?? DimensionSchema(),
            configuration: first?.configuration ?? .default
        )
        self.governor = initialGovernor
        self.lastWindow = nil
        self.snapshot = initialGovernor.snapshot

        // Warm up so the dashboard is populated the instant it appears. An empty
        // dashboard on launch reads as a broken demo, and the interesting behaviour —
        // survivors settling, the tail collapsing — needs a few windows to show up.
        warmUp()
    }

    public func select(_ id: String) {
        guard id != selectedID, scenarios.contains(where: { $0.id == id }) else { return }
        selectedID = id
        reset()
    }

    public func reset() {
        random = SplitMix64(seed: seed)
        governor = CardinalityGovernor(
            schema: selected?.schema ?? DimensionSchema(),
            configuration: selected?.configuration ?? .default
        )
        lastWindow = nil
        snapshot = governor.snapshot
        warmUp()
    }

    public func observeBurst() {
        observe(count: Self.burstSize)
        snapshot = governor.snapshot
    }

    public func rollWindow() {
        lastWindow = governor.rollWindow()
        snapshot = governor.snapshot
    }

    private func warmUp() {
        guard selected != nil else { return }
        for _ in 0..<3 {
            observe(count: Self.burstSize)
            lastWindow = governor.rollWindow()
        }
        observe(count: Self.burstSize)
        snapshot = governor.snapshot
    }

    private func observe(count: Int) {
        guard let scenario = selected, count > 0 else { return }
        for _ in 0..<count {
            governor.admit(scenario.makeEvent(&random))
        }
    }
}

// MARK: - View

/// `@MainActor` on the whole view, not just `body`.
///
/// `GovernorDashboardModel` is main-actor isolated, and `init` constructs one. Under Swift
/// 6 the protocol only carries isolation onto `body`, so an un-annotated `init` is a
/// concurrency error rather than a style question.
@MainActor
public struct GovernorDashboardView: View {

    @State private var model: GovernorDashboardModel

    public init(scenarios: [Scenario]) {
        _model = State(initialValue: GovernorDashboardModel(scenarios: scenarios))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if model.scenarios.isEmpty {
                    ContentUnavailableView(
                        "No scenarios",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("The host app supplied an empty scenario catalog.")
                    )
                } else {
                    dashboard
                }
            }
            .navigationTitle("Cardinality Governor")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var dashboard: some View {
        List {
            scenarioSection
            ledgerSection
            jointSection
            keysSection
            if let window = model.lastWindow {
                windowSection(window)
            }
        }
        .safeAreaInset(edge: .bottom) { controls }
    }

    // MARK: Sections

    private var scenarioSection: some View {
        Section {
            Picker("Scenario", selection: Binding(
                get: { model.selectedID },
                set: { model.select($0) }
            )) {
                ForEach(model.scenarios) { scenario in
                    Text(scenario.title).tag(scenario.id)
                }
            }
            .pickerStyle(.menu)

            if let explanation = model.selected?.explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Scenario")
        }
    }

    private var ledgerSection: some View {
        Section {
            let finding = model.snapshot.conservation
            HStack {
                Image(systemName: finding.isConserved ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(finding.isConserved ? Color.green : Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.isConserved ? "Conserved" : "VIOLATED")
                        .font(.headline)
                    Text(finding.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Observations admitted", value: model.snapshot.totalAdmitted.formatted())
            LabeledContent("Observations dropped", value: "0")
        } header: {
            Text("Conservation ledger")
        } footer: {
            Text("Collapsing a label changes its attribution, never its count. Every number above is recomputed from the live tallies, not asserted.")
        }
    }

    private var jointSection: some View {
        Section {
            let snapshot = model.snapshot
            LabeledContent("Series tracked") {
                Text("\(snapshot.trackedSeries) / \(snapshot.jointSeriesBudget)")
                    .monospacedDigit()
                    .foregroundStyle(snapshot.trackedSeries >= snapshot.jointSeriesBudget ? Color.orange : Color.primary)
            }
            budgetBar(
                value: Double(snapshot.trackedSeries),
                total: Double(max(1, snapshot.jointSeriesBudget))
            )
            LabeledContent("Joint space upper bound", value: snapshot.jointSpaceUpperBound.formatted())
            LabeledContent("Collapsed to __overflow__", value: snapshot.jointOverflowObservations.formatted())
            LabeledContent("Fingerprints interned", value: snapshot.fingerprintCatalog.count.formatted())
            if snapshot.fingerprintCatalog.collisionsResolved > 0 {
                LabeledContent("Fingerprint collisions resolved",
                               value: snapshot.fingerprintCatalog.collisionsResolved.formatted())
            }
            if !snapshot.undeclaredKeyDrops.isEmpty {
                ForEach(snapshot.undeclaredKeyDrops.keys.sorted(), id: \.self) { key in
                    LabeledContent("Undeclared key dropped: \(key.rawValue)",
                                   value: (snapshot.undeclaredKeyDrops[key] ?? 0).formatted())
                    .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Joint series budget")
        } footer: {
            Text("Per-key budgets bound each dimension on its own. The joint space is their product — which is the number the backend bills, and why it needs a separate cap.")
        }
    }

    private var keysSection: some View {
        Section {
            if model.snapshot.keys.isEmpty {
                Text("No dimensions declared.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.keys, id: \.key) { stats in
                    keyRow(stats)
                }
            }
        } header: {
            Text("Dimensions")
        }
    }

    private func keyRow(_ stats: KeyStatistics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stats.key.rawValue)
                    .font(.headline)
                Text(stats.isOpen ? "open" : "closed")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stats.isOpen ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
                if let rate = stats.collapseRate {
                    Text(rate.formatted(.percent.precision(.fractionLength(0))) + " collapsed")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(rate > 0 ? Color.orange : Color.secondary)
                } else {
                    Text("no samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if stats.isOpen {
                budgetBar(
                    value: Double(stats.survivors),
                    total: Double(max(1, stats.allocation))
                )
                HStack(spacing: 12) {
                    metric("slots", "\(stats.survivors)/\(stats.allocation)")
                    metric(
                        "distinct (est.)",
                        "\(stats.estimatedDistinctValues) ±\(max(0, stats.estimatedDistinctInterval.upperBound - stats.estimatedDistinctValues))"
                    )
                    metric("→ __other__", stats.collapsedToOther.formatted())
                }
            } else {
                HStack(spacing: 12) {
                    metric("values", stats.allocation.formatted())
                    metric("→ __invalid__", stats.collapsedToInvalid.formatted())
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func windowSection(_ window: WindowReport) -> some View {
        Section {
            LabeledContent("Window", value: "#\(window.windowIndex)")
            LabeledContent("Observations in window", value: window.observationsInWindow.formatted())
            if window.allocation.floorsWereInfeasible {
                Label("Declared floors exceed the budget", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            let keys = window.reconciliations.keys.sorted()
            if keys.isEmpty {
                Text("No open dimensions to reconcile.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(keys, id: \.self) { key in
                    if let report = window.reconciliations[key] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.rawValue).font(.subheadline.weight(.semibold))
                            Text("promoted \(report.promoted.count) · demoted \(report.demoted.count) · expired \(report.expired.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text("refused for insufficient separation: \(report.refusedForInsufficientSeparation.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Last window reconciliation")
        } footer: {
            Text("A challenger only takes a slot when its lower bound beats the incumbent's upper bound. Everything counted as \u{201C}refused\u{201D} is a series that would have flapped.")
        }
    }

    // MARK: Pieces

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.caption.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// `ProgressView` traps on a non-finite or negative fraction, and `total` here is
    /// derived from a budget that a host app could configure to zero — hence the clamps.
    private func budgetBar(value: Double, total: Double) -> some View {
        let safeTotal = total.isFinite && total > 0 ? total : 1
        let safeValue = value.isFinite ? min(max(value, 0), safeTotal) : 0
        return ProgressView(value: safeValue, total: safeTotal)
            .tint(safeValue >= safeTotal ? Color.orange : Color.accentColor)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.observeBurst()
            } label: {
                Label("Observe \(GovernorDashboardModel.burstSize)", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                model.rollWindow()
            } label: {
                Label("Roll window", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                model.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
#endif
