# AISPM Host Agent — Releases

Public distribution of the AISPM host agent: release binaries, install
scripts and version manifests. **No source code lives here.**

## Install
The recommended path is from your AISPM console: **Agents Fleet → Deploy
agent** (downloads a self-contained installer package), or the one-liner
shown there. Both require root/Administrator on the target host.

## Verifying downloads
Every release ships `SHA256SUMS` and a `manifest.json` carrying per-asset
sha256. The install scripts verify checksums automatically; to verify
manually: `sha256sum -c SHA256SUMS`.

## Versioning
`channel.json` on this branch points at the current stable release
manifest. Releases are immutable; a bad release is yanked by re-pointing
`channel.json`, never by reusing a version number.
