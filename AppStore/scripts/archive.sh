#!/bin/sh
# Archives the Release build and uploads it to App Store Connect.
#
#   AppStore/scripts/archive.sh ios             iPhone and iPad
#   AppStore/scripts/archive.sh macos           Mac
#   AppStore/scripts/archive.sh ios --no-upload archive and export locally only
#
# Needs: XcodeGen, Xcode signed in to your Apple account, and Config/Local.xcconfig
# with DEVELOPMENT_TEAM set. The team ID is read from that file and never printed.
set -eu

platform="${1:-}"
upload="yes"
[ "${2:-}" = "--no-upload" ] && upload="no"

case "$platform" in
  ios)   destination="generic/platform=iOS" ;;
  macos) destination="generic/platform=macOS" ;;
  *)     echo "usage: $0 ios|macos [--no-upload]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if [ ! -f Config/Local.xcconfig ]; then
  echo "Config/Local.xcconfig is missing. Copy Config/Local.xcconfig.example and set your team ID." >&2
  exit 1
fi
team="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig | head -1)"
if [ -z "$team" ] || [ "$team" = "ABCDE12345" ]; then
  echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig." >&2
  exit 1
fi

out="$root/build/appstore/$platform"
archive="$out/UnalomePocket.xcarchive"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate

echo "Archiving for $platform..."
xcodebuild archive \
  -project UnalomePocket.xcodeproj \
  -scheme UnalomePocket \
  -configuration Release \
  -destination "$destination" \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  > "$out/archive.log" 2>&1 || { tail -40 "$out/archive.log"; echo "Archive failed. Full log: $out/archive.log" >&2; exit 1; }

options="$out/ExportOptions.plist"
cp AppStore/scripts/ExportOptions.plist "$options"
/usr/libexec/PlistBuddy -c "Add :teamID string $team" "$options"
[ "$upload" = "no" ] && /usr/libexec/PlistBuddy -c "Set :destination export" "$options"

echo "Exporting..."
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$options" \
  -exportPath "$out/export" \
  -allowProvisioningUpdates \
  > "$out/export.log" 2>&1 || { tail -40 "$out/export.log"; echo "Export failed. Full log: $out/export.log" >&2; exit 1; }

rm -f "$options"

if [ "$upload" = "yes" ]; then
  echo "Uploaded. The build appears in App Store Connect under TestFlight after processing."
else
  echo "Exported to $out/export"
fi
