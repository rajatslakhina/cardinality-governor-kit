import Foundation

/// The shape iOS 27 MetricKit's `StateReporting` hands you: an app state, tagged, so that
/// launch time, hangs and memory break down by user flow, configuration or experiment
/// instead of a blended app-wide average.
///
/// ## Why this module does not `import MetricKit`
///
/// It would cost more than it buys. MetricKit is unavailable on Linux, which is where the
/// governor's CI runs; it is unavailable in a unit test that wants to drive ten thousand
/// synthetic observations through the policy; and it would pin the package to an OS
/// version for the sake of a type that is, in the end, a bag of strings. The governor
/// governs *label sets*. MetricKit is one producer of label sets. Keeping the seam here —
/// a plain struct and a mapping function — is what makes the whole system testable
/// without a device, and it costs one adapter.
///
/// A production integration converts an `MXMetricPayload` / `MetricManager` state tag into
/// a `StateDescriptor` at the boundary and never mentions MetricKit again.
public struct StateDescriptor: Sendable, Equatable {
    /// The user-facing flow the app is in. Closed by construction — flows are enum cases
    /// in your code, not runtime strings.
    public var flow: String
    /// Experiment or rollout variant. Open: variant identifiers are minted server-side.
    public var variant: String
    /// Device performance tier. Closed and small.
    public var deviceTier: String
    /// Locale identifier. Open, and the classic explosion: ~700 possible values, a long
    /// tail of them with a handful of users each.
    public var locale: String
    /// Anything else the call site wants to attach. **Every key here must be declared in
    /// the schema** or the governor drops it — which is the point. An undeclared extra is
    /// how a search query ends up as a label.
    public var extras: [String: String]

    public init(
        flow: String,
        variant: String,
        deviceTier: String,
        locale: String,
        extras: [String: String] = [:]
    ) {
        self.flow = flow
        self.variant = variant
        self.deviceTier = deviceTier
        self.locale = locale
        self.extras = extras
    }
}

public enum StateReportingAdapter {

    public static let flow = DimensionKey("flow")
    public static let variant = DimensionKey("variant")
    public static let deviceTier = DimensionKey("deviceTier")
    public static let locale = DimensionKey("locale")

    public static func labels(for state: StateDescriptor) -> LabelSet {
        var labels = LabelSet()
        labels.set(flow, state.flow)
        labels.set(variant, state.variant)
        labels.set(deviceTier, state.deviceTier)
        labels.set(locale, state.locale)
        for key in state.extras.keys.sorted() {
            if let value = state.extras[key] {
                labels.set(DimensionKey(key), value)
            }
        }
        return labels
    }

    /// A starting schema for the four standard state dimensions.
    ///
    /// `flow` and `deviceTier` are closed because their value sets live in your source
    /// code. `variant` and `locale` are open because theirs do not — and each therefore
    /// has to state a floor, which is the argument this API is designed to force.
    public static func schema(
        flows: Set<String>,
        deviceTiers: Set<String>,
        variantFloor: Int = 8,
        localeFloor: Int = 12
    ) -> DimensionSchema {
        var schema = DimensionSchema()
        schema.declare(flow, .closed(flows))
        schema.declare(deviceTier, .closed(deviceTiers))
        schema.declare(variant, .open(floor: variantFloor))
        schema.declare(locale, .open(floor: localeFloor))
        return schema
    }
}
