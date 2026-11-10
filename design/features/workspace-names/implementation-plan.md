# Workspace Names Implementation Plan

> **For agentic workers:** this feature spans two repos and two PRs. Drive it with the
> `orchestrate-feature` skill: PR 1 (daemon) merges first, then PR 2 (client) starts from a
> fresh context. Inside each PR, use superpowers:subagent-driven-development or
> superpowers:executing-plans task by task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Every sidebar workspace shows a short, steady name. The agent sets it once the work
is clear, Brian can rename it at any time, and Brian's name always wins.

**Architecture:**
- The daemon stores two names per session in `sessions/<id>/name.json`.
- The agent writes through a new MCP tool, `slipstream_name_workspace`, which calls the
  control verb `name_workspace`.
- The app writes through the control verb `rename_session` and reads both names from
  `GET /v1/sessions`, which it polls every 2 s.
- The app shows `user_name ?? agent_name ?? folder` everywhere it labels a workspace.

**Tech Stack:**
- Daemon: TypeScript on Node ≥ 24, `node:test`.
- Client: Swift 6 with strict concurrency, `@Observable` models, swift-dependencies, Swift
  Testing, CustomDump, XcodeGen.

**Spec:** `design/features/workspace-names/spec.md` in the client repo
(`playola-radio/slipstream-client-swift`). The contracts to implement are in the same folder:
- [models.md](./models.md): the file format, validation and Swift types;
- [endpoints.md](./endpoints.md): the verbs, tool and list field;
- [screens.md](./screens.md): the states and copy.

Read the spec (including its Phase-7 simplicity table) and all three files before starting
either PR. This plan points at them and does not repeat them.

## Base commits

| Repo | Branch | SHA |
|---|---|---|
| Daemon `playola-radio/slipstream` (`~/playola/slipstream`) | `develop` | `4117951` |
| Client `playola-radio/slipstream-client-swift` | `develop` | `6de9526` (no app-code change since the design base `3f49250`) |

## Global Constraints

- Both PRs target `develop`, never `main`, and each title starts with `feature:` in plain
  English.
- No `Co-Authored-By` trailers.
- Never point anything at the real `~/.slipstream`. Manual QA uses `SLIPSTREAM_STORE` with a
  disposable daemon (`npm run qa:daemon` in the daemon repo). Never print or persist the
  daemon bearer token.
- Names: at most 64 UTF-8 bytes after ECMAScript trim. No C0/C1 controls, U+2028 or U+2029,
  checked before the trim. No normalization. The 2–5 word target is guidance only.
- Wire keys are exactly `naming`, `agent_name`, `user_name`, `replace_existing` and
  `changed`. The only new error code is `INVALID_NAME`. No new `attach_features` value.
- The app polls `GET /v1/sessions` every **2 s**, only while the window is shown and the app
  is active.
- Client: Swift 6, complete strict concurrency, warnings are errors. No logic in views. Use
  `pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump` and
  `pfw-modern-swiftui` before writing Swift. Never `Task.sleep` in tests; use `TestClock`
  with `.mainSerialExecutor`.
- Changelog: the client adds `changelog.d/workspace-names.md` (format in
  `changelog.d/README.md`) and never edits `CHANGELOG.md`. The daemon repo has no changelog.

**UI copy, verbatim:**

| Where | Copy |
|---|---|
| Menu items | "Rename…", "Use agent's name", "Archive" |
| Tooltip, no history | "Can be named once work starts here." |
| Tooltip, older daemon | "This version of the Slipstream daemon can't rename workspaces." |
| Dialog title | "Rename workspace" |
| Dialog helper | "Only changes the name shown in Slipstream. The folder and branch stay the same." |
| Name too long | "That name is too long. Shorten it to save." |
| Invalid characters | "Names can't contain line breaks or special characters." |
| Save failed, no reply | "Couldn't confirm the name was saved. Slipstream didn't reply." + block `OUTCOME_UNKNOWN: the rename was sent but no valid reply came back` |
| Save failed, can't connect | "Couldn't reach Slipstream, so the name wasn't saved." + block `DAEMON_UNAVAILABLE: couldn't connect to Slipstream's control socket` |
| Save failed, refused | "Slipstream refused the rename." + block `<CODE>: <daemon message>` |
| Workspace gone | "This workspace was deleted, so it can't be renamed." |
| Clear-failure alert title | "Couldn't switch back to the agent's name" (message: the raw error block text; buttons "OK" and "Copy error") |

**Tool copy, verbatim:**
- `slipstream_name_workspace` description and schema: [endpoints.md](./endpoints.md).
- Success texts: "Agent name saved." and "An agent name was already set; kept it."
- `slipstream_begin_task` description suffix: "Once you know what this workspace's work is
  about, also call slipstream_name_workspace with a 2-5 word name — usually on your first
  task."

## Review Focus

1. **Brian is typing in the dialog when a poll lands with a new agent name.** The draft must
   not change. Test: C5 `pollDoesNotChangeDraft`.
2. **The agent calls `slipstream_name_workspace` on every task.** Without `replace_existing`
   the name must stay put and reply `changed: false`. Test: D5 `secondNameKeepsFirst`.
3. **The app is in the background for hours.** No `/v1/sessions` traffic should happen, and
   coming back must refresh at once. Test: C4 `noPollWhileInactive` and
   `reactivationRefreshesImmediately`.
4. **The daemon is restarted mid-rename.** The dialog shows Save failed and the row
   self-corrects on the next successful poll; there is no resend. Test: C5
   `outcomeUnknownShowsSaveFailedAndRefreshes`.
5. **A capture-only row, an older daemon, or a bad `naming` value.** Rename is disabled with
   the right tooltip, and the list still loads. Test: C3 `renameDisabledReasons` and C1
   `malformedNamingIsNilAndListDecodes`.

---

# PR 1 — Daemon (`~/playola/slipstream`)

- Branch `briankeane/workspace-names` from `develop` at `4117951` or later.
- Checks for every task: `npm run typecheck && npm test`. Before the PR, also run
  `npm run test:tools && npm run check:package`. There is no lint script.
- Daemon logs use `console.error('slipstream daemon: …')`.

## Task D1: Name validation

**Files:**
- Create: `src/workspace-name.ts`
- Test: `src/workspace-name.test.ts`

**Interfaces:**
- Produces:
  ```ts
  type NameReason = 'not_string' | 'ill_formed' | 'control_character' | 'empty' | 'too_long'
  validateName(input: unknown): { ok: true; name: string } | { ok: false; reason: NameReason; message: string }
  ```

- [ ] **Write the failing test** `validateName: every case matches`. It is one inline table
  of `{ input, stored }` or `{ input, reason }` rows, with at least one row per rule in
  [models.md](./models.md#session-name-file-sessionsidnamejson--new):
  - a number and `null` (`not_string`);
  - a lone surrogate `'\ud800'` (`ill_formed`);
  - a tab, `\n`, U+0085 and U+2028 (`control_character`);
  - `'  Fix login  '` → `'Fix login'`, and `'　Fix　'` → `'Fix'`;
  - `''` and `'   '` (`empty`);
  - 64 ASCII bytes (valid), 65 bytes (`too_long`);
  - 16 × `'🙂'` (64 bytes, valid) and 17 × `'🙂'` (`too_long`).
- [ ] **Run it.** `node --test src/workspace-name.test.ts` should FAIL because the module is
  missing.
- [ ] **Implement `validateName`.** Run the checks in models.md order. Use
  `String.prototype.isWellFormed`, a regex over `[\u0000-\u001f\u007f-\u009f\u2028\u2029]`,
  `.trim()` and `Buffer.byteLength(s, 'utf8') > 64`. The `message` names the failed rule in
  plain English. It becomes the `INVALID_NAME` message.
- [ ] **Run it.** It should PASS. Then commit: `feat: validate workspace names`.

## Task D2: The `name.json` file — read, crash-safe write, history cleanup

**Files:**
- Create: `src/session-name.ts`
- Modify:
  - `src/maintenance.ts:30` (`HISTORY_FILES`)
  - `src/store-reader.ts` (export a `namePath` beside `tombstonePath` at :30)
- Test:
  - `src/session-name.test.ts`
  - `src/maintenance.test.ts` (the "history removal" describe at :73)

**Interfaces:**
- Uses `FILE_MODE`, `StorageError`, `writeAll` and `fsyncDir` from `src/storage.ts`.
- Produces:
  ```ts
  interface Naming { agent_name: string | null; user_name: string | null }
  namePath(storeDir: string, id: string): string                       // sessions/<id>/name.json
  readNaming(storeDir: string, id: string): Promise<{ naming: Naming; malformed?: string }>
  writeNaming(storeDir: string, id: string, naming: Naming, assertOwnership: () => void): Promise<void>
  ```
  - `readNaming` returns both `null` on ENOENT.
  - It returns both `null` plus a `malformed` reason on bad JSON, `version !== 1`, a missing
    key, or a value that is neither `null` nor a string. It does not re-validate names.
  - Any other I/O error throws.
  - `writeNaming` follows `publishTombstone` (`src/maintenance.ts:55-79`) step for step, with
    one addition: it calls `assertOwnership()` after the temp file's `sync()` and immediately
    before `rename`, with no await in between.
  - If `assertOwnership()` throws, `writeNaming` removes the temp file and rethrows
    unchanged.
  - The written body is `{"version":1,"agent_name":…,"user_name":…}`.
  - It never creates the directory: a missing directory fails `open` with a
    `StorageError`.
  - The parameter is named `assertOwnership`, like the existing `CaptureSession` seams in
    `src/session.ts:121`.

- [ ] **Write failing tests** in `session-name.test.ts`, using `withTempDir` from
  `src/test/helpers.ts`:
  - `missing file reads as two nulls`;
  - `round-trips both fields`;
  - `malformed file reads as nulls with a reason`, for each of: bad JSON, version 2, a
    missing key, and a numeric value;
  - `assertOwnership throwing leaves no name.json and no temp file`, where the directory
    listing equals what it was before;
  - `write into a missing session directory throws StorageError`;
  - `file mode is 0600`.
- [ ] **Add a test to `maintenance.test.ts`:** `removeSessionHistory also removes name.json`.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.** Add `'name.json'` to `HISTORY_FILES`, add `namePath`, and create
  `session-name.ts`.
- [ ] **Run them.** They should PASS. Then commit:
  `feat: store workspace names beside each session`.

## Task D3: `naming` on `GET /v1/sessions`

**Files:**
- Modify: `src/http-reader.ts:174-195`
- Test: `src/http-reader.test.ts` (the `describe('http-reader core')` at :50)

**Interfaces:**
- Consumes `readNaming` (D2).
- Produces: every list item gains `naming: { agent_name, user_name }`, as in
  [endpoints.md § GET /v1/sessions](./endpoints.md#get-v1sessions).

- [ ] **Write failing tests:**
  - `lists naming for each session`: one named and one unnamed session give
    `naming: {agent_name, user_name}` and `{agent_name:null, user_name:null}`;
  - `removed session reports null naming without reading the file`: a tombstoned session
    with a `name.json` present still reports nulls;
  - `malformed name.json leaves the rest of the list intact and warns once`:
    - capture `console.error` (save and restore it);
    - call the endpoint twice;
    - expect one warning that names the session id, the bad session's naming as nulls, and
      a 200 status.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
  - For non-removed sessions, `Promise.all` the `readNaming` calls.
  - Keep a reader-scoped `Set<string>` of session ids already warned about, so a malformed
    file logs once per reader lifetime.
  - The warning is `console.error('slipstream reader: name.json for <id> is malformed (<reason>); showing no name')`.
- [ ] **Run them.** They should PASS. Then commit:
  `feat: report workspace names in the session list`.

## Task D4: Metadata lock, teardown drain, and `rename_session`

**Files:**
- Modify `src/daemon.ts`:
  - state near :395-400;
  - `doTeardown` :430-477;
  - the dispatch switch :2069-2083;
  - the header verb list :50-56.
- Modify `src/control-protocol.ts`:
  - the header verb list :3-5;
  - add `INVALID_NAME` to `ControlErrorCode` :27-55, with a doc line in :17-26.
- Test: `src/daemon.test.ts` (inside `describe('daemon control verbs')`, using the local
  `withDaemon` and `controlCall`).

**Interfaces:**
- Consumes `validateName`, `readNaming`, `writeNaming`, `readTombstone` and
  `sessionExists`.
- Produces, inside `startDaemon`:
  - `let metadataTail: Promise<void> = Promise.resolve()`;
  - `withMetadataLock<T>(fn: () => Promise<T>): Promise<T>`, which chains onto
    `metadataTail` and never breaks the chain on rejection;
  - the handler `renameSession(req): Promise<Record<string, unknown> | ErrorFields>`.
- Produces on the wire: `rename_session`, exactly as in
  [endpoints.md § CONTROL rename_session](./endpoints.md#control-rename_session). It replies
  `{}`.

**Decisions:**
- **Teardown:** `doTeardown` adds `await metadataTail` after the per-capture inflight drain
  (:455) and before `reader.close()`.
- **Publication check** (the `assertOwnership` passed to `writeNaming`): throw
  `QuestionError('STORAGE_UNAVAILABLE')` if `compromised || torn`. It is the only teardown
  check; the lock adds none of its own.
- **Not in maintenance:** it is not routed through `runMaintenance` and never touches a
  capture.
- **Read before write:** `writeNaming` starts from `readNaming`'s result, so a malformed
  file becomes two nulls and is replaced. Log the repair once with `console.error`.

- [ ] **Write failing tests:**
  - `rename_session sets user_name and keeps agent_name`:
    - pre-write `name.json` with an agent name;
    - call the verb;
    - read the file and expect both fields.
  - `rename_session null clears user_name`.
  - `rename_session requires the name key`: omitting it gives `PROTOCOL`.
  - `rename_session rejects a non-UUID id with PROTOCOL`.
  - `rename_session rejects an invalid name with INVALID_NAME`.
  - `rename_session on an unknown or deleted session is SESSION_NOT_FOUND`: cover both a
    missing directory and a tombstoned one.
  - `rename_session works on a stopped (archived) session`.
  - `rename_session replaces a malformed name.json`.
  - `concurrent renames serialize`: fire two without awaiting; the final file holds the
    second.
  - `teardown waits for a queued rename`:
    - hold the write with a gate in the test;
    - start teardown;
    - expect the store lock to be released only after the rename settles.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
  - The handler runs the checks in endpoints.md order.
  - Validation errors come before taking the lock.
- [ ] **Run them.** They should PASS. Then commit:
  `feat: let the app rename a workspace`.

## Task D5: `name_workspace` control verb

**Files:**
- Modify: `src/daemon.ts` (a new handler beside `beginTask` at :1651, a shared admission
  helper, and the dispatch switch)
- Test: `src/daemon.test.ts`. Use `linkChat`, `linkRecording` and `chatOf` from
  `src/test/daemon-harness.ts`, as the existing begin_task tests do.

**Interfaces:**
- Consumes:
  - `withMetadataLock` (D4);
  - `bindingAtEntry`, `captureForChat`, `liveCaptureAt`, `chatTarget`, `staleBinding` and
    `track`;
  - `WATCH_ONLY_MESSAGE` and `SETUP_PENDING_MESSAGE`.
- Produces:
  - `admitChat(req, worktree, atEntry): { c: Capture; b: Binding } | ErrorFields`. This is the
    synchronous body of `beginTask` from `if (compromised || torn)` through the
    `b.check.state` check (:1667-1680), moved unchanged. `beginTask` calls it.
  - The handler `nameWorkspace(req)` and the `name_workspace` wire verb, as in
    [endpoints.md § CONTROL name_workspace](./endpoints.md#control-name_workspace). It replies
    `{ changed }`.

**Decisions:**
- **No await between admission and `track`.** Each handler validates its own input,
  captures `bindingAtEntry`, awaits the realpath, then calls `admitChat` and `track` with no
  await in between.
- **Admission:** `track(c, withMetadataLock(…), r => ({ changed: r.changed }))`.
  `controlFailure` already passes `QuestionError` codes through.
- **Publication check:** `compromised || torn || c.activation?.lost` throws
  `QuestionError('STORAGE_UNAVAILABLE')`. No binding re-check: the write targets
  `c.session!.sessionId`, the session linked at entry.
- **Inside the lock:** skip the write with `changed: false` when an agent name is set and
  `replace_existing !== true`, or when it already equals the trimmed name.

- [ ] **Write failing tests:**
  - `name_workspace sets agent_name once`: the first call gives `changed: true`;
  - `secondNameKeepsFirst`: a second call without `replace_existing` gives
    `changed: false` and the file is unchanged;
  - `replace_existing replaces; same name is changed:false`;
  - `name_workspace never touches user_name`;
  - `interleaved name_workspace and rename_session keep both fields`;
  - `non-boolean replace_existing is PROTOCOL`;
  - `store lock loss before publication publishes nothing`:
    - trigger `onCompromised` through the harness the existing lock-loss tests use;
    - expect `STORAGE_UNAVAILABLE`;
  - `unlink drains an in-flight name`: `stopForMaintenance` waits for it.

  The existing begin_task tests cover `admitChat`'s link and watch-only errors; they must
  still pass unchanged.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
- [ ] **Run them.** They should PASS. Commit:
  `feat: let the linked agent name its workspace`.

## Task D6: `slipstream_name_workspace` MCP tool

**Files:**
- Create: `src/name-forwarder.ts`
- Modify:
  - `src/mcp-forwarder.ts`:
    - add `NAME_WORKSPACE_TOOL` after :58;
    - append the description suffix to `BEGIN_TASK_TOOL.description` (:29-42);
    - set `tools` at :87;
    - turn the `callTool` ternary (:92-100) into a `switch` on `name`;
    - update the header comment at :12;
  - `tools/package-check.ts:236`;
  - `tools/package-check.test.ts:58`;
  - `docs/mcp-forwarder-config.md:15` (the tool list).
- Test:
  - `src/name-forwarder.test.ts`;
  - `src/mcp-forwarder.test.ts:150-155` (the tool-name list).

**Interfaces:**
- Produces:
  ```ts
  interface ForwardNameDeps { identity: IdentityResult; name: unknown; replaceExisting: unknown | undefined; send: (r: RequestEnvelope) => Promise<ResponseEnvelope> }
  forwardNameWorkspace(deps: ForwardNameDeps): Promise<ToolResult>
  ```
- Add `rawArg(params, key): unknown | undefined` in `mcp-forwarder.ts`, which returns the
  argument value untouched. Pass `name` as `rawArg(params,'name')` and `replace_existing`
  only when the key is present, so the daemon validates both.

**Decisions:**
- **Shape:** model it on `src/answer-forwarder.ts`, but with **one send and no resend**.
- **Errors:**
  - `OutcomeUnknownError` gives `failure('OUTCOME_UNKNOWN', 'the name was sent but whether it was saved could not be confirmed')`;
  - `ok:false` gives `failure(code, message)`;
  - an `ok:true` reply without a boolean `changed` is treated as `OUTCOME_UNKNOWN`.
- **`failure` helper:** keep it local, as `answer-forwarder.ts` does.

- [ ] **Write failing tests**, using a fake `send`:
  - `success text depends on changed`;
  - `structured result is {changed}`;
  - `daemon error passes through as {code}`;
  - `lost reply is OUTCOME_UNKNOWN and sends exactly once`;
  - `malformed ack is OUTCOME_UNKNOWN`;
  - `replace_existing "true" is forwarded raw` (the envelope holds the string);
  - `absent replace_existing is omitted from the envelope`;
  - `unresolved identity never sends`.
- [ ] **Extend the tool-list tests:**
  - in `mcp-forwarder.test.ts`, the tool list includes `slipstream_name_workspace`, and
    begin_task's description ends with the verbatim suffix;
  - update the two package-check name lists.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
- [ ] **Run them.** They should PASS. Run `npm run test:tools && npm run check:package`.
  Commit: `feat: give agents a tool to name their workspace`.

## Task D7: Docs and contract

**Files:**
- Modify:
  - `docs/ask-agent/contract.md`: add `## Workspace names` after `## Agent readiness` (:528),
    and add `naming` next to `agent_connection` at :557;
  - `SKILL.md`: under `## How to use it`;
  - `README.md`: `## Connect an agent chat` (:124) and the `/v1/sessions` row (:347).

- [ ] **Copy the contracts into `contract.md`.** Bring over the `name_workspace`,
  `rename_session`, tool and `naming` contracts from [endpoints.md](./endpoints.md) and the
  `name.json` rules from [models.md](./models.md).
- [ ] **Add the naming rule to `SKILL.md` and the README:** name the workspace once, on the
  first task, in 2–5 words; replace it only if the work changes direction; don't rename per
  task.
- [ ] **Commit** with `docs: describe workspace naming`. Then open PR 1 per the global
  rules.

---

# PR 2 — Client (`slipstream-client-swift`)

- Start only after PR 1 is merged.
- Branch `briankeane/workspace-names` from `develop`.
- Checks for every task:
  - `swift test` for Core;
  - `xcodegen generate && xcodebuild -scheme SlipstreamViewer -destination 'platform=macOS' test -skipPackagePluginValidation`
    for the app.
- There is no lint tool. Warnings are errors.

## Task C1: Decode `naming` (Core)

**Files:**
- Modify: `Sources/SlipstreamCore/DaemonTransport.swift`:
  - `SessionSummary` :3-34;
  - add a `SessionNaming` struct in the same file.
- Test: `Tests/SlipstreamCoreTests/DecodingTests.swift`. Add a `SessionNamingDecodingTests`
  suite beside `AgentConnectionDecodingTests` (:144), reusing the shape of its `summary(_:)`
  helper.

**Interfaces:**
- Produces:
  ```swift
  public struct SessionNaming: Equatable, Sendable, Decodable {
    public var agentName: String?
    public var userName: String?
    public init(agentName: String? = nil, userName: String? = nil)
  }
  ```
  - It uses synthesized decoding, with `CodingKeys` `agent_name` and `user_name`.
  - `SessionSummary` gains `public var naming: SessionNaming?`, and the memberwise init gains
    a trailing `naming: SessionNaming? = nil`. 96 call sites rely on that default.
  - In `init(from:)`:
    `naming = (try? container.decodeIfPresent(SessionNaming.self, forKey: .naming)) ?? nil`.

- [ ] **Write failing tests:**
  - `absentNamingIsNil`;
  - `bothNullDecodes`, which gives `SessionNaming()`;
  - `bothSetDecodes`;
  - `malformedNamingIsNilAndListDecodes`: a list whose `naming` is a string still decodes,
    with that item's `naming == nil`.
- [ ] **Run them.** `swift test --filter SessionNamingDecodingTests` should FAIL.
- [ ] **Implement.**
- [ ] **Run them.** They should PASS. Commit: `feat: read workspace names from the daemon`.

## Task C2: `rename_session` on `ControlTransport` (Core)

**Files:**
- Modify: `Sources/SlipstreamCore/ControlTransport.swift`. Put the verb with the others at
  :15-39 and a private request type beside `PauseRequest` at :142.
- Test: `Tests/SlipstreamCoreTests/ControlTransportTests.swift`, using the
  `exchange(reply:expecting:_:)` helper at :216.

**Interfaces:**
- Produces:
  `public func renameSession(sessionID: String, name: String?) async throws` on
  `ControlTransport`.
  - The request has a custom `encode(to:)` that calls `container.encode(name, forKey: .name)`,
    so a `nil` name is written as JSON `null`.
  - The reply goes through `ControlReply.check`, as `pause` does at :37-39.

- [ ] **Write failing tests:**
  - `renameSendsNameAndSessionID`: expects
    `{"v":1,"verb":"rename_session","session_id":"…","name":"Fix login"}`;
  - `clearSendsExplicitNull`: expects `"name":null`;
  - `sessionNotFoundIsRejected`: expects `QuestionError.rejected(code: "SESSION_NOT_FOUND", …)`.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
- [ ] **Run them.** They should PASS. Commit: `feat: send workspace renames to the daemon`.

## Task C3: One name resolver, every label surface, both snapshots

**Files:**
- Modify:
  - `SlipstreamViewer/Models/FeedContent.swift:5-12` (`SessionOption`);
  - `SlipstreamViewer/Models/WorkspaceSidebar.swift:48-50` (`rowName`);
  - `ChangeStreamPageModel.swift`:
    - :1044-1068 (build);
    - :1095-1107 (selected patch);
    - :1129-1140 and :1563-1572 (`sessionLabels`, deleted);
    - :572 (queued notice);
    - :503-515 and :1245-1248 (child page inits);
  - `InstantAskModel.swift`: `InstantQuestion` :10, and `AskFailure.noChat` :52-56;
  - `AskAgentPageModel.swift:193` and `QuestionThreadPageModel.swift:342`.
- Test:
  - `SlipstreamViewerTests/Models/WorkspaceSidebarTests.swift`;
  - `ChangeStreamPageTests.swift`;
  - `InstantAskModelTests.swift`.

**Interfaces:**
- Consumes `SessionNaming` (C1).
- Produces:
  - `SessionOption.naming: SessionNaming? = nil`.
  - `SidebarGroup.rowName(_:)` returns
    `session.naming?.userName ?? session.naming?.agentName ?? <today's folder value>`.
  - On `ChangeStreamPageModel`:
    - `renameDisabledReason(_ session: SessionOption) -> String?`. It returns `nil` when
      `hasHistory && naming != nil`. Otherwise it returns the no-history tooltip when
      `!hasHistory`, else the older-daemon tooltip.
    - `isUseAgentNameEnabled(_:) -> Bool`, which is `naming?.userName != nil`.
  - `InstantQuestion` carries `sessionID: String`, not a cached workspace name, and
    `AskFailure.noChat(folder:)` becomes `noChat(sessionID:)`. Its display text resolves that
    id through the parent-supplied `workspaceName(for:)` resolver. The copy is unchanged apart
    from the substituted name.
  - `AskAgentPageModel` and `QuestionThreadPageModel` take the stable `sessionID` and the
    read-only `workspaceName(for:)` resolver at init. `ChangeStreamPageModel` supplies a
    resolver over its current sessions/selected-session snapshots, using `rowName`.

**Decisions:**
- **One publication step.** Where `sessions` is rebuilt (:1050), set
  `naming: summary.naming`. In the selected-session patch (:1095-1107), add
  `selectedSession?.naming = listed.naming` unconditionally. The two snapshots must never
  disagree.
- **Labels.** Delete `sessionLabels` and the loop that applies it. A listed session's
  `label` stays its id, which `rowName` only shows while the folder is still unknown. The
  queued notice and no-chat question keep the session id and resolve it through `rowName` at
  display time, so a poll changes every visible name together.
- **Unchanged.** `RecordingControlsModel` and `TerminalTabModel` keep the folder name.

- [ ] **Write failing tests:**
  - in `WorkspaceSidebarTests`, `rowNamePrefersUserThenAgentThenFolder`, as a 4-row table
    test;
  - in `ChangeStreamPageTests`:
    - `namesUpdateRowAndBreadcrumbTogether`: list a session with an agent name, select it,
      re-list with a user name, reload, then
      `expectNoDifference([model.rowName(model.sessions[0]), model.breadcrumbWorkspaceText], [user, user])`;
    - `queuedNoticeUsesLatestNameAfterPoll`;
    - `renameDisabledReasons`, covering three rows: named, capture-only and `naming == nil`;
    - `useAgentNameEnabledOnlyWithUserName`;
  - in `InstantAskModelTests`, `noChatCopyUsesLatestWorkspaceNameAfterPoll`.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.** Then fix every existing test that constructs these types or asserts on
  the deleted timestamp labels.
- [ ] **Run them.** The whole app suite should PASS. Commit:
  `feat: show each workspace's name wherever the app labels it`.

## Task C4: 2 s poll with start records fetched once

**Files:**
- Modify:
  - `ChangeStreamPageModel.swift`: the start-record fan-out at :1121-1145, and a new poll
    method;
  - `ChatPageModel.swift:35` (`isAppActive` becomes `private(set)`);
  - `ChangeStreamPageView.swift` (one `.task(id:)`).
- Test: `ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes the existing coalescing `reloadSessions()` (:1015-1026), the existing
  `appBecameActive()` reload (:651-655), and `chat.isAppActive`, which the view already
  feeds through `chat.appActivityChanged`.
- Produces on `ChangeStreamPageModel`:
  - `var isSessionPollRunning: Bool { isShown && chat.isAppActive }`;
  - `func sessionPollTask() async`. While running, it loops
    `try await clock.sleep(for: .seconds(2))`, then `await reloadSessions()`. It exits on
    cancellation, or when `!isSessionPollRunning`.
  - The view adds `.task(id: model.isSessionPollRunning) { if model.isSessionPollRunning { await model.sessionPollTask() } }`.

**Decisions:**
- **Fetch each start record once.** The task group at :1121 only fetches
  `daemon.sessionStart` for sessions whose `root` is still `nil`. The build step already
  carries a known root forward (:1056). A failed fetch is retried on a later tick.
- **Window visibility.** "Window visible" is approximated by the existing `isShown`, which is
  set in `viewAppeared` and `viewDisappeared`. Nothing in the app tracks occlusion today, and
  this feature doesn't add it.
- **Overlap.** Poll ticks go through `reloadSessions()`, so they coalesce. Other existing
  callers of `loadSessions()` are unchanged; its generation check already keeps stale
  responses from publishing.

- [ ] **Write failing tests**, using `TestClock` with `.mainSerialExecutor`:
  - `pollRefreshesEveryTwoSeconds`:
    - start `sessionPollTask` in a `Task`;
    - `clock.advance(by: .seconds(2))`;
    - `fake.sessionsCallCount` goes up by one;
    - an agent name set in `fake` appears in `rowName`.
  - `noPollWhileInactive`: after the app resigns active, advancing 10 s adds no calls.
  - `reactivationRefreshesImmediately`.
  - `pollFetchesStartRecordsOnce`: across three ticks, `fake.sessionStartCallCount` equals
    the number of sessions.
  - `pollTicksCoalesce`:
    - hold `fake.sessionsGate`;
    - advance 6 s;
    - release;
    - the call count rises by at most two (one in flight plus one coalesced).
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
- [ ] **Run them.** They should PASS. Commit:
  `feat: pick up new workspace names within two seconds`.

## Task C5: Name dependency client and `WorkspaceNamingModel`

**Files:**
- Create:
  - `SlipstreamViewer/Dependencies/WorkspaceNameClient.swift`;
  - `SlipstreamViewer/Models/WorkspaceNamingModel.swift`;
  - `SlipstreamViewerTests/Models/WorkspaceNamingModelTests.swift`.
- Modify:
  - `ChangeStreamPageModel.swift`: own the child, wire its callbacks, and add a menu action;
  - `ChangeStreamPageTests.swift` `makeModel` (:32-58): override `workspaceName`.

**Interfaces:**
- Consumes `ControlTransport.renameSession` (C2), and `rowName` and `renameDisabledReason`
  (C3).
- Produces the client:
  ```swift
  struct WorkspaceNameClient: Sendable { var rename: @Sendable (_ sessionID: String, _ name: String?) async throws -> Void }
  extension DependencyValues { var workspaceName: WorkspaceNameClient }
  ```
  - `liveValue` builds `ControlTransport(store: DescriptorDiscovery.storeURL(...))`, as
    `RecordingClient.swift:11-21` does.
  - `testValue` is `unimplemented("WorkspaceNameClient.rename")`.
- Produces `@MainActor @Observable final class WorkspaceNamingModel: ViewModel`. It owns
  every name mutation.
  - **Dependencies:** `@Dependency(\.workspaceName)` and the existing `@Dependency(\.pasteboard)`.
  - **Callbacks, set by the parent:**
    - `var onWriteFinished: () async -> Void`, which the parent sets to `reloadSessions`;
    - `var onClearFailed: (_ detail: String) -> Void`, which the parent wires to
      `workspaceFailed(title:text:detail:)`.
  - **State:**
    - `private(set) var dialog: Dialog?`, where
      `struct Dialog: Identifiable { let id: String /* session id */; var draft: String; var phase: Phase }`;
    - `private(set) var activeMutation: Mutation?`, where `Mutation` identifies the target
      session and whether the in-flight operation is `.rename` or `.clear`.
    - `enum Phase: Equatable { case editing, saving, saveFailed(headline: String, detail: String), gone, rejected(String) }`.
  - **Display text:** `titleText`, `helperText`, `validationMessage: String?`,
    `failureHeadline: String?`, `failureDetail: String?` (the error block), `primaryButtonTitle`
    ("Rename", or "Try again" after a failed save), and `isRenameEnabled`.
  - **View helpers:**
    - `isSaving`, which disables the field, Cancel and Esc;
    - `isMutationInFlight`, which disables both naming menu actions while a rename or clear
      is in flight;
    - `isCloseOnly`, true for `.gone`.
  - **User actions:**
    - `renameTapped(sessionID:currentName:)` opens the dialog with
      `draft = currentName`. The draft is set once and never touched by polls.
    - `draftChanged(_:)`.
    - `renameConfirmed() async`.
    - `cancelTapped()` and `closeTapped()`.
    - `useAgentNameTapped(sessionID:) async`.
    - `copyErrorTapped()`, which copies `failureDetail` with `pasteboard.copy`.

**Decisions:**
- **Live validation.** A private static check in the model drives `validationMessage` and
  `isRenameEnabled`.
  - Reject any unicode scalar in U+0000–U+001F, U+007F–U+009F, U+2028 or U+2029, checked
    before trimming.
  - Trim with `CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))`.
  - Too long when `trimmed.utf8.count > 64`.
  - Empty shows no message and disables Rename. Too long and control characters show the
    screens.md copy. The trimmed draft is what gets sent.
- **Mutation serialization and stale completions.** Starting either action records
  `activeMutation`; attempts to start another Rename or Use agent's name while it is non-nil
  do nothing. A completion clears it only when it still identifies that operation. A rename
  completion changes `dialog` only if `dialog?.id` is still the session it was sent for. It
  always calls `onWriteFinished`: the refresh is harmless and shows a write that did land.
- **Outcome mapping.** Every outcome calls `onWriteFinished` after the write.
  - Success closes the dialog.
  - `.rejected("SESSION_NOT_FOUND", _)` gives `.gone`.
  - `.rejected("INVALID_NAME", message)` gives `.rejected(message)`.
  - Any other error gives `.saveFailed(headline:detail:)`, with the headline and block text
    from the UI copy table.
  - One private `static func errorDetail(_ error: any Error) -> String` builds the block:
    `.rejected(code, message)` → `"\(code): \(message)"`; `.outcomeUnknown` and `.unavailable`
    → the fixed `OUTCOME_UNKNOWN: …` and `DAEMON_UNAVAILABLE: …` lines; anything else →
    `String(describing: error)`. The clear-failure alert uses the same function.
- **Use agent's name.** The clear remains `activeMutation` until its request and
  `onWriteFinished` complete; any failure calls `onClearFailed(errorDetail(error))`. The parent
  extends its existing alert: `workspaceFailed(title:text:)` gains an optional
  `detail: String?` (stored as `workspaceFailureDetail`), the alert's message shows it, and a
  "Copy error" button appears only when it is non-nil. Existing callers pass nil and are
  unchanged.

- [ ] **Write failing tests**, using a fake client that records calls and can hold or fail:
  - `opensWithCurrentName`;
  - `emptyDisablesRename`;
  - `tooLongShowsMessage`, at 65 bytes, with 64 bytes of `"🙂"` still enabled;
  - `controlCharacterShowsMessage`, covering a newline and U+2028;
  - `sendsTrimmedName`;
  - `savingDisablesFieldAndCancel`;
  - `successClosesAndRefreshes`;
  - `outcomeUnknownShowsSaveFailedAndRefreshes`, where the primary button reads "Try again"
    and there is no automatic second send;
  - `saveFailedShowsHeadlineAndRawError`, a table over `.outcomeUnknown`, `.unavailable` and
    `.rejected("STORAGE_UNAVAILABLE", "store lock lost")`, asserting
    `[failureHeadline, failureDetail]` with `expectNoDifference`;
  - `copyErrorCopiesDetail`, where the fake pasteboard receives exactly `failureDetail`;
  - `sessionNotFoundShowsGone`;
  - `invalidNameShowsDaemonMessage`;
  - `useAgentNameSendsNull`;
  - `clearBlocksSubsequentRename`: hold a clear, verify Rename and a second clear do not send,
    then release it and verify Rename can send;
  - `useAgentNameFailureRaisesAlert`, whose alert detail is
    `"STORAGE_UNAVAILABLE: store lock lost"` for that rejection, and whose
    `copyWorkspaceFailureTapped()` copies that detail to the fake pasteboard.

  In `ChangeStreamPageTests`, add `pollDoesNotChangeDraft`: open the dialog, change the
  agent name in `fake`, advance the clock by 2 s, and the draft is unchanged.
- [ ] **Run them.** They should FAIL.
- [ ] **Implement.**
- [ ] **Run them.** They should PASS. Commit:
  `feat: rename a workspace or go back to the agent's name`.

## Task C6: Menu, dialog view, changelog

**Files:**
- Create:
  - `SlipstreamViewer/Views/Pages/ChangeStreamPage/RenameWorkspaceSheetView.swift`;
  - `changelog.d/workspace-names.md`.
- Modify:
  - `WorkspaceSidebarView.swift`: add `.contextMenu` on the row at :143-205;
  - `ChangeStreamPageView.swift`: add `.sheet(item:)` bound to `model.naming.dialog`.

**Interfaces:**
- Consumes everything on `WorkspaceNamingModel` and the C3 helpers. It adds no logic.

**Decisions:**
- **The context menu.** It has three items, each with an SF Symbol:
  - "Rename…" (`pencil`), with `.disabled(reason != nil)` and `.help(reason ?? "")`;
  - "Use agent's name" (`arrow.uturn.backward`), disabled unless enabled by the model;
  - a `Divider()`, then "Archive" (`archivebox`) only when `isArchivable`, calling the
    existing `archiveTapped`.
- **If tooltips don't show.** If `.help` on a disabled context-menu item shows no tooltip on
  the deployment macOS, keep the item disabled and note it in the PR. Do not add inline
  copy; Brian rejected that.
- **The sheet.** It shows the title, the helper text and a `TextField` that opens with its
  text selected and submits on Return. Use `.onExitCommand` for Esc, disabled while saving.
  Buttons are "Cancel" (or "Close" alone when the workspace is gone) and the primary button.
  It uses `DesignTokens` only; the visual reference is the screen C frames in `screens.md`.
  When `failureDetail` is set, show `failureHeadline`, then the detail in a Geist Mono block
  with `.textSelection(.enabled)` and a "Copy" button calling `copyErrorTapped()`.
- **The alert.** In `ChangeStreamPageView`'s existing `.alert`, add a "Copy error" button when
  `model.workspaceFailureDetail` is non-nil. It calls a new
  `ChangeStreamPageModel.copyWorkspaceFailureTapped()`, which copies the detail with the
  existing `pasteboard` dependency (tested in C5 by `useAgentNameFailureRaisesAlert`).
- **Changelog.** One `### Changes` bullet:
  "Workspaces in the sidebar now show a short name for what they're about. The agent names
  each one, and you can rename it from the right-click menu. Needs an up-to-date Slipstream
  daemon."

- [ ] **Build.** Run `xcodegen generate` and the app build and tests. They should PASS.
- [ ] **Manual QA** with a disposable daemon. Run `npm run qa:daemon` and set
  `SLIPSTREAM_STORE` to its store. Never use `~/.slipstream`. Then check:
  - right-click shows the menu;
  - Rename opens with the current name fully selected, saves, and the row updates;
  - "Use agent's name" reverts;
  - an agent `slipstream_name_workspace` call shows up within about 2 s;
  - a capture-only row has Rename disabled, with the tooltip.

  Screenshot each state against screens.md.
- [ ] **Commit** with `feat: add the rename menu and dialog`, then open PR 2 per the global
  rules.

---

## Spec coverage

| Spec item | Tasks |
|---|---|
| D1 storage, lock, publication checks | D2, D4, D5 |
| D2 effective name | C3 |
| D3 session id is the named unit | D4, D5 (keyed by session id) |
| D4 validation | D1 (authority), C5 (live dialog checks) |
| D5 tool and verb | D5, D6, D7 |
| D6 `rename_session` | D4, C2 |
| D7 history-less rows disabled | C3, C6 |
| D8 polling | C4 |
| D9 first-turn limitation | none needed (documented in D7 docs) |
| D10 rename UI | C5, C6 |
| Label surfaces | C3 |
| Daemon acceptance criteria 1–10 | D1–D6 tests |
| Client acceptance criteria 11–17 | C1–C5 tests; criterion 17 in C1 and C3 |

## Unresolved questions

None blocking. One thing to watch at implementation: whether `.help` shows on a disabled
context-menu item (C6). Its fallback is already decided.
