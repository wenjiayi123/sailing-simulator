# Visual asset rights ledger

The release has no blanket license for media. Every included image, vector,
video, or audio file is identified by path, SHA-256, origin, and license in
`data/verification/visual_asset_release_manifest_v1.json`.

## Included visual assets

- `assets/generated/release/*.svg` are project-authored vector replacements and
  are distributed under Apache-2.0. They replace legacy runtime references for
  the icon, hidden animation atlas, horizon, water floor, cloud bridge, rock
  albedo, and Xiaoyi officer portrait.
- `docs/readme-hero.svg`, the registered PNG files under `docs/screenshots/`
  (including `docs/screenshots/scenarios/`), and the four registered
  report screenshots are project-authored documentation artwork or project
  runtime captures and are distributed under Apache-2.0.
- The six registered files under `assets/generated/tasks/` are project-directed
  image-generation outputs for the five task horizons and their shared water
  texture. Their prompts, runtime purpose, paths, and hashes are recorded in
  `docs/TASK_VISUAL_ASSET_PROVENANCE.md`; they are distributed under
  `LicenseRef-Project-Generated-Asset`.
- The exact cargo-circuit MP4 and its poster/GIF derivatives are supplied by the
  project owner for public redistribution under
  `LicenseRef-User-Authorized-Public-Redistribution`. Their permission is
  limited to the registered files and hashes; it does not relicense unlisted
  legacy source assets visible in a rendered frame.

## Local-only excluded assets

Legacy character sequences, the old icon, reference rock photograph, old sound
effects, old backgrounds/cloud textures, and the old Xiaoyi raster portrait are
retained in the working tree so the author's source material is not destroyed.
They are not referenced by the public runtime and are excluded by the verified
full-visual release inventory. No redistribution permission is asserted for
them.

The release audit fails on an unregistered media file, digest mismatch, missing
license/source record, or a runtime reference to any excluded path.
