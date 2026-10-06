#!/bin/bash
set -euo pipefail

# Usage: bash scripts/build-dmg.sh VERSION BUILD_NUMBER OUTPUT_DIRECTORY
version=${1:?Version is required}
build_number=${2:?Build number is required}
output_dir=${3:?Output directory is required}
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid version' >&2; exit 1; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build number' >&2; exit 1; }

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
# Use local temporary storage: cloud-synced directories may add Finder metadata that breaks codesign.
task_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/slotpick-dmg.XXXXXX")
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    if ! hdiutil detach "$task_dir/mounted"; then
      echo "Could not detach $task_dir/mounted; preserving temporary directory." >&2
      return
    fi
  fi
  rm -rf "$task_dir"
}
trap cleanup EXIT

cd "$repo_dir"
xcodebuild -project SlotPick.xcodeproj -scheme SlotPick -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$task_dir/derived" \
  -clonedSourcePackagesDirPath "$task_dir/packages" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" build

mkdir -p "$task_dir/staging"
app_path="$task_dir/staging/SlotPick.app"
ditto --norsrc --noextattr "$task_dir/derived/Build/Products/Release/SlotPick.app" "$app_path"
ln -s /Applications "$task_dir/staging/Applications"
codesign --verify --deep --strict "$app_path"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app_path/Contents/Info.plist")
[[ "$actual_version" == "$version" && "$actual_build" == "$build_number" ]]
lipo "$app_path/Contents/MacOS/SlotPick" -verify_arch arm64 x86_64

asset="SlotPick-$version.dmg"
hdiutil create -volname "SlotPick $version" -srcfolder "$task_dir/staging" -format UDZO "$task_dir/$asset"
hdiutil verify "$task_dir/$asset"
hdiutil attach -readonly -nobrowse -mountpoint "$task_dir/mounted" "$task_dir/$asset"
mounted=true
codesign --verify --deep --strict "$task_dir/mounted/SlotPick.app"
[[ "$(readlink "$task_dir/mounted/Applications")" == /Applications ]]
hdiutil detach "$task_dir/mounted"
mounted=false
cp "$task_dir/$asset" "$output_dir/$asset"
(cd "$output_dir" && shasum -a 256 "$asset" > "$asset.sha256")
python3 scripts/appcast.py --app "$app_path" --archive "$output_dir/$asset" \
  --sign-tool "$task_dir/packages/artifacts/sparkle/Sparkle/bin/sign_update" \
  --output "$output_dir/appcast.xml"
echo "Verified DMG: $output_dir/$asset"
