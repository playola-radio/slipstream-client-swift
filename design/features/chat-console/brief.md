Chat console in the Slipstream window — client brief

Date: 2026-10-18 · Owner: Brian · Written from the daemon workspace for the
slipstream-client-swift workspace, where the final design and build happen.

Why

Today Brian juggles two windows: click a workspace in Conductor, switch it in
Slipstream, ask a code question in Slipstream, go back to Conductor to give the
agent its next instruction. The goal is one window: the stream and the
agent chat side by side, switched together by one workspace picker.

Conductor’s local chats can’t be driven from outside (its API is cloud-only;
there is no supported way to send into a local Conductor chat). So the client
runs the chat agent itself. Brian decided this explicitly, and it amends the
project rule “Slipstream does not launch agents” (see “Daemon side” below).

What it is

A carbon copy of Conductor’s center pane (chat transcript + composer with an
agent/model picker), living in the Slipstream Swift app next to the stream.

v0.1 — do what the terminal does

Workspace picker drives both panes. Choosing a workspace switches the
stream and the chat. A workspace = a Slipstream capture; its folder is the
root in that capture’s slipstream.session.started.v1 event.
Tabs per workspace, a ”+” to start a new tab, and an agent picker
per tab (model/effort). v0.1 is Claude-only (Brian, 2026-10-18); build
the picker so Codex slots in next.
Live conversation: send messages; see the agent’s replies stream in, plus
what it’s doing (tool calls, edits, commands); a stop button that interrupts
the current turn.
Same behavior as Brian’s Conductor sessions today — permissions bypassed,
his user/project settings, skills, and plugins loaded.
Resume: closing and reopening the app (or a tab) continues the same
conversation.
Non-goals for v0.1: Conductor’s extras (its question pop-ups, diff comments,
checkpoints, PR buttons). Add later only if Brian misses them. Importing old
Conductor conversations is out (my guess; Brian didn’t ask for it).

Anti-goals: the chat must not become a second capture source; it never writes
file-change events. Don’t overlay Conductor or read its private database.

How Conductor runs Claude today (copy this)

Observed from Brian’s running Conductor tabs (Claude Code 2.1.300), one
long-running process per tab, cwd = the workspace folder:

claude --output-format stream-json --verbose --input-format stream-json \
  --thinking=adaptive --thinking-display=summarized \
  --effort=<picker> --model=<picker> --max-turns=1000 \
  --permission-prompt-tool=stdio --permission-mode=bypassPermissions \
  --disallowedTools=AskUserQuestion \
  --setting-sources=user,project,local \
  [--resume=<conversation id> | --session-id=<new uuid>]
Drop Conductor-only flags (--session-mirror, --plugin-dir=<Conductor's skill>, --chrome). Keep AskUserQuestion disallowed until there’s UI for it.
With --permission-prompt-tool=stdio, permission/control requests can still
arrive on stdout; v0.1 must answer them (allow) rather than hang.

Codex comes right after v0.1 (Brian’s call: Claude first, then Codex). Its
invocation is not yet observed: capture Conductor’s Codex command the same way
(ps -o args -ax while a Conductor Codex tab is open) and match it, and
confirm Codex can fork a conversation before designing its ask-at-a-line path.

Ask-at-a-line (after v0.1)

The existing inline thread UI (AskAgentPage, QuestionThreadPage) stays.
What changes is where the answer comes from:

Highlight lines → ask → the client makes a branch-off copy of the
selected tab’s conversation (Claude: --resume <id> --fork-session) and asks
there. The main chat is never interrupted or cluttered and can keep working.
The thread at the line shows only from the question onward (question,
answer, follow-ups). The copied conversation is background knowledge, never
displayed in the thread.
Follow-ups continue in that same copy. Each highlight gets its own copy.
Changes go back to the main chat, decided by the copy (Brian,
2026-10-18). The copy doesn’t edit files itself — two agents editing one
folder at once would collide, and the main agent wouldn’t know its files
changed. Instead, when the copy judges that Brian has asked for a change, it
says so in the thread (“Sending change request to chat…”) and hands it to
the original tab as its next message: a short summary it writes, the file and
lines, and a link back to the thread. If the main agent is busy, the message
queues (as Conductor queues). No button — the copy decides.
The thread shows exactly what was sent, so a misjudged hand-off is visible.
Mechanism is the builder’s call (e.g. a tool the client gives the copy, such
as an MCP tool send_change_request, rather than parsing text markers).
The resulting edit is made by the main agent, so it’s attributed to the
main conversation like any other edit.
Line-asks on a Conductor-run linked chat keep using the old ask path;
line-asks on a client-run tab use the new verb. A thread never mixes the two.
Ask-at-a-line needs a captured change to point at, so it’s only offered on
workspaces with a recording capture.
If recording the thread fails (daemon down, capture stopped), keep the thread
locally, mark it visibly “not saved to Slipstream’s log”, and retry. Never
drop it silently.
Honesty: the copy answers from what the agent said and did, not its private
reasoning; the UI must not present the answer as verified authorship.
Codex fork support is unconfirmed — verify before designing the Codex path.
Threads must land in Slipstream’s event log (they’re part of the public
record today). That needs a new daemon verb, record_question_exchange
(designed in the daemon repo: docs/chat-console/DESIGN.md). Ask-at-a-line
depends on that daemon PR; v0.1 does not.
Daemon side (for context)

v0.1 needs no daemon change. Capture and “possibly agent” attribution
already work for any agent running in the watched folder: the daemon finds
Claude/Codex conversation logs by folder, independent of how the agent was
started. Attribution reading is off unless the daemon is started with
--enable <harness> or a config file — check that when testing.
The old attach/hook/answer-tool plumbing is not used by client-run chats; it
stays for Conductor-run chats. Retiring it is a later call for Brian.
Decided

Client runs the agent (amends the “does not launch agents” rule).
Permissions/settings identical to Brian’s Conductor sessions.
Branch-off copy for ask-at-a-line; inline thread shows from the question on.
The copy hands change requests to the main chat itself (“Sending change
request to chat…”); no button. The main agent makes the edit.
Claude first; Codex right after v0.1.
All of this lives in the client; daemon change limited to recording threads.
Left to the client workspace

Layout and visual design (where the chat sits relative to the stream).
How tabs/conversation IDs are persisted locally (client UI state; the
conversations themselves are the agents’ own transcript files).
Showing history when a tab is resumed: --resume doesn’t replay past
messages on stdout, so the client reads the agent’s own transcript file
directly (my call; no daemon involvement). Budget for it — it’s a second
parser alongside the live stream.
Markdown rendering approach (no markdown dependency exists yet).
Process management details: login-shell environment for spawned agents
(GUI apps don’t inherit PATH), which claude/codex binary to use
(my call: the user’s own, resolved through the login shell), crash/restart.
Codex invocation and fork, in the follow-up slice after v0.1.