import Foundation

/// Checks the module's central invariant: **collapsing a label must never drop an
/// observation.**
///
/// ## Why this is the invariant that matters
///
/// Every commercial answer to cardinality is a variant of "stop accepting the series."
/// Drop the sample, drop the tag, refuse the write. All of them are biased in the same
/// direction and it is the worst possible direction: the samples you drop are exactly the
/// ones carrying rare label values, and rare label values are disproportionately the
/// unusual sessions — the cold launches, the 2%-of-users locale, the device tier that
/// only exists in one market. So the metric gets *better looking* as it gets less true.
/// The p99 improves because you stopped measuring the tail.
///
/// This module collapses **attribution** instead. `locale=fj_FJ` becomes
/// `locale=__other__` and the observation is still counted. You lose the ability to ask
/// "how slow was Fiji"; you do not lose Fiji from the average. The count is conserved, and
/// conservation is mechanically checkable — which is why it is a type in the public API
/// rather than a sentence in a README.
public enum ConservationAuditor {

    public enum Finding: Sendable, Equatable, CustomStringConvertible {
        /// Tallies account for every admitted observation.
        case conserved(total: Int)
        /// Observations were admitted but never landed in a series — the bias described
        /// above, now detected instead of shipped.
        case leaked(admitted: Int, tallied: Int)
        /// More tallied than admitted — double counting, which inflates every rate.
        case inflated(admitted: Int, tallied: Int)

        /// Observations admitted but never tallied into any series. Zero unless the
        /// invariant is broken; negative is impossible, because double-counting is
        /// `.inflated` rather than a negative shortfall.
        public var shortfall: Int {
            switch self {
            case .conserved: return 0
            case .leaked(let admitted, let tallied): return admitted.saturatingSubtracting(tallied)
            case .inflated: return 0
            }
        }

        public var isConserved: Bool {
            if case .conserved = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .conserved(let total):
                return "conserved: \(total) observations tallied"
            case .leaked(let admitted, let tallied):
                return "LEAKED: \(admitted) admitted but only \(tallied) tallied (\(admitted - tallied) lost)"
            case .inflated(let admitted, let tallied):
                return "INFLATED: \(admitted) admitted but \(tallied) tallied (\(tallied - admitted) fabricated)"
            }
        }
    }

    public static func audit(admitted: Int, seriesCounts: [LabelSet: Int]) -> Finding {
        let tallied = seriesCounts.values.reduce(0) { $0.saturatingAdding($1) }
        if tallied == admitted { return .conserved(total: tallied) }
        return tallied < admitted
            ? .leaked(admitted: admitted, tallied: tallied)
            : .inflated(admitted: admitted, tallied: tallied)
    }
}
