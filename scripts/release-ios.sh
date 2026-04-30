#!/usr/bin/env bash
#
# release-ios.sh — archive + export + upload SimmerSmith to TestFlight.
#
# Reads the App Store Connect API key from .release-ios.env (gitignored,
# lives in the repo root next to the AuthKey_*.p8 files). The .env file
# must define:
#   IOS_RELEASE_KEY_ID      — e.g. "6X83L5SG4J"; the AuthKey_<ID>.p8
#                             file in the repo root must match.
#   IOS_RELEASE_ISSUER_ID   — UUID from App Store Connect → Users and
#                             Access → Integrations → App Store Connect
#                             API.
#
# Why this script exists: `xcodebuild -exportArchive` falls through to
# Xcode-account auth when no `-authenticationKey*` flags are passed.
# That auth state isn't durable from a non-interactive shell, so
# previous "it worked once, now it doesn't" upload failures were really
# Xcode-session expirations. This script always uses the API-key path
# so uploads are reproducible from any shell.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.release-ios.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "release-ios: missing $ENV_FILE" >&2
    echo "  Create it with IOS_RELEASE_KEY_ID and IOS_RELEASE_ISSUER_ID." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${IOS_RELEASE_KEY_ID:?Set IOS_RELEASE_KEY_ID in .release-ios.env}"
: "${IOS_RELEASE_ISSUER_ID:?Set IOS_RELEASE_ISSUER_ID in .release-ios.env}"

KEY_PATH="${IOS_RELEASE_KEY_PATH:-$REPO_ROOT/AuthKey_${IOS_RELEASE_KEY_ID}.p8}"
if [[ ! -f "$KEY_PATH" ]]; then
    echo "release-ios: missing API key at $KEY_PATH" >&2
    exit 1
fi

PROJECT="$REPO_ROOT/SimmerSmith/SimmerSmith.xcodeproj"
SCHEME="SimmerSmith"
EXPORT_OPTIONS="$REPO_ROOT/SimmerSmith/ExportOptions.plist"
PROJECT_YML="$REPO_ROOT/SimmerSmith/project.yml"

BUILD_NUMBER="$(awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' "$PROJECT_YML")"
if [[ -z "$BUILD_NUMBER" ]]; then
    echo "release-ios: could not read CURRENT_PROJECT_VERSION from $PROJECT_YML" >&2
    exit 1
fi

ARCHIVE_PATH="/tmp/SimmerSmith-build${BUILD_NUMBER}.xcarchive"
EXPORT_PATH="/tmp/SimmerSmith-build${BUILD_NUMBER}-export"

echo "release-ios: regenerating Xcode project for build ${BUILD_NUMBER}"
xcodegen generate --spec "$PROJECT_YML" >/dev/null

echo "release-ios: archiving (Release, generic iOS device)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=iOS' \
    archive

echo "release-ios: exporting + uploading to App Store Connect"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$IOS_RELEASE_KEY_ID" \
    -authenticationKeyIssuerID "$IOS_RELEASE_ISSUER_ID"

echo "release-ios: build ${BUILD_NUMBER} uploaded to TestFlight"
