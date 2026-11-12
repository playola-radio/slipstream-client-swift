# slipstream-client-swift

Native macOS client for Slipstream: it watches captures, creates workspaces, and runs agent
chats. `IMPLEMENTATION_PLAN.md` is the plan (read its top addendum first); the daemon
(`briankeane/slipstream`) owns the wire contract.

The app follows the same architecture as `~/playola/logic-utils` (and through it
`~/playola/playola-radio-ios`): MV with `@Observable` models, fully tested models, and
**zero logic in views**. When in doubt, match those repos.

## ALWAYS use the Point-Free Workflow (pfw-*) skills

Before writing or planning Swift code here, invoke every `pfw-*` skill that applies:

- `@Observable` models (`*PageModel.swift`) → `pfw-observable-models`
- dependency clients (`@Dependency`, `liveValue`/`testValue`) → `pfw-dependencies`
- tests → `pfw-testing` and `pfw-custom-dump`
- `IdentifiedArrayOf` → `pfw-identified-collections`
- SwiftUI views → `pfw-modern-swiftui`
- `reportIssue` / `isTesting` → `pfw-issue-reporting`

Subagents must invoke the relevant `pfw-*` skills too.

## Targets

- `SlipstreamCore` (SwiftPM, `Sources/`): pure logic and transport. No Observation, no
  SwiftUI. Tested with `swift test`.
- `SlipstreamViewer` (XcodeGen app, `project.yml`): pages, dependency clients, design
  tokens. The generated `.xcodeproj` is gitignored; run `xcodegen generate` after editing
  `project.yml`.
- Swift 6 language mode, complete strict concurrency, warnings are errors.

## Architecture

A page is a trio:

```
SlipstreamViewer/Views/Pages/<Name>Page/<Name>PageModel.swift   # all state + behavior
SlipstreamViewer/Views/Pages/<Name>Page/<Name>PageView.swift    # visuals only
SlipstreamViewerTests/Views/Pages/<Name>Page/<Name>PageTests.swift
```

Models are `@MainActor @Observable final class …: ViewModel` (base class in
`Views/Reusable Components/ViewModel.swift`), with `// MARK:` sections in this order:
Dependencies, Shared State (if any), Initialization, Properties, Display Text, View
Helpers, User Actions, Private Helpers.

- **Views contain zero logic.** Every string, count, colour choice and show/hide decision
  is a model property. Views bind and call model methods; they never decide.
- **Actions are named after what the user did:** `viewAppeared()`, `sessionSelected(_:)`,
  `retryTapped()`, `jumpToLatestTapped()`. Async work is an `async` method; the view
  creates the `Task` (or uses `.task`).
- **Ownership (plan §2.8):** every async operation has one owner, an explicit lifetime and
  a generation check before it publishes. Switching session discards stale completions.
  One event follower per window.

## Ownership: daemon facts vs client state

- The daemon owns durable facts that more than the app needs: store identity, canonical roots,
  session identity, capture lifecycle, workspace lifecycle capabilities, names, and chat bindings.
- The client owns presentation and app-local user intent: selection, sidebar membership, window
  layout, chat-tab records, terminal records, drafts, and transient operation state.
- The client may derive presentation from daemon facts, but must not derive daemon capabilities
  or durable identity from paths.

For example, whether the user opened a folder in the app is client state (`.openedFolders`).

## Dependencies

Every side effect is a `Sendable` struct-of-closures client with `liveValue` and
`testValue`, injected with `@Dependency` (`DaemonClient`, the continuous clock, the random
number generator, the time zone). Tests override them with `withDependencies`; model tests
never touch a daemon, the network or real time.

## Design

Visual values come from `design/features/live-change-stream/exports/<date>/tokens.md`,
copied verbatim into `SlipstreamViewer/DesignTokens.swift`. Views use only
`DesignTokens`; never hardcode a colour, font or spacing. Geist and Geist Mono are bundled
variable fonts (`Resources/Fonts`, SIL OFL).

## Testing

- Swift Testing everywhere. `expectNoDifference` / `expectDifference` for values.
- Time is a `TestClock`; ordering uses the `.mainSerialExecutor` trait. Never
  `Task.sleep` in tests.
- Test the model, never the view. Add a regression test with every bug fix.
- Test targets link only what the tested target doesn't already provide
  (`DependenciesTestSupport`, `CustomDump`).

## Safety

- Never point anything at the real `~/.slipstream`; use `SLIPSTREAM_STORE` with a
  disposable daemon (`npm run qa:daemon` in the daemon repo).
- Never print or persist the daemon bearer token. No Keychain; credentials live in memory.

## Logs

- The app writes `~/Library/Logs/slipstream/app.log` (rotates to `app.log.1` at 10 MB); debug builds
  write `app-debug.log` instead. The daemon's log is `~/Library/Logs/slipstream/daemon.log`. `tail -F`
  or `grep` them to diagnose a problem after the fact.
- Categories: `app`, `daemon`, `follow`, `agent`, `recorder`, `terminal`, `issue`.
- Log through `@Dependency(\.appLog)`. Log full errors (`"\(error)"`, stderr, exit codes), never just
  `localizedDescription`. Never log the daemon token, launch environments or agent argument arrays.

## Changelog

Never edit `CHANGELOG.md` in a pull request. A user-visible change adds one new file,
`changelog.d/<short-kebab-description>.md`, in the format in `changelog.d/README.md`; a pure
chore adds none and says so in the PR description. When the current version is tagged, pending
`### Changes` notes make CI bump the patch version and roll all pending notes into
`CHANGELOG.md`; `### Ops`-only notes wait for Changes notes. An untagged version publishes as
is, and notes merged after that bump wait for a later release (`packaging/README.md`).
