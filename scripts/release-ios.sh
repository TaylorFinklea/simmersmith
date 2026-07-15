#!/usr/bin/env bash
#
# release-ios.sh — archive + export + upload SimmerSmith to TestFlight.
#
# App Store Connect API credentials resolve in this order:
#   1. the environment (an already-exported IOS_RELEASE_* var wins),
#   2. the macOS Keychain (the durable home — see bead simmersmith-ana),
#   3. .release-ios.env (gitignored, repo root; legacy fallback).
# Two values are needed:
#   IOS_RELEASE_KEY_ID      — e.g. "6X83L5SG4J"; the AuthKey_<ID>.p8
#                             file in the repo root must match.
#   IOS_RELEASE_ISSUER_ID   — 36-char UUID from App Store Connect → Users
#                             and Access → Integrations → App Store Connect
#                             API. NOT the key ID: pasting the key ID here
#                             yields a bare HTTP 401 (cost an evening on 151).
# Seed the Keychain with:
#   security add-generic-password -U -a "$USER" -s IOS_RELEASE_KEY_ID -w '<id>'
#   security add-generic-password -U -a "$USER" -s IOS_RELEASE_ISSUER_ID -w '<uuid>'
#
# Why the Keychain: .release-ios.env is local-only, gitignored, and unbacked —
# it silently vanished between builds 150 and 151, as did the Apple
# Distribution certificate. The Keychain survives that; the .env path stays
# as a fallback so existing checkouts keep working.
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

# Keychain lookup; empty (not fatal) when the item is absent.
keychain_value() {
    security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null || true
}

# Capture anything already exported BEFORE sourcing — `source` would otherwise
# clobber the caller's values with the file's, inverting the precedence above.
ENV_KEY_ID="${IOS_RELEASE_KEY_ID:-}"
ENV_ISSUER_ID="${IOS_RELEASE_ISSUER_ID:-}"

ENV_FILE="$REPO_ROOT/.release-ios.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

IOS_RELEASE_KEY_ID="${ENV_KEY_ID:-${IOS_RELEASE_KEY_ID:-$(keychain_value IOS_RELEASE_KEY_ID)}}"
IOS_RELEASE_ISSUER_ID="${ENV_ISSUER_ID:-${IOS_RELEASE_ISSUER_ID:-$(keychain_value IOS_RELEASE_ISSUER_ID)}}"

if [[ -z "${IOS_RELEASE_KEY_ID}" || -z "${IOS_RELEASE_ISSUER_ID}" ]]; then
    echo "release-ios: missing App Store Connect credentials." >&2
    echo "  Store them in the Keychain (preferred):" >&2
    echo "    security add-generic-password -U -a \"\$USER\" -s IOS_RELEASE_KEY_ID -w '<key-id>'" >&2
    echo "    security add-generic-password -U -a \"\$USER\" -s IOS_RELEASE_ISSUER_ID -w '<issuer-uuid>'" >&2
    echo "  ...or define both in $ENV_FILE." >&2
    exit 1
fi

# The issuer ID is a UUID. A key ID pasted here authenticates as a bare 401
# with no hint of the cause, so fail loudly and early instead.
if [[ ! "${IOS_RELEASE_ISSUER_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "release-ios: IOS_RELEASE_ISSUER_ID is not a UUID (got ${#IOS_RELEASE_ISSUER_ID} chars)." >&2
    echo "  Expected the 36-char Issuer ID from App Store Connect → Users and Access →" >&2
    echo "  Integrations, not the ${#IOS_RELEASE_KEY_ID}-char key ID." >&2
    exit 1
fi

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

# simmersmith-224 — no build ships without us having decided what to tell the
# people using it. This runs before the archive so the failure costs seconds
# rather than a full build + upload cycle.
CATALOG="$REPO_ROOT/SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift"
if [[ ! -f "$CATALOG" ]]; then
    echo "release-ios: missing release-note catalog at $CATALOG" >&2
    exit 1
fi
if ! grep -qE "^[[:space:]]*build:[[:space:]]*${BUILD_NUMBER},[[:space:]]*$" "$CATALOG"; then
    echo "release-ios: no release-note entry for build ${BUILD_NUMBER}." >&2
    echo >&2
    echo "  Add a ReleaseNote(build: ${BUILD_NUMBER}, ...) to:" >&2
    echo "    $CATALOG" >&2
    echo >&2
    echo "  A build with nothing user-visible to say still needs an entry —" >&2
    echo "  leave new/improved/fixed empty and no What's New sheet is shown." >&2
    exit 1
fi
echo "release-ios: release notes present for build ${BUILD_NUMBER}"

echo "release-ios: regenerating Xcode project for build ${BUILD_NUMBER}"
xcodegen generate --spec "$PROJECT_YML" >/dev/null

echo "release-ios: archiving (Release, generic iOS device)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$IOS_RELEASE_KEY_ID" \
    -authenticationKeyIssuerID "$IOS_RELEASE_ISSUER_ID" \
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

echo "release-ios: build ${BUILD_NUMBER} accepted for processing by App Store Connect"

# simmersmith-5fm: `xcodebuild -exportArchive` exiting 0 means the binary was ACCEPTED FOR
# PROCESSING — not that it passed. A build can fail ASC's async validation minutes later while
# this script has already printed success and exited 0 (build 153 shipped with its processing
# state unconfirmed for exactly this reason). Poll until the build reaches a terminal state.
processing_state_from_response() {
    local response="$1"
    printf '%s' "$response" | grep -o '"processingState"[[:space:]]*:[[:space:]]*"[A-Z]*"' |
        head -1 | sed 's/.*"\([A-Z]*\)"$/\1/' || true
}

processing_state_result() {
    local state="$1"
    local build_number="${2:-${BUILD_NUMBER:-unknown}}"
    case "$state" in
        VALID)
            echo "release-ios: build ${build_number} processed — VALID (ready for TestFlight)"
            return 0
            ;;
        INVALID|FAILED)
            echo "release-ios: ERROR — build ${build_number} processing state is ${state}." >&2
            echo "release-ios: check App Store Connect for the rejection detail." >&2
            return 1
            ;;
        "")
            return 2
            ;;
        *)
            echo "release-ios: processing (${state})…"
            return 2
            ;;
    esac
}

poll_processing_state() {
    local jwt exp iat header payload signature response state result
    # ES256 JWT for the ASC API, signed with the same .p8 the upload used.
    iat=$(date +%s)
    exp=$((iat + 600))
    header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$IOS_RELEASE_KEY_ID" |
        openssl base64 -e -A | tr -d '=' | tr '/+' '_-')
    payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' \
        "$IOS_RELEASE_ISSUER_ID" "$iat" "$exp" |
        openssl base64 -e -A | tr -d '=' | tr '/+' '_-')
    signature=$(printf '%s.%s' "$header" "$payload" |
        openssl dgst -sha256 -binary -sign "$KEY_PATH" |
        openssl asn1parse -inform DER |
        awk -F: '/INTEGER/ {printf "%s", $4}' | xxd -r -p |
        openssl base64 -e -A | tr -d '=' | tr '/+' '_-')
    jwt="${header}.${payload}.${signature}"

    for _ in $(seq 1 30); do   # ~10 minutes at 20s
        sleep 20
        response=$(curl -sS -H "Authorization: Bearer ${jwt}" \
            "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bversion%5D=${BUILD_NUMBER}&limit=1" 2>/dev/null) || continue
        state=$(processing_state_from_response "$response")
        if processing_state_result "$state" "$BUILD_NUMBER"; then
            return 0
        else
            result=$?
            [ "$result" -eq 1 ] && return 1
        fi
    done
    echo "release-ios: WARNING — build ${BUILD_NUMBER} still processing after ~10 min; check App Store Connect." >&2
    return 0
}

poll_processing_state
