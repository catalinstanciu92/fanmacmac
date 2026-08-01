#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$project_root/dist/FanMac.app"
release_directory="$project_root/dist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/AppBundle/Info.plist")"
archive="$release_directory/FanMac-$version.zip"
checksum="$archive.sha256"

if [[ "${FANMAC_SIGN_IDENTITY:--}" != "-" ]]; then
    echo "This script creates the free ad-hoc release. Unset FANMAC_SIGN_IDENTITY before running it." >&2
    exit 1
fi

"$project_root/scripts/package-app.sh"

codesign --verify --deep --strict --verbose=2 "$app_bundle"
rm -f "$archive" "$checksum"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app_bundle" "$archive"
shasum -a 256 "$archive" > "$checksum"

echo "Created $archive"
echo "Created $checksum"
