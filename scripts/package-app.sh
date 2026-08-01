#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_build_root="$project_root/.build/arm64-apple-macosx/release"
helper_scratch="$project_root/.build-helper"
helper_build_root="$helper_scratch/arm64-apple-macosx/release"
app_bundle="$project_root/dist/FanMac.app"
helper_destination="$app_bundle/Contents/Library/LaunchServices/com.fanmac.helper"
sign_identity="${FANMAC_SIGN_IDENTITY:--}"
team_id="${FANMAC_TEAM_ID:-LOCAL}"
helper_info="$helper_scratch/FanMacHelperInfo.plist"
app_requirement='identifier "com.fanmac.app"'
helper_requirement='identifier "com.fanmac.helper"'

if [[ "$sign_identity" != "-" ]]; then
    if [[ "$team_id" == "LOCAL" ]]; then
        echo "FANMAC_TEAM_ID is required when FANMAC_SIGN_IDENTITY is set." >&2
        exit 1
    fi
    app_requirement="anchor apple generic and identifier \"com.fanmac.app\" and certificate leaf[subject.OU] = \"$team_id\""
    helper_requirement="anchor apple generic and identifier \"com.fanmac.helper\" and certificate leaf[subject.OU] = \"$team_id\""
fi
escaped_app_requirement="${app_requirement//\"/\\\"}"
escaped_helper_requirement="${helper_requirement//\"/\\\"}"

rm -rf "$helper_scratch"
mkdir -p "$helper_scratch"
cp "$project_root/AppBundle/HelperInfo.plist" "$helper_info"
/usr/libexec/PlistBuddy -c "Set :FanMacTeamIdentifier $team_id" "$helper_info"
/usr/libexec/PlistBuddy -c "Set :SMAuthorizedClients:0 $escaped_app_requirement" "$helper_info"

swift build --configuration release --arch arm64 --package-path "$project_root" --product FanMac
swift build \
    --configuration release \
    --arch arm64 \
    --package-path "$project_root" \
    --scratch-path "$helper_scratch" \
    --product FanMacHelper \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "$helper_info" \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __launchd_plist \
    -Xlinker "$project_root/AppBundle/com.fanmac.helper.plist"

mkdir -p "$project_root/dist"
rm -f "$project_root/dist/FanMacHelper" "$project_root/dist/com.fanmac.helper.plist"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
mkdir -p "$app_bundle/Contents/Library/LaunchServices"
cp "$app_build_root/FanMac" "$app_bundle/Contents/MacOS/FanMac"
cp "$project_root/AppBundle/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$helper_build_root/FanMacHelper" "$helper_destination"
/usr/libexec/PlistBuddy -c "Set :SMPrivilegedExecutables:com.fanmac.helper $escaped_helper_requirement" "$app_bundle/Contents/Info.plist"

codesign \
    --force \
    --sign "$sign_identity" \
    --identifier com.fanmac.helper \
    --requirements "=designated => $helper_requirement" \
    "$helper_destination"
codesign \
    --force \
    --sign "$sign_identity" \
    --identifier com.fanmac.app \
    --requirements "=designated => $app_requirement" \
    "$app_bundle"

echo "Built $app_bundle"
if [[ "$sign_identity" == "-" ]]; then
    echo "Warning: ad-hoc signing is for local builds. Set FANMAC_SIGN_IDENTITY to an Apple signing identity for reliable first-use helper installation."
fi
