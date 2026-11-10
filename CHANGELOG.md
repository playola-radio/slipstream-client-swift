# Changelog

Notable changes to Slipstream for macOS. Release notes describe what changes for
the person using the app, not how it was built.

Don't edit this file in a pull request; add a file to `changelog.d/` (see
[changelog.d/README.md](changelog.d/README.md)).

## [Unreleased]

<!-- Don't add notes here: add a file to changelog.d/ (see changelog.d/README.md). -->

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
