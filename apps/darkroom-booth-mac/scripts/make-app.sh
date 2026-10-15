#!/bin/sh
# Builds a release binary and wraps it in DarkroomBooth.app with Info.plist,
# signed ad hoc for local use.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product DarkroomBooth
bin="$(swift build -c release --show-bin-path)"
app="build/Darkroom Booth.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/DarkroomBooth" "$app/Contents/MacOS/DarkroomBooth"
cp Sources/DarkroomBooth/Info.plist "$app/Contents/Info.plist"
# SwiftPM resource bundles (device catalogs) must sit next to the executable.
for bundle in "$bin"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
codesign --force --sign - "$app"
echo "Built $app"
