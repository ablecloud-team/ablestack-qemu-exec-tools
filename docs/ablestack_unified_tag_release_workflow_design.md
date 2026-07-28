# ABLESTACK Unified Tag Release Workflow Design

## Background

The former release path used two independent workflow runs:

1. A tag-triggered workflow generated WinPE and created or updated a partial
   GitHub Release.
2. A `workflow_run` workflow rebuilt Linux, Windows, V2K, and N2K artifacts,
   then updated the same Release.

This split made the official release depend on cross-run event metadata,
cross-run artifact lookup, and a second GitHub Release update. A failure in the
second update could leave a public Release that contained only WinPE assets.

## Design

`build-winpe-release.yml` is the only `v*` tag entry point.

1. `build` calls the reusable WinPE core and uploads the ISO and
   `SHA256SUMS` as `winpe-iso-release`.
2. `release` calls the reusable integrated `build.yml` after WinPE succeeds.
3. The integrated build downloads the WinPE artifact from the same top-level
   run, embeds the ISO in the V2K RPM, builds every package and OS ISO, and
   assembles the final release assets.
4. The final job creates the GitHub Release exactly once after all direct build
   dependencies succeed.

The integrated workflow remains manually dispatchable for validation.
Manual runs build their own `winpe-iso-validation` artifact and default to
`publish_release=false`.

## Source and Failure Policy

- The tag workflow passes the exact tag commit SHA to both reusable workflows.
- Every checkout uses the resolved `source_ref`.
- The top-level workflow grants `contents: write` for the one-time Release
  creation and `actions: read` for same-run artifact consumption.
- Missing WinPE ISO, missing `SHA256SUMS`, checksum mismatch, missing MSI, or
  any failed direct build dependency prevents publication.
- The release staging job requires exactly 12 assets: WinPE ISO,
  `SHA256SUMS`, three OS ISOs, three core RPMs, and four V2K/N2K RPMs.
- Dependency RPMs and source RPMs remain excluded from GitHub Release assets.

## Compatibility

- Existing manual release-build validation remains available.
- Official publication continues to use a `v*` tag.
- Existing release asset names and the V2K WinPE packaging contract remain
  unchanged.
- No database, runtime API, or installed package behavior changes.
