import Foundation

/// The name of a telemetry dimension — `flow`, `variant`, `deviceTier`.
public struct DimensionKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: DimensionKey, rhs: DimensionKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Values the governor writes itself. A caller that supplies one of these is treated as
/// having supplied an invalid value — otherwise instrumentation code could forge a
/// collapse and make the conservation ledger unauditable.
public enum ReservedValue {
    /// A value that lost its identity to the per-key distinct-value budget.
    public static let other = "__other__"
    /// A value outside a closed domain, or a forged reserved value.
    public static let invalid = "__invalid__"
    /// A declared key the caller did not supply.
    public static let unset = "__unset__"
    /// The entire label set collapsed because the *joint* series budget was exhausted.
    public static let overflow = "__overflow__"

    public static let all: Set<String> = [other, invalid, unset, overflow]

    @inline(__always)
    public static func isReserved(_ value: String) -> Bool {
        all.contains(value)
    }
}

/// How many distinct values a dimension is allowed to take, and who decides.
public enum DimensionDomain: Sendable, Equatable {
    /// A finite set known at build time — an enum's cases, a fixed list of flows.
    /// Never governed and never collapsed to `__other__`, because its cardinality is a
    /// property of the source code rather than of user behaviour. A value outside the set
    /// is a bug, and is collapsed to `__invalid__` and counted.
    case closed(Set<String>)

    /// Values produced at runtime — locale, experiment id, remote config revision.
    /// The associated value is the *floor*: the number of distinct values this key is
    /// guaranteed regardless of how the global budget is apportioned.
    ///
    /// The floor is not optional, and that is the point. There is no way to declare
    /// "this dimension takes runtime values" without also stating what it costs, so the
    /// dangerous case cannot be written accidentally — it has to be argued for in review.
    case open(floor: Int)
}

/// The declared shape of a metric's label space.
///
/// A key not in the schema is not "unbudgeted", it is *undeclared* — and an undeclared key
/// carrying runtime values is the failure this whole module exists to prevent, so the
/// governor drops undeclared keys and counts them rather than admitting them.
public struct DimensionSchema: Sendable, Equatable {
    public private(set) var domains: [DimensionKey: DimensionDomain]

    /// Keys rejected at declaration time, with the reason, so misuse is inspectable
    /// instead of silent.
    public private(set) var declarationWarnings: [String]

    public init() {
        self.domains = [:]
        self.declarationWarnings = []
    }

    public init(_ domains: [DimensionKey: DimensionDomain]) {
        self.domains = [:]
        self.declarationWarnings = []
        // Sorted so warnings are emitted in a deterministic order regardless of the
        // dictionary's iteration order.
        for key in domains.keys.sorted() {
            if let domain = domains[key] {
                declare(key, domain)
            }
        }
    }

    /// Floors are clamped rather than rejected: a schema that silently loses a key would
    /// be worse than one that keeps it with a usable floor, and the clamp is recorded.
    public static let floorRange: ClosedRange<Int> = 1...4096

    public mutating func declare(_ key: DimensionKey, _ domain: DimensionDomain) {
        switch domain {
        case .closed(let allowed):
            let forged = allowed.filter { ReservedValue.isReserved($0) }
            let cleaned = allowed.subtracting(ReservedValue.all)
            if !forged.isEmpty {
                declarationWarnings.append(
                    "\(key): dropped reserved value(s) \(forged.sorted().joined(separator: ", ")) from closed domain"
                )
            }
            guard !cleaned.isEmpty else {
                declarationWarnings.append("\(key): closed domain is empty after cleaning; key not declared")
                return
            }
            domains[key] = .closed(cleaned)

        case .open(let floor):
            let clamped = floor.clamped(to: Self.floorRange)
            if clamped != floor {
                declarationWarnings.append("\(key): floor \(floor) clamped to \(clamped)")
            }
            domains[key] = .open(floor: clamped)
        }
    }

    public var declaredKeys: [DimensionKey] { domains.keys.sorted() }

    public var openKeys: [DimensionKey] {
        domains.keys.sorted().filter {
            if case .open = domains[$0] { return true }
            return false
        }
    }

    public func floor(for key: DimensionKey) -> Int {
        if case .open(let floor) = domains[key] { return floor }
        return 0
    }

    /// The number of distinct label sets this schema can produce, given a per-open-key
    /// allocation — i.e. the size of the *joint* space, not the sum of the marginals.
    ///
    /// This is the number that surprises teams. Four keys budgeted at 8 distinct values
    /// each is 32 values and 8⁴ = 4096 series, and the second number is the one the
    /// backend bills. Saturating throughout: the product overflows easily and an
    /// overflowing capacity estimate must not be the thing that crashes the app.
    public func jointSpaceUpperBound(openAllocation: [DimensionKey: Int]) -> Int {
        var product = 1
        for key in declaredKeys {
            switch domains[key] {
            case .closed(let allowed):
                // +1 for `__invalid__`.
                product = product.saturatingMultiplied(by: allowed.count.saturatingAdding(1))
            case .open:
                // +2 for `__other__` and `__unset__`.
                let allocated = openAllocation[key] ?? 0
                product = product.saturatingMultiplied(by: allocated.saturatingAdding(2))
            case .none:
                continue
            }
        }
        return product
    }
}

/// A set of dimension key/value pairs. Hashable so it can be a tally key; canonicalised
/// (sorted by key) before hashing so two label sets built in different orders are one
/// series rather than two.
public struct LabelSet: Hashable, Sendable {
    public private(set) var pairs: [DimensionKey: String]

    public init(_ pairs: [DimensionKey: String] = [:]) {
        self.pairs = pairs
    }

    public subscript(key: DimensionKey) -> String? {
        get { pairs[key] }
        set { pairs[key] = newValue }
    }

    public mutating func set(_ key: DimensionKey, _ value: String) {
        pairs[key] = value
    }

    public var isEmpty: Bool { pairs.isEmpty }
    public var count: Int { pairs.count }

    /// Key-sorted pairs. The single source of ordering for fingerprinting and display.
    public var canonical: [(key: DimensionKey, value: String)] {
        pairs.keys.sorted().compactMap { key in
            guard let value = pairs[key] else { return nil }
            return (key: key, value: value)
        }
    }

    /// A stable, human-readable rendering — also the exact byte sequence that is hashed
    /// into a `LabelFingerprint`.
    ///
    /// Keys and values are escaped so that `{a=b, c=d}` and `{a=b\, c=d}` cannot produce
    /// the same string. Without escaping, a value containing "," or "=" would let one
    /// label set impersonate another and the fingerprint would collide *by construction*
    /// rather than by birthday chance.
    public var canonicalDescription: String {
        canonical
            .map { "\(Self.escape($0.key.rawValue))=\(Self.escape($0.value))" }
            .joined(separator: ",")
    }

    static func escape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "\\": out += "\\\\"
            case ",": out += "\\c"
            case "=": out += "\\e"
            default: out.append(character)
            }
        }
        return out
    }
}
