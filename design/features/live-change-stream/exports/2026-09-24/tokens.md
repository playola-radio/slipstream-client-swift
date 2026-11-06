# Change stream — design values

Read from `~/Documents/ai-flow.pen`, frame `n2R36` ("A · Compact sticky task bar"),
feed column `Qdg5a` ("Hideable task activity feed"). The file-level variables
(`brand-*`, Manrope/Inter/IBM Plex Mono) belong to the brand studies. This frame
uses the literal values below instead.

## Fonts

| Use | Family | Size | Weight | Colour |
|---|---|---|---|---|
| Pane title ("Change stream") | Geist | 16 | 550 | `#D9E7EF` |
| Pane subtitle ("Full functions") | Geist | 10 | regular | `#7D98AD` |
| Task title | Geist | 15 | 550 | `#E0EBF1` |
| Task number badge ("01") | Geist Mono | 12 | regular | `#B2DEC9` |
| File path (card header) | Geist Mono | 11 | regular | `#A2CBE3` newest card, `#8DA9BD` others |
| Event time (card header) | Geist | 10 | regular | `#68879E` |
| Line number | Geist Mono | 10 | regular | `#5F8099`, 25 pt wide column |
| Source line | Geist Mono | 12 | regular | `#BDCDDF` |
| Live status ("Live · New changes appear below") | Geist | 11 | regular | `#789F91` |
| "Jump to latest ↓" | Geist | 10 | regular | `#82AAC5` |

Geist and Geist Mono are SIL Open Font License 1.1 (github.com/vercel/geist-font).

## Surfaces

| Element | Fill | Stroke | Radius | Padding / gap |
|---|---|---|---|---|
| Feed pane | `#191F27` | `#405562` | — | header 52 tall, padding 0×20, gap 10 |
| Stream | — | — | — | gap 28 between task groups, 24 inside a group |
| Task heading (sticky) | `#24313B` | `#526B7B` | — | 12×20 |
| Task number badge | `#344B57` | — | 3 | 6×8 |
| Card outer inset | — | — | — | 0×20 |
| File card | `#1C2630` | `#5B859F` newest, `#3F5363` others | 8 | — |
| Card header | `#2B4050` newest, `#283642` others | `#405564` | — | 12×14, gap 7 |
| Code block | `#1D2D3B` newest, `#1C2630` others | — | — | top 14, sides 10, bottom 16 |
| Code line | — | — | — | height 22, gap 10 |
| Changed-line marker | `#4B9CDA` | — | — | 3 wide, full line height; unchanged lines keep a transparent 3-wide slot |
| Live footer | — | `#314351` | — | 10×20, gap 8 |

## Icons (Lucide in the canvas)

| Canvas icon | Size | Colour | Suggested SF Symbol |
|---|---|---|---|
| `list-tree` (pane title) | 15 | `#96B7CA` | `list.bullet.indent` |
| `file-text` (card header) | 12 | `#789FB9` | `doc.text` |
| `activity` (live footer) | 13 | `#83BDA4` | `waveform.path.ecg` |
| `pin` (sticky task) | 13 | `#9ACBB8` pinned, `#7F96A6` idle | `pin` |
