# chimpread 0.4.0

A minimal download page, an Apple Silicon DMG installer, and optional iCloud Drive sync.

## Install

Download `chimpread-0.4.0-arm64.dmg`, open it, and drag chimpread to Applications.
Requires Apple Silicon (M1 or later) and macOS 14+. A ZIP is also available.
Checksums are included in `SHA256SUMS.txt`.

This early release is ad-hoc signed, **not Apple-notarized**. If macOS blocks it,
review [Apple’s instructions](https://support.apple.com/102445) before approving an app you trust.
No Terminal commands or global Gatekeeper changes are required.

## iCloud Drive sync — experimental

Choose **chimpread → iCloud Sync…** and select a dedicated folder in iCloud Drive.
Select that same folder on your other Mac, preferably starting with an empty library.
**Sync Now** saves and closes the active paper. Automatic checks run every minute
while the reader is closed. Wait for Finder to finish uploading before switching Macs.

Saved PDFs, annotations, metadata, notes, and reading positions transfer. Drafts and
connector permissions remain local. Concurrent notes are retained; different annotated
PDF versions become supporting files. Other metadata conflicts use the latest synced
revision. Cloud history and local recovery copies are retained; there is no pruning yet.

Local replica tests pass, but **real two-device iCloud delivery remains unverified**.
Keep a full backup of the local library. iCloud sync starts off; existing libraries
are not uploaded automatically by installing this update.

## Verification

- Native reader, migration, citation, and connector self-tests pass from the mounted DMG.
- Sync tests cover replica transfer, byte preservation, repeat sync, concurrent notes,
  concurrent PDF preservation, convergence, missing files, and corrupt blob rejection.
- Chrome native-message framing and official Python MCP SDK regression checks pass.
- DMG checksum verification, embedded app signature verification, and Applications shortcut pass.
- Native iCloud settings window verified with sync disabled; no real library was uploaded.
- Landing page checked visually: black background, centered clickable icon, keyboard focus,
  reduced-motion support, and direct DMG URL. No JavaScript, third-party assets, or tracking.

Google Docs live OAuth insertion remains unverified and requires setup. Chrome is an
unpacked extension, not a Chrome Web Store release. Intel, Windows, and iPad builds
are not provided.
