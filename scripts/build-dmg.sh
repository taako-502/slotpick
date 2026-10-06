#!/bin/bash
set -euo pipefail

# Usage: bash scripts/build-dmg.sh VERSION BUILD_NUMBER OUTPUT_DIRECTORY
version=${1:?Version is required}
build_number=${2:?Build number is required}
output_dir=${3:?Output directory is required}
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid version' >&2; exit 1; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build number' >&2; exit 1; }
: "${CODE_SIGN_IDENTITY:?Developer ID Application identity is required}"
: "${APPLE_TEAM_ID:?Apple Developer Team ID is required}"
: "${SIGNING_KEYCHAIN:?Signing keychain is required}"
: "${NOTARYTOOL_PROFILE:?Notarization credential profile is required}"
[[ "$CODE_SIGN_IDENTITY" != '-' ]] || { echo 'Ad-hoc signing is not allowed for releases' >&2; exit 1; }

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
  -archivePath "$task_dir/SlotPick.xcarchive" \
  -clonedSourcePackagesDirPath "$task_dir/packages" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS='--timestamp' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" archive

# Archive/export also re-signs Sparkle's nested helpers and XPC services for distribution.
python3 - "$task_dir/ExportOptions.plist" <<'PY'
import os
import plistlib
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "method": "developer-id", "signingStyle": "manual",
    "teamID": os.environ["APPLE_TEAM_ID"],
    "signingCertificate": os.environ["CODE_SIGN_IDENTITY"],
}))
PY
xcodebuild -exportArchive -archivePath "$task_dir/SlotPick.xcarchive" \
  -exportOptionsPlist "$task_dir/ExportOptions.plist" -exportPath "$task_dir/exported"

mkdir -p "$task_dir/staging"
app_path="$task_dir/staging/SlotPick.app"
ditto --norsrc --noextattr "$task_dir/exported/SlotPick.app" "$app_path"
ln -s /Applications "$task_dir/staging/Applications"
codesign --verify --deep --strict "$app_path"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app_path/Contents/Info.plist")
[[ "$actual_version" == "$version" && "$actual_build" == "$build_number" ]]
lipo "$app_path/Contents/MacOS/SlotPick" -verify_arch arm64 x86_64

# Notarize and staple the app itself so it remains verifiable after copying out of the DMG.
notarize() {
  local archive=$1
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARYTOOL_PROFILE" \
    --keychain "$SIGNING_KEYCHAIN" --wait --timeout 20m --output-format json > "$task_dir/notary-result.json"
  python3 - "$task_dir/notary-result.json" <<'PY'
import json
import sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization failed: {result.get('status')} (submission {result.get('id')})")
PY
}
ditto -c -k --keepParent "$app_path" "$task_dir/SlotPick.zip"
notarize "$task_dir/SlotPick.zip"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

asset="SlotPick-$version.dmg"
hdiutil create -volname "SlotPick $version" -srcfolder "$task_dir/staging" -format UDZO "$task_dir/$asset"
codesign --force --sign "$CODE_SIGN_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp "$task_dir/$asset"
notarize "$task_dir/$asset"
xcrun stapler staple "$task_dir/$asset"
xcrun stapler validate "$task_dir/$asset"
hdiutil verify "$task_dir/$asset"
hdiutil attach -readonly -nobrowse -mountpoint "$task_dir/mounted" "$task_dir/$asset"
mounted=true
codesign --verify --deep --strict "$task_dir/mounted/SlotPick.app"
xcrun stapler validate "$task_dir/mounted/SlotPick.app"
spctl --assess --type execute --verbose=2 "$task_dir/mounted/SlotPick.app"
[[ "$(readlink "$task_dir/mounted/Applications")" == /Applications ]]
hdiutil detach "$task_dir/mounted"
mounted=false
cp "$task_dir/$asset" "$output_dir/$asset"
(cd "$output_dir" && shasum -a 256 "$asset" > "$asset.sha256")
python3 scripts/appcast.py --app "$app_path" --archive "$output_dir/$asset" \
  --sign-tool "$task_dir/packages/artifacts/sparkle/Sparkle/bin/sign_update" \
  --output "$output_dir/appcast.xml"
echo "Verified DMG: $output_dir/$asset"
