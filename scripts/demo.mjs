#!/usr/bin/env node
// A throwaway Slipstream you can watch: a disposable daemon, a scratch worktree that
// keeps changing, a stand-in agent that answers questions, and the app pointed at it.
//
//   node scripts/demo.mjs            # build and open the app too
//   node scripts/demo.mjs --no-app   # daemon + changes + answers only
//   node scripts/demo.mjs --manual   # ask nothing; you ask every question, the agent answers
//   node scripts/demo.mjs --keep     # leave the scratch directory behind on exit (make … KEEP=1)
//
// Ctrl-C (or quitting the app) stops everything and deletes the scratch directory.
// Never touches ~/.slipstream. Set SLIPSTREAM_DAEMON_DIR to use an existing daemon
// checkout; otherwise develop is cloned into ~/.cache/slipstream-demo/daemon.

import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = new Set(process.argv.slice(2));
const withApp = !args.has('--no-app');
const keep = args.has('--keep');
const seedsQuestions = !args.has('--manual');
const CHANGE_EVERY_MS = 4000;
const USER_ANSWER_DELAY_MS = 6000;
const SEED_TIMEOUT_MS = 20000;
const RETRY_ATTEMPTS = 5;

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
const root = mkdtempSync('/tmp/ss-demo-');
const store = join(root, 'store');
const work = join(root, 'work');
const harnessSessionID = randomUUID();
const transcript = join(store, 'demo-transcript.jsonl');

const log = (...parts) => console.log(`[${new Date().toLocaleTimeString()}]`, ...parts);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Every child runs in its own process group and is tracked from the moment it is
// spawned until its whole group is gone, so shutdown can kill it (and anything it
// started) in any phase.
let stopped = false;
const children = new Set();

function spawnTracked(command, argv, options) {
  if (stopped) throw new Error('stopping');
  const child = spawn(command, argv, { ...options, detached: true });
  children.add(child);
  child.once('exit', () => { if (!killGroup(child, 0)) children.delete(child); });
  return child;
}

function killGroup(child, signal) {
  try { process.kill(-child.pid, signal); return true; } catch { return false; }
}

function run(command, argv, { cwd, input, env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnTracked(command, argv, { cwd, env: env ?? process.env, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (s) => { stdout += s; });
    child.stderr.setEncoding('utf8').on('data', (s) => { stderr += s; });
    child.once('error', reject);
    child.once('close', (code) => resolve({ stdout, stderr, code }));
    child.stdin.end(input);
  });
}

async function must(command, argv, options) {
  const result = await run(command, argv, options);
  if (result.code !== 0) throw new Error(`${command} ${argv.join(' ')} failed:\n${result.stderr || result.stdout}`);
}

async function withRetry(what, attempt) {
  for (let n = 1; ; n++) {
    try {
      return await attempt();
    } catch (error) {
      if (stopped || n === RETRY_ATTEMPTS) throw error;
      log(`retry   ${what} failed (attempt ${n}/${RETRY_ATTEMPTS}): ${error.message}`);
      await sleep(1000 * 2 ** (n - 1));
    }
  }
}

// MARK: - Daemon checkout

// The daemon repo is private: HTTPS works with a git credential helper (`gh auth
// setup-git`), SSH with a GitHub key. Try both before giving up.
const DAEMON_REMOTES = ['https://github.com/briankeane/slipstream.git', 'git@github.com:briankeane/slipstream.git'];

async function cloneDaemon(dir) {
  const failures = [];
  for (const remote of DAEMON_REMOTES) {
    log(`cloning the daemon (develop) from ${remote}…`);
    const result = await run('git', ['clone', '--quiet', '--branch', 'develop', remote, dir]);
    if (result.code === 0) return;
    failures.push(`${remote}: ${result.stderr.trim()}`);
  }
  throw new Error(`could not clone the daemon:\n${failures.join('\n')}\nSet SLIPSTREAM_DAEMON_DIR to an existing checkout instead.`);
}

async function daemonCheckout() {
  const dir = process.env.SLIPSTREAM_DAEMON_DIR ?? join(homedir(), '.cache', 'slipstream-demo', 'daemon');
  if (!process.env.SLIPSTREAM_DAEMON_DIR) {
    if (!existsSync(dir)) {
      await cloneDaemon(dir);
    } else {
      await must('git', ['fetch', '--quiet', 'origin', 'develop'], { cwd: dir });
      await must('git', ['checkout', '--quiet', '--detach', 'origin/develop'], { cwd: dir });
    }
  }
  const lockHash = createHash('sha256').update(readFileSync(join(dir, 'package-lock.json'))).digest('hex');
  const stamp = join(dir, 'node_modules', '.demo-lock-hash');
  if (!existsSync(stamp) || readFileSync(stamp, 'utf8') !== lockHash) {
    log('installing daemon dependencies…');
    await must('npm', ['ci', '--silent'], { cwd: dir });
    writeFileSync(stamp, lockHash);
  }
  return dir;
}

// MARK: - Scratch worktree

const seedFiles = {
  'src/user.ts': [
    'export interface User {', '  id: string;', '  name: string;', '  email: string;', '}', '',
    'export function displayName(user: User): string {', '  return user.name.trim();', '}', '',
    'export function isValidEmail(email: string): boolean {', "  return email.includes('@');", '}', '',
    'export const MAX_NAME_LENGTH = 64;',
  ],
  'src/cart.ts': [
    "import { priceWithTax } from './pricing';", '',
    'export interface Item {', '  sku: string;', '  price: number;', '  quantity: number;', '}', '',
    'export function subtotal(items: Item[]): number {', '  return items.reduce((sum, item) => sum + item.price * item.quantity, 0);', '}', '',
    'export function total(items: Item[]): number {', '  return priceWithTax(subtotal(items));', '}',
  ],
  'src/pricing.ts': [
    'export const TAX_RATE = 0.08;', 'export const FREE_SHIPPING_OVER = 50;', '',
    'export function priceWithTax(amount: number): number {', '  return Math.round(amount * (1 + TAX_RATE) * 100) / 100;', '}', '',
    'export function shipping(amount: number): number {', '  return amount >= FREE_SHIPPING_OVER ? 0 : 5;', '}',
  ],
  'src/api.ts': [
    'const BASE_URL = "https://example.test/api";', 'const TIMEOUT_MS = 5000;', 'const RETRIES = 2;', '',
    'export async function getJSON(path: string): Promise<unknown> {', '  const response = await fetch(BASE_URL + path);',
    '  if (!response.ok) throw new Error(`HTTP ${response.status}`);', '  return response.json();', '}',
  ],
};
const files = Object.keys(seedFiles);

async function seedWorktree() {
  for (const [path, lines] of Object.entries(seedFiles)) {
    await must('mkdir', ['-p', dirname(join(work, path))]);
    writeFileSync(join(work, path), lines.join('\n') + '\n');
  }
  await must('git', ['init', '--quiet'], { cwd: work });
  await must('git', ['add', '.'], { cwd: work });
  await must('git', ['-c', 'user.name=demo', '-c', 'user.email=demo@example.test', 'commit', '--quiet', '-m', 'seed'], { cwd: work });
}

const pick = (list) => list[Math.floor(Math.random() * list.length)];
const verbs = ['format', 'normalize', 'validate', 'compute', 'resolve', 'clamp'];
const nouns = ['Total', 'Name', 'Discount', 'Limit', 'Offset', 'Quantity'];

function mutate(path) {
  const full = join(work, path);
  const lines = readFileSync(full, 'utf8').replace(/\n$/, '').split('\n');
  const numbered = lines.map((line, index) => ({ line, index })).filter(({ line }) => /\d/.test(line));
  const roll = Math.random();
  let summary;
  if (roll < 0.45 || lines.length < 10) {
    const name = `${pick(verbs)}${pick(nouns)}`;
    const k = 2 + Math.floor(Math.random() * 9);
    lines.push('', `export function ${name}(value: number): number {`, `  return Math.max(0, value * ${k});`, '}');
    summary = `added ${name}()`;
  } else if (roll < 0.85 && numbered.length > 0) {
    const { line, index } = pick(numbered);
    lines[index] = line.replace(/\d+(\.\d+)?/, (n) => String(Number(n) + 1 + Math.floor(Math.random() * 5)));
    summary = `edited line ${index + 1}`;
  } else {
    const index = 1 + Math.floor(Math.random() * (lines.length - 1));
    lines.splice(index, 1);
    summary = `removed line ${index + 1}`;
  }
  writeFileSync(full, lines.join('\n') + '\n');
  log(`change  ${path}: ${summary}`);
}

// MARK: - Daemon and capture

const cli = (daemon, argv, input) => run(process.execPath, ['src/cli.ts', ...argv], { cwd: daemon, input });

async function startDaemon(daemon) {
  const child = spawnTracked(process.execPath, ['src/cli.ts', 'start', '--store', store], { cwd: daemon, stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  child.stderr.setEncoding('utf8').on('data', (s) => { stderr += s; });
  for (let i = 0; i < 100 && !existsSync(join(store, 'control.sock')); i++) {
    if (child.exitCode !== null) throw new Error(`daemon exited:\n${stderr}`);
    await sleep(100);
  }
  if (!existsSync(join(store, 'control.sock'))) throw new Error(`daemon did not open its control socket:\n${stderr}`);
  return child;
}

async function attach(daemon) {
  writeFileSync(transcript, JSON.stringify({
    type: 'attachment', sessionId: harnessSessionID, cwd: work, version: '2.1.280',
    entrypoint: 'sdk-ts', userType: 'external', isSidechain: false,
  }) + '\n', { mode: 0o600 });
  const result = await cli(daemon, ['attach', work, '--store', store, '--harness', 'claude-code',
    '--harness-session-id', harnessSessionID, '--root-transcript', transcript]);
  const sessionID = result.stdout.split('\n').find((line) => line.startsWith('session_id: '))?.slice(12);
  if (result.code !== 0 || !sessionID) throw new Error(`attach failed:\n${result.stderr}`);
  return sessionID;
}

function latestChanges(sessionID) {
  const path = join(store, 'sessions', sessionID, 'events.jsonl');
  if (!existsSync(path)) return new Map();
  const byPath = new Map();
  const lines = readFileSync(path, 'utf8').split('\n');
  lines.pop(); // '' after the last complete record, or a record still being written
  for (const line of lines) {
    const record = JSON.parse(line);
    if (record.type === 'slipstream.file.changed.v1' && record.data?.after?.kind === 'content') {
      byPath.set(record.data.path, { seq: String(record.seq), path: record.data.path, sha: record.data.after.sha256 });
    }
  }
  return byPath;
}

// Retries reuse the request id, so the daemon never queues the same question twice.
async function ask(daemon, sessionID, change, text, replyTo) {
  const requestID = randomUUID();
  const input = join(root, `ask-${requestID}.json`);
  writeFileSync(input, JSON.stringify({
    text,
    context: { change_seq: change.seq, path: change.path, snapshot_sha256: change.sha, line_start: 2, line_end: 4 },
    ...(replyTo ? { reply_to_question_id: replyTo } : {}),
  }), { mode: 0o600 });
  const questionID = await withRetry(`ask "${text}"`, async () => {
    const result = await cli(daemon, ['ask', '--store', store, '--session', sessionID, '--request-id', requestID, '--input', input]);
    if (result.code !== 0) throw new Error(result.stderr.trim());
    const response = JSON.parse(result.stdout);
    if (!response.question_id) throw new Error('ask response did not include question_id');
    return response.question_id;
  });
  rmSync(input, { force: true });
  log(`ask     ${change.path}: "${text}"`);
  return questionID;
}

// MARK: - Stand-in agent

const longAnswer = [
  'Short version: it returns 0, but the path there is worth walking through.',
  ...Array.from({ length: 24 }, (_, i) => `Step ${i + 1}: the reducer visits each item, multiplies price by quantity, and adds it to the running sum; with no items the initial value of 0 is returned untouched.`),
  'That last line is the end of the answer — the bar should only flip to Answered once you have scrolled down to here.',
].join('\n\n');

// Keyed by question id. Seeding and claiming are serialized in agentStep, so a
// plan is registered immediately after its ask returns and before a claim runs.
const plannedAnswers = new Map();
let seedingDue = false;

async function claimNext(daemon) {
  const result = await cli(daemon, ['hook', 'claude-code', 'post-tool-use', '--store', store], JSON.stringify({
    hook_event_name: 'PostToolUse', session_id: harnessSessionID, cwd: work, transcript_path: transcript, tool_name: 'Bash',
  }));
  if (result.code !== 0 || !result.stdout.trim()) return null;
  const context = JSON.parse(result.stdout).hookSpecificOutput?.additionalContext ?? '';
  const questionID = context.match(/Slipstream question ([0-9a-f-]{36})/)?.[1];
  const text = context.match(/^Question: (.*)$/m)?.[1] ?? '';
  return questionID ? { questionID, text } : null;
}

async function answer(daemon, questionID, text) {
  const messages = [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'claude-code', version: 'demo' } } },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'slipstream_answer_question', arguments: { question_id: questionID, text } } },
  ].map((m) => JSON.stringify(m)).join('\n') + '\n';
  const result = await run(process.execPath, ['src/mcp-forwarder.ts', '--store', store], {
    cwd: daemon, input: messages,
    env: { PATH: process.env.PATH ?? '', CLAUDE_CODE_SESSION_ID: harnessSessionID, CLAUDE_PROJECT_DIR: work },
  });
  const reply = result.stdout.split('\n').filter(Boolean).map((l) => JSON.parse(l)).find((m) => m.id === 2);
  if (!reply?.result || reply.result.isError) {
    throw new Error(JSON.stringify(reply?.result?.structuredContent ?? result.stderr));
  }
}

async function agentLoop(daemon, sessionID) {
  while (!stopped) {
    try { await agentStep(daemon, sessionID); } catch (error) { log(`agent   ${error.message}`); await sleep(1500); }
  }
}

async function agentStep(daemon, sessionID) {
  if (seedingDue) {
    try {
      await seedQuestions(daemon, sessionID);
      seedingDue = false;
    } catch (error) {
      if (!stopped) console.error(error.message);
      await shutdown(1);
      return;
    }
  }
  const claimed = await claimNext(daemon);
  if (!claimed) { await sleep(1500); return; }
  const plan = plannedAnswers.get(claimed.questionID)
    ?? { delayMs: USER_ANSWER_DELAY_MS, text: `(demo agent) You asked: "${claimed.text}". It changed because the agent was refactoring this block; nothing else depends on it.` };
  plannedAnswers.delete(claimed.questionID);
  log(`agent   claimed "${claimed.text}", answering in ${plan.delayMs / 1000}s`);
  await sleep(plan.delayMs);
  if (stopped) return;
  // Resending the same answer is safe, and the daemon never offers a claimed question
  // again, so this is the only chance to answer it.
  try {
    await withRetry(`answer to "${claimed.text}"`, () => answer(daemon, claimed.questionID, plan.text));
  } catch (error) {
    if (!stopped) log(`agent   GAVE UP on ${claimed.questionID} (${error.message}): the daemon will not offer it again, so it stays unanswered`);
    return;
  }
  log(`agent   answered "${claimed.text}"`);
  if (plan.followUp) {
    const questionID = await ask(daemon, sessionID, plan.followUp.change, plan.followUp.text, claimed.questionID);
    plannedAnswers.set(questionID, plan.followUp.plan);
  }
}

async function recordedChanges(sessionID, paths) {
  const deadline = Date.now() + SEED_TIMEOUT_MS;
  for (;;) {
    const changes = latestChanges(sessionID);
    const missing = paths.filter((path) => !changes.has(path));
    if (missing.length === 0) return paths.map((path) => changes.get(path));
    if (Date.now() > deadline) {
      throw new Error(`no questions seeded: the daemon recorded no change to ${missing.join(', ')} within ${SEED_TIMEOUT_MS / 1000}s`);
    }
    await sleep(500);
  }
}

async function seedQuestions(daemon, sessionID) {
  const [first, second, third] = await recordedChanges(sessionID, files.slice(0, 3));
  const firstPlan = {
    delayMs: 4000,
    text: 'The agent tightened this block so the value can never go negative.',
    followUp: {
      change: first,
      text: 'Could this be simpler?',
      plan: { delayMs: 8000, text: 'Yes — the two branches could share one helper, but keeping them separate makes the diff easier to review.' },
    },
  };
  const firstID = await ask(daemon, sessionID, first, 'Why did this change?');
  plannedAnswers.set(firstID, firstPlan);
  const secondID = await ask(daemon, sessionID, second, 'What does this return when the cart is empty?');
  plannedAnswers.set(secondID, { delayMs: 5000, text: longAnswer });
  const thirdID = await ask(daemon, sessionID, third, 'Is this safe to ship?');
  plannedAnswers.set(thirdID, { delayMs: 20000, text: 'Mostly — the new constant needs a test before it ships.' });
}

// MARK: - App

async function launchApp() {
  log('building SlipstreamViewer…');
  await must('xcodegen', ['generate', '--quiet'], { cwd: repo });
  const derived = join(repo, '.build', 'demo-app');
  await must('xcodebuild', ['-scheme', 'SlipstreamViewer', '-destination', 'platform=macOS', '-derivedDataPath', derived, '-quiet', 'build'], { cwd: repo });
  const binary = join(derived, 'Build/Products/Debug/SlipstreamViewer.app/Contents/MacOS/SlipstreamViewer');
  return spawnTracked(binary, [], { env: { ...process.env, SLIPSTREAM_STORE: store }, stdio: 'ignore' });
}

// MARK: - Main

async function shutdown(code = 0) {
  if (stopped) return;
  stopped = true;
  log('stopping…');
  const running = [...children];
  const exited = running.filter((child) => child.exitCode === null && child.signalCode === null)
    .map((child) => new Promise((resolve) => child.once('exit', resolve)));
  for (const child of running) killGroup(child, 'SIGTERM');
  await Promise.race([Promise.all(exited), sleep(3000)]);
  process.exit(code);
}

// Runs on every exit, including crashes: nothing outlives the script, and the
// scratch root goes unless --keep.
process.on('exit', () => {
  for (const child of children) killGroup(child, 'SIGKILL');
  if (keep) log(`kept ${root}`);
  else rmSync(root, { recursive: true, force: true });
});
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => shutdown());

try {
  const daemon = await daemonCheckout();
  await seedWorktree();
  const daemonProcess = await startDaemon(daemon);
  daemonProcess.once('exit', () => { if (!stopped) { log('daemon exited'); shutdown(1); } });
  const sessionID = await attach(daemon);
  log(`daemon  store ${store}`);
  log(`capture session ${sessionID}`);
  log(`to open another window by hand: SLIPSTREAM_STORE=${store} <SlipstreamViewer binary>`);

  if (withApp) {
    const app = await launchApp();
    app.once('exit', () => { if (!stopped) { log('app closed'); shutdown(); } });
    log('app     opened — pick the session from the toolbar');
  }

  await sleep(2000);
  agentLoop(daemon, sessionID);
  let changes = 0;
  while (!stopped) {
    mutate(files[changes % files.length]);
    changes += 1;
    if (seedsQuestions && changes === files.length) seedingDue = true;
    await sleep(CHANGE_EVERY_MS);
  }
} catch (error) {
  if (!stopped) console.error(error.message);
  await shutdown(1);
}
