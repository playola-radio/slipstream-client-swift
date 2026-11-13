# Syntax highlighting — source lines and chat code read at a glance

**Status:** Ready to implement. Screens, adversarial review, implementation plan and simplicity gate are done. Plan: [implementation-plan.md](./implementation-plan.md).

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `95af09ccedbfd35c34e0049c4e58b53221de3b1b`
  (develop). `git fetch` failed on 2026-11-12 (no network), so this was checked against the local
  `origin/develop`, which equals `HEAD`. Re-check before implementing.
- Daemon (`playola-radio/slipstream`): not touched. The client works out the language from data it
  already has.

## Target surface

- `client` only.

## Why

Brian (2026-11-12): "I just noticed my cognitive load was high." Today every source line is
drawn in one flat colour (`DesignTokens.Colors.sourceLine`, `#BDCDDF`). You have to read the code
word by word to find its shape: where the keywords, strings and calls are.

Syntax colour should make code faster to scan, so that LLM mistakes stand out sooner (the product
goal). It must not drown out the blue "this changed" marks, which are what the stream is for.

## Scope

1. **Change-stream card source lines.** Every line of every card's code snippet is coloured by
   token kind (direction A). The change marks are drawn on top, unchanged:
   - the changed-line marker;
   - the `changedTextTint` run tint;
   - the removal tick.
2. **Chat reply fenced code blocks.** A fence whose language tag is supported is coloured with the
   same palette. Chat code has no change marks.
3. **One muted palette, with no blue in it.** Blue stays reserved for "changed". Token kinds and
   colours are listed below. They are taken from the Pen canvas, and the Pen file is the source of
   truth.

   | Kind | Colour | Inside a change tint |
   |---|---|---|
   | keyword | `#C3A6E6` | `#E3D6F4` |
   | string | `#A9CF9B` | `#CBE2C2` |
   | number, constant, enum case | `#E5B98C` | `#F0D7BD` |
   | type | `#8ECDC2` | `#BFE3DC` |
   | function call or declaration | `#E2D29A` | `#E8DBAE` |
   | comment | `#7D93A5` | `#D5DCE2` |
   | punctuation and operators | `#8DA2B4` | `#D5DDE3` |
   | plain identifier | `#C9D6E3` | `#D1DCE7` |

   Inside the 50% change tint (composited `#34658A`), every token uses its lifted colour, which is
   the base colour mixed toward white until it reaches 4.5:1 (finding R1). A token that is partly
   inside a tint is lifted only for the tinted characters.

4. **Falling back.** These are drawn flat, exactly as today:
   - a card whose file extension isn't supported, in `#BDCDDF`;
   - a chat fence with no tag or an unknown tag, in the `Chat.CodeBlock.color` primary.
5. **Languages (Brian, 2026-11-12):** Swift, TypeScript/JavaScript (`ts`, `tsx`, `js`, `jsx`,
   `mjs`, `cjs`), JSON, YAML, shell (`sh`, `bash`, `zsh`), Markdown, Python, CSS and HTML. Anything
   else falls back to flat.
6. **Language comes from data the client already has.** A card uses its file path's extension, and
   a chat block uses its fence tag (first word of the info string, case-insensitive). One resolver
   maps both, with an explicit alias table. Extensionless files (`Makefile`, `Dockerfile`, shebang
   scripts) are flat; there is no content sniffing. This is presentation derived on the client;
   the daemon is not asked.
7. **Lexical, whole-source colouring.** Colour comes from a lexer, not from understanding the
   code. "Type", "constant" and "function" are lexical guesses (a capitalised identifier, a
   `.case` after a dot, an identifier before `(`). When unsure, a word is a plain identifier.
   - A card lexes the whole captured after-file, which the loader already fetches, and projects
     the tokens onto the lines it shows. A snippet that starts inside a block comment or a
     multi-line string is coloured correctly. The working-tree file is never read.
   - A chat block lexes the whole block. An unclosed fence (a reply still arriving) is coloured
     like a closed one.
   - One language per source. Embedded languages (`<script>`/`<style>` in HTML, fences inside
     Markdown, JSX markup) are coloured by the host language's rules only. JSON accepts `//` and
     `/* */` comments.
8. **The text itself is unchanged.** Copy, Ask selection, truncation, ligatures and chat's
   horizontal scrolling behave as today. Each card line stays one `Text`, so the existing change
   marks keep their glyph positions.

## Non-goals

- The function-changes page.
- Themes, a palette setting, and light mode.
- Semantic or LSP highlighting. Lexical colouring only.
- Changing the change marks themselves (marker, tint, tick).
- Colouring the Ask selection differently. The selection draws over coloured text as it does today.

## Open questions

None. The highlighter is a small in-house lexer, decided in the implementation plan and confirmed
by the simplicity gate there.

## Adversarial review (Codex `gpt-6-astra`, 2026-11-12)

| # | Finding | Disposition |
|---|---|---|
| R1 | Inside the 50% change tint, token colours fall to 1.96–4.23:1 (keyword 2.95, punctuation 2.37). Today's flat text there is 3.86:1. | Resolved: Brian approved lifting every token inside a tint to ≥4.5:1 (palette table, scope 3). This supersedes the earlier comment-only lift to `#B3C4D2`. |
| R2 | "Models: none" is inaccurate: chat discards the fence tag (`ChatTabModel.swift:247–252`). No single language resolver is defined. | Resolved: scope 6 and Design deliverables reworded. |
| R3 | Lexing each shown line alone gets block comments and multi-line strings wrong; the loader already has the whole after-file (`CardContentLoader.swift:46`). Embedded languages are undecided. | Resolved: scope 7. Lex the whole file and project onto shown lines. Embedded languages use host-language rules only. |
| R4 | Syntax ranges must use the same display coordinates as the change ranges (tabs are expanded, `CardContentLoader.swift:94–103`). Layering was misdescribed: the tint draws behind the glyphs and the ticks after. | Resolved: scope 8. The coordinate mapping is in the plan. |
| R5 | Tokenizing inside view bodies would repeat on every redraw (`MarkdownText.swift:10` already reparses in `body`). | Cards: resolved. They tokenize in the content loader off the main thread and cache with the content. Chat: accepted with rationale. It tokenizes when `markdownBlocks` builds the blocks, and that runs in the view body, so it repeats on redraw as Markdown parsing already does. Chat code blocks are small and the lexer is linear (plan, S9). Files over 1 MiB are already rejected. |
| R6 | Behaviour for an unclosed fence is undefined. | Resolved: scope 7, coloured like a closed fence. |
| R7 | Semantic type and constant detection can't be guaranteed. | Resolved: scope 7, lexical guesses with a plain-identifier fallback. |
| R8 | Acceptance criteria are missing. | Resolved in the plan: table-driven resolver tests; fragment and multi-line fixtures; open-fence tests; unchanged copy and Ask text; visual check of marks, Unicode, ligatures and truncation. |

## Approval log

| Date | What | Revision |
|---|---|---|
| 2026-11-12 | Direction **A · Colour every line** chosen over B (dim context lines) and C (colour only changed lines). Brian: "I like A — I like A a LOT!" | Pen zone `CLeqn`, A column `dVYbc` |
| 2026-11-12 | **Change-stream card** states approved: Highlighted, Unsupported language, Ask selection, including the comment lift to `#B3C4D2` inside a tint. Brian: "approved" | Nodes `O5yb0`, `I8nfWI`, `hwIGn` |
| 2026-11-12 | Language list approved, adding CSS and HTML (SQL not included) | Scope item 5 |
| 2026-11-12 | **Chat reply code block** states approved: Tagged fence, Untagged or unknown fence. Common tag aliases (`typescript`/`ts`, `py`/`python`, `yml`/`yaml`, `bash`/`sh`/`zsh`) count as supported. Brian: "approved" | Nodes `KaEDj`, `iO7Nd` |
| 2026-11-12 | Inside a change tint, every token lifts toward white to ≥4.5:1 (R1). Brian: "looks good". Applied to `O5yb0` and `hwIGn` and re-exported. | Palette table, scope 3 |
| 2026-11-12 | **Implementation plan** approved, including the simplicity-gate dispositions S1–S11. Brian: "yes" | [implementation-plan.md](./implementation-plan.md) at `8e2e092` |

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: none — client-only presentation, no daemon or API change
- Models: none — no API or stored model changes. Client presentation types change (a chat code
  block keeps its fence tag; a card line carries token colours); those are in the implementation
  plan.
