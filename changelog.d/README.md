# Release notes

A pull request with a change someone using the app would notice adds one new file here
instead of editing `CHANGELOG.md`, so pull requests never conflict over release notes.
Merging one to `develop` releases it: CI bumps the patch version, moves every note into
`CHANGELOG.md` under that version and deletes the files.

Name the file after the change, in kebab case, for example `changelog.d/pause-recording.md`:

```markdown
### Changes

- Pause and resume recording a workspace from its row in the sidebar. Paused
  workspaces stay listed, marked **Paused**.

### Ops

- Add the `EXAMPLE_KEY` secret to the `release` GitHub environment before merging.
```

- **`### Changes`**: what changes for the person using the app, not how it was built.
  These bullets are the release notes in the app's update dialog. Mention when a change
  needs an up-to-date Slipstream daemon. Wrap a long bullet by indenting its next lines.
- **`### Ops`**: something a person must do when this version ships. Never shown in the
  app. Leave the heading out when there is nothing to do.
- Only those two headings, `- ` bullets, and one-line `<!-- comments -->` are allowed.
  Anything else, or a file with no bullets, fails the release with the file and line.
  CI checks every pull request's notes.
- A pure chore with nothing visible to users adds no file; say so in the pull request
  description.

Preview what the next release will say:

```bash
ruby packaging/release_notes.rb notes CHANGELOG.md changelog.d
```
