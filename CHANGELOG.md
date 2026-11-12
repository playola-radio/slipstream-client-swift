# Changelog

Notable changes to Slipstream for macOS. Release notes describe what changes for
the person using the app, not how it was built.

Don't edit this file in a pull request; add a file to `changelog.d/` (see
[changelog.d/README.md](changelog.d/README.md)).

## [Unreleased]

<!-- Don't add notes here: add a file to changelog.d/ (see changelog.d/README.md). -->

## [0.4.12] - 2026-11-12

- A new chat now connects to its workspace's stream as soon as you send its first message,
  instead of after the agent's first reply, so you can ask it about changes while it works.
- The link icon on a chat tab only appears once the chat really is linked, and while the link
  is waiting for the agent to confirm it now says **Linked to Stream** instead of claiming
  it's connected.
- The stream no longer shows "Unsupported event" rows when a capture starts, stops or links
  a chat. A capture stopping or a chat linking now updates the stream panel right away.

## [0.4.11] - 2026-11-12

- New workspaces now appear at the top of their repository in the sidebar instead of the
  bottom. While one is being created, a **Creating workspace…** row with a spinner shows in
  its place, and the workspace's icon stays a spinner until its setup script finishes.

## [0.4.10] - 2026-11-12

- New workspaces now name themselves within seconds of your first message, instead of
  waiting for the agent to pick a name. Requires an up-to-date Slipstream daemon.

## [0.4.9] - 2026-11-12

- A repository stays in the sidebar after its last workspace is archived, so its **+**
  button can start a new workspace without adding the repository again. Right-click an empty
  repository and choose **Remove from sidebar** to drop it.

## [0.4.8] - 2026-11-12

- A bar above the right column shows the workspace's pull request status, with one button for the next step (create, push, fix, merge, continue).

## [0.4.7] - 2026-11-12

- Folders you record with **Record a folder…** stay in the sidebar after you select something
  else, and still appear after the app restarts. To take one out, right-click it and choose
  **Remove from sidebar**. This pauses its recording and leaves the folder on disk.

## [0.4.6] - 2026-11-11

- The sidebar lists only workspaces created in Slipstream. Chats Slipstream records in
  other folders, such as Conductor workspaces, no longer fill it up.
- Chats now name their workspace and start a task on their own once they are linked to the
  stream, so workspaces no longer stay "workspace-n" until you rename them. The name appears
  after your second message in a new chat. Slipstream's guidance to the chat is hidden from
  the conversation.

## [0.4.5] - 2026-11-11

- Chat replies now show headings, numbered and bulleted lists, quotes, dividers and
  bold text, instead of the raw markdown symbols.

## [0.4.4] - 2026-11-11

- The workspace sidebar keeps a steady order: repositories A to Z, and workspaces by
  folder name (`workspace-2` before `workspace-10`). Creating, archiving, pausing or
  renaming a workspace no longer shuffles the others, and a new workspace appears in
  its repository instead of briefly showing up under a long ID.

## [0.4.3] - 2026-11-11

- Slipstream now bundles recorder 0.3.2, so it can take over again from a recorder
  installed with npm. When a newer recorder is running, the recorder message says to
  update Slipstream instead of showing "Couldn't find …/runtime/bin/slipstream" when
  you link a chat, archive a workspace or run setup.

## [0.4.2] - 2026-11-11

- Slipstream now includes its own recorder, so one app update moves both and there is no
  separate npm install. Existing setups move over automatically the first time the new
  version opens.
- When the recorder can't start, update or connect, Slipstream shows exactly what went wrong,
  with the full error and a Copy button.

## [0.4.1] - 2026-11-11

- Workspaces in the sidebar now show a short name for what they're about. The agent names each
  one, and you can rename it from the right-click menu. Needs an up-to-date Slipstream daemon.

### Ops

- Before merging, allow `develop` in the `release` GitHub environment's deployment
  branch policy (Settings > Environments > release), otherwise the release job is refused.

## [0.4.0] - 2026-11-10

- The app is now called Slipstream instead of SlipstreamViewer in the menu bar, the
  About window and update prompts. New downloads install as Slipstream.app.
- A paused workspace stays in the sidebar only if Slipstream created it. Paused Conductor
  workspaces and other folders no longer clutter the list.

## [0.3.0] - 2026-11-10

- See the workspace name in a slimmer window header, with the sidebar toggle and
  **Open in** close at hand.
- Reload workspaces from **View > Reload Workspaces** with **⌘R**; Slipstream also
  reloads when it becomes active again.
- Hide or show either side of the window from the toolbar or the **View** menu:
  the workspaces sidebar with **⌘B**, the change stream and terminals with **⌥⌘B**.
- Drag the edge of the sidebar or the chat to resize it; double-click the edge to
  put it back. Slipstream remembers the sizes and what's hidden.
- When asking the agent a question or checking whether a requested change was done
  fails, the reply now says why, such as Claude Code's own error, a missing setup
  step or the daemon's reason, instead of only "the chat couldn't be reached".
- Once setup creates the new workspace, the terminals pane keeps each workspace's
  terminals separate, so another workspace's setup output no longer appears there
  or opens in its place.

## [0.2.0] - 2026-11-06

- Pause and resume recording a workspace from its row in the sidebar. Paused
  workspaces stay listed, marked **Paused**, with a **Record** button.
- Start recording another folder with **Record a folder…** at the bottom of the
  sidebar. When every recording slot is in use, it tells you to pause one first.
- Ask offers **Record** when its workspace is paused, and the chat links up again
  once recording resumes.
- Chats in a workspace that is recording stay connected.
- Pausing and recording need an up-to-date Slipstream daemon.

## [0.1.0] - 2026-11-05

- First signed release. Download the disk image, drag Slipstream to Applications,
  and it updates itself from then on (**Check for Updates…** in the app menu).
- Watch an agent's code changes arrive in a live, scrolling feed, pause by scrolling
  up, and jump back to the latest.
- Compare functions before and after a change in Map and Tree views.
- Create and archive workspaces, run agent chats and terminals in tabs, and ask the
  agent about selected code.
- Requires a running Slipstream daemon.
