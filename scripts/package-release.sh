#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
app="$PWD/build/chimpread.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
out="$PWD/build/release/$version"
mkdir -p "$out"
stage=$(mktemp -d "$PWD/build/installer.XXXXXX")
trap 'rm -rf "$stage"' EXIT
codesign --verify --deep --strict "$app"
ditto "$app" "$stage/chimpread.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read me first.txt" <<'TEXT'
chimpread — a little room to read

Requires an Apple Silicon Mac (M1 or later), macOS 14 or later.

1. Drag chimpread.app to Applications.
2. Open chimpread from Applications.
3. Import a PDF, or use File > Migrate from Zotero.

This early release is ad-hoc signed and is NOT Apple-notarized.
If macOS blocks it, review Apple's instructions for opening an app you trust:
https://support.apple.com/102445
No Terminal command or global security setting change is required.

Optional iCloud Drive sync is in chimpread > iCloud Sync.
Choose the same dedicated folder on each Mac. Sync Now saves and closes the
open paper. Automatic checks run while the reader is closed. Wait for Finder
uploads before switching Macs. Keep a backup; real two-device iCloud delivery
has not yet been verified. Drafts and connector permissions stay local.

Chrome extension setup: chimpread > Integrations > Show Extension.
Source, license, setup, and issue reporting:
https://github.com/benfngu/chimpread
TEXT
hdiutil create -volname "chimpread $version" -srcfolder "$stage" -format UDZO -ov "$out/chimpread-$version-arm64.dmg"
hdiutil verify "$out/chimpread-$version-arm64.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/chimpread-$version-arm64.zip"
(cd "$out" && shasum -a 256 "chimpread-$version-arm64.dmg" "chimpread-$version-arm64.zip" > SHA256SUMS.txt)
printf '%s\n' "$out"
