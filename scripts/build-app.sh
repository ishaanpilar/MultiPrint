#!/bin/bash
# Builds MultiPrint.app into ./build.
#   --install   also copy it to ~/Applications
#   --release   universal (Apple silicon + Intel) build, zipped to build/MultiPrint-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)

if [[ "$MODE" == "--release" ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c release --product MultiPrint ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/MultiPrint"

APP="build/MultiPrint.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MultiPrint"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/MultiPrint"))"

if [[ "$MODE" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/MultiPrint.app"
    cp -R "$APP" "$HOME/Applications/"
    # Let Launch Services know about the app so "Open With" and the PDF menu find it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/MultiPrint.app"
    echo "Installed to ~/Applications/MultiPrint.app"
fi

if [[ "$MODE" == "--release" ]]; then
    ZIP="build/MultiPrint-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
    shasum -a 256 "$ZIP"
fi
