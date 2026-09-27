# Change stream — changed text inside lines

Approved by Brian on 2026-09-27: **Option A** (tint plus deletion tick), chosen from a
proposal that showed a replacement, an insertion and a deletion-only edit side by side
(`intraline-highlight-option-a.png`). The proposal was an HTML mockup rendered in
Geist Mono, not a frame in `~/Documents/ai-flow.pen`; the canvas is unchanged.

These values add to `../2026-09-24/tokens.md`; everything there still applies.

| Element | Value | Notes |
|---|---|---|
| Changed-text tint | `#4B9CDA` at 50% opacity | Fills the glyph bounds of inserted or replaced characters, behind the text. Same blue as the line marker. Text colour does not change. Raised from the proposal's 28% after Brian reviewed it in the app: a one-character change was too faint on the dark card. |
| Deletion tick | `#4B9CDA`, 2 pt wide, glyph height | Drawn where characters were removed and nothing replaced them. Overlays the text; nothing moves. |

Rules:

- Only lines that already have a changed-line marker get character highlighting.
- A line whose earlier version can't be matched confidently keeps the marker only.
- Removed text is never shown and is never part of a selection.
