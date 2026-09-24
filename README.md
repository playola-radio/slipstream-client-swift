# slipstream-client-swift

Native macOS client for [Slipstream](https://github.com/briankeane/slipstream). It watches a
capture session and shows a live, scrolling feed of the code changes an agent is making.

- `SlipstreamCore` (SwiftPM library, `Sources/`): event decoding, arbitrary-precision seq,
  the SSE parser, daemon discovery, the HTTP transport, the single reconnecting follower,
  changed-line markers and follow state. No UI.
- `SlipstreamViewer` (macOS 15 app, `SlipstreamViewer/`): the change stream window. The
  Xcode project is generated from `project.yml` by XcodeGen; the generated
  `SlipstreamViewer.xcodeproj` is gitignored so `project.yml` stays the single source of
  truth and never conflicts in review.

## Requirements

- macOS 15 or later, Xcode 26.4 or later (Swift 6.3)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A running Slipstream daemon

## Build

```sh
swift build                      # library only
xcodegen generate                # after cloning or editing project.yml
xcodebuild -scheme SlipstreamViewer -destination 'platform=macOS' build
```

## Run

The app finds the daemon through its store directory. It uses `~/.slipstream` unless
`SLIPSTREAM_STORE` is set. Point it at a disposable store when testing:

```sh
SLIPSTREAM_STORE=/tmp/ss-qa/.slipstream \
  "$(xcodebuild -scheme SlipstreamViewer -showBuildSettings 2>/dev/null \
      | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/SlipstreamViewer.app/Contents/MacOS/SlipstreamViewer"
```

In Xcode, set `SLIPSTREAM_STORE` under Product → Scheme → Edit Scheme → Run → Environment
Variables instead.

Pick a session from the toolbar. New changes scroll into view while you are at the bottom;
scroll up to pause (the footer counts what arrived) and click **Jump to latest ↓** to
resume. Credentials are read from the daemon's runtime descriptor and held in memory only.

## Test

```sh
swift test                                                       # SlipstreamCore
xcodebuild -scheme SlipstreamViewer -destination 'platform=macOS' test   # page model
```

The live integration test in `SlipstreamCoreTests` runs only when `SLIPSTREAM_STORE` points
at a running daemon's store (see `LiveFollowTests.swift`); it is skipped otherwise.
