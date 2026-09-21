# Implementation Plan — `slipstream-client-swift`

The native macOS **watching** client for Slipstream. This is a plan document, not
production code. It is meant to be reviewed and ratified before any feature code is
written.

- **Language/framework:** decided — Swift + vanilla The Composable Architecture
  (TCA), macOS-first. Won a three-way bake-off (`playola-radio/slipstream-native-bakeoff`,
  `SYNTHESIS.md`). Not relitigated here; this plan builds on it.
- **Sources of truth:** the merged Swift/TCA spike (`slipstream-native-bakeoff/swift/`)
  and the daemon (`briankeane/slipstream`). Captured session data
  (`.slipstream/`, `sessions/`, `blobs/`, `*.jsonl`) is never copied into this repo.
- **Provenance:** synthesized from both repos and pressure-tested through two rounds of
  adversarial architecture review before writing. Where a claim is proven vs assumed,
  the plan says which.

> **PR-graph discipline:** every PR lists **Depends**, a **Red** (the named failing
> fixture/check that defines "start"), a **Green** (the concrete condition that defines
> "done"), and a **QA** (how a human observes it working end-to-end at land time, not
> just unit tests passing). Some PRs marked **(splits on ratification)** are known to be
> larger than one landing and are deliberately left un-split until the decision they hang
> on (Part 7) is made — they are not yet claimed to be TDD-sized.
>
> **Every PR is independently QA-able — no deferred integration risk.** The explicit
> goal is that a blocker never hides in a logic PR and surfaces three PRs later at
> integration. Two structural rules enforce it:
>
> 1. **The `slipstream-watch` CLI is the QA harness for every pre-GUI PR.** Folds,
>    decoders, projections, and transport all land with a CLI subcommand that exercises
>    the new capability against a **replayed or live session** and prints observable
>    output a human (or a script) can inspect. A logic PR whose only demonstration is a
>    green unit-test run is not done — it must be runnable against real event data the
>    day it lands. This is why the CLI is a first-class deliverable, not an afterthought.
> 2. **Walking skeleton, not horizontal layers.** The graph reaches *observable output
>    against a real daemon* as early as PR2.1 (finite replay printed by the CLI) and
>    thickens from there. No PR depends on unverified work proving out later: each PR's
>    QA line exercises its own dependencies end-to-end, so if a dependency is a blocker,
>    it is caught in the PR that first leans on it — never downstream.
>
> GUI PRs (P4–P7) QA through their visible surface on a real Mac against a live/replayed
> session; every one still also keeps its CLI handle green so the headless path never
> silently rots.

---

## Part 1 — Overview & goals, and the map onto reshaped Stage 5

### 1.1 What this client is

A read-only macOS app that **watches** a Slipstream session: it renders the live feed
of captured changes, a focused two-sided diff of any change, a
function-interface-change list, and a captured-inventory explorer. It consumes **only**
the public reader API (loopback HTTP/SSE + bearer token) plus the single allowed
runtime-descriptor bootstrap. It **displays** committed attribution; it never
**produces** attribution.

The central product property is **honesty**: every surface must distinguish what was
observed from what is inferred, what is unavailable from what is empty, and a reader
interruption from a capture gap. A client that renders a plausible-but-wrong state is
worse than one that renders "unknown," because it launders inference into apparent fact.

### 1.2 Goals

1. Reproduce the daemon's **display fold** natively and demonstrably in-sync with the
   durable record, across a TypeScript-daemon / Swift-client version skew — with a
   runtime compatibility check for *versioned* fold changes and a disclosed limit for
   any change that ships unversioned (§2.4).
2. Ship the three surfaces (feed, focused diff, interface list) plus the explorer at
   production quality, each landing with its full honesty/uncertainty/coverage/gap
   states from its first commit.
3. Real-daemon transport (URLSession/Network), not just the spike's replay harness:
   descriptor discovery, Keychain credentials, reconnect with credential refresh,
   `409` explicit-recovery, `410` stop, bounded failure handling.
4. A signed, notarized, hardened-runtime `.app` within a stated bundle-size budget.
5. Accessibility (VoiceOver tree + labels) and full keyboard navigation.
6. Pass the Stage 5 / Q14 acceptance bar, including the "delete the front-end and an
   independent client reproduces the same state" invariant.

### 1.3 Non-goals (explicit)

- **Never** run `evaluateChange`, any scoring, or the grace clock. Recomputing inference
  could disagree with the durable record — an honesty violation. The client folds
  *published* records only.
- **Never** read session state, blobs, or logs off disk. The only disk touch is the
  runtime-descriptor bootstrap file; everything else is the HTTP reader API.
- **Never** open a second capture source or a privileged back channel.
- No new worktree filesystem access for the "All files" explorer — it renders the
  **captured inventory**, not the live disk.

### 1.4 Map onto reshaped Stage 5

The alignment target is the **reshaped Stage 5** on the slipstream `briankeane/vienna`
branch (not `develop`, which still carries the cancelled React Stage 5). The pivot
(Brian, 2026-09-20): the watching UI must be **native**, and a rich TypeScript **Stage
T** TUI is built first to prove the fold + API and to serve as the independent
reproduction client.

| Reshaped Stage 5 node | This plan |
|---|---|
| **S5.0** gate: lock language, client-scoped exception, fold-repro strategy | **P0** — contract & fixture gate (§3) |
| **S5.1** app skeleton **split from** transport/reconnect parity | **P1** (skeleton + feasibility) + **P2** (transport, split into 3) |
| **S5.2** session-state parity | **P3** (pure projections + integrated parity) |
| **S5.3** native live feed | **P4** |
| **S5.4** native focused diff ("Monaco-diff equivalent") | **P5** |
| **S5.5** native interface-change list (+ explorer) | **P6** + **P7** |
| **S5.6** honesty/uncertainty **audit** | **P10** (accessibility audit is **P8**) |
| **S5.7** Q14 acceptance run | **P11** |

**Stage T's role, stated precisely.** Stage T is the required **independent reproduction
client** for the Q14 invariant, and its published **fold contract + shared conformance
fixtures** are what P0 negotiates against. It is *not* the sole correctness oracle:
authoritative daemon fold source (run through the differential oracle, §2.4) and the
independently-specified expected-state fixtures are references even before Stage T
lands. Sequencing: **P0 needs Stage T's contract and fixtures to exist**; **P11 needs
Stage T acceptance to have passed**. Those are two different milestones and are not
conflated.

---

## Part 2 — Architecture

### 2.1 Module split (carried from the spike, unchanged)

- **`SlipstreamCore`** — platform-agnostic, Linux-clean. Models (`Seq`, `CloudEvent`,
  `JSONValue`, event payloads, clip projection, `ReaderEvent`), the display fold and
  `SessionModel` feed projection, the `@DependencyClient` boundaries (Reader/Blob/Clip/
  Fold/Credentials), transport plumbing, interface-change core. The cross-platform hedge
  and the reproduction seam.
- **`SlipstreamKit`** — canonical TCA reducers and live implementations, gated
  `#if os(macOS)`.
- **`SlipstreamApp`** — SwiftUI shell + AppKit (`NSTableView` feed, the one focused diff
  renderer), Keychain, the fold runtime.
- **`slipstream-watch`** — headless CLI + replay-harness, cross-platform. Doubles as a
  scriptable acceptance/parity driver.

Only the TCA UI is Apple-locked. `SlipstreamCore` is where a future port lives, and it
is the layer the conformance fixtures and the parity oracle bind to.

### 2.2 Point-Free package set (from the spike's `Package.swift`)

swift-composable-architecture 1.26.2, swift-dependencies 1.17.1,
swift-identified-collections 1.1.1, swift-case-paths 1.10.0, swift-custom-dump 1.7.3
(plus transitive swift-navigation/perception/sharing/clocks/concurrency-extras/
collections/syntax). `SlipstreamCore` links only
Dependencies/DependenciesMacros/IdentifiedCollections/CasePaths/CustomDump to stay
Linux-clean; TCA proper is gated to macOS. Versions are pinned; revisited only as a
deliberate PR.

### 2.3 Transport

- Bootstrap: newest-by-mtime `<storeDir>/runtime/*.json` → `{url, token}`, opened
  `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, requiring a regular file, mode `& 0o077 == 0`,
  owned by the running uid, `http:` URL on `127.0.0.1`/`[::1]`/`localhost`, path `/`,
  no query/fragment/credentials.
- Reader: `GET /v1/sessions`; `GET /v1/sessions/:id/events?after=&follow=` (NDJSON
  finite replay with the `slipstream-durable-seq: H` header, or SSE follow with
  `id:`/`event: slipstream`/`data:` frames, 15s heartbeat comments, `Last-Event-ID`
  reconnect); `GET /v1/sessions/:id/changes/:seq/clips`; `GET /v1/blobs/sha256/:hex`;
  `GET /v1/schemas/:type` and `/v1/schemas/projections/:version`.
- Auth: bearer + loopback bind + pinned `Host`, enforced by the daemon in the order
  method → Host/Origin (403) → bearer (401) → route.
- Restart handling: a daemon restart mints a **new** token and ephemeral port and
  republishes the descriptor. On any auth/connection failure the client re-reads the
  descriptor and refreshes credentials for **all** in-flight work (events, blobs, clips)
  before resuming.

Contract details that are easy to get wrong:

- **Clips are not "200 always."** `handleClips` can return 404 / 410 / 500 in addition
  to auth failures. **Only a successfully obtained (200) projection has a body**
  expressing content availability (`status` / `fallback_reason`); an unsuccessful HTTP
  response carries no projection to interpret. HTTP status and projection-availability
  are two separate axes and only the 200 axis has the second.
- **Fetching schemas does not teach a compiled Swift client new semantics.** Runtime
  schema fetch is a compatibility *check*, not a source of behavior. The build declares
  which schema/contract versions it supports and what it does when it sees one it does
  not (§2.4, D-K).
- **Recovery must be bounded, with a disclosed terminal state.** Descriptor refresh must
  not turn persistent corruption, an unsupported schema, or a missing blob into an
  endless reconnect loop. There is an explicit owner for attempt/time limits and a
  retry classification; on exhaustion the client reaches a **disclosed terminal /
  manual-retry state**. SSE corruption can surface merely as a socket close; the client
  reports "connection ended, reason unknown," never a fabricated capture gap.
- **Workload bounds are part of the contract.** Virtualizing the feed does not bound
  retained fold state, queued events, in-flight downloads, or parse work. Cancellation,
  backpressure, and resource limits are defined at the transport and projection layers,
  and a durable event is **never** silently dropped to stay under a limit (that is a
  correctness failure, not a performance tradeoff).

### 2.4 The fold-reproduction contract (the crux)

The daemon is TypeScript on Node 24; this client is Swift. Two toolchains must agree on
the display fold, including after the daemon's fold logic changes. The mechanism has
four parts.

**(a) Runtime contract-version compatibility — the primary guard, with an honest
limit.** The silent-divergence failure to defend against: the daemon changes attribution
semantics while keeping the event JSON shape identical. Swift and any bundled old JS
still agree; all client CI is green; the deployed client silently renders obsolete
attribution. Fixtures and schema fetches cannot catch a semantic change that preserves
shape. What catches a **versioned** such change is a runtime fold-contract-version
identifier the reader surfaces, tied to the history being interpreted, checked against
the set of versions this build supports.

The honest limit: a version identifier **cannot** detect a semantic change that ships
**unversioned** (same shape, same version, changed behavior). That residual risk is
closed only by daemon-side **release discipline** — a check that refuses to ship a fold
change without bumping the contract version and the conformance corpus together (part
(d)). The plan does not claim "provably in-sync forever"; it claims "detectable for
versioned changes, and structurally prevented from shipping unversioned by daemon-side
discipline."

The reader API exposes no such version identifier today (`http-reader.ts`). Publishing
one is an **upstream prerequisite** and a decision for Brian (D-A). If Brian instead
accepts an interim guard, that guard must provide **demonstrable equivalent enforcement**
or the S5.0 acceptance criterion is explicitly amended to record the reduced guarantee —
acknowledging an honesty limit does not by itself satisfy the criterion.

**(b) Fail visibly on unsupported semantics.** Advancing the cursor past an unknown
event is correct *transport* behavior. Claiming the resulting projection is *complete*
may be false. The client tracks two distinct boundaries — "event consumed" (cursor
advanced) and "semantics understood" (event type + contract version are ones this build
folds correctly). When they diverge, the derived view is marked **not-known-current**,
never shown as authoritative. A future attribution event the client does not understand
must not leave a stale "possibly agent" badge looking current.

**(c) A Node differential oracle from pinned daemon source.** The CI conformance oracle
is **Node executing the daemon's authoritative display exports at a pinned revision** —
not a hand-maintained JavaScript copy, which would be a third implementation that proves
nothing. Neither the client nor the oracle invokes `evaluateChange`; both fold published
records only.

**(d) Versioned contract + shared fixtures + applied-through-seq boundary, with release
discipline.** Semantic fold changes update the contract version **and** the conformance
corpus together, enforced daemon-side. Fixtures are the regression net beneath the
runtime version check, not a substitute for it. The corpus has a named owner and a
change-discipline rule (P0).

**What the native fold must reproduce, exactly.** The authoritative attribution fold
(`attribution.ts`) is a **two-pass, validity-gated** computation, not merely
"highest-seq wins":

- **Pass 1** collects the valid `(source, seq)` of every `file.changed.v1` — the set of
  legitimate attribution targets.
- **Pass 2**, for each `change.attribution.v1`: reject if `change_seq` is malformed;
  require `change_seq < attr_seq`; require the target `(source, change_seq)` to **exist
  in the same source**. Only among the survivors does the **highest `attr_seq` win, as a
  full replacement** of the record (this is revision-in-place, not a merge).

Dropping any of those guards lets an invalid late record supersede a legitimate
attribution. PR3.2 must include **explicit rejection fixtures** (malformed `change_seq`;
`change_seq >= attr_seq`; target-in-different-source; target-absent) — revision fixtures
alone do not establish conformance.

Beyond that, the fold depends on: exact-decimal `Seq` (the `2^53+1` and `2^128` fixtures
break Int/Double); **structured key equality** (maps keyed by `(source, change_seq)` and
by the evidence key `[harness, harness_session_id, record_id]`, by exact string, not a
re-encoded form); **JavaScript string ordering** (Swift comparison must not change
Unicode identity/ordering); **scope canonicalization**; and **earliest-seq evidence
de-duplication** (variants deduped by `[tool_name, timestamp.basis, at_ms, scope]`,
keeping the **min** seq). The **coverage fold** (highest-seq-wins per `(source, harness)`;
absence = health unknown, not listed) and the **gap fold** are not implemented in
`attribution.ts`; their authoritative specifications must be pinned in the fold contract
and covered by fixtures with equal rigor, or they diverge first.

### 2.5 SwiftUI + AppKit hybrid

Lightweight SwiftUI feed cards over an `NSTableView`; exactly **one** expensive focused
diff renderer, never one per card. The diff renderer's concrete technology
(CodeEditSourceEditor per pane vs paired `NSTextView`) is **not yet proven** and is gated
behind a feasibility exercise (§2.7, P5).

### 2.6 Reuse map — lifted vs reworked vs new (evidence-graded)

The spike is the canonical architecture reference, but **its GUI never ran on a Mac** (CI
is Linux). The spike report **demonstrates only Linux core tests**; the TestStore and JS
parity tests are macOS-only and their *passing* is not established by the report. So
"tests exist" is downgraded to "tests exist, execution unverified" wherever the evidence
is Linux-only, and every LIFT entry below is a **verification obligation**, not an
assumption of correctness.

**LIFT (verify on-device):**

| Component | Evidence | Verification obligation |
|---|---|---|
| `Seq`, `JSONValue`, `CloudEvent`/payloads/`ReaderEvent` | Linux unit tests | Re-run on-device; confirm Unicode/ordering identity against the fold spec |
| `DisplayFold` (foldAttributions/foldEvidence) | Linux unit tests | Confirm the validity-gated two-pass (§2.4) and add rejection fixtures; supply authoritative coverage/gap specs and confirm whether existing code covers them before rewriting |
| `SessionModel` feed projection | Linux tests; the report *illustrates* sequence-only row identity | Inspect the actual identity policy; adopt **composite identity** (source + change-seq) so multi-source cannot collide — do not assume the report's illustration is the full policy |
| `@DependencyClient` boundaries, Feed/App/SessionList reducer skeletons | macOS TestStore, execution unverified | Re-run on-device at P1 |
| `Fixtures.swift` + `FoldConformanceTests` pattern | Solid | Extend into the shared corpus |

**REWORK:**

| Component | Why |
|---|---|
| `KeychainTokenStore` | **Removed (D-I).** Credentials are memory-only, sourced fresh from the descriptor on every use; the ephemeral token rotates on daemon restart, so there is nothing durable to persist. No Keychain component ships |
| `TwoSidedDiffView` | Compile-only skeleton; CodeEditSourceEditor integration was never demonstrated (the actual view uses paired `NSTextView`s). No syntax highlight, intraline, or alignment. Editor decoration/alignment hooks must be validated before the diff architecture is committed |
| `FeedTableView` (`NSTableView`) | Compile-only, never rendered on a Mac. Needs on-device Instruments validation of frame stability + selection/scroll preservation under revision churn |
| `Loopback*` transport | POSIX loopback convenience → real URLSession/Network HTTP+SSE |
| `InterfaceExtractor` | Regex stand-in → **consumer of the daemon interface-projection endpoint** (route (a), D-C); the client renders the projection and reports coverage/version, it does not parse blobs itself |

**Undercredited — preserve as test infrastructure:**

- `ReplayHarness` (POSIX loopback HTTP/SSE with 409/410/restart/corruption) is a
  **controllable fault server**. Replacing the production transport does not invalidate
  it — keep it for deterministic reconnect/recovery testing.
- The bake-off `WORKLOAD.md` scenarios are reusable acceptance fixtures.
- **Add real-daemon integration tests** so the harness cannot certify its own (possibly
  wrong) protocol assumptions.

**NEW:** real URLSession/Network HTTP+SSE client; runtime contract-version consumer
(§2.4a); Node differential-oracle harness (§2.4c); the **daemon interface-projection
endpoint** consumer (route (a), D-C) covering Swift + TypeScript behind the
`LanguageProjection` contract; Developer-ID signing/notarization pipeline (unsandboxed,
D-I); **memory-only credential sourcing** from the descriptor (no Keychain, D-I); macOS
performance/Instruments budgets; accessibility + keyboard validation; the `Changed · N |
All files` explorer; a native design-token source (the browser's canvas `GetVariables()` no
longer applies). The whole-UI honesty audit (P10) is an audit pass, not a new surface.

### 2.7 De-risking the never-ran-on-a-Mac GUI

The single biggest unknown. It is retired early by a **throwaway, time-boxed feasibility
probe** at **P1.2** whose only deliverable is go/no-go evidence and surfaced decisions —
**it is not the production transport or credential store** (those are P2 / P2.3, which
own the regression-protected implementations). The probe proves, on a real Mac, that each
of the following is *achievable* under the model D-I selects: app launch + windowing;
real URLSession finite-replay and SSE follow against a local daemon; restart-recovery
credential refresh; descriptor access; Keychain read/write/rotate/delete; and a signing +
notarization dry-run. It does **not** presuppose sandboxing or persistent tokens — it
runs against whichever candidate models D-I is weighing and feeds that decision. A narrow
**diff feasibility exercise** (editor decoration/alignment hooks) runs before P5 expands;
feed **table churn is measured** when P4 lands.

---

## Part 3 — Dependency-ordered PR graph

Each PR names **Depends / Red / Green**. Phases mirror S5.x. **P8/P10/P11 are acceptance
gates**, not necessarily code PRs — they land as commits only if they produce changes; no
commits are manufactured to preserve numbering.

### P0 — Contract & fixture gate (S5.0) — *ratification + upstream prerequisites*

- **Status:** decisions D-A…D-L **RATIFIED 2026-09-21** (Part 7). Remaining to fully
  discharge P0: the two upstream slipstream PRs (reader fold-contract version; daemon
  interface-projection endpoint) open or their interim substitute accepted; shared-corpus
  owner named. P1 begins only on explicit direction from Brian.
- **Depends:** Stage T's fold contract + conformance fixtures exist.
- **Red:** decisions D-A…D-L unresolved; no runtime fold-contract-version identifier on
  the reader; parity oracle undefined.
- **Green:** Brian has ratified D-A…D-L; the reader exposes a fold-contract version tied
  to history (upstream slipstream PR) **or** an interim guard with demonstrable
  equivalent enforcement / an explicit criterion amendment (§2.4a); the shared corpus has
  an owner and a change-discipline rule; the parity-oracle operational definition (§5.3)
  is approved; Stage T acceptance and the Stage 3 real-session gap are tracked as P11
  prerequisites.
- **QA:** none (ratification gate, no code). The exit is a checked-in, signed-off
  decision record, reviewable as a document.

### P1 — Skeleton + on-device feasibility (S5.1a)

- **PR1.1 — Package/module skeleton.**
  - Depends: P0. Red: no package builds; no macOS test target runs. Green: `swift build`
    + `swift test` green on Linux **and** macOS in CI; the app launches to an empty
    window in a macOS run; the native design-token source exists; `slipstream-watch
    --version` runs.
  - QA: launch the empty app on a Mac (window appears); run the CLI and see it respond.
    The skeleton is observably alive, both GUI and headless.
- **PR1.2 — Throwaway feasibility probe (§2.7).**
  - Depends: PR1.1. Red: none of the §2.7 items demonstrated on a Mac. Green: a
    checked-in run log shows each achievable (or a failure surfaced as a decision).
    Explicitly disposable — no production code, no regression contract; its output is
    evidence + inputs to D-I/D-K, not the P2 implementation.
  - QA: read the run log — each §2.7 item is marked achievable-or-blocked with the raw
    on-device evidence attached. QA is the log review itself.

### P2 — Transport parity (S5.1b) — split into three

- **PR2.1 — Bootstrap + finite replay.**
  - Depends: PR1.1; **PR3.1** (shared types + application contract — the applied-cursor
    needs them). Red: descriptor-validation + replay fixtures fail. Green: validation +
    finite-replay fixtures pass; the applied-event cursor (advances only after
    application, §5.3) is unit-proven; `slipstream-durable-seq: H` captured.
  - QA: `slipstream-watch replay <session>` against a **real local daemon** discovers the
    descriptor and prints the finite event stream + the durable high-water H. This is the
    first observable end-to-end proof that descriptor discovery and the reader wire up —
    integration risk retired here, in this PR.
- **PR2.2 — SSE follow decoder.**
  - Depends: PR3.1. Red: SSE-frame fixtures fail. Green: pure decoder passes
    malformed/partial/heartbeat/`Last-Event-ID` fixtures with no network.
  - QA: `slipstream-watch follow <session>` against a live daemon tails events as they
    arrive, printing each frame and the reconnect cursor; a human sees the stream move.
- **PR2.3 — Reconnect / recovery integration + production credential store.**
  - Depends: PR2.1, PR2.2; D-I (credential model). Red: ReplayHarness 409/410/restart
    fixtures fail; a corrupt-stream fixture loops. Green: 409 explicit-recovery (never
    silent reset to 0), 410 stop, credential refresh for all in-flight work, **bounded**
    recovery reaching a disclosed terminal/manual-retry state; malformed-known-event and
    seq-discontinuity fixtures **halt trustworthy application** rather than apply blindly.
  - QA: run `follow`, then **kill and restart the daemon** — the CLI re-reads the new
    descriptor, refreshes creds, and resumes with a disclosed recovery choice on 409 /
    stop on 410; a human watches it survive the restart (or halt honestly).

### P3 — Projections & parity (S5.2) — pure components before integrated parity

- **PR3.1 — Shared event types + contract-aware envelope decode.**
  - Depends: P0. Red: envelope + unknown-event + unsupported-version fixtures fail.
    Green: unknown type advances the cursor **and** records the semantics-understood
    boundary (§2.4b); unsupported version marks derived state not-known-current; coverage
    **absence** decodes as unknown (not "unknown"-valued).
  - QA: `slipstream-watch decode <session>` prints each event's type, seq, and its
    consumed-vs-understood status; feed it a session with an unknown type and the human
    sees the not-known-current marking, not a silent skip.
- **PR3.2 — Pure display fold *(splits on ratification if the corpus is large)*.**
  - Depends: PR3.1; the Node differential oracle (§2.4c). Red: conformance corpus + oracle
    differential fail, including the **rejection fixtures** (§2.4) and exact-Seq /
    scope-canonicalization / evidence-dedup / full-replacement cases. Green: native fold
    == oracle across the corpus. (This is the fold parity that must precede integrated
    session-state parity — PR3.4 — because full expected state includes attribution.)
  - QA: `slipstream-watch fold <session>` prints the folded attribution/coverage per
    change; run it beside the Node oracle on the same session and diff the two outputs —
    a human sees them match (and sees a rejection case drop an invalid late record).
- **PR3.3 — Pure session-state projection.**
  - Depends: PR3.1. Red: expected-state fixtures fail. Green: pass with **composite row
    identity** from the start.
  - QA: `slipstream-watch state <session>` prints the projected session model (rows with
    composite identity, revision-in-place applied); a human reads the state a session
    produces.
- **PR3.4 — Integrated session-state parity.**
  - Depends: PR2.*, PR3.2, PR3.3; **PR7.1** (inventory semantics, if the compared
    expected state includes inventory). Red: end-to-end expected-state parity over a
    replayed session fails. Green: passes against the applied-through-seq oracle (§5.3),
    including attribution/coverage/gaps (and inventory, if in scope).
  - QA: `slipstream-watch parity <session> --through <H>` applies the real client through
    H and reports match/diverge against the oracle export — the full headless watching
    pipeline is demonstrably correct before any GUI is built on it.

### P4 — Live feed (S5.3)

- **PR4.1 — Feed table + selection + connection state.**
  - Depends: PR3.4. Red: honesty-state + revision-in-place TestStore cases fail; a churn
    fixture drops a durable row. Green: pass; **Instruments run** shows frame stability +
    selection/scroll preservation under churn; connection state rendered distinct from
    capture; sticky non-stacking headings.
  - QA: on a real Mac, watch a live/replayed session in the feed — rows appear, a
    revision updates in place without reordering, selection survives churn, and killing
    the daemon flips the connection indicator (not a capture gap). First visible surface.
- **PR4.2 — Task grouping + whole-function stream cards *(splits on ratification)*.**
  - Depends: PR4.1; **PR5.1** (content acquisition + truncation/fallback for the cards).
    Red: a grouping fixture implies authorship or reorders chronology; a card fixture
    shows truncated content as complete. Green: grouping disclosed-as-hint, chronology
    preserved; cards disclose truncation/fallback.
  - QA: watch a grouped session — cards group under a hint label (visibly *not* an
    authorship claim), chronology intact, and a truncated card shows its truncation mark.

### P5 — Focused two-sided diff (S5.4)

- **PR5.1 — Blob/clip access.**
  - Depends: PR2.*. Red: the clip-availability fixtures fail. Green: HTTP axis
    (200/404/410/500) and, **for 200 responses only**, the projection-availability axis
    (`ready|fallback|skipped|unavailable` + `fallback_reason`) each render an honest
    state; `null` span = no corresponding side (create/delete), never unreadable;
    unreadable = method `unavailable` + reason; truncated ≠ complete.
  - QA: `slipstream-watch clip <session> <seq>` prints the clip's HTTP outcome and, when
    200, its availability + spans; point it at create/delete/truncated/unavailable
    changes and a human sees each honest state distinctly.
- **PR5.2 — Pure alignment/coordinate logic.**
  - Depends: none beyond Core. Red: alignment/intraline fixtures fail. Green: pass
    deterministically, no UI.
  - QA: `slipstream-watch align <before> <after>` prints the aligned hunk + intraline
    map as text; a human inspects the alignment on a known pair before any renderer exists.
- **PR5.3 — Renderer integration *(splits on ratification; needs D-B + §2.7 sign-off)*.**
  - Depends: PR5.1, PR5.2; the §2.7 diff feasibility exercise; D-B (approved native diff
    bar). Red: a streaming-update fixture shows stale content under a new heading. Green:
    async results **bound to (session, change, snapshots, selection) generation**;
    synchronized scroll; selection retained under streaming; the approved bar's features
    present. (Alignment/intraline correctness is PR5.2's Green, surfaced here.)
  - QA: on a Mac, open a change's focused diff while the session streams — panes align,
    scroll in sync, selection holds, and rapidly switching changes never shows stale
    content under a new heading.

### P6 — Interface-change list (S5.5) — route (a), Swift + TypeScript (D-C ratified)

- **PR6.1 — Interface projection consumer (route (a)).**
  - Depends: shared selection/content contracts (PR3.1, PR5.1); **upstream slipstream PR #2
    (daemon interface-projection endpoint)**. Red:
    identity/overload/rename/partial-parse/timeout/missing-blob fixtures fail; a
    third-language fixture is mishandled. Green: the client **consumes** the daemon
    projection (the daemon parses whole before/after blobs — the client does not);
    added/removed/changed symbols render for **Swift and TypeScript**; empty result provably
    distinguished from unsupported/partial/unavailable; coverage + algorithm version
    surfaced from the projection; the **`LanguageProjection` seam and the "adding a
    language" checklist** ship so a third language is additive.
  - QA: `slipstream-watch interface <session> <seq>` prints added/removed/changed symbols
    with coverage + algorithm version for a Swift change and a TypeScript change; run it on
    an unsupported-language and a partial-parse change and a human sees
    "unsupported"/"partial", not a bare empty list.
- **PR6.2 — List rendering.**
  - Depends: PR6.1. Red: an unsupported-language fixture renders as "no changes." Green:
    renders unsupported/partial/unavailable honestly, coverage + algorithm version
    visible.
  - QA: on a Mac, open the interface-change list for those same changes — the unsupported
    and partial states are visible on screen, distinct from "no changes."

### P7 — `Changed · N | All files` explorer (S5.5b)

- **PR7.1 — Inventory / count semantics (in the session projection).**
  - Depends: PR3.1. Red: counting-semantics fixtures fail. Green: `Changed · N` defined
    (unique paths vs events vs net changes, over which interval) and tested; "All files"
    = observed inventory at a boundary; a post-capture-gap inventory does not look
    filesystem-complete.
  - QA: `slipstream-watch inventory <session>` prints `Changed · N` (with its counting
    rule) and the observed inventory with disclosed scopes; run it across a capture gap
    and the inventory is visibly marked not-current.
- **PR7.2 — Explorer UI.**
  - Depends: PR7.1. Red: exclusions/unknown scopes hidden. Green: baseline completion,
    exclusions, unavailable entries, unknown scopes all disclosed; never touches the
    worktree filesystem.
  - QA: on a Mac, browse the explorer — exclusions and unknown scopes are visible;
    confirm (via Instruments/file-monitor) it makes **zero** worktree filesystem reads.

### P8 — Accessibility audit gate (S5.6a)

Accessibility ships **with each surface** (P4–P7). P8 is the sweep: VoiceOver tree
completeness + labels + full keyboard navigation across all surfaces and every
honesty/unavailable state.
- Depends: P4–P7. Red: any checklist item fails on any surface. Green: checklist passes.
- QA: drive the whole app with VoiceOver + keyboard only — every surface and every
  honesty state is reachable and correctly announced.

### P9 — Distribution (S5.6b)

Feasibility proven at P1.2; P9 finishes packaging.
- Depends: P1.2, and the surfaces to be packaged. Red: notarization/staple fails or
  bundle exceeds budget (§6.2). Green: a notarized, stapled `.app` within budget,
  hardened runtime + entitlements.
- QA: download the notarized `.app` on a clean Mac, launch it past Gatekeeper, confirm it
  runs and is within the bundle-size budget.

### P10 — Honesty/uncertainty audit gate (S5.6c)

An audit + corrections pass over the whole assembled UI; not a new surface.
- Depends: P4–P7. Red: any Part-4 invariant violated in the assembled app. Green: all
  pass; corrections landed.
- QA: walk the Part-4 honesty checklist against the running app, surface by surface;
  each invariant is observably satisfied (or its correction is visible).

### P11 — Q14 acceptance gate (S5.7)

- **Depends:** Stage T acceptance **passed**; Stage 3 real-session gap (P4 acceptance +
  P5 PR) closed; P8, P10 passed; a release-candidate build (P9).
- Live Conductor sessions for both harnesses; task grouping visible; daemon killed and
  readers reconnected mid-session; **measured capture latency via instrumented
  telemetry, not inferred from event timestamps**; known coverage gaps documented; the
  native UI stopped entirely and the **independent Stage T client reproduces the same
  session state** through the parity oracle (§5.3).
- Red: any acceptance budget (§6.2) unmet, or the reproduction diverges. Green: all
  budgets met; reproduction matches.
- QA: run the scripted acceptance session end-to-end and read the report — every budget
  shows a measured number, and the Stage T reproduction shows a clean match against the
  stopped native UI's state.

### Carried-over deliverable → owning PR (so nothing passes unimplemented)

| Carried-over browser deliverable | Owning PR |
|---|---|
| Native "Monaco-diff" bar (D-B) | P5.3 |
| Whole-function stream cards | P4.2 |
| Three-column interaction | P5.3 / P7.2 (per approved layout) |
| Sticky, non-stacking headings | P4.1 (feed), P7.2 (explorer) |
| Design tokens → native token source | P1.1 (source) + applied per surface |
| `Changed · N | All files` explorer | P7 |
| Reproduction client = Stage T rich TUI | P11 (dependency) |

---

## Part 4 — Honesty contract per surface

**Global** (contract §6, `CLAUDE.md`): `heuristic` → "possibly agent," never
"attributed"; `ambiguous`/`unknown` render as themselves and `unknown` ≠ human;
`pending` is the **absence** of published attribution, not an enum value — its own label,
never "possibly agent"; revisions update the original row **in place** without changing
chronology; capture is observed states with gaps rendered as gaps (reason + scope);
coverage `readable` describes **evidence access, not capture completeness** — **do not use
one global green indicator for both**; unavailable content is explicitly unavailable with
a reason; a reader disconnect is a **reader interruption shown separately**, not a capture
gap; `session_id`/`source` = capture scope, not authorship; `task_hint_id` = grouping
hint, not authorship/completion; `excluded_conflicts` disclosed, never silently dropped.

### 4.1 Live feed
- **Pending is not "possibly agent"** (a bug in the spike report this plan fixes).
- **Revisions replace all attribution fields** and update the currently-selected detail
  view, not just the row.
- **Connection recovery ≠ catch-up** — connection state shown separately; a stale view
  discloses it is behind.
- **Task grouping must not imply authorship or completion, nor reorder chronology.**

### 4.2 Focused two-sided diff
- **Unavailable ≠ empty file; absent ≠ unreadable.**
- **Truncated clips are not complete functions** (300-line / 64 KiB per-side budget).
- **Adjacent sides do not establish function identity.**
- **Show observation / coalescing / gap context** so a snapshot pair does not imply every
  intermediate edit was captured.
- **Generation-bound async** (session, change, snapshots, selection) so stale content
  never appears under a new heading.

### 4.3 Interface-change list
- **Empty ≠ "no changes"** after unsupported language, partial parse, timeout, missing
  blobs.
- **Syntax extraction ≠ semantic/API equivalence.**
- **Name-only identity is defeated** by overloads, nested scopes, extensions, renames.
- **Extraction coverage and algorithm version are explicit** on the surface.

### 4.4 `Changed · N | All files` explorer
- **Define `Changed · N`** (unique paths vs events vs net changes, over which interval)
  and render that definition.
- **"All files" = observed inventory at a boundary**, disclosing baseline completion,
  exclusions, unavailable entries, unknown scopes.
- **After a relevant capture gap, last-known inventory must not look current or
  filesystem-complete.**
- Never new worktree filesystem access.

---

## Part 5 — Test strategy

### 5.1 Levels
- **TestStore** exhaustively over reducers, loud `unimplemented` `testValue`, fixture
  `previewValue`, Swift Testing wrapping `TestStore`, `TestClock`/`ImmediateClock`,
  cancellation IDs for follow/reconnect/staleness.
- **Shared cross-language conformance fixtures** — the correctness anchor, extended to
  cover: the attribution **rejection** cases (§2.4), coverage + gap folds, exact-Seq
  edges (`2^53+1`, `2^128`), scope canonicalization, evidence dedup (min-seq), and
  full-replacement revision-in-place. Owned, with a change-discipline rule (§2.4d).
- **Native-vs-oracle fold parity** in CI — against **Node executing pinned daemon
  source** (§2.4c), not a hand-maintained JS copy.
- **Real-daemon integration tests** — so the replay harness cannot certify its own wrong
  protocol assumptions. `ReplayHarness` stays for deterministic fault injection.
- **Named transport/honesty acceptance cases:** malformed-known-event and
  seq-discontinuity **halt** trustworthy application; coverage **absence** stays unknown;
  bounded recovery reaches a disclosed terminal/manual-retry state; composite identity;
  pending labeling; clips' two-axis status.

### 5.2 On-device tests (the spike never ran these)
Feed frame stability + selection/scroll preservation under churn (Instruments, P4.1);
diff decoration/alignment feasibility (P5.3); Keychain + descriptor + real URLSession/SSE
+ restart recovery (P1.2 probe, P2.3 production); signing/notarization (P1.2 dry-run, P9
real). Treat all macOS test *passing* as unproven until a checked-in on-device run shows
it.

### 5.3 The parity oracle (applied-through-seq) — operational definition
The comparison is over an **identical session/source scope and event prefix through a
chosen H**, at an **identical contract version**, of **normalized state** (attribution
provenance, coverage, gaps, inventory) — **not** screenshots.

Operationally (the API has no `through=H` parameter, and two finite replays can return
different high-water marks during live capture):

1. Select a single H (e.g. the `slipstream-durable-seq: H` observed at one finite-replay
   call, frozen for the run).
2. Both clients apply **fully through that H** and **exclude every later event**; the
   cursor advances only after application, and the checkpoint is **preserved when the
   native UI stops** (persisting a cursor without its matching applied state would skip
   history on restart — forbidden).
3. Contract identity stays **bound to that replay** across any daemon restart or
   historical version change.
4. Live SSE supplies no durable-high-water header, so "connected" never establishes
   "caught up"; live-follow parity is asserted only at a finite-replay checkpoint.

The canonical form and same-H export protocol are **RATIFIED (D-J, option A)**: both
clients apply through a frozen H (from finite replay's `slipstream-durable-seq`), exclude
later events, and compare normalized state — no upstream API change. This was the hardest
protocol requirement in the plan; it is now settled and owned by PR3.4.

---

## Part 6 — Validation & acceptance plan (with open gaps)

### 6.1 Acceptance run (Q14 / P11)
As P11: both harnesses live; task grouping visible; daemon-kill + reconnect; **measured**
latency via instrumented telemetry (public event `time` is not a latency proxy —
`CLIP-LATENCY-PROTOCOL.md`); documented coverage gaps; native UI stopped and the
independent Stage T client reproduces state through the §5.3 oracle.

### 6.2 Acceptance budgets — set at P0 (D-K resolved)
Proposed budgets, ratifiable as a unit; tighten once P4/P5 Instruments runs give real
numbers. Any surface exceeding its budget on the acceptance corpus is a P11 failure.

| Budget | Value |
|---|---|
| Minimum macOS | macOS 14 (Sonoma) or later |
| Reference hardware | Apple silicon (M1 or later), 16 GB |
| Supported languages (bounds the interface list) | **Swift, TypeScript** (D-C); others render as "unsupported", never as "no changes" |
| Session size | ≥ 5,000 committed events replays and follows without degradation |
| Memory ceiling | ≤ 1.5 GB resident on the reference session |
| Replay duration | finite replay of the reference session ≤ 30 s to durable H |
| Revision-render latency | ≤ 100 ms from applied event to visible feed update at p95 |
| Diff size limits | focused diff renders ≤ 10,000 changed lines; beyond that, collapse + explicit "large diff" state |

On an unsupported contract or semantics version the client **freezes derived rendering and
shows an explicit incompatibility banner** (D-K) — it never hard-fails and never shows a
raw view that could imply an un-reproduced attribution.

### 6.3 Open gaps (proven vs assumed)
- **GUI has never run on a Mac** — the dominant unknown; probed at P1.2 before surfaces.
- **Real-daemon HTTP/SSE via URLSession/Network** — spike used POSIX loopback; new at P2.
- **macOS performance** — unmeasured; Instruments budgets at P4/P5.
- **Signing / notarization** — unproven; **unsandboxed Developer-ID + hardened runtime +
  notarized** (D-I); dry-run P1.2, real P9.
- **The reader has no runtime fold-contract-version identifier yet** — the linchpin of
  the versioned-change guard; upstream prerequisite at P0 (D-A), with the unversioned-
  change limit closed only by daemon release discipline.
- **The same-H parity protocol** (§5.3) is **resolved client-side (D-J, option A)** — no
  API change; both clients truncate to a frozen H and compare normalized state.
- **Stage T must have passed** and the **Stage 3 real-session gap** must be closed before
  P11 — flagged, not discharged here.

---

## Part 7 — Decisions for Brian — RATIFIED 2026-09-21

All twelve decisions were ratified by Brian on **2026-09-21**, satisfying the **P0
ratification gate**. Each entry records the decision as **surfaced** (the tradeoff) and
**RESOLVED** (the chosen option + any follow-on it creates). Two upstream slipstream PRs
fall out of D-A and D-C and are listed as explicit P0 prerequisites after the decisions.

- **D-A — Fold-reproduction strategy + runtime contract version.**
  **RESOLVED: native fold at runtime, with Node-from-pinned-daemon-source as the CI
  differential oracle, and a published fold-contract version on the reader** (upstream
  slipstream PR #1 below). Until that version ships, P0 may proceed only on an interim
  guard with demonstrable equivalent enforcement, or an explicit §2.4a criterion
  amendment. The unversioned-change residual is **accepted, not eliminated** — it is
  closed only by daemon release discipline.
- **D-B — Native diff bar. RESOLVED: approve** the native equivalent's feature bar
  (Diff/Plain toggle, collapsed unchanged ranges, etc.); the P5.3 §2.7 feasibility
  exercise de-risks it before it lands.
- **D-C — Interface-change semantics + ownership. RESOLVED: route (a) — daemon projection
  endpoint** (upstream slipstream PR #2 below). **Initial supported languages: Swift and
  TypeScript**, behind a **modular language-adoption architecture**: each language is a
  self-contained projection module behind a single `LanguageProjection` contract (symbol
  identity, signature normalization, overload/rename handling, partial-parse outcome,
  coverage + algorithm-version reporting). Adding a language is **additive** — a new module
  plus its conformance fixtures — never a rewrite of the interface pipeline. The daemon
  owns the projection; the client renders it and reports coverage/version honestly. A
  documented "adding a language" checklist ships with PR6.1.
- **D-D — Reproduction-client substitution. RESOLVED: ratify** substituting Stage T's
  rich TUI for the cancelled "Stage 2 TUI" as the independent reproduction oracle.
- **D-E — Carried-over browser deliverables. RESOLVED: confirm** scope as mapped in the
  Part 3 table (explorer, three-column interaction, sticky non-stacking headings,
  whole-function stream cards, native design-token source).
- **D-F — Client-scoped exception to "TypeScript throughout / replaceable front-end."**
  **RESOLVED: make the exception explicit** — a Swift client consuming only `/v1/*`
  preserves front-end replaceability.
- **D-G — Cross-platform hedge. RESOLVED: accept** the risk framing; the Apple-locked TCA
  UI sits above `SlipstreamCore`, which is the platform-agnostic migration seam.
- **D-H — Daemon topology. RESOLVED: colocated-only.** The reader binds strictly to
  `127.0.0.1`, pins `Host`, and bootstraps from local files. Remote support is deferred —
  it is a contract/deployment change, not a URL preference — and sits cleanly under the
  unsandboxed local-descriptor model (D-I).
- **D-I — Distribution + credential lifecycle. RESOLVED: unsandboxed + memory-only
  credentials.** Distribution is **Developer-ID + hardened runtime + notarized** (not
  sandboxed, not Mac App Store); the descriptor is read directly from
  `<storeDir>/runtime/*.json`, guarded by `O_NOFOLLOW` + mode `0600` + owner check.
  Credentials are **held in memory only, sourced fresh from the descriptor on every use —
  no Keychain persistence**; `KeychainTokenStore` is **removed from the plan**. Rationale:
  the reader token is ephemeral and rotates on daemon restart, so persisting it risks a
  stale credential and buys nothing, while memory-only eliminates the entire
  sandbox/Keychain lifecycle (rotation, locked/denied, deletion). Revisit only if Mac App
  Store distribution becomes a requirement.
- **D-J — Parity-oracle definition + same-H export. RESOLVED: option A** — client-side
  truncation to a frozen H (from finite replay's `slipstream-durable-seq` header); both
  clients apply through H and exclude later events, then compare **normalized state**
  (attribution provenance, coverage, gaps, inventory). **No upstream API change.**
- **D-K — Compatibility-failure policy + acceptance budgets. RESOLVED: freeze with an
  explicit incompatibility state.** On an unsupported contract/semantics version the client
  **stops derived rendering and shows an explicit incompatibility banner** naming the
  mismatch; it never hard-fails, and never shows a raw view that could imply an
  un-reproduced attribution. Acceptance budgets are set in §6.2.
- **D-L — Stage 3 prerequisite gap. RESOLVED: ratify the sequencing.** P11 (the Q14 gate)
  cannot run until slipstream Stage 3's real-harness sessions exist; the plan already
  orders P11 last, and Stage T acceptance + the Stage 3 gap are tracked as P11
  prerequisites.

### P0 upstream slipstream prerequisites (created by D-A and D-C)

1. **Reader fold-contract version** (D-A) — the public reader publishes a fold-contract
   version tied to history, so the client can detect a shape-preserving semantic change and
   trigger the D-K freeze. Until it ships, P0 proceeds only on the §2.4a interim guard
   (demonstrable equivalent enforcement) or an explicit criterion amendment. The §2.4a
   guard depends on this PR.
2. **Daemon interface-projection endpoint** (D-C) — a `/v1/*` projection endpoint that
   returns added/removed/changed symbols per the ratified semantics for the supported
   languages (Swift, TypeScript), with coverage + algorithm version. **PR6.1 depends on
   this PR.**

Both are tracked on the slipstream `briankeane/vienna` branch and must be open (or their
interim substitute accepted) before the PRs that consume them land. P2.3 depends on
neither.

---

*End of plan. No production code is written in this task. Part 7 is ratified (2026-09-21);
the P0 gate is satisfied. P1 begins only on explicit direction from Brian.*
