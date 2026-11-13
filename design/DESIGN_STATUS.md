# Design status

## Ask agent about selected lines

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| Full screen · dropdown closed | `yDIp9` | Exploring | Previously exported question composer. |
| Full screen · dropdown open | `OY4ZN` | Exploring | Previously exported question composer. |
| Modal only · dropdown closed | `U3qs1P` | Exploring | Previously exported question composer. |
| Modal only · dropdown open | `Q8o5Lh` | Exploring | Previously exported question composer. |
| Q8 · Compact question bars in the code feed | `v51ziQ` | Exploring | Compact blue question bars and connected reply popover. |

## Changed text inside stream cards

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| Option A · tint plus deletion tick | — (HTML proposal) | Approved 2026-09-27 | `features/live-change-stream/exports/2026-09-27/`. Not in the canvas. |

## Stream names

Zone `XxvOh` ("10 · Stream names · rename streams"). Spec: `features/stream-names/spec.md`.

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| Stream window (component) | `YiBPq` | Component | Mock Change stream window used by every frame below. |
| A1 · Picker menu open | `QS4AU` | Exploring | Direction A, chosen (D6). |
| A2 · Rename sheet | `x7JKQ` | Exploring | Direction A, chosen (D6). |
| B1 · Name in toolbar · hover | `lG7Sx` | Rejected | Direction B, not pursued. |
| B2 · Editing in place | `mYXcU` | Rejected | Direction B, not pursued. |
| Stream picker · menu open | `BNJ5S` | Approved 2026-10-14 | `exports/stream-picker--menu-open.png` |
| Stream picker · rename unavailable | `G5M93` | Approved 2026-10-14 | `exports/stream-picker--rename-unavailable.png` |
| Rename sheet · 8 states | `p60lo9`, `AHgJG`, `qeFrb`, `wpFbu`, `pmfs5`, `QAebu`, `RhnOw`, `QoKyQ` | Approved 2026-10-14 | `exports/rename-sheet--*.png` |

## Capture states

Zone `SP9Ol` ("12 · Capture states — is each workspace really recording?"). Spec: `features/capture-states/spec.md`.

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| Stream window (component) | `AyBoP` | Component | `CS · Window`, used by every change-stream frame below. |
| Change stream · 34 capture and chat-link states | see `features/capture-states/screens.md` | Exploring | `exports/change-stream--*.png` |
| Stream picker · menu open / state unavailable | `kIilE`, `eGE4q` | Exploring | `exports/stream-picker--*.png` |
| Ask Agent · 6 gate states | `gETof`, `J7Gw4`, `y3rtsC`, `ssOml`, `TX08u`, `WCdUs` | Exploring | `exports/ask-agent--*.png` |

## Bundled recorder

Zone 16 (title `uSI5e`, "16 · Bundled recorder"). Spec: `features/bundled-daemon/spec.md`.

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| Change stream · starting, update didn't finish, another recorder, won't start | `K7uP6`, `PsvtW`, `o3IPH`, `HZDOk` | Approved 2026-11-10 | `exports/change-stream--*.png`; full message in the feed |
| Change stream · stream open: restarting, update didn't finish, another recorder, won't start | `aZBNS`, `sLAQ5`, `RbXdB`, `pIu3P` | Approved 2026-11-10 | Docked above the footer |
| Change stream · migration incomplete | `Y1Pnk` | Approved 2026-11-10 | Always docked |

## Commit chapters

Zone `dcPGn` ("Zone · Commit chapters"). Spec: `features/commit-chapters/spec.md`.

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| Chapter heading / open chapter heading / stream marker (components) | `gPla3`, `VSPW0`, `HG5yk` | Component | Used by every frame below |
| Change stream · chapters, just committed, no commits yet, branch moves, chapters unavailable | `A3nxO`, `EiNBf`, `NhNk1`, `ybVL3`, `epuHV` | Approved 2026-11-11 | `exports/change-stream--*.png`; `ybVL3` is rev 2 |

## Syntax highlighting

Zone `CLeqn` ("Zone · Syntax highlighting"). Spec: `features/syntax-highlighting/spec.md`.

| Frame | Node ID | Status | Notes |
|---|---|---|---|
| A · Colour every line | `dVYbc` | Chosen 2026-11-12 | Direction A |
| B · Dim context lines / C · Colour only changed lines | `IJC5d`, `dRte1` | Rejected | Not pursued |
| Change card · highlighted, unsupported language, Ask selection | `O5yb0`, `I8nfWI`, `hwIGn` | Approved 2026-11-12 | `exports/change-card--*.png` |
| Chat code block · tagged fence, untagged fence | `KaEDj`, `iO7Nd` | Approved 2026-11-12 | `exports/chat-code-block--*.png` |
