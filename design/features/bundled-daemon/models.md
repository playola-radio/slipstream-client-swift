# Bundled daemon — Model changes

None. This feature adds no database tables or columns, and no new or changed persisted record
formats.

- **Bundled identity** is read from files the daemon build already produces: `app/package.json`
  `version` and `app/dist/build-id`. There is no runtime manifest. The extracted copy is checked
  by comparing it byte for byte with the signed bundle.
- **`<store>/control/install.json`** stays at version 1, written by the existing
  `writeManagedInstall`.
  - `slipstream service install` fills `node` and `cli` with the app runtime's concrete versioned
    paths.
  - `repos` is kept as it was.
  - The format is unchanged.
- **The runtime descriptor** (`<store>/runtime/<uuid>.json`) and the `status` reply are unchanged.
