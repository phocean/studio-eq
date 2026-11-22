#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Jean-Christophe Baptiste
#
# Builds the distributable Studio EQ: Release build signed with Developer ID (Hardened Runtime,
# secure timestamp, no debugger entitlement), checked, packaged as a DMG, notarized and stapled.
# Run it through make on the Mac that holds the Developer ID key: `make publish` (also tags and
# uploads), `make release` (DMG only) or `make dmg` (trial without notarization).
#
# Environment:
#   VERSION            version shown to users, e.g. 1.2.0 (required)
#   BUILD_NUMBER       CFBundleVersion (default 1)
#   TEAM_ID            Apple developer team ID (required)
#   SIGN_IDENTITY      default "Developer ID Application"
#   KEYCHAIN           keychain holding the identity; default: the login search list
#   Notarization, one of:
#     NOTARY_PROFILE                            keychain profile (xcrun notarytool store-credentials)
#     NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   App Store Connect API key (.p8)
#     SKIP_NOTARIZATION=1                       local dry run: signed DMG, not notarized
#
# Output: build/release/StudioEQ-<VERSION>.dmg and its .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, e.g. 1.0.0}"
: "${TEAM_ID:?set TEAM_ID}"
BUILD_NUMBER=${BUILD_NUMBER:-1}
SIGN_IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
OUT=build/release
APP=$OUT/DerivedData/Build/Products/Release/StudioEQ.app
DMG=$OUT/StudioEQ-$VERSION.dmg
fail() { echo "release: $*" >&2; exit 1; }
step() { echo "\n==> $*"; }

KEYCHAIN_FLAGS=()
[[ -n ${KEYCHAIN:-} ]] && KEYCHAIN_FLAGS=(--keychain "$KEYCHAIN")

step "Generate the project"
command -v xcodegen >/dev/null || fail "xcodegen is required (brew install xcodegen)"
xcodegen generate --quiet
rm -rf "$OUT"; mkdir -p "$OUT"

step "Build Release $VERSION ($BUILD_NUMBER), signed by $SIGN_IDENTITY"
if ! xcodebuild -project StudioEQ.xcodeproj -scheme StudioEQ -configuration Release \
       -derivedDataPath "$OUT/DerivedData" \
       MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
       DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
       CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
       OTHER_CODE_SIGN_FLAGS="--timestamp ${KEYCHAIN:+--keychain $KEYCHAIN}" \
       build > "$OUT/build.log" 2>&1; then
  grep -E "error:" "$OUT/build.log" | sort -u >&2 || true
  fail "build failed (log: $OUT/build.log)"
fi

step "Check the app before shipping it"
codesign --verify --strict --deep "$APP" || fail "signature does not verify"
SIG=$(codesign -dvv "$APP" 2>&1)
grep -q "^Authority=Developer ID Application" <<<"$SIG" || fail "not signed with a Developer ID Application certificate"
grep -q "^Timestamp=" <<<"$SIG" || fail "no secure timestamp"
grep -q "flags=.*runtime" <<<"$SIG" || fail "Hardened Runtime is off"
# Exactly one entitlement, the sandbox, set to true: no debugger (get-task-allow), no network,
# no microphone, nothing else. Parsed as a plist, not matched as text.
ENT=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - -)
[[ $ENT == '{"com.apple.security.app-sandbox":true}' ]] || fail "entitlements must be exactly the App Sandbox: $ENT"
# Validation tools (SelfTest, overrides) must not be compiled in. Outputs are captured first:
# `strings | grep -q` under pipefail misses a match (grep exits early, strings gets SIGPIPE), and
# Swift strings of 15 bytes or less are stored inline, invisible to strings: look for the
# SelfTest symbols and for long markers only.
BIN=$APP/Contents/MacOS/StudioEQ
SYMBOLS=$(nm "$BIN")
STRINGS=$(strings "$BIN")
grep -q "8AppModelC" <<<"$SYMBOLS" || fail "no symbol table in $BIN: cannot check for validation tools"
grep -q "8SelfTestO" <<<"$SYMBOLS" && fail "validation tools (SelfTest) compiled into the distributed app"
grep -q -E -- "--permission-probe|SimulateEngineFailure" <<<"$STRINGS" \
  && fail "validation overrides compiled into the distributed app"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") == "$VERSION" ]] \
  || fail "version mismatch"
echo "ok: Developer ID, timestamp, Hardened Runtime, sandbox only, no test tools, version $VERSION"

step "Package the DMG"
STAGE=$OUT/dmg; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Studio EQ" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$SIGN_IDENTITY" --timestamp "${KEYCHAIN_FLAGS[@]}" "$DMG"
codesign --verify --strict "$DMG"

if [[ ${SKIP_NOTARIZATION:-0} == 1 ]]; then
  echo "\nSKIP_NOTARIZATION=1: $DMG is signed but NOT notarized (Gatekeeper will refuse it on another Mac)."
else
  step "Notarize"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER:-} ]]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    fail "no notarization credentials (NOTARY_PROFILE, or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER, or SKIP_NOTARIZATION=1)"
  fi
  RESULT=$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json)
  echo "$RESULT"
  STATUS=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$RESULT")
  if [[ $STATUS != Accepted ]]; then
    ID=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$RESULT")
    [[ -n $ID ]] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    fail "notarization status: $STATUS"
  fi

  step "Staple and verify with Gatekeeper"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "\nDone: $DMG"
