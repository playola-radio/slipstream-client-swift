# Collapse a change card

## Why

Some changes are long but tell you little: a `package.json` bump, a lockfile, a formatting pass over
part of a file. They push the substantive changes off screen. Brian wants to fold one of those away
while leaving later, meaningful changes to the same file open.

## Goals

- Any file card in the change stream can be collapsed to its header line and expanded again.
- Collapsing is per card: a later card for the same file is unaffected.

## Non-goals

- No collapsing by file path, task group, or a list of "noisy" files (considered, not wanted).
- No persistence: collapsed state lives for the current session's feed only.

## Anti-goals

- Interface bloat. One small affordance on the existing header, nothing else.
- Logic in the view. The model owns collapsed state, the chevron choice and the accessibility text.

## Approaches

- **A. Collapse by file path** — one click hides every card for that file. Rejected: a formatting fix
  and a later substantive change to the same file must be closable independently.
- **B. Auto-collapse known noisy files** — fixed list, misses `package.json`, hides things silently.
  Rejected.
- **C. Per-card collapse (chosen)** — matches the formatting-fix case exactly.

## Design

- Clicking a card's header toggles it. A chevron at the header's leading edge shows the state
  (down = expanded, right = collapsed). The header keeps path, time and the `OPEN →` indicator.
- A collapsed card shows only its header; the code/note/loading area is hidden.
- New cards arrive expanded.
- State is a set of collapsed row IDs on `ChangeStreamPageModel`, cleared whenever the feed is
  rebuilt (session switch / feed generation change), so stale IDs never leak across sessions.
- Question bars under a card stay visible when it's collapsed — they're the user's own threads.
- If the ask-agent selection sits on a card that gets collapsed, the selection is dropped the same way
  it is when the block scrolls away (`sourceBlockDisappeared`).
- Chevron icon, colour and size come from `DesignTokens`; the header becomes a plain button with an
  accessibility label ("Collapse <path>" / "Expand <path>") from the model.

## Left to the builder

- Exact chevron asset (reuse an existing chevron in the asset catalog if one fits).
- Whether the toggle animates (match the existing pane-toggle animation if it does).
