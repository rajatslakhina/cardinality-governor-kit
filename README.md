# CardinalityGovernor

**Four dimensions budgeted at eight values each is thirty-two values — and four thousand and ninety-six series. Teams reason about the first number and pay for the second.**

iOS 27 rebuilt MetricKit (see Apple's MetricKit documentation for the current `MetricManager` and `StateReporting` surface). `MetricManager` replaces the delegate-based `MXMetricManager`, reports arrive as `Codable` async sequences, and — the part that changes your bill — `StateReporting` lets you tag app states so launch time, hangs and memory break down by user flow, configuration or experiment instead of a blended app-wide average.

That is a genuinely good API. It also hands every iOS team a problem that backend teams have been paying for since Prometheus shipped: **the moment you can attach dimensions to a metric, the series space becomes the product of the dimension domains, and nothing in the SDK stops you from multiplying.**

`CardinalityGovernor` is the layer that sits between your instrumentation call sites and your exporter and makes that product a designed number rather than an emergent one.

---

## The failure it prevents

The industry-standard answer to cardinality is *stop accepting the series*: drop the sample, drop the tag, refuse the write. Every one of those is biased, and it is biased in the worst possible direction.

The samples you drop are exactly the ones carrying rare label values. Rare label values are disproportionately the unusual sessions — the cold launches, the 2%-of-users locale, the device tier that only exists in one market, the config that only the beta cohort has. So the metric gets **better-looking as it gets less true**. Your p99 improves because you stopped measuring the tail. Nobody files a bug, because the dashboard is green.

This module collapses **attribution** instead of observations. `locale=fj_FJ` becomes `locale=__other__` and the observation is still counted. You lose the ability to ask *"how slow was Fiji"*. You do not lose Fiji from the average.

That property is mechanically checkable, so it is a type — `ConservationAuditor` — rather than a sentence in a README:

```
sum(every series count, __other__ and __overflow__ included) == observations admitted
```

`GovernorSnapshot.conservation` evaluates it live, against the real tallies. The demo app renders it. `ConservationTests` proves the auditor can *fail*, by handing it the tally a dropping implementation would produce.

---

## Two budgets, and why one does not imply the other

This is the insight the API is shaped around.

| | bounds | exceeded by | mechanism |
|---|---|---|---|
| `distinctValueBudget` | each dimension's **marginal** — how many values of `locale` keep their own identity | one dimension having too many values | collapse that value to `__other__` |
| `jointSeriesBudget` | the number of **distinct label sets** tracked at all | too many *combinations* of already-budgeted values | collapse the whole label set to `__overflow__` |

Budget four keys at eight values each and you have authorised 32 values and 8⁴ = 4096 series. Per-key budgets bound the marginals; only the joint cap bounds the product, and the product is what the backend bills.

Both conserve the count. Neither drops a sample.

> **A bug this repo found in itself.** The joint cap was originally off by one: the last free slot went to a real series, the next observation overflowed, and materialising `__overflow__` to receive it took the tally to `budget + 1` — the enforcement mechanism breaking the limit it existed to enforce. It surfaced because `testJointCapHoldsExactlyAtEveryBudgetIncludingTheBoundary` asserts the bound after *every* observation at *every* budget from 1 to 12, rather than asserting "roughly bounded" once. One slot is now permanently reserved for `__overflow__`, and `jointSeriesBudget` is clamped to at least 1 — a budget of zero asks for a conserved tally with nowhere to tally.

---

## Design decisions, with the alternatives that lost

### Which values survive is decided by frequency, not arrival order

**Rejected — first N values win.** Makes the surviving series a function of when the app launched. Two devices on the same build report different series, and a value that is 90% of traffic loses to one that fired once at startup.

**Rejected — count everything, keep the top N at window end.** Unbounded memory over exactly the input we are defending against. The defence allocates proportionally to the attack.

**Chosen — Space-Saving** (Metwally, Agrawal & El Abbadi, 2005). Fixed counters regardless of stream length, with a two-sided guarantee per monitored value: `count - error ≤ trueFrequency ≤ count`. `SpaceSavingSketchTests` checks that interval against exact counts over a 20,000-observation Zipf stream into 16 counters.

Implemented over an **indexed binary min-heap** (O(log n)) rather than the canonical Stream-Summary bucket list (O(1)). At the capacities this operates at — tens to low thousands of counters — a flat array plus one dictionary beats a pointer structure on cache behaviour and allocation churn, and is a third of the code to get right. The trade is explicit: at a capacity where log n stops being small, Stream-Summary is correct and this should be replaced.

### The error interval is not decoration — it is the anti-flapping rule

Recomputing "top k by frequency" every window looks correct and is not. Two values whose true frequencies differ by less than the sketch's own error swap places on noise, so the winner flips every window. Downstream that is not cosmetic: the backend sees `locale=de_DE` appear, vanish, and reappear — three disjoint segments where there was one continuous signal. Every rate across the gap is wrong and every alert on it fires.

So promotion is deliberately asymmetric:

- A **free** slot is filled immediately, on the admission path.
- A **contested** slot changes hands only when the challenger's *lower* bound exceeds the incumbent's *upper* bound — separated by more than the sketch's uncertainty. Anything closer is refused and counted in `refusedForInsufficientSeparation`, so the rule is observable rather than a matter of faith.
- An incumbent that stops appearing keeps its slot for `promotionGraceWindows`. A nightly sync is not a dead dimension value.

`testTenWindowsOfNoiseProduceZeroFlaps` runs ten windows of two statistically indistinguishable values swapping point estimates. A recompute-every-window implementation produces ten flaps; this produces zero.

### Demand estimation and heavy-hitter tracking are two different problems

Space-Saving knows the top-k. It has no idea whether the tail it evicted was 12 values or 120,000 — and those want completely different budgets. So there is a second sketch: **HyperLogLog** at 1 KB per open dimension (p=10, ~3.25% standard error), feeding the allocator the *upper* end of its interval, because under-allocating costs attribution that cannot be recovered later while over-allocating costs slots the joint cap bounds anyway.

### Budget apportionment is an apportionment problem

The budget is a whole number of series and so is every share of it.

**Rejected — equal split.** Ignores every piece of evidence the sketches collected. **Rejected — proportional with independent rounding.** The total drifts off the budget, usually upward, which is the direction that costs money. **Rejected — greedy first-come.** Same arrival-order pathology, one layer up.

**Chosen — largest-remainder (Hamilton)**, which sums to the budget *exactly*. `testAllocationSumsToTheBudgetExactly` checks it over 400 randomised cases. Known limitation, accepted with reasons: largest-remainder admits the Alabama paradox. Divisor methods avoid it but do not sum exactly without their own iteration; exact-sum matters here and cross-budget monotonicity does not, because the budget is a constant the app ships with.

### An unbounded dimension is a privacy defect before it is a cost defect

A free-text value — a search query, a filename, a user-supplied id — as a label is simultaneously cardinality explosion and PII exfiltration into a telemetry backend. Two decisions follow:

1. **`DimensionDomain.open` carries a mandatory floor.** There is no way to say "this dimension takes runtime values" without also stating what it costs, so the dangerous case cannot be written accidentally — it has to be argued for in review. Values known at build time use `.closed`, are never governed, and a value outside the set becomes `__invalid__` and is counted.
2. **Undeclared keys are dropped, never admitted.** An undeclared key has no budget, and a dimension with no budget is unbounded by definition. The drop is counted per key so the leak is visible.

`ValueDisposition` deliberately carries **no payload**. Knowing that 4,182 values collapsed is enough to act on. Knowing *which strings* they were is what turns a cardinality bug into a privacy incident.

### Diagnostics carry a fingerprint, not the labels

MetricKit delivers metrics and diagnostics through separate channels. Attaching the full dimension set to every hang report re-creates the explosion on the diagnostics side, where it is worse — large payloads, no aggregation step to hide behind. `FingerprintCatalog` interns each admitted label set into one 64-bit token and publishes the reverse mapping once, which works precisely because the governor has already bounded how many label sets can exist.

At a joint budget of 4096, the birthday probability of a 64-bit collision is about 4×10⁻¹³ — so the honest answer is "it will not happen". But that is a probability, and the failure if it does is silent: two unrelated series merge and neither is ever right again. Detection costs one dictionary lookup that is already happening, so the catalog **detects and re-probes**, with a bounded probe count. `FingerprintTests` forces the path with a hasher that returns a constant.

### `Swift.Hasher` is unusable here, and the reason is a test-design trap

`Hasher` is seeded per process. Fingerprint stability across launches, HyperLogLog register assignment and reproducible tests all need cross-process stability, so the module uses FNV-1a with a splitmix64 finalizer behind a `StableHasher` seam.

The subtle part: **the tempting determinism test passes against `Hasher`.** Hash a value twice inside one process, assert the results match — `Hasher` is stable *within* a process, so the test goes green while the property it claims to check is false. `FingerprintTests` pins golden constants computed independently of this implementation instead.

### Value semantics for the policy, an actor only for the concurrency

`CardinalityGovernor` is a `struct` with `mutating` methods and no concurrency of its own, so the hard part — the policy — is a pure function of state and input, deterministically testable and replayable from a seed. `GovernorService` is a thin actor wrapper that can be reviewed on its own.

**No method in that actor contains an `await`.** Every body is one synchronous mutation. There is no suspension point at which another task could observe half-updated state, so the classic reentrancy bug is *designed out* rather than defended against — which is worth stating because adding a single `await` inside `admit` would silently destroy it with no compiler diagnostic. `StableHasher` is a synchronous protocol for the same reason.

---

## What's in it

| Type | Role |
|---|---|
| `CardinalityGovernor` | The policy engine. `admit(_:)` governs one label set; `rollWindow()` re-apportions and reconciles. |
| `GovernorService` | Actor wrapper. Reentrancy-free by construction. |
| `DimensionSchema` / `DimensionDomain` | Declares the label space. `.closed(Set)` or `.open(floor:)` — never open without a stated cost. |
| `SpaceSavingSketch` | Bounded heavy hitters with a two-sided error interval, over an indexed binary min-heap. |
| `HyperLogLog` | 1 KB distinct-value estimation, with the standard error reported alongside every estimate. |
| `BudgetAllocator` | Largest-remainder apportionment. Sums to the budget exactly. |
| `SurvivorSet` | Which values keep identity. Owns the separation rule and the grace period. |
| `FingerprintCatalog` | 64-bit interning with collision detection and bounded probing. |
| `ConservationAuditor` | The invariant, as a checkable type. |
| `StateReportingAdapter` | Maps an iOS 27 `StateReporting`-shaped descriptor onto a governed `LabelSet`. |

**The core module deliberately does not `import MetricKit`.** It governs *label sets*; MetricKit is one producer of them. Keeping the seam at a plain struct is what makes the whole system unit-testable without a device and CI-runnable on Linux — and it costs one adapter.

---

## Usage

```swift
import CardinalityGovernor

var schema = DimensionSchema()
schema.declare(DimensionKey("flow"), .closed(["home", "search", "cart", "checkout"]))
schema.declare(DimensionKey("deviceTier"), .closed(["low", "mid", "high"]))
schema.declare(DimensionKey("variant"), .open(floor: 8))     // minted server-side
schema.declare(DimensionKey("locale"), .open(floor: 12))     // ~700 possible values

let service = GovernorService(
    schema: schema,
    configuration: .init(distinctValueBudget: 64, jointSeriesBudget: 512)
)

let result = await service.admit(LabelSet([
    DimensionKey("flow"): "search",
    DimensionKey("deviceTier"): "mid",
    DimensionKey("variant"): experiment.variantID,
    DimensionKey("locale"): Locale.current.identifier,
]))

exporter.record(latency, labels: result.labels)          // governed, bounded
diagnostics.attach(fingerprint: result.fingerprint)      // 64 bits, not the label set

// At your reporting boundary:
let report = await service.rollWindow()
let snapshot = await service.snapshot()
precondition(snapshot.conservation.isConserved)
```

Add it with:

```swift
.package(url: "https://github.com/rajatslakhina/cardinality-governor-kit.git", from: "1.0.0")
```

---

## Demo app

A companion repo ships a runnable SwiftUI demo that drives synthetic label spaces through the governor and renders the conservation ledger, the per-key budgets, and the window-by-window reconciliation live:

**https://github.com/rajatslakhina/cardinality-governor-kit-demo-app**

It consumes this package as a **version-pinned remote Swift Package dependency**, exactly as a real consumer would — not a local path reference.

---

## Verification

**What was actually run, and what was not.**

- ✅ `swift build -Xswiftc -warnings-as-errors` on a **clean tree** (`.build` removed first — an incremental build compiles nothing and still prints "Build complete!", which is evidence of nothing). Zero warnings, zero errors.
- ✅ `swift test` — **107 XCTest cases across 10 suites**, all passing. Toolchain: Swift 6.0.3, Linux aarch64.
- ✅ Both are re-run in CI on every push, and **both jobs are green**: a Linux job (`swift:6.0-jammy` container) and a macOS 15 job, each running the same clean warnings-as-errors build and the same suite. Live results: **[Actions](https://github.com/rajatslakhina/cardinality-governor-kit/actions)**.
- ⚠️ **Four red runs in the Actions history are diagnosed, not ignored.** They are commits `1b39825`, `3a14808`, `6d21321` and `cb2e91c`, and all four fail at the *test* step for the same reason: this repo was published through a multi-commit web upload rather than a single `git push`, so for a few commits the sources and the tests were out of sync — e.g. `SurvivorSet` had the new grace-period behaviour while `SurvivorSetTests` had not yet been updated to state observation explicitly. Every one of those trees passes locally once the matching test commit lands, and `main` is green on both jobs. They are left in place rather than deleted because deleting a red run you cannot re-derive is worse than explaining it, and this explanation is checkable: compare the file list of each red commit against the commit immediately after it.
- ❌ **This library was not run on a Simulator by the pipeline that produced it.** Simulator access was refused, verbatim: *"Computer-use access to 'Simulator' can't be approved during a scheduled run."* The companion demo repo states the same thing in its own words. Compiling for a Simulator and running on a Simulator are two different claims and neither repo conflates them.

> **The macOS job earned its keep on the very first run.** `canImport(SwiftUI)` is false on Linux, so `CardinalityGovernorUI` compiles to an *empty module* there and the Linux job went green over code it had never type-checked. macOS failed the same commit with one real error: `'self' used in property access 'governor' before all stored properties are initialized`. Under `@Observable` every stored property becomes a computed accessor over macro-generated storage, so `self.snapshot = governor.snapshot` in `init` is a property *access*, not a field read — illegal until initialisation completes. Fixed by assigning through a local; the comment explaining it is still in `GovernorDashboard.swift` because the next person to "simplify" that initialiser needs to know. This is the whole argument for the second job: a single-platform CI on a package with `#if canImport` seams is a green tick over unread code.

### What an independent review found

Both repos were put through an adversarial review before publication, and it was worth doing. Four real defects came out of the first round, all now fixed and all covered by tests that were confirmed to fail without the fix:

- **`jointSpaceUpperBound` was not an upper bound.** It counted `__invalid__` for closed keys but not `__unset__`, and `__other__`/`__unset__` for open keys but not `__invalid__` — which an open key does produce, because the forged-sentinel check runs before the domain switch. A type named `…UpperBound` that undercounts is worse than no type.
- **`AdmissionResult` contradicted itself on joint overflow.** `dispositions` was finalised in the per-key loop; the overflow branch then replaced `labels` wholesale and never revisited it, so a caller could read `.kept` for a key whose label said `__overflow__`. Any "how many values kept their identity" counter built on it was wrong by exactly the overflow volume.
- **The heavy-hitter sketch never followed the allocation.** Sized once at construction and never resized, it capped the effective per-key budget — and the slots it could no longer nominate for were filled by *arrival order* on the admission path. The module's headline design decision, defeated one layer down.
- **Demand was a lifetime ratchet.** `SpaceSavingSketch.decay()` gave the heavy-hitter side windowed semantics, but HyperLogLog has no eviction and its estimate fed the allocator raw, so a key that saw one burst of distinct values held those slots forever. Two sketches feeding one allocator, disagreeing about what time is.

The last two share a cause worth naming: no test exercised a *changing* allocation, so both survived a suite that was otherwise fairly aggressive. The prose describing this system was more careful than the code that ran it, and only a test that varies the thing the prose is about could have caught that.

A second review round then found a fifth, and a better one:

- **The grace period measured the wrong thing.** `SurvivorSet` derived "was this value observed?" from the sketch's ranked candidate list rather than from live observation, which is wrong in *both* directions. A value that genuinely stopped arriving never expired, because `decay()` floors counts at 1 and never removes a counter, so a sketch under no pressure lists it forever — which made `Reconciliation.expired` dead in integrated use and the dashboard's "expired" row permanently zero. And a value observed thousands of times but evicted from the sketch under pressure accrued misses and expired *while live*. `touch(_:)` was consequently dead code: its only write was unconditionally overwritten before anything read it. Observation is now tracked explicitly, and two tests pin the two directions separately.

That one is the most interesting of the five, because nothing about it looked wrong. `expired` was populated in unit tests — just never in integration — and the prose describing the grace period was accurate about the *intent*.

### On the tests

The suite is written against a specific failure mode: tests that would still pass if the implementation were gutted. Concretely —

- Every validator has a test that constructs a **deliberately broken** input and asserts the validator **fails**. `testValidatorRejectsABrokenHeap`, `testValidatorRejectsADesyncedIndex`, `testAuditorDetectsAnImplementationThatDropsObservations`, `testAuditorDetectsDoubleCounting`.
- Determinism is checked across **independently constructed instances** or **opposite insertion orders**, never by calling the same function twice in one process.
- `testRepeatedObservationsOfOneValueEstimateOne` feeds 10,000 copies of one hash to HyperLogLog. An implementation that counted observations rather than distinct values passes every accuracy test and fails only here.
- The concurrency test runs **eight concurrent writers**, not one awaited task.
- **Non-vacuity is verified by mutation, not by inspection.** Three behaviours were checked by reverting the fix and confirming the specific test fails: the sketch resize (`testSurvivorsAreChosenByFrequencyEvenAfterAKeysAllocationGrows`), the windowed demand estimate (`testAKeyThatStopsBeingDiverseGivesItsSlotsBack`), and the overflow dispositions (`testOverflowDispositionsAgreeWithLabels`). The first did *not* fail on the first attempt — it asserted the survivor set fills its allocation, which is true under the bug too, because free slots are handed out live on the admission path. It now asserts survivors are the top-k by *frequency*, against an input where arrival order is deliberately anti-correlated with frequency. A test you have not watched fail is a test you have not written.
- The fourth test in that file, `testASingleQuietWindowDoesNotStripAKey`, is **not** a mutation test and is not claimed as one: a lifetime estimator passes it too. It guards the opposite error — a reset that strips a key on its first quiet window — and it is called out separately rather than folded into the count, because "four tests, mutation-checked" would have been one test too many.
- Every trap site named in the source has a test that hits it: `Int(Double.nan)`, `Int(.infinity)`, `Int.min / -1`, `x % 0`, `Int.max + 1`, `count - error` at `Int.min`, `Int.min.saturatingSubtracting(1)`, `heap[0]` on an empty heap, and `ProgressView` with a zero, negative, NaN or infinite total — the last of these via `SafeProgress`, which lives in the core module precisely so the guard has a test that runs on every platform in CI rather than only the ones with SwiftUI.

---

## License

MIT — see [LICENSE](LICENSE).
