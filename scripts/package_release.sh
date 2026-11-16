#!/bin/bash
# Builds GlassTrack.app and packages it as the .zip and .dmg that go on a GitHub release.
# The in-app updater installs the .zip, so its name must keep ending in ".zip".
#   VERSION=1.3 ./scripts/package_release.sh   → build/GlassTrack-1.3-AppleSilicon.{zip,dmg}
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:?set VERSION, e.g. VERSION=1.3}"
export VERSION
export BUILD="${BUILD:-$(git rev-list --count HEAD)}"
./scripts/build_app.sh

NAME="GlassTrack-$VERSION-AppleSilicon"
rm -f "build/$NAME.zip" "build/$NAME.dmg"
ditto -c -k --keepParent build/GlassTrack.app "build/$NAME.zip"

STAGE=$(mktemp -d)
cp -R build/GlassTrack.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "GlassTrack $VERSION" -srcfolder "$STAGE" -ov -format UDZO "build/$NAME.dmg" >/dev/null
rm -rf "$STAGE"
echo "Packaged build/$NAME.zip and build/$NAME.dmg"
