# Chat Console Implementation Plan

> **For agentic workers:** this plan spans four PRs. Drive it with `orchestrate-feature`;
> each PR is implemented in a fresh session with superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Run Claude Code chats inside the Slipstream window, beside the change stream, so the
one stream picker switches both.

**Architecture:** Pure parsing and transcript projection live in `SlipstreamCore`. Process,
login-shell environment, transcript-file and tab-record effects are struct-of-closures
dependency clients in the app. One app-lifetime `ChatPageModel` owns every tab's runtime,
independent of stream selection. `ChangeStreamPageModel` stays the owner of selection and
feeds it the current folder. Views render model properties only.

**Tech Stack:** Swift 6 (complete strict concurrency, warnings are errors), SwiftUI on
macOS 15, swift-dependencies 1.17.1, swift-identified-collections, swift-sharing, Swift
Testing, CustomDump, swift-clocks (`TestClock`), XcodeGen.

**Spec:** [spec.md](./spec.md) is the source of truth. Contracts to implement, pointed at
here and not copied: [screens.md](./screens.md), [models.md](./models.md), spec.md
"Existing contracts" (CLI flags, stdin/stdout lines, transcript file), and spec.md "Runtime
design" (ownership, launch, turns, shutdown, transcript, records, workspaces). Endpoints:
none.

**Base commits:** client `develop` @ `317788b`; daemon untouched (`312aa42`).

**Required skills for every implementing session** (project `CLAUDE.md`):
- `pfw-observable-models` for `*PageModel`
- `pfw-dependencies` for clients
- `pfw-testing` and `pfw-custom-dump` for tests
- `pfw-identified-collections` for `IdentifiedArrayOf`
- `pfw-modern-swiftui` for views
- `pfw-issue-reporting` for `reportIssue`

Subagents invoke them too.

## Global Constraints

- Minimum `claude` version: `2.1.293`. Older is a can't-start error naming the version found.
- Invocation, exactly (spec "Existing contracts"):

  ```
  claude --print --output-format stream-json --verbose --input-format stream-json --thinking=adaptive --thinking-display=summarized --effort=<e> --model=<m> --max-turns=1000 --permission-prompt-tool=stdio --permission-mode=bypassPermissions --disallowedTools=AskUserQuestion --setting-sources=user,project,local (--session-id=<uuid> | --resume=<uuid>)
  ```

  Never pass `--chrome`, `--no-chrome`, `--session-mirror`, `--plugin-dir`, `--replay-user-messages` or `--include-partial-messages`.
- Timeouts: login-shell environment 10 s; Stop → `result` 10 s; SIGTERM → SIGKILL grace 3 s. No startup timeout: a launch that hangs shows the ticking working line until Stop.
- Line cap: 1 MiB (1_048_576 bytes). The stderr ring keeps 4 KB.
- Tab records: `@Shared(.chatTabs)`, a swift-sharing `fileStorage` key at `<Application Support>/<bundle id>/chatTabs.json`, written only by `ChatPageModel` on the main actor.
- Defaults for a tab with no tab to copy from: model `claude-opus-5-5`, effort `high`.
- Model menu (Claude's call, v0.1): Opus 5.5 `claude-opus-5-5`, Sonnet 5.5 `claude-sonnet-5-5`, Haiku 5.5 `claude-haiku-5-5`.
- Effort menu: Low / Medium / High / Extra high / Max, raw values `low medium high xhigh max`.
- Copy is verbatim from screens.md:

  | Use | Text |
  |---|---|
  | Placeholder | "Ask to make changes, @mention files, run /commands" |
  | New tab | "New chat" |
  | Working line | "Working 1m 12s · last output 3s ago" |
  | Stopped footer | "Stopped · 41s · 3:09 PM" |
  | Gap row | "Part of this conversation couldn't be shown" |
  | Crash | "Claude stopped unexpectedly" |
  | Folder not known yet (Claude's call) | "Finding this stream's folder…" |
  | Quit alert | "Claude is still working in 2 tabs. Quitting stops them. You can pick the conversations up again next time." |
  | Restore feed | "◧  Activity" (existing `showFeedText`) |
- Views use only `DesignTokens`. Chat values come from this feature's `exports/screens/*.json` and `exports/design-tokens.json`.
- Never point anything at the real `~/.slipstream`, and never print or persist the daemon token.
- Tests never spawn `claude`, read `~/.claude`, or sleep. Time comes from `TestClock`.
- Probe-derived fixtures are hand-written minimal JSONL. Never copy raw probe or transcript files: they contain the user's `CLAUDE.md` text.

## Review Focus

1. **A turn ending while you're on another workspace.** It must mark that tab waiting and its stream bold, and the agent must not be cancelled by the switch. Covered by Task 9, `turnEndingOffScreenMarksWaiting`.
2. **Stop pressed on an agent that never answers.** It must end within 10 s as stopped, with no spinner left behind. Covered by Task 10, `stopWithoutResultShutsDownAfterTenSeconds`.
3. **Closing a tab mid-turn.** Its process group must be gone and its late lines must change nothing. Covered by Task 11, `closingWorkingTabRemovesRecordThenShutsDown`, and Task 5, `shutdownKillsChildProcesses`.
4. **A huge tool result (a multi-MB `cat`).** It must show one gap row, and the next line must still parse. Covered by Task 1, `overLongLineBecomesOverflowAndNextLineParses`.
5. **Relaunching with a tab whose transcript file was deleted.** It must start fresh under the same id, not error. A file that can't be read must error and launch nothing. Covered by Task 8, `missingTranscriptStartsNewSession` and `unreadableTranscriptShowsErrorAndDoesNotLaunch`.

## PR graph

| PR | Tasks | Depends on | Red → Green | QA |
|---|---|---|---|---|
| A · Claude line parsing | 1–3 | — | `swift test --filter Claude` fails → passes | `swift test` |
| B · Running the agent | 4–6 | A (Task 1) | client tests fail → pass; Task 4 probe recorded | the `ProcessIntegrationTests` script fixture |
| C · Chat model | 7–11 | A, B | `ChangeStreamPageTests` root tests and `ChatPageTests` fail → pass | app tests; picker still works with a disposable daemon |
| D · Chat screen | 12–14 | C | view compiles; manual QA | spec acceptance #15 against a disposable daemon |

A and B can run in parallel once Task 1 lands (B needs only `JSONLineFramer`). Every PR
targets `develop`. Titles follow the PR-title rules: A–C are `chore:`, and D is
`feature: chat with Claude beside the change stream`.

**Coordination with P6a (capture states, running in parallel):** P6a changes
`ChangeStreamPageModel`, the picker labels and the stream header, which Task 7 and Task 13
also touch; whichever lands second rebases onto the other. P6a's `/v1/captures` carries each
capture's `root`. If it has merged when PR C starts, Task 7 may take the folder from there
instead of the start record, keeping `normalizedFolder` and the carry-across-refresh rule.
The offline reader has no `/v1/captures`, so the start record stays the fallback.

---

## PR A — Claude line parsing (`SlipstreamCore`)

### Task 1: JSON line framing

**Files:**
- Create: `Sources/SlipstreamCore/JSONLineFramer.swift`
- Test: `Tests/SlipstreamCoreTests/JSONLineFramerTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum FramedLine: Equatable, Sendable { case line(Data), overflow }
  public struct JSONLineFramer: Sendable {
    public init(maxLineBytes: Int = 1_048_576)
    public mutating func append(_ chunk: Data) -> [FramedLine]
  }
  ```

- [ ] **Step 1: Write the failing tests**
  - `splitsLinesAcrossChunks`: append `"{\"a\":"`, then `"1}\n{\"b\":2}\n"`. Expect `[]`, then `[.line(#"{"a":1}"#), .line(#"{"b":2}"#)]`.
  - `dropsCarriageReturn`: `"x\r\n"` gives `[.line("x")]`.
  - `overLongLineBecomesOverflowAndNextLineParses`: with cap 8, `"0123456789AB\n{}\n"` across two chunks gives `[.overflow, .line("{}")]`. Exactly one `.overflow`.
  - `emptyLinesAreSkipped`.
- [ ] **Step 2: Run** `swift test --filter JSONLineFramerTests`. Expect FAIL (no type).
- [ ] **Step 3: Implement.** Use a byte buffer. Once it passes the cap without a newline, enter discard mode until the next `\n`, then emit one `.overflow`. A partial line left at exit is simply dropped. Don't share code with `SSEParser`; its overflow rule differs.
- [ ] **Step 4: Run.** Expect PASS.
- [ ] **Step 5: Commit** `chore: frame Claude's output into lines`.

### Task 2: Decoding Claude lines

**Files:**
- Create: `Sources/SlipstreamCore/JSONValue.swift`
- Create: `Sources/SlipstreamCore/ClaudeLines.swift`
- Create: `Sources/SlipstreamCore/ClaudeInvocation.swift`
- Create: `Tests/SlipstreamCoreTests/Fixtures/claude/` with hand-written minimal JSONL:
  - `live-turn.jsonl`: init, running, assistant thinking/text/tool_use, user tool_result, assistant text, result, idle
  - `live-interrupt.jsonl`: control_response `int-1`, the user "[Request interrupted by user for tool use]" line, a result with `stop_reason: tool_use`, then idle
  - `transcript.jsonl`: two prompts with `promptId`/`uuid`/`timestamp`, an `isSidechain: true` line, `ai-title` twice, plus `attachment`, `queue-operation`, `system` and `cost-state` lines
  - `control-can-use-tool.jsonl`
- Test: `Tests/SlipstreamCoreTests/ClaudeLinesTests.swift`
- Test: `Tests/SlipstreamCoreTests/ClaudeInvocationTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum JSONValue: Codable, Equatable, Sendable { case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue]) }
  public enum AgentLine: Equatable, Sendable {
    case assistant(uuid: String, timestamp: Date?, blocks: [AssistantBlock])
    case user(uuid: String, timestamp: Date?, isPrompt: Bool, blocks: [UserBlock])
    case result(durationMs: Int, isError: Bool, text: String?)
    case controlRequest(requestID: String, subtype: String, input: JSONValue?)
    case title(String)
    case gap
    case ignored
  }
  public enum AssistantBlock: Equatable, Sendable { case text(String), thinking(String), toolUse(id: String, name: String, input: JSONValue) }
  public enum UserBlock: Equatable, Sendable { case text(String), toolResult(toolUseID: String, text: String, isError: Bool) }
  public enum AgentLine { public static func decode(_ line: Data) -> AgentLine }
  public enum ClaudeSessionStart: Equatable, Sendable { case new(UUID), resume(UUID) }
  public enum ClaudeInvocation {
    public static func arguments(model: String, effort: String, session: ClaudeSessionStart) -> [String]
    public static func userMessage(_ text: String) -> Data
    public static func interrupt(requestID: String) -> Data
    public static func reply(requestID: String, subtype: String, input: JSONValue?) -> Data
  }
  ```

  - `userMessage`, `interrupt` and `reply` each return one JSON line ending in `\n`.

- [ ] **Step 1: Write the failing tests**

  `ClaudeLinesTests`, decoding each fixture line:
  - `decodesLiveTurn`: `expectNoDifference` against the expected `[AgentLine]`.
  - `lifecycleLinesAreIgnored`: `system/init`, `session_state_changed` and `control_response` give `.ignored`.
  - `transcriptSkipsSidechainAndBookkeeping`: sidechain and the bookkeeping lines give `.ignored`. The prompt user lines have `isPrompt == true`, and tool_result user lines have `false`.
  - `toolResultContentArrayJoinsTextAndNamesOtherBlocks`: content `[{"type":"text","text":"a"},{"type":"image"}]` gives text `"a\n[image]"`.
  - `supportedTypeThatFailsToDecodeIsGap`: `{"type":"assistant","message":42}` gives `.gap`.
  - `notJSONIsGap`.
  - `malformedControlRequestIsGap`: `{"type":"control_request","request":7}` gives `.gap`.
  - `unknownTypeIsIgnored`.

  `ClaudeInvocationTests`:
  - `argumentsForNewSession`: equals the Global Constraints flag list with `--session-id=<uuid>`, in that order.
  - `argumentsForResume`: same, with `--resume=<uuid>`.
  - `replyAllowsCanUseToolEchoingInput`: the decoded JSON equals spec "Existing contracts" `can_use_tool` envelope.
  - `replyRejectsUnknownSubtype`: the `error` envelope with `"unsupported"`.
  - `interruptLine`: equals the spec's interrupt line with the given id.
- [ ] **Step 2: Run** `swift test --filter Claude`. Expect FAIL.
- [ ] **Step 3: Implement.**
  - Use `Decodable` wire structs, then map to `AgentLine`.
  - `timestamp` is ISO-8601 with fractional seconds.
  - `isPrompt` is "has `promptId` and at least one text block". A stdout user line has no `promptId`, so live lines decode with `isPrompt == false`.
- [ ] **Step 4: Run.** Expect PASS.
- [ ] **Step 5: Commit** `chore: read Claude's stream and transcript lines`.

### Task 3: Transcript projection

**Files:**
- Create: `Sources/SlipstreamCore/TranscriptProjection.swift`
- Test: `Tests/SlipstreamCoreTests/TranscriptProjectionTests.swift`

**Interfaces:**
- Consumes: `AgentLine`, `AssistantBlock`, `UserBlock` (Task 2).
- Produces:

  ```swift
  public enum TurnEnding: Equatable, Sendable { case completed, failed, stopped }
  public enum ToolStatus: Equatable, Sendable { case running, done, failed, stopped }
  public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case userMessage(String), reply(String), thinking(String)
      case toolCall(name: String, target: String?, status: ToolStatus, detail: String?)
      case turnFooter(ending: TurnEnding, duration: Duration, time: Date)
      case gap
    }
    public let id: String
    public var kind: Kind
  }
  public struct TranscriptProjection: Equatable, Sendable {
    public private(set) var items: [TranscriptItem]
    public init()
    public static func history(_ lines: [AgentLine]) -> TranscriptProjection
    public mutating func userSent(_ text: String, id: String)
    public mutating func apply(_ line: AgentLine)
    public mutating func endTurn(_ ending: TurnEnding, duration: Duration, at time: Date, id: String)
    public func replyText(endingAt footerID: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**
  - `liveTurnBuildsRowsInOrder`: `userSent`, then the `live-turn.jsonl` lines, then `endTurn(.completed, .seconds(41), …)`. The kinds are `[userMessage, thinking, toolCall(done, detail: …), reply, reply, turnFooter]`.
  - `toolCallTargetsFromMainInput`: `Edit` + `file_path` `/a/b/File.swift` gives target `"File.swift"`. `Bash` + `command` gives the command. An unknown tool gives target `nil`.
  - `failedToolResultMarksFailed`: `is_error: true` gives `.failed`.
  - `endTurnStopsRunningTools`: a `tool_use` with no result, then `endTurn(.stopped…)`, gives `.stopped`.
  - `interruptMarkerIsNotABubble`: the "[Request interrupted by user" user text adds nothing.
  - `gapAddsGapRow`: `.gap` adds a `.gap` item.
  - `replyTextCollectsTheTurnsReplies`: for a footer, the `.reply` texts between it and the previous footer, joined with `"\n\n"` (Copy).
  - `historyFootersFromTimestamps`: `history(transcript lines)` gives two footers. Each one's `time` is the turn's last timestamp, `duration` is last minus first, and `ending` is `.completed`. A turn containing the interrupt marker ends `.stopped`.
  - `idsAreStable`: applying the same line twice to separate projections gives equal ids. Ids are `uuid#blockIndex`, and a tool call's id is its tool-use id.
- [ ] **Step 2: Run** `swift test --filter TranscriptProjectionTests`. Expect FAIL.
- [ ] **Step 3: Implement.** The verb's tense is a view concern: `ChatPageModel` derives "Running/Ran/Edited" from `name` and `status` (Task 9). `history` splits turns at `user` lines with `isPrompt`.
- [ ] **Step 4: Run** `swift test`. Expect all PASS.
- [ ] **Step 5: Commit** `chore: turn Claude's lines into chat rows`.

---

## PR B — Running the agent (app clients)

### Task 4: Probe and environment client

**Files:**
- Create: `SlipstreamViewer/Dependencies/AgentEnvironmentClient.swift`
- Test: `SlipstreamViewerTests/Dependencies/AgentEnvironmentClientTests.swift`
- Modify: `design/features/chat-console/spec.md` (Open questions: record the probe result)

**Interfaces:**
- Produces:

  ```swift
  struct AgentEnvironment: Equatable, Sendable { var claudePath: String; var variables: [String: String]; var configDirectory: URL }
  enum AgentEnvironmentError: Error, Equatable { case shellTimedOut, claudeNotFound, tooOld(found: String), unreadableVersion }
  struct AgentEnvironmentClient: Sendable { var resolve: @Sendable () async throws -> AgentEnvironment }
  extension AgentEnvironmentError { var message: String }
  static func parseEnvironment(_ output: Data, marker: String) -> [String: String]
  static func isSupported(version: String) -> Bool
  ```

  - `DependencyValues.agentEnvironment`.
  - The live value resolves once and caches the result for the app run. A failure isn't cached, so Try again retries.

- [ ] **Step 1: Manual probe.** Run against a scratch folder, never a real project, and record the answers in spec.md "Open questions". Use the Global Constraints flags and pipe in one user line each:
  - a skill slash command (e.g. `/help`-style or a user skill)
  - `@a.txt`, to check whether the file content was attached
  - Read stdout for an `attachment`/expanded prompt.

  If either doesn't work, change the placeholder copy in `screens.md` and the Global Constraints before PR D.
- [ ] **Step 2: Write the failing tests** (pure helpers only)
  - `parsesEnvAfterMarkerIgnoringChatter`: `"motd\n" + marker + "\0PATH=/a\0CLAUDE_CONFIG_DIR=/c\0"` gives `["PATH": "/a", "CLAUDE_CONFIG_DIR": "/c"]`.
  - `versionFloor`: `"2.1.293 (Claude Code)"` gives true; `"2.1.292 (Claude Code)"` gives false; `"2.2.0"` gives true.
  - `messagesNameTheProblem`: `tooOld(found: "2.1.100")` reads `"Slipstream needs Claude Code 2.1.293 or newer (found 2.1.100)"`, and `claudeNotFound` reads `"Couldn't find claude on your login shell's PATH"`.
- [ ] **Step 3: Run.** Expect FAIL.
- [ ] **Step 4: Implement.**
  - Live: `Process` runs `$SHELL -ilc "printf '\0<marker>\0'; env -0"` with a 10 s deadline (terminate on expiry gives `.shellTimedOut`).
  - Look up `claude` in the parsed `PATH`, then run `claude --version` and check the floor; the version isn't returned.
  - `configDirectory` is `CLAUDE_CONFIG_DIR`, else `~/.claude`.
- [ ] **Step 5: Run.** Expect PASS. **Commit** `chore: find the user's claude and its environment`.

### Task 5: Process client

**Files:**
- Create: `SlipstreamViewer/Dependencies/AgentProcessClient.swift`
- Test: `SlipstreamViewerTests/Dependencies/ProcessIntegrationTests.swift`
- Test fixture: `SlipstreamViewerTests/Support/fake-claude.sh`, which echoes stdin lines as JSON, writes to stderr, and can ignore SIGTERM. Add it as a test resource in `project.yml`.

**Interfaces:**
- Consumes: `JSONLineFramer` (Task 1).
- Produces:

  ```swift
  struct AgentLaunch: Equatable, Sendable { var executable: String; var arguments: [String]; var environment: [String: String]; var directory: String }
  enum AgentProcessEvent: Equatable, Sendable { case line(Data), overflow, exited(status: Int32, stderrTail: String) }
  struct AgentProcessHandle: Sendable {
    var events: AsyncStream<AgentProcessEvent>
    var write: @Sendable (Data) async throws -> Void
    var shutdown: @Sendable () async -> Void
  }
  struct AgentProcessClient: Sendable { var launch: @Sendable (AgentLaunch) async throws -> AgentProcessHandle }
  ```

  - `DependencyValues.agentProcess`.

- [ ] **Step 1: Write the failing tests** (they spawn `/bin/sh fake-claude.sh` only; real-time waits are bounded by `withTimeout` helpers, not sleeps)
  - `echoesWrittenLines`.
  - `exitCarriesStatusAndStderrTail`: the tail is at most 4096 bytes, keeping the end.
  - `shutdownEscalatesToKill`: the fake ignores SIGTERM, and `shutdown()` returns within 3 s + ε with `.exited`.
  - `shutdownKillsChildProcesses`: the fake spawns `sleep 100 &`, and after `shutdown` its pid is gone.
  - `writeAfterExitThrows`.
- [ ] **Step 2: Run** `-only-testing:SlipstreamViewerTests/ProcessIntegrationTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
  - Use `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgid 0) and pipes for stdin, stdout and stderr.
  - Read stdout and stderr on separate `FileHandle.readabilityHandler`s; stderr goes into the 4 KB ring.
  - Writes are serialised in an actor; `EPIPE` throws.
  - `shutdown`: close stdin, `kill(-pgid, SIGTERM)`, wait up to 3 s for `waitpid`, then `kill(-pgid, SIGKILL)` and reap. It is idempotent.
- [ ] **Step 4: Run.** Expect PASS. **Commit** `chore: start and stop agent processes`.

### Task 6: Transcript client

**Files:**
- Create: `SlipstreamViewer/Dependencies/TranscriptClient.swift`
- Test: `SlipstreamViewerTests/Dependencies/TranscriptClientTests.swift`

**Interfaces:**
- Produces:

  ```swift
  enum TranscriptLookup: Equatable, Sendable { case notFound, found([AgentLine]) }
  struct TranscriptClient: Sendable { var load: @Sendable (_ configDirectory: URL, _ sessionID: UUID) async throws -> TranscriptLookup }
  ```

  - Lines are framed with `JSONLineFramer` and decoded with `AgentLine.decode`. `.overflow` becomes `.gap`.
  - `DependencyValues.transcripts`.

- [ ] **Step 1: Write the failing tests** (a temp directory as the config directory)
  - `findsFileInAnyProjectFolder`.
  - `notFoundWhenAbsent`.
  - `unreadableThrows`: file mode `000`; the call throws and does not return `.notFound`.
- [ ] **Step 2: Run.** Expect FAIL.
- [ ] **Step 3: Implement.** Scan `projects/*/` directories for `<id>.jsonl`; this needs no folder-name encoding.
- [ ] **Step 4: Run.** Expect PASS. **Commit** `chore: read a chat's earlier messages`.

---

## PR C — Chat model (app)

### Task 7: Keep each stream's folder

**Files:**
- Modify: `SlipstreamViewer/Models/FeedContent.swift:5` (`SessionOption` gains `var root: String?`)
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift:538-600` (`loadSessions`)
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`

**Interfaces:**
- Produces:
  - `ChangeStreamPageModel.selectedFolder: String?`, the selected stream's normalised root.
  - `static func normalizedFolder(_ root: String) -> String`: `URL(fileURLWithPath:).standardizedFileURL.resolvingSymlinksInPath().path`.

- [ ] **Step 1: Write the failing tests**
  - `selectedFolderComesFromStartRecord`: with the fixture start root `/tmp/project`, `selectedFolder == normalizedFolder("/tmp/project")`.
  - `rootSurvivesRefreshThatFailsStartFetch`: on the second `loadSessions`, `sessionStart` throws, and `selectedFolder` is unchanged.
  - `rootIsNilUntilStartLoads`.
- [ ] **Step 2: Run** `xcodegen generate && xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS' -only-testing:SlipstreamViewerTests/ChangeStreamPageTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
  - Carry `root` from `known` exactly as `agentConnection` is carried.
  - Set `sessions[id:].root` and `selectedSession?.root` beside the label update.
- [ ] **Step 4: Run** the whole `ChangeStreamPageTests` suite (touched-area rule). Expect PASS.
- [ ] **Step 5: Commit** `chore: remember each stream's folder`.

Chat model tests (Tasks 8–11) live in `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift`:
- `@MainActor @Suite(.serialized, .mainSerialExecutor)`, with a `TestClock`.
- Fakes for the three clients in `SlipstreamViewerTests/Support/AgentFake.swift`. Each launch gets a controllable `AsyncStream` continuation, records writes, and counts `shutdown`.
- `withDependencies` sets `agentEnvironment`, `agentProcess`, `transcripts`, `continuousClock`, `uuid` (`.incrementing`) and `date.now`. `@Shared(.chatTabs)` uses swift-sharing's in-memory file system in tests; assert on it directly.

### Task 8: Tabs, workspaces and launching

**Files:**
- Create: `SlipstreamViewer/Models/ChatTabRecord.swift` (`ChatTabRecord`, `ChatEffort`, `ChatModelChoice`, the `.chatTabs` key)
- Create: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift`
- Create: `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift`
- Test: `ChatPageTests.swift`, `SlipstreamViewerTests/Support/AgentFake.swift`

**Interfaces:**
- Consumes: Tasks 2–3 and 4–7.
- Produces:

  ```swift
  struct ChatTabRecord: Codable, Equatable, Identifiable, Sendable { let id: UUID; var folder: String; var model: String; var effort: ChatEffort; var isWaiting: Bool }
  enum ChatEffort: String, Codable, CaseIterable, Sendable { case low, medium, high, xhigh, max }
  struct ChatModelChoice: Equatable, Sendable { let id: String; let name: String; static let all: [ChatModelChoice] }
  extension SharedKey where Self == FileStorageKey<[ChatTabRecord]>.Default { static var chatTabs: Self }
  @MainActor @Observable final class ChatPageModel: ViewModel {
    var tabs: IdentifiedArrayOf<ChatTabModel>
    var folder: String?
    var visibleTabs: [ChatTabModel]
    var selectedTab: ChatTabModel?
    var noWorkspaceText: String?
    func viewAppeared() async
    func workspaceChanged(folder: String?, emptyText: String?)
    func newTabTapped() async
    func tabSelected(_ id: UUID) async
    func closeTabTapped(_ id: UUID) async
    func sendTapped() async
    func isWaiting(folder: String) -> Bool
  }
  @MainActor @Observable final class ChatTabModel: ViewModel, Identifiable {
    var id: UUID { record.id }
    var record: ChatTabRecord
    var title: String
    var projection: TranscriptProjection
    var draft: String
    var errorText: String?
    var isWorking: Bool { activeTurn != nil }
  }
  ```

  - `visibleTabs`, `selectedTab`, `noWorkspaceText` and every flag below are computed, never stored copies.
  - `visibleTabs` are the tabs whose `record.folder == folder`, in `$chatTabs` order.
  - `ChatPageModel` keeps a private selected-tab id per folder, and owns `@Shared(.chatTabs)`; tab models write their record through it.
  - `ChatTabModel.activeTurn` is a private value (start time, Stop pressed, last output time). Send creates it; the turn's single ending consumes it.

- [ ] **Step 1: Write the failing tests**
  - `firstVisitToFolderCreatesNewChat`: `workspaceChanged("/w")` gives one tab titled "New chat", and `$chatTabs` gains a `claude-opus-5-5`/`high` record.
  - `newTabCopiesCurrentChoice`.
  - `noWorkspaceShowsFeedText`: `workspaceChanged(nil, "Choose a capture session to watch its changes")` gives `noWorkspaceText` equal to that string and `visibleTabs` empty.
  - `missingTranscriptStartsNewSession`: on the first send, the launch arguments contain `--session-id=<id>`.
  - `foundTranscriptResumesAndShowsHistory`: on selection after launch, the history items are shown and the first send uses `--resume=<id>`.
  - `unreadableTranscriptShowsErrorAndDoesNotLaunch`.
  - `sendAddsBubbleWritesLineAndClearsWaiting`: the record is waiting; after a successful write its `isWaiting` is false.
  - `failedWriteKeepsDraftAndWaiting`.
  - `environmentErrorShowsMessageAndLaunchesNothing`: `tooOld` gives `errorText` equal to the Task 4 message.
  - `closingCurrentSelectsLeftThenRight`.
  - `closingLastTabLeavesFreshNewChat`.
- [ ] **Step 2: Run** `-only-testing:SlipstreamViewerTests/ChatPageTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
  - The process starts lazily on the first send.
  - One `generation` per tab, bumped on every start, shutdown and history load. Every event handler and history result checks it before publishing.
  - `sendTapped` awaits launch (if needed) and the write only. Each process gets one follower task (`for await event in handle.events`), stored on its `ChatTabModel` and cancelled at shutdown; it is the one owned unstructured task per process (spec "Ownership").
- [ ] **Step 4: Run.** Expect PASS. **Commit** `chore: chat tabs that follow the stream folder`.

### Task 9: Turns, waiting and the working line

**Files:** modify `ChatPageModel.swift` and `ChatTabModel.swift`; test `ChatPageTests.swift`.

**Interfaces:**
- Produces:
  - `ChatPageModel.appActivityChanged(isActive: Bool)` and `comparisonVisibilityChanged(isShown: Bool)`.
  - `ChatTabModel.workingText: String?`, e.g. "Working 1m 12s · last output 3s ago".
  - `ChatTabModel.isTitleBold`, `showsSpinner` and `showsStop`.
  - `ChatTabModel.rowText(for: TranscriptItem) -> String`, giving the tool verb in its tense ("Running `x`", "Ran `x`", "Ran `x` · failed", "Edited `File.swift`").
  - `ChatTabModel.footerText(for:)`, giving "41s · 3:09 PM" or "Stopped · 41s · 3:09 PM".
  - `ChatPageModel.clockTask() async`, a 1 s `continuousClock.timer` that drives `now` while any tab works.

- [ ] **Step 1: Write the failing tests**
  - `resultEndsTurnOnce`: `result` then more lines give one footer, `isWorking == false`, and one title re-read (`transcripts.load` called once).
  - `exitBeforeResultFailsOnce`: one `.failed` footer, and `errorText` is "Claude stopped unexpectedly" followed by the stderr tail. The message lives only in `errorText`.
  - `turnEndingOffScreenMarksWaiting`: a turn running on folder A, `workspaceChanged("/b")`, then `result` sets A's record `isWaiting`, and `isWaiting(folder: "/a") == true`. The process was not shut down.
  - `turnEndingOnScreenDoesNotMarkWaiting`.
  - `turnEndingWhileAppInactiveMarksWaiting`.
  - `turnEndingUnderComparisonMarksWaiting`.
  - `selectingWaitingTabKeepsItBold`.
  - `workingLineTicks`:
    1. Advance 72 s, with the last line at 69 s: "Working 1m 12s · last output 3s ago".
    2. Advance 1 s: "Working 1m 13s · last output 4s ago".
  - `staleGenerationLinesIgnored`: lines from a shut-down handle change nothing.
  - `canUseToolIsAnswered`: the written line equals `ClaudeInvocation.reply(requestID:subtype:input:)`.
- [ ] **Step 2: Run.** Expect FAIL.
- [ ] **Step 3: Implement.**
  - The first of `result`, exit or the Stop deadline consumes `activeTurn`; a later one finds it nil and does nothing.
  - Every complete stdout line, including `.ignored` ones, updates last output.
  - On screen means `isAppActive && !isComparisonShown && folder == record.folder && selected tab id == id`.
- [ ] **Step 4: Run.** Expect PASS. **Commit** `chore: follow each turn to its end`.

### Task 10: Stop, Try again and model change

**Files:** modify the model files; test `ChatPageTests.swift`.

**Interfaces:**
- Produces:
  - `ChatPageModel.stopTapped() async`, `tryAgainTapped() async` and `choiceSelected(model: String, effort: ChatEffort) async`.
  - `ChatTabModel.pickerText` ("Opus 5.5 High") and `isPickerEnabled`.

- [ ] **Step 1: Write the failing tests**
  - `stopWritesInterruptAndEndsStopped`: the interrupt line is written, and the next `result` gives a stopped footer.
  - `stopWithoutResultShutsDownAfterTenSeconds`: advance 10 s; `shutdown` count is 1, the ending is stopped, and the next send relaunches with `--resume`.
  - `tryAgainReloadsAndNeverResends`: after a crash, Try again relaunches with `--resume`, reloads history, and the writes contain no user line.
  - `choiceChangeOnIdleTabRestartsWithNewFlags`: the record holds the new choice and the idle process is shut down; the next send has `--model=claude-sonnet-5-5 --effort=low --resume=<id>`.
  - `pickerDisabledWhileWorking`.
- [ ] **Step 2: Run.** Expect FAIL. **Step 3: Implement.** **Step 4: Run.** Expect PASS.
- [ ] **Step 5: Commit** `chore: stop, retry and switch model in a chat`.

### Task 11: Close and quit

**Files:** modify the model files; test `ChatPageTests.swift`.

**Interfaces:**
- Produces:
  - `ChatPageModel.workingTabCount: Int` and `quitAlertText: String?` (nil when 0).
  - `ChatPageModel.quitConfirmed() async`, which shuts every process down and awaits all.

- [ ] **Step 1: Write the failing tests**
  - `closingWorkingTabRemovesRecordThenShutsDown`: the record is gone from `$chatTabs`, `shutdown` count is 1, and late lines from that handle change nothing.
  - `quitAlertTextCountsWorkingTabsInAllFolders`: "Claude is still working in 2 tabs. Quitting stops them. You can pick the conversations up again next time." The singular reads "in 1 tab".
  - `quitConfirmedShutsDownEverything`.
  - `hiddenFolderTabsStillCount`: a tab whose folder no stream reports, while working, counts.
- [ ] **Step 2: Run.** Expect FAIL. **Step 3: Implement.** **Step 4: Run** the full app test suite (touched-area rule). Expect PASS.
- [ ] **Step 5: Commit** `chore: close tabs and quit cleanly`.

---

## PR D — Chat screen

### Task 12: Design tokens

**Files:**
- Modify: `SlipstreamViewer/DesignTokens.swift` (new `DesignTokens.Chat` namespace)

**Steps:**
- [ ] **Step 1:** Copy every colour, font, size, gap, padding and radius used by the zone 11 frames from `exports/screens/main-window--conversation.json`, `--agent-working.json` and `--no-workspace.json` (resolved values), naming each after its pen node name. Reuse existing tokens where the value is identical.
- [ ] **Step 2:** `xcodebuild build`. Expect success. **Commit** `chore: chat design tokens`.

### Task 13: Chat views

**Files:**
- Create: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift` (tab strip, transcript, working line, message box, no-workspace)
- Create: `SlipstreamViewer/Views/Pages/ChatPage/MarkdownText.swift`
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift:121-151`. The placeholder branch becomes `ChatPageView`. The "◧  Activity" button moves into the chat's tab strip when the feed is hidden. Comparison still replaces the area.
- Modify: `ChangeStreamPageModel.swift`:
  - Takes `chat: ChatPageModel` in `init`.
  - Adds `chatEmptyText: String?`: nil when `selectedFolder` is known; `emptyStateText` when no stream is selected; otherwise "Finding this stream's folder…". (`emptyStateText` alone returns nil or "Waiting for changes…" for a selected stream.)
  - Calls `chat.workspaceChanged(folder: selectedFolder, emptyText: chatEmptyText)` whenever either changes.
  - Calls `chat.comparisonVisibilityChanged` when `functionChanges` opens or closes.
  - Picker rows expose `isBold` from `chat.isWaiting(folder:)`.
  - Delete `fileViewerPlaceholderText`.
- Test: `ChangeStreamPageTests.swift`:
  - `selectingStreamTellsChatTheFolder`
  - `chatTextWhileFolderUnknown`
  - `comparisonOpenTellsChat`
  - `pickerRowBoldWhenFolderWaiting`

**Steps:**
- [ ] **Step 1:** Write the four failing page tests, run them, and expect FAIL.
- [ ] **Step 2:** Implement the wiring and run. Expect PASS.
- [ ] **Step 3:** Build the views against screens.md, frame by frame, with every string and decision read from the models.
  - Markdown (closes the spec open question, Claude's call): `MarkdownText` splits fenced code blocks (rendered in Geist Mono) from prose, which goes through `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`. No new dependency. The split function is a pure static on `ChatTabModel` and is tested there (`fencedCodeSplitsFromProse`).
  - The `.task` calls `viewAppeared()` and `clockTask()`.
  - `NSApplication.didBecomeActiveNotification` / `didResignActiveNotification` go to `appActivityChanged`.
- [ ] **Step 4:** Build, and compare against each PNG in screens.md. **Commit** `feature: chat beside the change stream`.

### Task 14: Single window and quit

**Files:**
- Modify: `SlipstreamViewer/App/SlipstreamViewerApp.swift`:
  - `WindowGroup` becomes `Window("Slipstream", id: "main")`.
  - `@State var chat = ChatPageModel()`, passed to `ChangeStreamPageView`.
  - `@NSApplicationDelegateAdaptor`.
- Create: `SlipstreamViewer/App/AppDelegate.swift`:
  - `applicationShouldTerminateAfterLastWindowClosed` returns true.
  - `applicationShouldTerminate`: with `chat.quitAlertText == nil`, it starts `quitConfirmed` and returns `.terminateLater`, replying when done. Otherwise it shows `NSAlert` (message `quitAlertText`, buttons "Quit"/"Cancel"); Quit does `.terminateLater` → `await quitConfirmed()` → `reply(true)`, and Cancel returns `.terminateCancel`.

**Steps:**
- [ ] **Step 1:** Implement, then `xcodebuild test`. The full suite passes.
- [ ] **Step 2: Manual QA** (spec acceptance #15), against a disposable daemon (`npm run qa:daemon` in the daemon repo with `SLIPSTREAM_STORE`) and a scratch git folder:
  1. Send a message.
  2. Stop.
  3. Switch streams mid-turn, and check the waiting bold.
  4. Relaunch and resume, with history shown.
  5. Change model.
  6. Close a working tab, then check `ps` shows no orphan.
  7. ⌘Q mid-turn: test both Cancel and Quit.
  8. Hide the feed, then check the no-workspace text.
- [ ] **Step 3: Commit** `feature: one window that stops its agents on quit`.

---

## Unresolved questions

- ~~`/commands` and `@mentions` passthrough~~: settled by Task 4 Step 1 — both work, the placeholder stays (spec "Open questions").
- A second app copy (`open -n`) and agents left over after an app crash: accepted risks (spec review #2, #6), not built.
