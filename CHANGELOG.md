# Changelog

Notable changes to Slipstream for macOS. Release notes describe what changes for
the person using the app, not how it was built.

Don't edit this file in a pull request; add a file to `changelog.d/` (see
[changelog.d/README.md](changelog.d/README.md)).

## [Unreleased]

### Changes

- See the workspace name in a slimmer window header, with the sidebar toggle and
  **Open in** close at hand.
- Reload workspaces from **View > Reload Workspaces** with **⌘R**; Slipstream also
  reloads when it becomes active again.

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
