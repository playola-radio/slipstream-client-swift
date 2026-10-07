# Capture scope compatibility

The client follows daemon develop at `f3c076ee23d80ddf2ce44a9feed4d79f329128c0`
(Git filtering from daemon PR #50). The 73 interface cases and schema are copied
byte for byte from that revision; the PIN records all 220 source files.

- Active Git or filesystem scope advances replay without adding a feed row.
- Git scope becoming unavailable produces a whole-session capture-gap marker.
  Recovery does not remove that historical warning.
- Comparisons accept the ordered built-in exclusions with an optional
  `git-ignored` suffix, and retain `capture-scope-unavailable` gaps for the
  existing comparison caveat.
- The `ignore-rules` suffix remains accepted for the previously installed
  preview daemon during upgrades. This is compatibility with that server, not
  a claim that the merged daemon emits that marker. Combining suffixes,
  reordering exclusions, or adding unknown exclusions is rejected.
- The pending daemon PR #54 `.slipstreamignore` extension is not covered here.

Contract checks replay the merged daemon's Git-scope histories and decode its
comparison fixtures. Malformed scope events remain decoding errors. The native
model test verifies the warning is visible and remains after scope recovery.

The operational live check uses a disposable Git repository and the compiled
merged daemon: baseline and live ignored files stay absent, a TypeScript change
appears, and an authenticated comparison returns the `git-ignored` marker.
