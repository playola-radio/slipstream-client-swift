# Native contract map scope

The 2026-09-28 owner export under `exports/2026-09-28/contract-map/` supplies the primary layout for the fixture-backed Function changes screen. The existing containment tree remains available as the secondary view. The export is illustrative; the pinned `interface.v2` daemon response and `FUNCTION-CHANGES.md` determine what the native screen may claim.

The map groups loaded observed files by their parent directory. Each recorded changed declaration occupies one row with code location, input deltas, function identity, output and declared-throws deltas, and a possible-effects lane labeled **Not analyzed**. A ready file with no change, an identical file, or a file that could not be compared gets a file-status row. Search and counts cover loaded files only while pagination is incomplete. The same declaration selection and before/after source reference work in both views.

The native version deliberately replaces the illustration's "Entire codebase" with **Observed files** and its comparison labels with recorded sequence boundaries. It does not display the illustration's caller counts, task completion, live branch or Git metadata, shared-type propagation, nested fields, inferred behavior, "Now checks Active," direct effects, or source diff. A declared throws clause is a signature component in Outputs; it is not an effects analysis. TypeScript's inability to express a throws clause stays distinct from a known nonthrowing declaration. The selection panel shows recorded endpoint side, snapshot hash, and UTF-8 span as metadata, without opening a file viewer.

All seven owner export files are copied byte-for-byte. `tokens.md` records values extracted from the Pen node for native styling.
