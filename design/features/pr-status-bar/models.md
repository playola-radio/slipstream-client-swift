# PR status bar — Model changes

Nothing is persisted: there are no tables, columns, migrations or store changes. Every value below
is in memory, derived live from `git` and `gh` on each check. The "Table" column says where the
type lives instead.

| Change | Model | Lives in | Summary |
|---|---|---|---|
| New | `GitHubPullRequest` | `SlipstreamCore` | One PR decoded from `gh pr list --json` |
| New | `PullRequestCheck` | `SlipstreamCore` | One normalized `statusCheckRollup` entry |
| New | `RepoSnapshot` | `SlipstreamCore` | The facts one status check gathered |
| New | `PRStatus` | `SlipstreamCore` | The domain status derived from a snapshot |
| New | `AttachmentMarker` | `SlipstreamCore` | Formats and parses `@⟦name⟧(path)` |
| New | `CommandResult` | `SlipstreamViewer/Dependencies` | A finished command |
| New | `PRBarFailure` | `SlipstreamViewer/Models` | A failure shown in Details |
| New | `PRStatusBarModel` | `SlipstreamViewer/Views/Pages/ChangeStreamPage` | The bar's state and actions |
| New | `RepoCommandClient` | `SlipstreamViewer/Dependencies` | Runs `git`/`gh` in a folder with a timeout |
| New | `AttachmentClient` | `SlipstreamViewer/Dependencies` | Writes and opens instruction files |
| Changed | `ChatTabModel` | `SlipstreamViewer/Views/Pages/ChatPage` | Adds `enqueueUserMessage(_:)` and attachment chips |
| Changed | `ChangeStreamPageModel` | `SlipstreamViewer/Views/Pages/ChangeStreamPage` | Owns `prStatusBar` |

## GitHubPullRequest — New

`Decodable`, `Equatable`, `Sendable`. Fields are exactly the `--json` list in spec step 4.

| Field | Type | Notes |
|---|---|---|
| `number` | `Int` | Chip label, selection order |
| `url` | `URL` | Chip link; Merge target |
| `state` | `State` (`OPEN`, `MERGED`, `CLOSED`) | Selection |
| `isDraft` | `Bool` | Draft status |
| `headRefOid` | `String` | Push state; merged/closed currency; `--match-head-commit` |
| `isCrossRepository` | `Bool` | Same-repo filter |
| `baseRefName` | `String` | Target branch |
| `mergeable` | `String` | `MERGEABLE` / `CONFLICTING` / `UNKNOWN`; kept raw, unknown values fall to Waiting |
| `mergeStateStatus` | `String` | Ready vs Waiting reason; kept raw |
| `reviewDecision` | `String?` | Waiting reason; null when no review is required |
| `statusCheckRollup` | `[PullRequestCheck]` | |

- **Source of truth:** GitHub, read on every check. Never cached past the current display.

## PullRequestCheck — New

Decoded by `__typename` (`CheckRun` / `StatusContext`, spec step 8) into one shape.

| Field | Type | Notes |
|---|---|---|
| `name` | `String` | `name` or `context` |
| `link` | `URL?` | `detailsUrl` or `targetUrl`; Fix errors file and run-ID parsing |
| `outcome` | `Outcome` (`failed`, `running`, `done`) | Classification per spec step 8 |

## RepoSnapshot — New

| Field | Type | Notes |
|---|---|---|
| `branch` | `String` | |
| `uncommittedCount` | `Int` | `git status --porcelain=v1` lines |
| `repository` | `String` | Origin repository's `nameWithOwner`; passed to `gh` actions and agent instructions |
| `defaultBranch` | `String` | From `gh repo view` (`GitHubRepository`: `isFork`, `defaultBranch`, `mergeMethod`); target when there is no PR |
| `mergeMethod` | `String` | `viewerDefaultMergeMethod`; used by Merge |
| `pullRequest` | `GitHubPullRequest?` | The selected PR after spec step 4 |
| `pushState` | `PushState?` (`inSync`, `localAhead`, `outOfSync`) | Open PR only |
| `aheadOfTarget` | `Int?` | No PR only |

## PRStatus — New

A pure function `PRStatus(snapshot:)` over a non-nil snapshot (a nil snapshot means the feature doesn't apply and the row is empty); the precedence in spec steps 9–11 lives here and only here.

| Case | Payload |
|---|---|
| `noPRUncommitted` / `noPRCommitted(ahead:, target:)` / `nothingToSubmit` | |
| `commitAndPush`, `conflicts(target:)`, `checksFailed(failed:, total:)`, `checksRunning(done:, total:)`, `draft`, `ready`, `waiting(reason:)` | the PR itself comes from `snapshot.pullRequest` |
| `merged`, `closed` | — |

`waiting(reason:)` is an enum (`gitHubChecking`, `changesRequested`, `reviewRequired`,
`behind(target:)`, `blocked`, `outOfSync`, `notMergeable`); its text is a model property.

## AttachmentMarker — New

`format(name:path:) -> String` and `parse(_ text:) -> Parsed?` (`Parsed` is an `Equatable` struct of `body`, `name`, `path`),
following the spec's marker grammar. Used by the bar (writing) and `ChatPageView`'s user bubble
via the tab model (reading).

## CommandResult — New

| Field | Type | Notes |
|---|---|---|
| `command` | `[String]` | Arguments as run; rendered with shell quoting |
| `folder` | `URL` | |
| `ending` | `Ending` (`exit(Int32)`, `timedOut(Duration)`, `launchFailed(String)`) | |
| `stdout` / `stderr` | `String` | Complete |

`succeeded` is `ending == .exit(0)`; `commandLine` renders `command` with `RuntimeInstall.shellQuoted` (made public) for Details.

## PRBarFailure — New

| Field | Type | Notes |
|---|---|---|
| `title` | `String` | The red title (spec Errors table) |
| `details` | `String` | Rendered when the failure happens: folder, command line, ending, stdout, stderr; or a message such as "the chat tab was closed" |

## PRStatusBarModel — New

`@MainActor @Observable final class PRStatusBarModel: ViewModel`, one per window, created and owned
by `ChangeStreamPageModel` (`prStatusBar`) with a reference to its `ChatPageModel`. Dependencies:
`RepoCommandClient`, `AttachmentClient`, the continuous clock.

| State | Type | Notes |
|---|---|---|
| `checked` | `Checked?` (`folder: String`, `result: Result<RepoSnapshot?, PRBarFailure>`) | The last read and the folder it belongs to |
| `actionFailure` | `PRBarFailure?` | Stays until dismissed, retried or the workspace changes |
| `isDetailsPresented` | `Bool` | |
| `operation` | `Operation?` (`merging`, `continuing`, `sending`) | Disables buttons and pauses the poll |
| `refreshCount` | `Int` (private) | Bumped by ⌘R |

Computed: `pollKey` (spec Ownership), `snapshot` and `status` (from `checked` when its folder is
the selected one), `isCheckingShown`, and everything the view shows — label, detail, icon, tint,
which button, enabled, shortcut, PR URL, Details text. Actions: `pollTask()`, `reloadRequested()`,
`primaryButtonTapped()`, `continueTapped()`, `archiveTapped()`, `detailsTapped()`,
`detailsDismissed()`, `copyTapped()`.

## RepoCommandClient — New

`struct RepoCommandClient: Sendable` — a plain struct of closures with `liveValue` and an `unimplemented` `testValue`, like `OpenInClient`.

- `run: @Sendable (_ arguments: [String], _ folder: URL, _ timeout: Duration) async -> CommandResult`
- Live: the poll-and-drain loop from `AgentEnvironmentClient.captureOutputBlocking`, extended with
  `currentDirectoryURL` and a second pipe, run with the login environment cached by a generalized
  `AgentEnvironmentCache`. SIGKILL on timeout.
- Test: unimplemented; tests script results per argument list.

## AttachmentClient — New

`struct AttachmentClient: Sendable` — same pattern as `RepoCommandClient`.

- `write: @Sendable (_ name: String, _ contents: String) throws -> URL` — atomic write under
  `Application Support/Slipstream/attachments/<uuid>/`.
- `open: @Sendable (_ file: URL) throws -> Void` — `NSWorkspace.shared.open`; throws when the
  file is missing or won't open.

## ChatTabModel — Changed

- **Added** `func enqueueUserMessage(_ text: String) async throws` — contract in the spec. Shares
  one private write/project/rollback path with `send()`.
- **Added** `attachment(for:)` on rows (via `AttachmentMarker.parse`), `attachmentTapped(_:)`,
  which opens the file, and `attachmentAlert`, set when opening fails.

## ChangeStreamPageModel — Changed

- **Added** `let prStatusBar: PRStatusBarModel`; `reloadShortcutPressed()` also calls
  `prStatusBar.reloadRequested()`, and `onArchive` routes to `archiveTapped(_:)`. Selection and
  activation reach the bar through `chat`, which it already reads.
