# Stream names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Consumer:** `orchestrate-feature`. Two PRs in two repos, each in its own workspace and session:
> 1. **PR 1, daemon:** `briankeane/slipstream`, base `develop` at `63add07`. Tasks 1–8.
> 2. **PR 2, client:** the macOS app `playola-radio/slipstream-client-swift`, base `develop` at `54de11d`. Tasks 9–15. It compiles and unit-tests on its own; only Task 15 (end-to-end) needs PR 1 merged.
>
> The design lives in the client repo at `design/features/stream-names/`. A daemon session reads it there (`gh api` or a local checkout of the client repo).

**Goal:** Let the agent give its workspace stream a short name when it attaches, let the user rename any stream from the macOS app, and show those names in the stream picker.

**Architecture:** The daemon stores both names in a per-session sidecar file `sessions/<id>/name.json`, written under one in-process metadata lock. It is set by `attach` (agent name) and by a new control verb `rename_session` (your name), and reported on each `GET /v1/sessions` item as `naming`. The app decodes `naming`, builds picker labels as `your name ?? agent's name ?? <folder> · started …`, and adds a Rename sheet that calls `rename_session` over the existing control socket.

**Tech Stack:** Daemon: TypeScript on Node ≥ 24, `node:test`, `node:assert/strict`. Client: Swift 6 (strict concurrency, warnings as errors), SwiftUI on macOS 15, `@Observable` models, swift-dependencies, Swift Testing, CustomDump.

**Spec:** [spec.md](./spec.md). The contracts to implement are [endpoints.md](./endpoints.md), [models.md](./models.md) and [screens.md](./screens.md). They are the source of truth; this plan points at them and does not restate them.

## Global Constraints

- PRs target `develop`. Never `main`. No `Co-Authored-By` or other co-sign trailers.
- PR titles start with `feature:` and are plain English.
- Never point anything at the real `~/.slipstream`. Use `SLIPSTREAM_STORE` (client) or `--store` (daemon) with a disposable store (`npm run qa:daemon` in the daemon repo).
- Never print or persist the daemon bearer token.
- Valid name, in this order: a string; well-formed UTF-16; none of U+0000–001F, U+007F–009F, U+2028, U+2029 (checked before trimming); ECMAScript `trim`; not empty; at most **64 UTF-8 bytes**. No Unicode normalization.
- Swift trim: the existing `QuestionRequest.trim`, called after the forbidden-scalar check. On the text that remains it removes exactly U+0020, U+00A0, U+1680, U+2000–U+200A, U+202F, U+205F, U+3000, U+FEFF (the other scalars in its set are forbidden and already rejected).
- `name.json` body: `{"version":1,"agent_name":<string|null>,"user_name":<string|null>}`.
- Feature flag string: `workspace-names-v1`. Status array becomes `["agent-connection-v1","workspace-names-v1"]`.
- New error code: `INVALID_NAME`.
- Fallback label: `<last path component of root> · started MMM d HH:mm` (en_US_POSIX, the injected time zone).
- Daemon checks: `npm test` and `npm run typecheck`. Client checks: `swift test`, then `xcodegen generate` and `xcodebuild test -scheme SlipstreamViewer -destination 'platform=macOS'`.
- Client: invoke the applicable `pfw-*` skills before writing Swift (`pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`, `pfw-identified-collections`, `pfw-modern-swiftui`). Views hold zero logic. Tests never touch a daemon or real time.

## Review Focus

1. **A malformed `name.json`.** Expected: `GET /v1/sessions` returns 500, rename and a named attach fail with `STORAGE_UNAVAILABLE`, and `gc` still completes because it never reads names. Pinned in Tasks 2, 4, 5 and 6.
2. **Names the two validators could disagree on** (trailing U+3000, a zero-width space, a decomposed accent, a 4-byte emoji at the 64-byte boundary). Expected: the app's Save button and the daemon agree on every case. Pinned by the shared fixture in Tasks 1 and 10.
3. **A rename reply that is lost or unreadable.** Expected: the sheet stays open with "Slipstream didn't confirm the rename. Check the stream picker, or try again.", the list refreshes, and nothing is resent automatically. Pinned in Task 13 and Task 14.

---

# PR 1 — daemon (`briankeane/slipstream`, base `develop` `63add07`)

## File structure

| File | Change | Responsibility |
|---|---|---|
| `src/stream-name.ts` | Create | The one name validator, used by `rename_session`, `attach` and the CLI |
| `docs/ask-agent/stream-name-cases.json` | Create | Shared validation cases; the client copies this file verbatim |
| `src/session-name.ts` | Create | Read and write `sessions/<id>/name.json` |
| `src/storage.ts` | Modify | Add `publishFileDurably`, the crash-safe publish now shared by the tombstone and the name file |
| `src/maintenance.ts` | Modify | `publishTombstone` uses `publishFileDurably`; `HISTORY_FILES` gains `name.json` |
| `src/control-protocol.ts` | Modify | `ControlErrorCode` gains `INVALID_NAME` |
| `src/daemon.ts` | Modify | Metadata lock, teardown drain, `rename_session`, attach name writes, status feature |
| `src/http-reader.ts` | Modify | `naming` on each `/v1/sessions` item |
| `src/cli.ts`, `src/attach-workflow.ts` | Modify | `--name`, feature check, output lines |
| `docs/ask-agent/contract.md`, `README.md`, `docs/connect-agent-chat.md`, `SKILL.md` | Modify | Document the contract and tell agents to name their stream |

### Task 1: Name validator and shared cases

**Files:**
- Create: `src/stream-name.ts`
- Create: `docs/ask-agent/stream-name-cases.json`
- Test: `src/stream-name.test.ts`

**Interfaces:**
- Produces: `checkStreamName(value: unknown): NameCheck` where
  `type NameCheck = { ok: true; name: string } | { ok: false; code: 'not_string' | 'unpaired_surrogate' | 'control' | 'empty' | 'too_long'; message: string }`;
  `MAX_NAME_BYTES = 64`.
- Produces: `docs/ask-agent/stream-name-cases.json`, an array of `{ "input": string, "name": string }` (valid; `name` is the stored, trimmed value) or `{ "input": string, "error": "control" | "empty" | "too_long" }`. Only cases a Swift `String` can hold go in this file; lone surrogates and non-strings are tested in the daemon only.

- [ ] **Step 1: Write the shared cases file**

```json
[
  { "input": "Invoice totals refactor", "name": "Invoice totals refactor" },
  { "input": "  Billing cleanup　", "name": "Billing cleanup" },
  { "input": " ﻿Docs pass  ", "name": "Docs pass" },
  { "input": "  Tax ", "name": "Tax" },
  { "input": "​zero width", "name": "​zero width" },
  { "input": "Café rewrite", "name": "Café rewrite" },
  { "input": "Billing\tcleanup", "error": "control" },
  { "input": "Billing cleanup\n", "error": "control" },
  { "input": "Billing cleanup", "error": "control" },
  { "input": "Billing\u0085cleanup", "error": "control" },
  { "input": "Billing\u007fcleanup", "error": "control" },
  { "input": "", "error": "empty" },
  { "input": " 　﻿ ", "error": "empty" },
  { "input": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  { "input": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "error": "too_long" },
  { "input": "  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ", "name": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  { "input": "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀", "name": "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀" },
  { "input": "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀a", "error": "too_long" },
  { "input": "éééééééééééééééééééééééééééééééé", "name": "éééééééééééééééééééééééééééééééé" },
  { "input": "ééééééééééééééééééééééééééééééééa", "error": "too_long" }
]
```

(The `a` runs are 64 and 65 characters; the emoji runs are 16 × 4 bytes and 16 × 4 + 1; the `é` runs are 32 × 2 bytes and 32 × 2 + 1. Count them when you paste.)

- [ ] **Step 2: Write the failing test**

```ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { checkStreamName } from './stream-name.ts';

type Case = { input: string; name?: string; error?: string };

describe('checkStreamName', () => {
  it('matches every shared case', async () => {
    const cases = JSON.parse(await readFile(new URL('../docs/ask-agent/stream-name-cases.json', import.meta.url), 'utf8')) as Case[];
    for (const c of cases) {
      const res = checkStreamName(c.input);
      if (c.name !== undefined) assert.deepEqual(res, { ok: true, name: c.name }, JSON.stringify(c.input));
      else assert.equal(res.ok === false && res.code, c.error, JSON.stringify(c.input));
    }
  });

  it('rejects non-strings and unpaired surrogates before anything else', () => {
    for (const value of [undefined, null, 5, {}]) assert.equal(checkStreamName(value).ok === false && (checkStreamName(value) as { code: string }).code, 'not_string');
    assert.equal((checkStreamName('a\ud800\n') as { code: string }).code, 'unpaired_surrogate');
  });

  it('checks control characters before trimming and length', () => {
    assert.equal((checkStreamName('\n' + 'a'.repeat(80)) as { code: string }).code, 'control');
  });

  it('names the byte count in the too-long message', () => {
    const res = checkStreamName('a'.repeat(65));
    assert.equal(res.ok === false && res.message, 'name is too long: 65 of 64 UTF-8 bytes');
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `node --test src/stream-name.test.ts`
Expected: FAIL, cannot find module `./stream-name.ts`.

- [ ] **Step 4: Implement**

```ts
/** The single rule for stream names (docs/ask-agent/contract.md, "Stream names").
 * Used by rename_session, attach and the CLI. The app mirrors it from
 * docs/ask-agent/stream-name-cases.json. */
export const MAX_NAME_BYTES = 64;

export type NameCheck =
  | { ok: true; name: string }
  | { ok: false; code: 'not_string' | 'unpaired_surrogate' | 'control' | 'empty' | 'too_long'; message: string };

function isForbidden(code: number): boolean {
  return code <= 0x1f || (code >= 0x7f && code <= 0x9f) || code === 0x2028 || code === 0x2029;
}

export function checkStreamName(value: unknown): NameCheck {
  if (typeof value !== 'string') return { ok: false, code: 'not_string', message: 'name must be a string' };
  if (!value.isWellFormed()) return { ok: false, code: 'unpaired_surrogate', message: 'name contains an unpaired surrogate' };
  for (const ch of value) {
    if (isForbidden(ch.codePointAt(0)!)) {
      return { ok: false, code: 'control', message: "name can't contain line breaks or control characters" };
    }
  }
  const name = value.trim();
  if (name === '') return { ok: false, code: 'empty', message: 'name is empty' };
  const bytes = Buffer.byteLength(name, 'utf8');
  if (bytes > MAX_NAME_BYTES) {
    return { ok: false, code: 'too_long', message: `name is too long: ${bytes} of ${MAX_NAME_BYTES} UTF-8 bytes` };
  }
  return { ok: true, name };
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `node --test src/stream-name.test.ts && npm run typecheck`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/stream-name.ts src/stream-name.test.ts docs/ask-agent/stream-name-cases.json
git commit -m "feature: one validation rule for stream names, with shared cases for the app"
```

### Task 2: The name file

**Files:**
- Create: `src/session-name.ts`
- Modify: `src/storage.ts` (add `publishFileDurably`)
- Modify: `src/maintenance.ts:30` (`HISTORY_FILES`) and `:49-79` (`publishTombstone` uses the shared publish)
- Test: `src/session-name.test.ts`, `src/maintenance.test.ts`

**Interfaces:**
- Consumes: `checkStreamName` (Task 1); `tombstonePath` from `store-reader.ts`; `StorageError`, `FILE_MODE`, `writeAll`, `fsyncDir` from `storage.ts`.
- Produces:
  - `publishFileDurably(dest: string, body: Buffer, op: string): Promise<void>` in `storage.ts`. Unique temp `${dest}.${randomUUID()}.tmp`, `wx` + `FILE_MODE`, `writeAll`, `sync`, rename over `dest`, `fsyncDir(dirname(dest))`; errors are `StorageError(\`write-${op}\`)` / `StorageError(\`rename-${op}\`)`; the temp is always unlinked.
  - `interface SessionNaming { agent_name: string | null; user_name: string | null }`
  - `EMPTY_NAMING: SessionNaming` (`{ agent_name: null, user_name: null }`)
  - `namePath(storeDir: string, id: string): string`
  - `readNaming(storeDir: string, id: string): Promise<SessionNaming>` (missing file → `EMPTY_NAMING`; malformed → throws `StorageError('read-name', …)`)
  - `writeNaming(storeDir: string, id: string, naming: SessionNaming): Promise<void>` (never creates the session directory)

- [ ] **Step 1: Write the failing tests**

`src/session-name.test.ts`:

```ts
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EMPTY_NAMING, namePath, readNaming, writeNaming } from './session-name.ts';
import { StorageError } from './storage.ts';

const ID = '0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90';

async function withStore(fn: (store: string) => Promise<void>): Promise<void> {
  const store = await mkdtemp(join(tmpdir(), 'slip-name-'));
  try { await fn(store); } finally { await rm(store, { recursive: true, force: true }); }
}

describe('session name file', () => {
  it('reads a missing file as no names', async () => {
    await withStore(async (store) => {
      await mkdir(join(store, 'sessions', ID), { recursive: true });
      assert.deepEqual(await readNaming(store, ID), EMPTY_NAMING);
    });
  });

  it('writes both fields, owner-only, and reads them back', async () => {
    await withStore(async (store) => {
      await mkdir(join(store, 'sessions', ID), { recursive: true });
      await writeNaming(store, ID, { agent_name: 'Invoice totals refactor', user_name: null });
      assert.equal(await readFile(namePath(store, ID), 'utf8'),
        '{"version":1,"agent_name":"Invoice totals refactor","user_name":null}\n');
      assert.equal((await stat(namePath(store, ID))).mode & 0o777, 0o600);
      assert.deepEqual(await readNaming(store, ID), { agent_name: 'Invoice totals refactor', user_name: null });
      assert.deepEqual((await readdir(join(store, 'sessions', ID))).filter((f) => f.endsWith('.tmp')), []);
    });
  });

  it('never creates a missing session directory', async () => {
    await withStore(async (store) => {
      await assert.rejects(writeNaming(store, ID, EMPTY_NAMING), StorageError);
      await assert.rejects(stat(join(store, 'sessions', ID)));
    });
  });

  it('treats every malformed shape as a storage error', async () => {
    await withStore(async (store) => {
      await mkdir(join(store, 'sessions', ID), { recursive: true });
      for (const body of ['nope', '{"version":2,"agent_name":null,"user_name":null}', '{"version":1,"agent_name":null}',
        '{"version":1,"agent_name":5,"user_name":null}', '{"version":1,"agent_name":" padded ","user_name":null}',
        '{"version":1,"agent_name":"","user_name":null}', '[]']) {
        await writeFile(namePath(store, ID), body);
        await assert.rejects(readNaming(store, ID), StorageError, body);
      }
    });
  });
});
```

Add to `src/maintenance.test.ts` (in the existing `removeSessionHistory` describe block; reuse its store fixture):

```ts
it('removes name.json with the history and keeps the tombstone', async () => {
  // seed sessions/<id>/events.jsonl, removed.json and name.json the same way the neighbouring tests seed history
  await removeSessionHistory(store, id);
  assert.equal(await exists(join(store, 'sessions', id, 'name.json')), false);
  assert.equal(await exists(tombstonePath(store, id)), true);
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `node --test src/session-name.test.ts src/maintenance.test.ts`
Expected: FAIL, missing module and `name.json` still present.

- [ ] **Step 3: Implement**

`src/storage.ts`, after `writeAll`:

```ts
/** Crash-safe replace of `dest`: unique temp, `wx`/0600, write, fsync, atomic
 * rename, fsync the directory. The directory must already exist. */
export async function publishFileDurably(dest: string, body: Buffer, op: string): Promise<void> {
  const tmp = `${dest}.${randomUUID()}.tmp`;
  let handle;
  try {
    try {
      handle = await open(tmp, 'wx', FILE_MODE);
      await writeAll(handle, body);
      await handle.sync();
    } catch (err) {
      throw new StorageError(`write-${op}`, err);
    } finally {
      await handle?.close();
    }
    try {
      await rename(tmp, dest);
    } catch (err) {
      throw new StorageError(`rename-${op}`, err);
    }
    await fsyncDir(dirname(dest));
  } finally {
    await unlink(tmp).catch(() => {});
  }
}
```

(Add the `open`, `rename`, `unlink`, `randomUUID` and `dirname` imports `storage.ts` lacks.)

`src/maintenance.ts`: replace the body of `publishTombstone` with `await publishFileDurably(tombstonePath(storeDir, id), TOMBSTONE_BODY, 'tombstone');`, drop the now-unused imports, and change line 30 to:

```ts
const HISTORY_FILES = ['events.jsonl', 'name.json'] as const;
```

`src/session-name.ts`:

```ts
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { StorageError, publishFileDurably } from './storage.ts';
import { tombstonePath } from './store-reader.ts';
import { checkStreamName } from './stream-name.ts';

/** `sessions/<id>/name.json`: the agent's name and your name for one stream.
 * The only store of names; see docs/ask-agent/contract.md, "Stream names". */
export interface SessionNaming { agent_name: string | null; user_name: string | null }

export const EMPTY_NAMING: SessionNaming = Object.freeze({ agent_name: null, user_name: null });

export function namePath(storeDir: string, id: string): string {
  return join(dirname(tombstonePath(storeDir, id)), 'name.json');
}

function storedName(value: unknown): value is string | null {
  if (value === null) return true;
  const check = checkStreamName(value);
  return check.ok && check.name === value;
}

export async function readNaming(storeDir: string, id: string): Promise<SessionNaming> {
  let raw: string;
  try {
    raw = await readFile(namePath(storeDir, id), 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return EMPTY_NAMING;
    throw new StorageError('read-name', err);
  }
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch (err) { throw new StorageError('read-name', err); }
  const p = parsed as Record<string, unknown>;
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed) || p.version !== 1
    || !('agent_name' in p) || !('user_name' in p) || !storedName(p.agent_name) || !storedName(p.user_name)) {
    throw new StorageError('read-name', new Error(`malformed ${namePath(storeDir, id)}`));
  }
  return { agent_name: p.agent_name, user_name: p.user_name };
}

export async function writeNaming(storeDir: string, id: string, naming: SessionNaming): Promise<void> {
  const body = Buffer.from(`${JSON.stringify({ version: 1, agent_name: naming.agent_name, user_name: naming.user_name })}\n`, 'utf8');
  await publishFileDurably(namePath(storeDir, id), body, 'name');
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `node --test src/session-name.test.ts src/maintenance.test.ts && npm run typecheck`
Expected: PASS, including every pre-existing tombstone test in `maintenance.test.ts`.

- [ ] **Step 5: Commit**

```bash
git add src/storage.ts src/maintenance.ts src/maintenance.test.ts src/session-name.ts src/session-name.test.ts
git commit -m "feature: store stream names in a crash-safe sidecar file that deletion cleans up"
```

### Task 3: Metadata lock and teardown drain

**Files:**
- Modify: `src/daemon.ts` (state block near `:225-237`, `doTeardown` `:262-305`)
- Test: none of its own. The lock has no caller until Task 4; Task 4's rename tests and Task 5's attach-name tests exercise it.

**Interfaces:**
- Produces (inside `startDaemon`, used by Tasks 4 and 5):
  `underMetadataLock<T>(op: () => Promise<T>): Promise<T>`, which runs `op` after every earlier operation on the chain settles and never lets a failure break the chain.
  `metadataClosed(): boolean`, true when `torn || compromised || state === 'wedged'`; called only from inside lock operations.

Delete and `gc` stay outside this lock. A `name.json` left behind in a removed stream is harmless: the list reports no names for a removed stream (`EMPTY_NAMING`), and `gc` re-runs `removeSessionHistory`, which unlinks it.

- [ ] **Step 1: Implement**

Next to the other state in `startDaemon`:

```ts
  // One in-process lock for name.json read-modify-writes (rename and the attach
  // name write). Delete and gc stay outside it: a name.json left in a removed
  // stream is never read (the list reports no names for removed streams) and gc
  // re-runs removeSessionHistory. Separate from runMaintenance: renaming the
  // recording stream must work.
  let metadataChain: Promise<unknown> = Promise.resolve();

  function underMetadataLock<T>(op: () => Promise<T>): Promise<T> {
    const run = metadataChain.then(op);
    metadataChain = run.catch(() => {});
    return run;
  }

  function metadataClosed(): boolean {
    return torn || compromised || state === 'wedged';
  }
```

In `doTeardown`, after the attach and `maintenanceInFlight` drains:

```ts
    // The chain tail settles after every admitted rename or name write, so each
    // one finishes before the store lock goes.
    await metadataChain;
```

- [ ] **Step 2: Run the daemon suites**

Run: `node --test src/daemon.test.ts src/maintenance.test.ts && npm run typecheck`
Expected: PASS. Every pre-existing delete, gc and shutdown test still passes, since this task changes only teardown ordering.

- [ ] **Step 3: Commit**

```bash
git add src/daemon.ts
git commit -m "feature: serialize name writes and let shutdown finish them"
```

### Task 4: `rename_session`

**Files:**
- Modify: `src/control-protocol.ts:24-42` (add `'INVALID_NAME'`, and document it in the comment above the union)
- Modify: `src/daemon.ts` (new `renameSession`; `case 'rename_session'` in `dispatch` `:968-985`)
- Test: `src/daemon.test.ts`, `src/control-protocol.test.ts` if it enumerates codes

**Interfaces:**
- Consumes: `checkStreamName` (Task 1); `readNaming`, `writeNaming` (Task 2); `underMetadataLock`, `metadataClosed` (Task 3); `isValidSessionId`, `readTombstone` from `store-reader.ts`; `sessionExists` from `maintenance.ts`.
- Produces: wire verb `rename_session` exactly as [endpoints.md](./endpoints.md#control-rename_session).

- [ ] **Step 1: Write the failing tests** (new `describe('rename_session')`)

```ts
describe('rename_session', () => {
  const NAME_FILE = (store: string) => join(store, 'sessions', ABSENT_ID, 'name.json');

  it('stores your trimmed name and replies with the session id only', async () => {
    await withDaemon(async ({ store, call }) => {
      await seedSession(store, ABSENT_ID, HEX_LIVE);
      const res = await call({ verb: 'rename_session', session_id: ABSENT_ID, name: '  Billing cleanup ' });
      assert.deepEqual(res, { v: 1, ok: true, session_id: ABSENT_ID });
      assert.equal(await readFile(NAME_FILE(store), 'utf8'),
        '{"version":1,"agent_name":null,"user_name":"Billing cleanup"}\n');
    });
  });

  it('clears your name with null and keeps the agent name', async () => {
    await withDaemon(async ({ store, call }) => {
      await seedSession(store, ABSENT_ID, HEX_LIVE);
      await writeFile(NAME_FILE(store), '{"version":1,"agent_name":"Invoice totals refactor","user_name":"Billing cleanup"}\n');
      const res = await call({ verb: 'rename_session', session_id: ABSENT_ID, name: null });
      assert.equal(res.ok, true);
      assert.equal(await readFile(NAME_FILE(store), 'utf8'),
        '{"version":1,"agent_name":"Invoice totals refactor","user_name":null}\n');
    });
  });

  it('renames the stream being recorded', async () => {
    await withDaemon(async ({ worktree, call }) => {
      const attached = await call({ verb: 'attach', worktree, ...IDENTITY });
      const res = await call({ verb: 'rename_session', session_id: rec(attached).session_id, name: 'Live one' });
      assert.equal(res.ok, true);
    });
  });

  it('checks the request in contract order', async () => {
    await withDaemon(async ({ store, call }) => {
      await seedSession(store, ABSENT_ID, HEX_LIVE);
      const code = async (req: CallRequest) => { const r = await call(req); return r.ok ? 'ok' : r.code; };
      assert.equal(await code({ verb: 'rename_session', session_id: '../etc', name: 'x' }), 'PROTOCOL');
      assert.equal(await code({ verb: 'rename_session', session_id: ABSENT_ID }), 'PROTOCOL');
      assert.equal(await code({ verb: 'rename_session', session_id: ABSENT_ID, name: 7 }), 'PROTOCOL');
      assert.equal(await code({ verb: 'rename_session', session_id: ABSENT_ID, name: 'a\nb' }), 'INVALID_NAME');
      assert.equal(await code({ verb: 'rename_session', session_id: ABSENT_ID, name: '   ' }), 'INVALID_NAME');
      assert.equal(await code({ verb: 'rename_session', session_id: ABSENT_ID, name: 'a'.repeat(65) }), 'INVALID_NAME');
    });
  });

  it('reports a missing or deleted stream as not found', async () => {
    await withDaemon(async ({ store, call }) => {
      const missing = await call({ verb: 'rename_session', session_id: ABSENT_ID, name: 'x' });
      assert.equal(missing.ok === false && missing.code, 'SESSION_NOT_FOUND');
      await seedSession(store, ABSENT_ID, HEX_LIVE);
      await call({ verb: 'delete_session', session_id: ABSENT_ID });
      const deleted = await call({ verb: 'rename_session', session_id: ABSENT_ID, name: 'x' });
      assert.equal(deleted.ok === false && deleted.message, `session ${ABSENT_ID} was deleted`);
      assert.equal(await exists(NAME_FILE(store)), false);
    });
  });

  it('refuses a malformed name file as a storage error and leaves it alone', async () => {
    await withDaemon(async ({ store, call }) => {
      await seedSession(store, ABSENT_ID, HEX_LIVE);
      await writeFile(NAME_FILE(store), '{"version":2}');
      const res = await call({ verb: 'rename_session', session_id: ABSENT_ID, name: 'x' });
      assert.equal(res.ok === false && res.code, 'STORAGE_UNAVAILABLE');
      assert.equal(await readFile(NAME_FILE(store), 'utf8'), '{"version":2}');
    });
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test --test-name-pattern="rename_session" src/daemon.test.ts`
Expected: FAIL with `unknown verb: rename_session`.

- [ ] **Step 3: Implement**

`src/control-protocol.ts`: add `| 'INVALID_NAME'` and a line to the doc comment: "`INVALID_NAME`: a stream name broke the rule in docs/ask-agent/contract.md, 'Stream names'; the message names the first failure."

`src/daemon.ts`, after `gc`:

```ts
  async function renameSession(req: RequestEnvelope): Promise<Record<string, unknown> | ErrorFields> {
    if (!nonEmptyString(req.session_id) || !isValidSessionId(req.session_id)) {
      return errFields('PROTOCOL', 'rename_session requires a valid session_id');
    }
    if (!('name' in req) || (req.name !== null && typeof req.name !== 'string')) {
      return errFields('PROTOCOL', 'rename_session requires name: a string, or null to clear it');
    }
    let userName: string | null = null;
    if (req.name !== null) {
      const check = checkStreamName(req.name);
      if (!check.ok) return errFields('INVALID_NAME', check.message);
      userName = check.name;
    }
    const id = req.session_id;
    const closed = () => errFields('STORAGE_UNAVAILABLE', 'the daemon is wedged, shutting down, or lost its store lock');
    return underMetadataLock(async () => {
      if (metadataClosed()) return closed();
      try {
        if (!await sessionExists(storeDir, id)) return errFields('SESSION_NOT_FOUND', `no session ${id}`);
        if (await readTombstone(storeDir, id)) return errFields('SESSION_NOT_FOUND', `session ${id} was deleted`);
        await writeNaming(storeDir, id, { ...(await readNaming(storeDir, id)), user_name: userName });
        return { session_id: id };
      } catch (err) {
        return errFields('STORAGE_UNAVAILABLE', (err as Error).message);
      }
    });
  }
```

In `dispatch`: `case 'rename_session': outcome = await renameSession(req); break;`. Add the imports.

- [ ] **Step 4: Run the daemon suites**

Run: `node --test src/daemon.test.ts src/control-protocol.test.ts && npm run typecheck`
Expected: PASS, including every pre-existing control-protocol and delete test.

- [ ] **Step 5: Commit**

```bash
git add src/control-protocol.ts src/daemon.ts src/daemon.test.ts
git commit -m "feature: let the app rename a stream, or clear its name, over the control socket"
```

### Task 5: Agent name on attach, and the status feature

**Files:**
- Modify: `src/daemon.ts` (`statusFields` `:368-383`; `attach` `:531-562`; `attachAgain` `:515-529`; `startAndActivate` after `recordAgentConnection` `~:476-500`; thread `agentName` through `resolveAndStart`)
- Modify: `src/attach-workflow.test.ts:64,347` (the fake status and the test pinning `attach_features` both gain `'workspace-names-v1'`)
- Test: `src/daemon.test.ts`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `attach` accepts optional `name`; `status.attach_features` is `['agent-connection-v1', 'workspace-names-v1']`.

- [ ] **Step 1: Write the failing tests** (new `describe('attach with a name')`)

```ts
describe('attach with a name', () => {
  const nameFile = (store: string, id: string) => join(store, 'sessions', id, 'name.json');

  it('advertises workspace-names-v1', async () => {
    await withDaemon(async ({ call }) => {
      assert.deepEqual(rec(await call({ verb: 'status' })).attach_features, ['agent-connection-v1', 'workspace-names-v1']);
    });
  });

  it('records the trimmed agent name for a new stream and leaves the reply unchanged', async () => {
    await withDaemon(async ({ store, worktree, call }) => {
      const res = await call({ verb: 'attach', worktree, ...IDENTITY, name: ' Invoice totals refactor ' });
      assert.deepEqual(Object.keys(res).sort(), ['agent_connection', 'ok', 'session_id', 'v']);
      assert.equal(await readFile(nameFile(store, rec(res).session_id), 'utf8'),
        '{"version":1,"agent_name":"Invoice totals refactor","user_name":null}\n');
    });
  });

  it('refuses an invalid name before attaching anything', async () => {
    await withDaemon(async ({ worktree, call }) => {
      const res = await call({ verb: 'attach', worktree, ...IDENTITY, name: 'a\tb' });
      assert.equal(res.ok === false && res.code, 'INVALID_NAME');
      assert.equal(rec(await call({ verb: 'status' })).state, 'detached');
    });
  });

  it('updates the agent name on an already-active attach and keeps your name', async () => {
    await withDaemon(async ({ store, worktree, call }) => {
      const first = await call({ verb: 'attach', worktree, ...IDENTITY, name: 'First' });
      const id = rec(first).session_id;
      await call({ verb: 'rename_session', session_id: id, name: 'Mine' });
      const again = await call({ verb: 'attach', worktree, ...IDENTITY, name: 'Second' });
      assert.equal(rec(again).already_active, true);
      assert.equal(await readFile(nameFile(store, id), 'utf8'), '{"version":1,"agent_name":"Second","user_name":"Mine"}\n');
    });
  });

  it('does not read or write the name file without a name', async () => {
    await withDaemon(async ({ store, worktree, call }) => {
      const res = await call({ verb: 'attach', worktree, ...IDENTITY });
      assert.equal(await exists(nameFile(store, rec(res).session_id)), false);
    });
  });

  it('fails an already-active named attach on a malformed name file', async () => {
    await withDaemon(async ({ store, worktree, call }) => {
      const id = rec(await call({ verb: 'attach', worktree, ...IDENTITY })).session_id;
      await writeFile(nameFile(store, id), 'garbage');
      const res = await call({ verb: 'attach', worktree, ...IDENTITY, name: 'x' });
      assert.equal(res.ok === false && res.code, 'STORAGE_UNAVAILABLE');
    });
  });

  it('fails a resume whose name cannot be recorded, with the retry remedy', async () => {
    await withDaemon(async ({ store, worktree, call }) => {
      const id = rec(await call({ verb: 'attach', worktree, ...IDENTITY })).session_id;
      await call({ verb: 'detach' });
      await writeFile(nameFile(store, id), 'garbage');
      const res = await call({ verb: 'attach', worktree, ...IDENTITY, name: 'x' });
      assert.equal(res.ok === false && res.code, 'SESSION_RESUME_FAILED');
      assert.match(res.ok === false ? res.message : '', /could not record the stream name/);
      assert.equal(rec(await call({ verb: 'status' })).state, 'detached');
    });
  });
});
```


- [ ] **Step 2: Run to verify they fail**

Run: `node --test --test-name-pattern="attach with a name" src/daemon.test.ts`
Expected: FAIL (feature missing, name ignored).

- [ ] **Step 3: Implement**

`statusFields`: `attach_features: ['agent-connection-v1', 'workspace-names-v1']`.

`attach`, directly after the `root_transcript` check:

```ts
    let agentName: string | undefined;
    if (req.name !== undefined) {
      const check = checkStreamName(req.name);
      if (!check.ok) return errFields('INVALID_NAME', check.message);
      agentName = check.name;
    }
```

Pass `agentName` to `attachAgain(…, agentName)` and `resolveAndStart(req, agentName)`, and on to `startAndActivate`.

Shared helper inside `startDaemon`:

```ts
  /** Write the agent's name, keeping your name. Throws on storage failure. */
  async function recordAgentName(id: string, agentName: string): Promise<void> {
    if (metadataClosed()) throw new StorageError('write-name', new Error('daemon is shutting down'));
    const stored = await readNaming(storeDir, id);
    if (stored.agent_name !== agentName) await writeNaming(storeDir, id, { ...stored, agent_name: agentName });
  }
```

`startAndActivate`, after the `recordAgentConnection` block and before the failure branch:

```ts
    let nameFailed = false;
    if (agentName !== undefined && !pendingFailed && !(torn || compromised || sessionCompromised || state !== 'attaching')) {
      try { await underMetadataLock(() => recordAgentName(id, agentName)); } catch { nameFailed = true; }
    }
```

Change the failure condition to `if (pendingFailed || nameFailed || torn || …)` and its resumed-session cause to:

```ts
        const cause = pendingFailed ? 'could not record the agent connection'
          : nameFailed ? 'could not record the stream name' : attachInterruptedCause();
```

`attachAgain`, after both `SESSION_ACTIVE` checks and before re-arming the pending check:

```ts
    if (agentName !== undefined) {
      try {
        const written = await underMetadataLock(async () => {
          if (state !== 'active' || current !== binding) return false;
          await recordAgentName(binding.id, agentName);
          return true;
        });
        if (!written) return errFields('CAPTURE_NOT_READY', 'the active capture changed; retry attach');
      } catch (err) {
        return errFields('STORAGE_UNAVAILABLE', `could not record the stream name: ${(err as Error).message}`);
      }
    }
```

- [ ] **Step 4: Run the daemon suites**

Run: `node --test src/daemon.test.ts src/attach-workflow.test.ts && npm run typecheck`
Expected: PASS, including every pre-existing attach and resume test.

- [ ] **Step 5: Commit**

```bash
git add src/daemon.ts src/daemon.test.ts src/attach-workflow.test.ts
git commit -m "feature: let an agent name its stream when it attaches"
```

### Task 6: `naming` on `GET /v1/sessions`

**Files:**
- Modify: `src/http-reader.ts:166-187`
- Test: `src/http-reader.test.ts`

**Interfaces:**
- Consumes: `readNaming`, `EMPTY_NAMING` (Task 2).
- Produces: every list item carries `naming: { agent_name, user_name }`.

- [ ] **Step 1: Write the failing tests**

Update the existing expectation at `http-reader.test.ts:~61` to include `naming: { agent_name: null, user_name: null }`, then add:

```ts
it('reports stored names, and none for a removed stream', async () => {
  const store = await storeWithSession();
  await writeFile(join(store, 'sessions', UUID, 'name.json'),
    '{"version":1,"agent_name":"Invoice totals refactor","user_name":"Billing cleanup"}\n');
  const srv = await startReaderServer({ storeDir: store });
  try {
    const body = await (await GET(srv, '/v1/sessions')).json();
    assert.deepEqual(body[0].naming, { agent_name: 'Invoice totals refactor', user_name: 'Billing cleanup' });
    await writeFile(join(store, 'sessions', UUID, 'removed.json'), '{"version":1}\n');
    const removed = await (await GET(srv, '/v1/sessions')).json();
    assert.deepEqual(removed[0].naming, { agent_name: null, user_name: null });
  } finally { await srv.close(); }
});

it('fails the list with 500 on a malformed name file', async () => {
  const store = await storeWithSession();
  await writeFile(join(store, 'sessions', UUID, 'name.json'), '{"version":1}');
  const srv = await startReaderServer({ storeDir: store });
  try { assert.equal((await GET(srv, '/v1/sessions')).status, 500); } finally { await srv.close(); }
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test src/http-reader.test.ts`
Expected: FAIL, no `naming` key.

- [ ] **Step 3: Implement**

```ts
    if (pathname === '/v1/sessions') {
      const sessions = await listSessions(opts.storeDir);
      // Names are added here, after listSessions, so gc and blob reclamation never
      // read them. A malformed name.json throws into the existing 500.
      sendJson(res, 200, await Promise.all(sessions.map(async (s) => {
        // …existing durableSeq / agentConnection lines unchanged…
        return { id: s.id, durable_seq: durableSeq.toString(), removed: s.removed, agent_connection: agentConnection,
          naming: s.removed ? EMPTY_NAMING : await readNaming(opts.storeDir, s.id) };
      })));
      return;
    }
```

- [ ] **Step 4: Run**

Run: `node --test src/http-reader.test.ts && npm run typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/http-reader.ts src/http-reader.test.ts
git commit -m "feature: include each stream's names in the session list"
```

### Task 7: `slipstream attach --name`

**Files:**
- Modify: `src/cli.ts` (`Args` attach type `:61`; `parseAttach` `:201-226`; `usage` `:282-283`; routing `:570-584`; `runThisChatAttach` `:458`)
- Modify: `src/attach-workflow.ts` (`runAttachWorkflow`/`attachThisChat` opts; feature check; attach envelope `:68`; output `:74-83`; the names-capability refusal goes right after the `requireSetupCheck(status, opts.store)` call, which is unchanged)
- Test: `src/cli.test.ts`, `src/attach-workflow.test.ts`

**Interfaces:**
- Consumes: `checkStreamName` (Task 1).
- Produces: `runAttachWorkflow(opts: { dir: string; store: string; name?: string }, deps)`; `Args` attach gains `name?: string` (already trimmed and validated by the time it is used).

- [ ] **Step 1: Write the failing tests**

`src/cli.test.ts` (next to the existing `parseArgs` attach cases):

```ts
it('parses --name for both attach forms and keeps the one-command route', () => {
  const one = parseArgs(['attach', '--name', 'Invoice totals']);
  assert.equal(one?.command === 'attach' && one.name, 'Invoice totals');
  assert.equal(one?.command === 'attach' && one.harness, undefined);
  const manual = parseArgs(['attach', '--harness', 'codex', '--harness-session-id', 'x', '--name', 'N']);
  assert.equal(manual?.command === 'attach' && manual.name, 'N');
  assert.equal(parseArgs(['attach', '--name']), null);
});
```

`src/attach-workflow.test.ts`: add `noNames?: boolean` to its `Daemon` type, then:

```ts
describe('slipstream attach --name', () => {
  async function withFixture(fn: (f: Fixture) => Promise<void>): Promise<void> {
    const f = await fixture();
    try { await fn(f); } finally { await rm(f.root, { recursive: true, force: true }); }
  }

  it('sends the name', async () => {
    await withFixture(async (f) => {
      await claudeTranscript(f);
      const code = await runAttachWorkflow({ dir: f.worktree, store: f.store, name: 'Invoice totals refactor' },
        deps(f, claudeEnv, { live: true }));
      assert.equal(code, 0);
      assert.equal(attachRequests(f)[0]!.name, 'Invoice totals refactor');
      assert.ok(!f.out.some((l) => l.startsWith('Name this stream once')));
    });
  });

  it('refuses before installing anything when the daemon lacks names', async () => {
    await withFixture(async (f) => {
      await claudeTranscript(f);
      const code = await runAttachWorkflow({ dir: f.worktree, store: f.store, name: 'x' },
        deps(f, claudeEnv, { live: true, noNames: true }));
      assert.equal(code, 1);
      assert.deepEqual(attachRequests(f), []);
      assert.deepEqual(f.commands, []);
      assert.match(f.err.join('\n'), /does not support stream names\. Restart the Slipstream daemon with this version, then run slipstream attach --name … again\. Nothing was installed or recorded\./);
    });
  });

  it('says the agent name was updated on an already-active attach', async () => {
    await withFixture(async (f) => {
      await claudeTranscript(f);
      await runAttachWorkflow({ dir: f.worktree, store: f.store, name: 'x' }, deps(f, claudeEnv, { live: true,
        attach: { session_id: 'cap-1', already_active: true, agent_connection: 'connected' } }));
      assert.equal(f.out[0], `Attached successfully: already recording ${f.worktree} with this chat, agent connected; agent name updated.`);
    });
  });

  it('hints to name the stream when no name is given', async () => {
    await withFixture(async (f) => {
      await claudeTranscript(f);
      await runAttachWorkflow({ dir: f.worktree, store: f.store }, deps(f, claudeEnv, { live: true }));
      assert.equal(f.out.at(-1), 'Name this stream once, in 2-5 words: slipstream attach --name "<name>"');
    });
  });
});
```

(`fixture`, `claudeTranscript`, `deps`, `claudeEnv` and `attachRequests` are the file's existing helpers. In `deps`, the status branch becomes `attach_features: daemon.legacy ? undefined : daemon.noNames ? ['agent-connection-v1'] : ['agent-connection-v1', 'workspace-names-v1']`.)

- [ ] **Step 2: Run to verify they fail**

Run: `node --test src/cli.test.ts src/attach-workflow.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

`cli.ts`:
- `Args` attach: add `name?: string`.
- `parseAttach`: add `'--name'` to the value flags and `else if (arg === '--name') name = value;`; return `...(name !== undefined ? { name } : {})`.
- `usage`: append ` [--name <name>]` to both attach lines.
- In the dispatcher, before the two attach branches:

```ts
  if (args.command === 'attach' && args.name !== undefined) {
    const check = checkStreamName(args.name);
    if (!check.ok) {
      console.error(`slipstream: ${check.message}; nothing was installed or recorded`);
      process.exitCode = 1;
      return;
    }
    args = { ...args, name: check.name };
  }
```

- One-command branch: `await runThisChatAttach(args.dir, args.store, args.name);` and in `runThisChatAttach` pass `{ dir, store, ...(name !== undefined ? { name } : {}) }`.
- Manual branch:

```ts
  if (args.command === 'attach') {
    if (args.name !== undefined) {
      const status = await sendControlRequest({ socketPath: controlSocketPath(args.store), request: { v: 1, verb: 'status' } });
      if (!status.ok || !hasFeature(status, 'workspace-names-v1')) {
        console.error(`slipstream: ${NAMES_UNSUPPORTED}`);
        process.exitCode = 1;
        return;
      }
    }
    await runControl(args.store, {
      verb: 'attach', worktree: args.dir, harness: args.harness, harness_session_id: args.harnessSessionId,
      root_transcript: args.rootTranscript, ...(args.name !== undefined ? { name: args.name } : {}),
    });
    return;
  }
```

`attach-workflow.ts`:

```ts
export const NAMES_UNSUPPORTED = 'the running daemon does not support stream names. Restart the Slipstream daemon '
  + 'with this version, then run slipstream attach --name … again. Nothing was installed or recorded.';

export function hasFeature(status: Record<string, unknown>, feature: string): boolean {
  return Array.isArray(status.attach_features) && status.attach_features.includes(feature);
}
```

In `attachThisChat` (opts now `{ dir; store; name?: string }`):
- After `requireSetupCheck(status, opts.store);`: `if (opts.name !== undefined && !hasFeature(status, 'workspace-names-v1')) throw new Refusal(NAMES_UNSUPPORTED);`
- Attach envelope: add `...(opts.name !== undefined ? { name: opts.name } : {})`.
- Connected + `again` line: end with `opts.name !== undefined ? '; agent name updated.' : '; nothing changed.'`.
- Last line, after `agent_connection`: `if (opts.name === undefined) deps.out('Name this stream once, in 2-5 words: slipstream attach --name "<name>"');`

- [ ] **Step 4: Run**

Run: `npm test && npm run typecheck`
Expected: PASS, whole suite.

- [ ] **Step 5: Commit**

```bash
git add src/cli.ts src/cli.test.ts src/attach-workflow.ts src/attach-workflow.test.ts
git commit -m "feature: slipstream attach --name"
```

### Task 8: Docs

**Files:**
- Modify: `docs/ask-agent/contract.md` (new top-level `## Stream names` after `## Agent readiness`)
- Modify: `README.md` ("Connect an agent chat" `:113-137`, manual form `:151-156`, command reference `:297-298`)
- Modify: `docs/connect-agent-chat.md:5-10`
- Modify: `SKILL.md` (near the attach paragraph at `:26-28`)

- [ ] **Step 1: `contract.md`.** Add `## Stream names` with these subsections, copying the content from the client repo's `design/features/stream-names/` verbatim where marked:
  - "Name rule": the six ordered checks and the trim set from models.md "Valid name"; point at `docs/ask-agent/stream-name-cases.json` as the shared cases.
  - "Storage": the `name.json` table, malformed-file definition, write and lock rules from models.md.
  - "Control verb `rename_session`": the whole endpoints.md section.
  - "`attach` with `name`", "`status` feature `workspace-names-v1`", "`GET /v1/sessions` `naming`": the endpoints.md sections.
  - Add `INVALID_NAME` wherever the contract lists error codes.
- [ ] **Step 2: README and `docs/connect-agent-chat.md`.** Change the example to:

```sh
slipstream attach --name "<2-5 words describing this workspace's work>"
```

  Add one sentence after it: "The name shows in the Slipstream app's stream picker. Leave `--name` off to keep the current name; you can also rename a stream in the app." Add `[--name <name>]` to both attach lines in the command reference.
- [ ] **Step 3: `SKILL.md`.** Add:

```markdown
When you run `slipstream attach`, pass `--name` with a 2-5 word name for the
workspace's overall work, for example `slipstream attach --name "Invoice totals refactor"`.
Name the workspace, not the current task, and don't rename it for each task.
```

- [ ] **Step 4: Verify.** Run `npm test && npm run typecheck` (doc tests such as `check:package` must still pass).
- [ ] **Step 5: Commit**

```bash
git add docs/ask-agent/contract.md README.md docs/connect-agent-chat.md SKILL.md
git commit -m "chore: document stream names and ask agents to name their workspace"
```

---

# PR 2 — client (`playola-radio/slipstream-client-swift`, base `develop` `54de11d`)

## File structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/SlipstreamCore/DaemonTransport.swift` | Modify | `SessionNaming`; `SessionSummary.naming` |
| `Sources/SlipstreamCore/StreamName.swift` | Create | The Swift mirror of the name rule |
| `Tests/SlipstreamCoreTests/Fixtures/stream-name-cases.json` | Create | Verbatim copy of the daemon's shared cases |
| `Sources/SlipstreamCore/ControlTransport.swift` | Modify | `rename(sessionID:name:)`; shared request runner |
| `Sources/SlipstreamCore/Rename.swift` | Create | Rename request encoding and reply decoding |
| `SlipstreamViewer/Dependencies/RenameClient.swift` | Create | `@Dependency(\.renameClient)` |
| `SlipstreamViewer/Models/FeedContent.swift` | Modify | `SessionOption.naming` |
| `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift` | Modify | Labels, rename availability, sheet ownership, window-activation refresh |
| `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift` | Modify | Menu item, shortcut, sheet, activation hook |
| `SlipstreamViewer/Views/Pages/RenameStreamPage/RenameStreamPage{Model,View}.swift` | Create | The Rename sheet |
| `SlipstreamViewerTests/Views/Pages/RenameStreamPage/RenameStreamPageTests.swift` | Create | Sheet model tests |

### Task 9: Decode `naming`

**Files:**
- Modify: `Sources/SlipstreamCore/DaemonTransport.swift:3-35`
- Test: `Tests/SlipstreamCoreTests/DecodingTests.swift`

**Interfaces:**
- Produces: `public struct SessionNaming: Equatable, Sendable, Decodable { public var agentName: String?; public var userName: String?; public init(agentName: String?, userName: String?) }`; `SessionSummary.naming: SessionNaming?` and `init(id:durableSeq:removed:agentConnection: = .unreported, naming: SessionNaming? = nil)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sessionNamingDecodesAndAbsentMeansOlderDaemon() throws {
  let named = try JSONDecoder().decode([SessionSummary].self, from: Data("""
    [{"id":"a","durable_seq":"1","removed":false,"naming":{"agent_name":"Invoice totals refactor","user_name":null}},
     {"id":"b","durable_seq":"1","removed":false}]
    """.utf8))
  expectNoDifference(named.map(\.naming), [SessionNaming(agentName: "Invoice totals refactor", userName: nil), nil])
}

@Test func malformedNamingFailsTheList() {
  for naming in [#"null"#, #"{"agent_name":null}"#, #"{"agent_name":5,"user_name":null}"#, #"[]"#] {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([SessionSummary].self, from: Data(#"[{"id":"a","durable_seq":"1","removed":false,"naming":\#(naming)}]"#.utf8))
    }
  }
}
```

- [ ] **Step 2: Run** `swift test --filter DecodingTests`. Expected: FAIL, `SessionNaming` undefined.
- [ ] **Step 3: Implement**

```swift
public struct SessionNaming: Equatable, Sendable, Decodable {
  public var agentName: String?
  public var userName: String?

  public init(agentName: String?, userName: String?) {
    self.agentName = agentName
    self.userName = userName
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentName = try Self.requiredNullable(container, .agentName)
    userName = try Self.requiredNullable(container, .userName)
  }

  private static func requiredNullable(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
    guard container.contains(key) else {
      throw DecodingError.keyNotFound(key, .init(codingPath: container.codingPath, debugDescription: "naming needs both keys"))
    }
    return try container.decodeNil(forKey: key) ? nil : container.decode(String.self, forKey: key)
  }

  private enum CodingKeys: String, CodingKey {
    case agentName = "agent_name"
    case userName = "user_name"
  }
}
```

In `SessionSummary`: add `public var naming: SessionNaming?`, the `naming` init parameter, `case naming` in `CodingKeys`, and in `init(from:)`:

```swift
    naming = container.contains(.naming) ? try container.decode(SessionNaming.self, forKey: .naming) : nil
```

(`decode` on a `null` value throws, which is the "`naming: null` is malformed" rule.)

- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -am "feature: read stream names from the session list"` (add the test file).

### Task 10: The name rule in Swift

**Files:**
- Create: `Sources/SlipstreamCore/StreamName.swift`
- Use, unchanged: `QuestionRequest.trim(_:)` in `Sources/SlipstreamCore/Questions.swift:69`. It is already `public static func trim(_ text: String) -> String`, so no visibility change is needed. Its character set also holds U+0009–U+000D, U+2028 and U+2029, which `check` rejects before it trims, so the result matches the ECMAScript trim.
- Create: `Tests/SlipstreamCoreTests/Fixtures/stream-name-cases.json` (byte-for-byte copy of the daemon's `docs/ask-agent/stream-name-cases.json` from PR 1; fetch it with `gh api repos/briankeane/slipstream/contents/docs/ask-agent/stream-name-cases.json?ref=<PR 1 head or develop> --jq .content | base64 -d`)
- Test: `Tests/SlipstreamCoreTests/StreamNameTests.swift`

**Interfaces:**
- Produces: `public enum StreamName { public static let maximumBytes = 64; public static func check(_ text: String) -> Check }` and `public enum Check: Equatable, Sendable { case valid(String), empty, invalidCharacters, tooLong(bytes: Int) }`.

- [ ] **Step 1: Write the failing test**

```swift
import CustomDump
import Foundation
import Testing
@testable import SlipstreamCore

struct StreamNameTests {
  struct Case: Decodable { let input: String; let name: String?; let error: String? }

  @Test func matchesTheDaemonsSharedCases() throws {
    let url = try #require(Bundle.module.url(forResource: "stream-name-cases", withExtension: "json", subdirectory: "Fixtures"))
    for c in try JSONDecoder().decode([Case].self, from: Data(contentsOf: url)) {
      switch (StreamName.check(c.input), c.name, c.error) {
      case (.valid(let name), let expected?, nil):
        expectNoDifference(Array(name.utf8), Array(expected.utf8), "\(c.input.debugDescription)")
      case (.invalidCharacters, nil, "control"), (.empty, nil, "empty"), (.tooLong, nil, "too_long"): break
      case (let result, _, _): Issue.record("\(c.input.debugDescription) gave \(result)")
      }
    }
  }

  @Test func reportsTheTrimmedByteCount() {
    expectNoDifference(StreamName.check("  " + String(repeating: "a", count: 69)), .tooLong(bytes: 69))
  }
}
```

(Byte comparison matters: Swift `==` treats `"Cafe\u{301}"` and `"Café"` as equal; the daemon does not normalize. Check how existing fixtures are bundled in `Package.swift`; if `Fixtures` is a `.copy` resource, the lookup above works as is.)

- [ ] **Step 2: Run** `swift test --filter StreamNameTests`. Expected: FAIL.
- [ ] **Step 3: Implement**

```swift
/// The daemon's stream-name rule (docs/ask-agent/contract.md, "Stream names"),
/// checked as the user types. The daemon stays the authority.
public enum StreamName {
  public static let maximumBytes = 64

  public enum Check: Equatable, Sendable {
    case valid(String)
    case empty
    case invalidCharacters
    case tooLong(bytes: Int)
  }

  public static func check(_ text: String) -> Check {
    if text.unicodeScalars.contains(where: isForbidden) { return .invalidCharacters }
    let name = QuestionRequest.trim(text)
    if name.isEmpty { return .empty }
    let bytes = name.utf8.count
    return bytes > maximumBytes ? .tooLong(bytes: bytes) : .valid(name)
  }

  private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: true
    default: false
    }
  }
}
```

- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feature: check stream names in the app with the daemon's own cases"` (add the three files).

### Task 11: Rename over the control socket

**Files:**
- Create: `Sources/SlipstreamCore/Rename.swift`
- Modify: `Sources/SlipstreamCore/ControlTransport.swift:15-30`
- Create: `SlipstreamViewer/Dependencies/RenameClient.swift`
- Test: `Tests/SlipstreamCoreTests/ControlTransportTests.swift`

**Interfaces:**
- Consumes: the existing private `exchange(_:cancelled:)` and `QuestionError` (`.unavailable` before sending, `.outcomeUnknown` after, `.rejected(code:message:)`).
- Produces:
  - `ControlTransport.rename(sessionID: String, name: String?) async throws`
  - `RenameRequest.encoded(sessionID:name:) throws -> Data` and `RenameAcknowledgment.decode(_ data: Data, sessionID: String) throws` (internal to the module)
  - `struct RenameClient: Sendable { var rename: @Sendable (_ sessionID: String, _ name: String?) async throws -> Void }` with `liveValue`, `testValue = unimplemented`, and `DependencyValues.renameClient`.

- [ ] **Step 1: Write the failing tests** (use the file's `SocketFixture`)

```swift
@Test func renameSendsTheVerbAndConfirmsTheSession() async throws {
  let server = try SocketFixture()
  let serving = server.serve { fd in
    var request = Data()
    var byte: UInt8 = 0
    while Darwin.read(fd, &byte, 1) == 1, byte != 10 { request.append(byte) }
    let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
    expectNoDifference(json["verb"] as? String, "rename_session")
    expectNoDifference(json["session_id"] as? String, QuestionsTests.sessionID)
    #expect(json["name"] is NSNull)
    let reply = #"{"v":1,"ok":true,"session_id":"\#(QuestionsTests.sessionID)"}"# + "\n"
    _ = reply.utf8CString.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, reply.utf8.count) }
  }
  try await ControlTransport(store: server.store).rename(sessionID: QuestionsTests.sessionID, name: nil)
  try await serving.value
}

@Test func renameReplyDecoding() throws {
  let id = QuestionsTests.sessionID
  #expect(throws: QuestionError.rejected(code: "INVALID_NAME", message: "name is empty")) {
    try RenameAcknowledgment.decode(Data(#"{"v":1,"ok":false,"code":"INVALID_NAME","message":"name is empty"}"#.utf8), sessionID: id)
  }
  for malformed in [#"{"v":1,"ok":true,"session_id":"other"}"#, #"{"v":1,"ok":true}"#, "not json"] {
    #expect(throws: QuestionError.outcomeUnknown) { try RenameAcknowledgment.decode(Data(malformed.utf8), sessionID: id) }
  }
}
```

(If `QuestionsTests` has no `sessionID` constant, add `static let sessionID = "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90"` to these tests instead.)

- [ ] **Step 2: Run** `swift test --filter ControlTransportTests`. Expected: FAIL.
- [ ] **Step 3: Implement**

`Rename.swift`:

```swift
import Foundation

enum RenameRequest {
  static func encoded(sessionID: String, name: String?) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "v": 1, "verb": "rename_session", "session_id": sessionID, "name": name ?? NSNull(),
    ] as [String: Any], options: [.sortedKeys])
  }
}

enum RenameAcknowledgment {
  /// A reply that can't be verified counts as outcome-unknown: the rename may have applied.
  static func decode(_ data: Data, sessionID: String) throws {
    let decoder = JSONDecoder()
    guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.v == 1 else {
      throw QuestionError.outcomeUnknown
    }
    if !envelope.ok {
      guard let error = try? decoder.decode(Rejection.self, from: data) else { throw QuestionError.outcomeUnknown }
      throw QuestionError.rejected(code: error.code, message: error.message)
    }
    guard let reply = try? decoder.decode(Reply.self, from: data), reply.sessionID == sessionID else {
      throw QuestionError.outcomeUnknown
    }
  }

  private struct Envelope: Decodable { let v: Int; let ok: Bool }
  private struct Rejection: Decodable { let code: String; let message: String }
  private struct Reply: Decodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
  }
}
```

`ControlTransport.swift`: extract the body of `ask` into a generic runner and use it from both:

```swift
  public func ask(_ request: QuestionRequest) async throws -> QuestionAcknowledgment {
    try await perform(request.encoded()) { try QuestionAcknowledgment.decode($0, for: request) }
  }

  public func rename(sessionID: String, name: String?) async throws {
    try await perform(RenameRequest.encoded(sessionID: sessionID, name: name)) {
      try RenameAcknowledgment.decode($0, sessionID: sessionID)
    }
  }

  private func perform<T: Sendable>(_ body: Data, decode: @escaping @Sendable (Data) throws -> T) async throws -> T {
    let bytes = body + Data([10])
    let cancellation = Mutex(false)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result { try decode(exchange(bytes, cancelled: { cancellation.withLock { $0 } })) })
        }
      }
    } onCancel: {
      cancellation.withLock { $0 = true }
    }
  }
```

`RenameClient.swift` (same shape as `QuestionClient.swift`):

```swift
import Dependencies
import Foundation
import SlipstreamCore

struct RenameClient: Sendable {
  var rename: @Sendable (_ sessionID: String, _ name: String?) async throws -> Void
}

extension RenameClient: DependencyKey {
  static var liveValue: Self {
    let store = DescriptorDiscovery.storeURL(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
    let transport = ControlTransport(store: store)
    return Self(rename: { try await transport.rename(sessionID: $0, name: $1) })
  }

  static var testValue: Self { Self(rename: unimplemented("RenameClient.rename")) }
}

extension DependencyValues {
  var renameClient: RenameClient {
    get { self[RenameClient.self] }
    set { self[RenameClient.self] = newValue }
  }
}
```

- [ ] **Step 4: Run** `swift test`, then `xcodegen generate && xcodebuild build -scheme SlipstreamViewer -destination 'platform=macOS'`. Expected: PASS; every existing `ControlTransportTests` case still passes.
- [ ] **Step 5: Commit** `git commit -m "feature: send stream renames to the daemon"` (add new files).

### Task 12: Picker labels, `SessionOption.naming`, and refresh on activation

**Files:**
- Modify: `SlipstreamViewer/Models/FeedContent.swift:5-10`
- Modify: `ChangeStreamPageModel.swift` (`loadSessions` `:538-608`; `sessionLabels` `:840-855`; new `windowActivated(_:)` in User Actions; new `sessionStarts` cache)
- Modify: `ChangeStreamPageView.swift` (activation hook only)
- Test: `ChangeStreamPageTests.swift` (update every expected label at `:82-172`, add the cases below)

**Interfaces:**
- Consumes: `SessionSummary.naming` (Task 9).
- Produces: `SessionOption.naming: SessionNaming? = nil`; `ChangeStreamPageModel.fallbackLabel(for id: String) -> String` (private, used by Task 14); `@ObservationIgnored private var sessionStarts: [String: SessionStarted]`; `private func relabel()`; `func windowActivated(_ isActive: Bool) async`.

- [ ] **Step 1: Update existing expectations and write the failing tests**

Existing labels change from `"/work/alpha · started Oct 3 14:18:10"` to `"alpha · started Oct 3 14:18"`; same for every other fixture label (folder only, no seconds). Then add, in the suite's style:

```swift
@Test func labelsPreferYourNameThenTheAgentsThenTheFallback() async {
  fake.setSessions([
    SessionSummary(id: "a", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Invoice totals refactor", userName: "Billing cleanup")),
    SessionSummary(id: "b", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Invoice totals refactor", userName: nil)),
    SessionSummary(id: "c", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: nil, userName: nil)),
  ], starts: ["a": start("/w/one", 0), "b": start("/w/two", 0), "c": start("/w/louisville-v2", 0)])
  let model = makeModel()
  await model.viewAppeared()
  await Task.megaYield()
  expectNoDifference(model.sessions.map(\.label), ["Billing cleanup", "Invoice totals refactor", "louisville-v2 · started Jan 1 00:00"])
}

@Test func sameNamesGetTheirStartTimeAndRemainingCollisionsGetTheID() async {
  let docs = SessionNaming(agentName: "Docs pass", userName: nil)
  fake.setSessions([
    SessionSummary(id: "a", durableSeq: .zero, removed: false, naming: docs),
    SessionSummary(id: "b", durableSeq: .zero, removed: false, naming: docs),
    SessionSummary(id: "c", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "x · started Jan 1 00:00", userName: nil)),
    SessionSummary(id: "d", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: nil, userName: nil)),
  ], starts: ["a": start("/w/a", 0), "b": start("/w/b", 60_000), "c": start("/w/c", 0), "d": start("/w/x", 0)])
  let model = makeModel()
  await model.viewAppeared()
  await Task.megaYield()
  expectNoDifference(model.sessions.map(\.label), [
    "Docs pass · started Jan 1 00:00", "Docs pass · started Jan 1 00:01",
    "x · started Jan 1 00:00 · c", "x · started Jan 1 00:00 · d",
  ])
}

@Test func aStreamWithoutAStartRecordKeepsItsNameOrShowsItsID() async {
  fake.setSessions([
    SessionSummary(id: "a", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Named", userName: nil)),
    SessionSummary(id: "b", durableSeq: .zero, removed: false, naming: SessionNaming(agentName: nil, userName: nil)),
  ], starts: [:])
  let model = makeModel()
  await model.viewAppeared()
  await Task.megaYield()
  expectNoDifference(model.sessions.map(\.label), ["Named", "b"])
}

@Test func activatingTheWindowRefreshesNames() async {
  let model = await connectedModel()
  fake.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false,
    naming: SessionNaming(agentName: "Renamed elsewhere", userName: nil))], starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
  await model.windowActivated(false)
  #expect(model.sessionPickerTitle != "Renamed elsewhere")
  await model.windowActivated(true)
  await Task.megaYield()
  expectNoDifference(model.sessionPickerTitle, "Renamed elsewhere")
}

@Test func aFailedRefreshKeepsThePreviousLabels() async {
  fake.setSessions([SessionSummary(id: "a", durableSeq: .zero, removed: false,
    naming: SessionNaming(agentName: "Docs pass", userName: nil))], starts: ["a": start("/w/a", 0)])
  let model = makeModel()
  await model.viewAppeared()
  await Task.megaYield()
  fake.setSessionsError(URLError(.cannotConnectToHost))
  await model.windowActivated(true)
  expectNoDifference(model.sessions.map(\.label), ["Docs pass"])
}
```

(`start(_ root: String, _ ms: Int64) -> SessionStarted` is a small private helper in the test file.)

- [ ] **Step 2: Run** `xcodebuild test -scheme SlipstreamViewer -destination 'platform=macOS' -only-testing:SlipstreamViewerTests/ChangeStreamPageTests`. Expected: FAIL.
- [ ] **Step 3: Implement**

`FeedContent.swift`: add `var naming: SessionNaming? = nil` to `SessionOption`.

`loadSessions`:
- Build options with `label: summary.id, …, naming: summary.naming`, then call `relabel()` once right after `sessions = …` so named sessions show their name before any start record loads.
- In the task group: `sessionStarts[id] = start` (when non-nil), keep the generation check, then `relabel()` instead of the per-id loop.
- In the `catch` branch, delete `sessions = []` so a failed refresh keeps the previous list and labels (spec: "A failed list refresh keeps the previous labels"). A failed first load still leaves the list empty, so the existing "daemon isn't running" test at `ChangeStreamPageTests.swift:210` is unchanged.

Replace `sessionLabels` with:

```swift
  private func relabel() {
    let labels = Self.sessionLabels(sessions, starts: sessionStarts, timeZone: timeZone)
    for (id, label) in labels { sessions[id: id]?.label = label }
    if let id = selectedSession?.id, let label = labels[id] { selectedSession?.label = label }
  }

  private func fallbackLabel(for id: String) -> String {
    sessionStarts[id].map { Self.fallback($0, timeZone: timeZone) } ?? id
  }

  private static func fallback(_ start: SessionStarted, timeZone: TimeZone) -> String {
    "\(URL(fileURLWithPath: start.root).lastPathComponent) · started \(startTime(start, timeZone: timeZone))"
  }

  private static func startTime(_ start: SessionStarted, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: Double(start.startedAtMs) / 1000))
  }

  private static func effectiveName(of session: SessionOption) -> String? {
    session.naming.flatMap { $0.userName ?? $0.agentName }
  }

  private static func sessionLabels(
    _ sessions: IdentifiedArrayOf<SessionOption>, starts: [String: SessionStarted], timeZone: TimeZone
  ) -> [String: String] {
    let nameCounts = Dictionary(sessions.compactMap(effectiveName(of:)).map { ($0, 1) }, uniquingKeysWith: +)
    var labels: [String: String] = [:]
    for session in sessions {
      let id = session.id
      if let name = effectiveName(of: session) {
        let start = starts[id]
        labels[id] = nameCounts[name, default: 0] > 1 && start != nil
          ? "\(name) · started \(startTime(start!, timeZone: timeZone))" : name
      } else {
        labels[id] = starts[id].map { fallback($0, timeZone: timeZone) } ?? id
      }
    }
    let labelCounts = Dictionary(labels.values.map { ($0, 1) }, uniquingKeysWith: +)
    return Dictionary(uniqueKeysWithValues: labels.map { id, label in
      (id, labelCounts[label, default: 0] > 1 ? "\(label) · \(id)" : label)
    })
  }
```

User Actions:

```swift
  func windowActivated(_ isActive: Bool) async {
    guard isActive else { return }
    await loadSessions()
  }
```

`ChangeStreamPageView`: `@Environment(\.appearsActive) private var appearsActive`, and on the root view:

```swift
    .onChange(of: appearsActive) { _, isActive in Task { await model.windowActivated(isActive) } }
```

- [ ] **Step 4: Run** the full app test target and `swift test`. Expected: PASS, including every pre-existing picker, readiness and generation test.
- [ ] **Step 5: Commit** `git commit -am "feature: show stream names in the picker and refresh them when the window comes forward"`

### Task 13: The Rename sheet model

**Files:**
- Create: `SlipstreamViewer/Views/Pages/RenameStreamPage/RenameStreamPageModel.swift`
- Test: `SlipstreamViewerTests/Views/Pages/RenameStreamPage/RenameStreamPageTests.swift`

**Interfaces:**
- Consumes: `StreamName.check` (Task 10); `renameClient` (Task 11, returns once the daemon confirms); `SessionNaming` (Task 9).
- Produces:

```swift
enum RenameOutcome: Equatable { case renamed, failed }

@MainActor @Observable final class RenameStreamPageModel: ViewModel, Identifiable {
  init(sessionID: String, subtitle: String, naming: SessionNaming)
  let sessionID: String
  var text: String                       // bound to the field
  var selection: TextSelection?          // whole text selected on open
  private(set) var isSaving: Bool
  // display: titleText, subtitle, placeholderText, agentRowText, clearButtonText,
  //          cancelButtonText, saveButtonText, fieldError, bannerText
  // helpers: canSave, isClearVisible, isCancelDisabled
  func saveTapped() async -> RenameOutcome
  func clearTapped() async -> RenameOutcome
}
```

Copy (from the approved frames; use exactly):

| Property | Value |
|---|---|
| `titleText` | `Rename stream` |
| `placeholderText` | `Name this stream` |
| `agentRowText` | agent name set → `Agent's name: <agentName>`; else your name set → `No name from the agent`; else `The agent hasn't named this stream` |
| `clearButtonText` | agent name set → `Use agent's name`; else `Use default name` |
| `cancelButtonText` | `Cancel` |
| `saveButtonText` | `Saving…` while saving, else `Save` |
| `fieldError` | empty and the sheet opened with a name → `Enter a name, or use the agent's name.` (agent name set) / `Enter a name, or use the default name.`; `.invalidCharacters` → `Names can't contain line breaks or control characters.`; `.tooLong(n)` → `Too long: n of 64 bytes.`; else the daemon's `INVALID_NAME` message until the text changes |
| `bannerText` (save failed) | `Couldn't save the name. Slipstream isn't responding. Your text is kept, so you can try again.` |
| `bannerText` (deleted) | `This stream was deleted.` |
| `bannerText` (outcome unknown) | `Slipstream didn't confirm the rename. Check the stream picker, or try again.` |

- [ ] **Step 1: Write the failing tests**

```swift
import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing
@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct RenameStreamPageTests {
  static let agentOnly = SessionNaming(agentName: "Invoice totals refactor", userName: nil)
  static let yours = SessionNaming(agentName: "Invoice totals refactor", userName: "Billing cleanup")

  func model(_ naming: SessionNaming, rename: @escaping @Sendable (String, String?) async throws -> Void = { _, _ in throw QuestionError.unavailable }) -> RenameStreamPageModel {
    withDependencies { $0.renameClient.rename = rename } operation: {
      RenameStreamPageModel(sessionID: "s", subtitle: "louisville-v1 · started Oct 14 15:02", naming: naming)
    }
  }

  @Test func opensWithTheEffectiveNameAndSaveDisabledUntilItChanges() {
    let sheet = model(Self.yours)
    expectNoDifference(sheet.text, "Billing cleanup")
    #expect(!sheet.canSave)
    #expect(sheet.isClearVisible)
    sheet.text = "  Billing and tax cleanup "
    #expect(sheet.canSave)
  }

  @Test func noNameYetOpensEmptyWithoutAnErrorAndHidesClear() {
    let sheet = model(SessionNaming(agentName: nil, userName: nil))
    expectNoDifference(sheet.text, "")
    expectNoDifference(sheet.fieldError, nil)
    expectNoDifference(sheet.agentRowText, "The agent hasn't named this stream")
    #expect(!sheet.isClearVisible)
  }

  @Test func yourNameWithoutAnAgentNameOffersTheDefault() {
    let sheet = model(SessionNaming(agentName: nil, userName: "Mine"))
    expectNoDifference(sheet.agentRowText, "No name from the agent")
    expectNoDifference(sheet.clearButtonText, "Use default name")
  }

  @Test func validationMessagesMatchTheFrames() {
    let sheet = model(Self.agentOnly)
    sheet.text = ""
    expectNoDifference(sheet.fieldError, "Enter a name, or use the agent's name.")
    sheet.text = "Billing cleanup\nnotes"
    expectNoDifference(sheet.fieldError, "Names can't contain line breaks or control characters.")
    sheet.text = String(repeating: "a", count: 69)
    expectNoDifference(sheet.fieldError, "Too long: 69 of 64 bytes.")
    #expect(!sheet.canSave)
  }

  @Test func savingSendsTheTrimmedNameAndLocksCancel() async {
    let sent = LockIsolated<[String?]>([])
    let sheet = model(Self.agentOnly) { _, name in sent.withValue { $0.append(name) } }
    sheet.text = " Billing cleanup "
    let outcome = await sheet.saveTapped()
    expectNoDifference(outcome, .renamed)
    expectNoDifference(sent.value, ["Billing cleanup"])
  }

  @Test func clearSendsNull() async {
    let sent = LockIsolated<[String?]>(["unset"])
    let sheet = model(Self.yours) { _, name in sent.withValue { $0 = [name] } }
    expectNoDifference(await sheet.clearTapped(), .renamed)
    expectNoDifference(sent.value, [nil])
  }

  @Test func failuresMapToTheirMessages() async {
    let cases: [(any Error, String?, String?)] = [
      (QuestionError.unavailable, "Couldn't save the name. Slipstream isn't responding. Your text is kept, so you can try again.", nil),
      (QuestionError.rejected(code: "STORAGE_UNAVAILABLE", message: "x"), "Couldn't save the name. Slipstream isn't responding. Your text is kept, so you can try again.", nil),
      (QuestionError.rejected(code: "SOMETHING_NEW", message: "x"), "Couldn't save the name. Slipstream isn't responding. Your text is kept, so you can try again.", nil),
      (QuestionError.outcomeUnknown, "Slipstream didn't confirm the rename. Check the stream picker, or try again.", nil),
      (QuestionError.rejected(code: "SESSION_NOT_FOUND", message: "x"), "This stream was deleted.", nil),
      (QuestionError.rejected(code: "INVALID_NAME", message: "name is empty"), nil, "name is empty"),
    ]
    for (error, banner, field) in cases {
      let sheet = model(Self.agentOnly) { _, _ in throw error }
      sheet.text = "Billing cleanup"
      expectNoDifference(await sheet.saveTapped(), .failed)
      expectNoDifference(sheet.bannerText, banner)
      expectNoDifference(sheet.fieldError, field)
      expectNoDifference(sheet.text, "Billing cleanup")
      #expect(!sheet.isSaving)
    }
  }

  @Test func aDeletedStreamCannotBeSavedAgain() async {
    let sheet = model(Self.agentOnly) { _, _ in throw QuestionError.rejected(code: "SESSION_NOT_FOUND", message: "x") }
    sheet.text = "Billing cleanup"
    _ = await sheet.saveTapped()
    #expect(!sheet.canSave)
  }

  @Test func cancelIsDisabledWhileSaving() async {
    let gate = AsyncStream<Void>.makeStream()
    let sheet = model(Self.agentOnly) { _, _ in for await _ in gate.stream { break } }
    sheet.text = "Billing cleanup"
    let task = Task { await sheet.saveTapped() }
    await Task.megaYield()
    #expect(sheet.isCancelDisabled)
    expectNoDifference(sheet.saveButtonText, "Saving…")
    gate.continuation.yield()
    _ = await task.value
    #expect(!sheet.isCancelDisabled)
  }
}
```

- [ ] **Step 2: Run** `xcodebuild test … -only-testing:SlipstreamViewerTests/RenameStreamPageTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `RenameStreamPageModel` with the `// MARK:` order from `CLAUDE.md` (Dependencies, Initialization, Properties, Display Text, View Helpers, User Actions, Private Helpers):
  - Stored: `sessionID`, `subtitle`, `naming` (the opening snapshot), `text` (with `didSet { serverFieldError = nil }`), `selection = TextSelection(range: text.startIndex..<text.endIndex)`, `isSaving`, `isDeleted`, `bannerText`, `serverFieldError`.
  - Computed `openedWithName`, used by `fieldError`: `(naming.userName ?? naming.agentName) != nil`, from the opening snapshot.
  - `canSave`: `case .valid(let name) = StreamName.check(text)`, `name != (naming.userName ?? naming.agentName)`, `!isSaving`, `!isDeleted`.
  - `isClearVisible`: `naming.userName != nil`. `isCancelDisabled`: `isSaving`.
  - `saveTapped()`: guard `canSave`, take the `.valid` name, `await send(name)`. `clearTapped()`: guard `!isSaving && !isDeleted`, `await send(nil)`.
  - `send(_:)`: `isSaving = true; defer { isSaving = false }; bannerText = nil`; `do { try await renameClient.rename(sessionID, name); return .renamed }`; `catch QuestionError.outcomeUnknown` → unknown banner; `catch QuestionError.rejected("SESSION_NOT_FOUND", _)` → deleted banner, `isDeleted = true`; `catch QuestionError.rejected("INVALID_NAME", let message)` → `serverFieldError = message`; any other error → save-failed banner; all failures return `.failed`.
- [ ] **Step 4: Run** the test target. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feature: rename sheet with live validation and honest failure messages"` (add new files).

### Task 14: Wire the sheet into the Change stream window

**Files:**
- Modify: `ChangeStreamPageModel.swift` (Properties, Display Text, View Helpers, User Actions)
- Modify: `ChangeStreamPageView.swift` (toolbar menu `:295-305`, sheet)
- Create: `SlipstreamViewer/Views/Pages/RenameStreamPage/RenameStreamPageView.swift`
- Test: `ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes: Tasks 9–13; `fallbackLabel(for:)` (Task 12).
- Produces on `ChangeStreamPageModel`:
  `var renameStream: RenameStreamPageModel?`; `let renameStreamText = "Rename Stream…"`; `var canRenameStream: Bool`; `var renameUnavailableHint: String?`; `func renameStreamTapped()`; `func renameCancelTapped()`; `func renameSaveTapped() async`; `func renameClearTapped() async`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func renameIsOfferedOnlyForAListedStreamOnADaemonWithNames() async {
  let model = await connectedModel()
  #expect(!model.canRenameStream)
  expectNoDifference(model.renameUnavailableHint, "Update Slipstream to rename streams")
  fake.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false,
    naming: SessionNaming(agentName: nil, userName: nil))], starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
  await model.refreshTapped()
  #expect(model.canRenameStream)
  expectNoDifference(model.renameUnavailableHint, nil)
}

@Test func noSelectionDisablesRenameWithoutAHint() async {
  fake.setSessions([], starts: [:])
  let model = await connectedModel()
  #expect(!model.canRenameStream)
  expectNoDifference(model.renameUnavailableHint, nil)
}

@Test func aConfirmedRenameClosesTheSheetAndReloadsTheList() async {
  fake.setSessions(Self.unnamedProject, starts: Self.projectStart)
  let model = makeModel(rename: { _, _ in })
  await model.viewAppeared()
  await Task.megaYield()
  model.renameStreamTapped()
  model.renameStream?.text = "Billing cleanup"
  fake.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false,
    naming: SessionNaming(agentName: nil, userName: "Billing cleanup"))], starts: Self.projectStart)
  let calls = fake.sessionsCallCount
  await model.renameSaveTapped()
  await Task.megaYield()
  #expect(model.renameStream == nil)
  expectNoDifference(fake.sessionsCallCount, calls + 1)
  expectNoDifference(model.sessionPickerTitle, "Billing cleanup")
}

@Test func aFailedRenameKeepsTheSheetAndRefreshesTheList() async {
  fake.setSessions(Self.unnamedProject, starts: Self.projectStart)
  let model = makeModel(rename: { _, _ in throw QuestionError.outcomeUnknown })
  await model.viewAppeared()
  await Task.megaYield()
  model.renameStreamTapped()
  model.renameStream?.text = "Billing cleanup"
  let calls = fake.sessionsCallCount
  await model.renameSaveTapped()
  expectNoDifference(model.renameStream?.bannerText,
    "Slipstream didn't confirm the rename. Check the stream picker, or try again.")
  expectNoDifference(fake.sessionsCallCount, calls + 1)
}

@Test func cancelIsIgnoredWhileSaving() async {
  let (gate, open) = AsyncStream<Void>.makeStream()
  fake.setSessions(Self.unnamedProject, starts: Self.projectStart)
  let model = makeModel(rename: { _, _ in
    for await _ in gate { break }
  })
  await model.viewAppeared()
  await Task.megaYield()
  model.renameStreamTapped()
  model.renameStream?.text = "Billing cleanup"
  let saving = Task { await model.renameSaveTapped() }
  await Task.megaYield()
  model.renameCancelTapped()
  #expect(model.renameStream != nil)
  open.yield()
  await saving.value
  #expect(model.renameStream == nil)
}
```

Shared fixtures and the `makeModel` change these tests need:

```swift
static let unnamedProject = [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false,
  naming: SessionNaming(agentName: nil, userName: nil))]
static let projectStart = [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)]

// makeModel gains `rename: (@Sendable (String, String?) async throws -> Void)? = nil`
// and, inside its withDependencies block:
//   if let rename { $0.renameClient.rename = rename }
// The sheet model is created with withDependencies(from:), so it inherits the override.
```

- [ ] **Step 2: Run** the ChangeStreamPage tests. Expected: FAIL.
- [ ] **Step 3: Implement**

Model:

```swift
  // Properties
  var renameStream: RenameStreamPageModel?

  // Display Text
  let renameStreamText = "Rename Stream…"

  var renameUnavailableHint: String? {
    guard let selected = selectedSession, let listed = sessions[id: selected.id], listed.naming == nil else { return nil }
    return "Update Slipstream to rename streams"
  }

  // View Helpers
  var canRenameStream: Bool {
    guard let selected = selectedSession, let listed = sessions[id: selected.id] else { return false }
    return listed.naming != nil
  }

  // User Actions
  func renameStreamTapped() {
    guard let selected = selectedSession, let naming = sessions[id: selected.id]?.naming else { return }
    renameStream = withDependencies(from: self) {
      RenameStreamPageModel(sessionID: selected.id, subtitle: fallbackLabel(for: selected.id), naming: naming)
    }
  }

  func renameCancelTapped() {
    guard renameStream?.isSaving != true else { return }
    renameStream = nil
  }

  func renameSaveTapped() async {
    guard let sheet = renameStream else { return }
    await renameFinished(await sheet.saveTapped(), sheet: sheet)
  }

  func renameClearTapped() async {
    guard let sheet = renameStream else { return }
    await renameFinished(await sheet.clearTapped(), sheet: sheet)
  }

  // Private Helpers
  private func renameFinished(_ outcome: RenameOutcome, sheet: RenameStreamPageModel) async {
    guard renameStream === sheet else { return }
    if outcome == .renamed { renameStream = nil }
    await loadSessions()
  }
```

A confirmed rename closes the sheet and reloads the list (spec decision D4); the reply carries only the session id, so the new name arrives with that reload. `loadSessions()` bumps `sessionsGeneration` itself, so the reload supersedes any refresh that started earlier. A failed save may still have applied, so the list is reloaded then too. Capability and names are read from `sessions[id: selectedSession.id]`, never from the `selectedSession` copy.

View, toolbar menu:

```swift
      Menu(model.sessionPickerTitle) {
        ForEach(model.sessions) { session in
          Button(model.sessionMenuText(for: session)) { model.sessionSelected(session.id) }
        }
        Divider()
        Button(model.renameStreamText) { model.renameStreamTapped() }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .disabled(!model.canRenameStream)
        if let hint = model.renameUnavailableHint {
          Text(hint)
        }
      }
```

Sheet on the root view:

```swift
    .sheet(item: $model.renameStream) { sheet in
      RenameStreamPageView(model: sheet,
        cancel: { model.renameCancelTapped() },
        save: { Task { await model.renameSaveTapped() } },
        clear: { Task { await model.renameClearTapped() } })
        .interactiveDismissDisabled(sheet.isSaving)
    }
```

`RenameStreamPageView`: built from frames `p60lo9` … `QoKyQ` and `exports/*.json` (Phase 8) for sizes and fonts, using `DesignTokens` only (add any missing token to `DesignTokens.swift` copied from the export, never a literal). Title, subtitle, `TextField(model.placeholderText, text: $model.text, selection: $model.selection)`, the field error, the agent row with the clear button when `model.isClearVisible`, the banner when `model.bannerText` is set, then `Button(model.cancelButtonText, action: cancel).keyboardShortcut(.cancelAction).disabled(model.isCancelDisabled)` and `Button(model.saveButtonText, action: save).keyboardShortcut(.defaultAction).disabled(!model.canSave)`.

- [ ] **Step 4: Run** the full app test target and `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feature: rename the watched stream from the stream picker or with Shift-Command-R"` (add new files).

### Task 15: End-to-end check against a disposable daemon

Needs PR 1 merged into the daemon's `develop` (or its branch checked out).

- [ ] **Step 1:** In the daemon repo, `npm run qa:daemon` and note the disposable store path it prints (`$STORE`). Never use `~/.slipstream`.
- [ ] **Step 2:** In a scratch git worktree: `slipstream attach --store "$STORE" --harness codex --harness-session-id e2e --name "  Invoice totals refactor "`. Expect `ok` and `cat "$STORE"/sessions/*/name.json` showing the trimmed agent name.
- [ ] **Step 3:** Launch the app with `SLIPSTREAM_STORE="$STORE"`. Expect the picker title `Invoice totals refactor`.
- [ ] **Step 4:** Press ⇧⌘R **with the menu closed**. Expect the sheet. If the shortcut only fires while the menu is open, move `.keyboardShortcut` to a zero-opacity background `Button` that calls `model.renameStreamTapped()` (the pattern at `SlipstreamViewerApp.swift:27-32`), keep the menu item's label, and re-run.
- [ ] **Step 5:** Save `Billing cleanup`. Expect the title to change and `name.json` to hold both names. Reopen, press "Use agent's name", expect the title back to `Invoice totals refactor`.
- [ ] **Step 6:** Re-attach with `--name "Second"` from the terminal, bring the app window forward, expect `Second`.
- [ ] **Step 7:** Stop the daemon, try a rename, expect the save-failed banner with the text kept.
- [ ] **Step 8:** Against a daemon built from the old `develop` (`63add07`), expect fallback labels and the disabled "Rename Stream…" with "Update Slipstream to rename streams".
- [ ] **Step 9:** Record the results in the PR description. Remove the disposable store.

---

## Acceptance criteria

See [spec.md, "Acceptance criteria"](./spec.md#acceptance-criteria). Every item maps to a task above:
daemon storage and lock (Tasks 2–3), `rename_session` (4), attach and status (5), list (6), CLI and docs (7–8), client decode and validation (9–10), transport (11), labels and freshness (12), sheet (13–14), end to end (15).

## Unresolved questions

None blocking. Whether ⇧⌘R fires from a closed toolbar menu is checked in Task 15, Step 4, which also gives the fallback.
