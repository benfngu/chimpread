#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/build/chimpread.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  Sources/Library.swift Sources/Reader.swift Sources/Interface.swift Sources/MCP.swift Sources/Audit.swift Sources/Citations.swift Sources/Zotero.swift Sources/BrowserConnector.swift Tests/ConnectorTests.swift Tests/SelfTests.swift Sources/main.swift \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework CryptoKit -framework JavaScriptCore \
  -o "$app/Contents/MacOS/chimpread.new"
mv "$app/Contents/MacOS/chimpread.new" "$app/Contents/MacOS/chimpread"
cp Info.plist "$app/Contents/Info.plist"
if [[ -f Assets/PaperShelf.icns ]]; then
  cp Assets/PaperShelf.icns "$app/Contents/Resources/chimpread.icns"
fi
cp -R Resources/Citations "$app/Contents/Resources/"
cp Resources/chrome-extension-id.txt "$app/Contents/Resources/"
cp -R ChromeExtension "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "$app"
