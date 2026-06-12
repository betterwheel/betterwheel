#!/usr/bin/env bash
# Local release pipeline for BetterWheel desktop — modeled on marie-lookapp.
#
# Builds the Windows binaries (cargo-xwin → NSIS installer) and the macOS bundle
# (tauri bundler: .app + .app.tar.gz updater artifact + .dmg), minisigns the
# updater artifacts, generates the updater manifest (latest.json: windows-x86_64
# + darwin-aarch64) and publishes everything as a GitHub Release on this repo —
# the in-app updater fetches
#   https://github.com/${RELEASES_REPO}/releases/latest/download/latest.json
# anonymously, so the repo MUST be public for auto-update to work (releases on a
# private repo can't be downloaded without auth).
#
# The macOS app is signed with the StarData Developer ID identity and (when
# notarytool creds are exported) notarized, so a fresh install opens without the
# right-click → Open dance. If that cert isn't in the keychain the build falls
# back to an ad-hoc signature. The updater only ever verifies the minisign
# signature, independent of Apple signing.
#
# Usage:  scripts/release.sh ["release notes…"]
#
# Bump the version in tauri.conf.json + package.json + src-tauri/Cargo.toml
# before releasing (the GitHub releases/latest endpoint ignores prereleases, so
# do NOT mark the release --prerelease — it would be invisible to the updater).
#
# Prereqs:
#   - gh logged in with push access to ${RELEASES_REPO}
#   - makensis on PATH (NSIS installer); cargo-xwin + Windows rust targets
#   - ~/.tauri/betterwheel-updater.key (updater signing key; pubkey in tauri.conf.json)
#   - Authenticode is OPT-IN: SKIP_AUTHENTICODE=0 + the betterwheel-signing keychain
#     item (see sign-windows.sh). Default leaves Windows binaries unsigned
#     (SmartScreen warns; the updater itself only checks the minisign signature).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Org/signing identifiers are NEVER hardcoded in this (public) repo. Locally they
# come from a gitignored scripts/release.env; in CI from repo Variables/Secrets
# exported as env. See scripts/release.env.example.
# shellcheck source=/dev/null
[ -f "${ROOT}/scripts/release.env" ] && . "${ROOT}/scripts/release.env"
# Releases live on THIS code repo now (consolidated 2026-06-12): the updater
# endpoint in tauri.conf.json points here, so CI publishes with the built-in
# GITHUB_TOKEN (no cross-repo PAT). Must stay PUBLIC for the anonymous fetch.
RELEASES_REPO="betterwheel/betterwheel"
UPDATER_KEY="${HOME}/.tauri/betterwheel-updater.key"
SKIP_AUTHENTICODE="${SKIP_AUTHENTICODE:-1}"
NOTES="${1:-BetterWheel desktop release}"

VERSION="$(node -p "require('${ROOT}/src-tauri/tauri.conf.json').version")"
TAG="v${VERSION}"

X64_EXE="${ROOT}/src-tauri/target/x86_64-pc-windows-msvc/release/betterwheel-desktop.exe"
ARM64_EXE="${ROOT}/src-tauri/target/aarch64-pc-windows-msvc/release/betterwheel-desktop.exe"
SETUP_EXE="${ROOT}/src-tauri/target/betterwheel-setup-${VERSION}.exe"

[ -f "${UPDATER_KEY}" ] || { echo "error: updater key missing: ${UPDATER_KEY}" >&2; exit 1; }
command -v makensis >/dev/null 2>&1 || { echo "error: makensis not on PATH (port/brew install nsis)" >&2; exit 1; }
# The release/** CI (.github/workflows/release.yml) may have already created this
# tag as an UNSIGNED prerelease. That's fine — we reuse it below (clobber its
# assets with the signed ones and promote it to a full release). Only a tag that
# already exists as a *full* release is a hard stop: that's an already-published
# signed release, so bump the version instead of overwriting it.
EXISTING_PRERELEASE=""
if gh release view "${TAG}" --repo "${RELEASES_REPO}" >/dev/null 2>&1; then
  if [ "$(gh release view "${TAG}" --repo "${RELEASES_REPO}" --json isPrerelease -q .isPrerelease)" = "true" ]; then
    echo ">> ${TAG} exists as an unsigned CI prerelease — will clobber its assets and promote to a full release"
    EXISTING_PRERELEASE=1
  else
    echo "error: ${TAG} already published (full release) on ${RELEASES_REPO} — bump the version first" >&2
    exit 1
  fi
fi

echo ">> building Windows binaries (x64 + arm64)"
"${ROOT}/scripts/build-windows.sh" release all

if [ "${SKIP_AUTHENTICODE}" != "1" ]; then
  echo ">> Authenticode-signing standalone exes"
  "${ROOT}/scripts/sign-windows.sh" "${X64_EXE}" "${ARM64_EXE}"
else
  echo ">> SKIP_AUTHENTICODE=1 — Windows exes stay unsigned (SmartScreen will warn)"
fi

# Re-running with BUILD_INSTALLER=1 only re-runs makensis (cargo's freshness
# check is source-based, so the signed exe isn't relinked/unsigned).
echo ">> building NSIS installer (wraps the x64 exe)"
BUILD_INSTALLER=1 "${ROOT}/scripts/build-windows.sh" release x64

if [ "${SKIP_AUTHENTICODE}" != "1" ]; then
  echo ">> Authenticode-signing installer"
  "${ROOT}/scripts/sign-windows.sh" "${SETUP_EXE}"
fi

# Updater (minisign) signature — what tauri-plugin-updater actually verifies.
# Must be generated AFTER any Authenticode signing (it hashes the final file).
echo ">> minisigning the Windows installer"
(cd "${ROOT}" && npx tauri signer sign -f "${UPDATER_KEY}" --password "" "${SETUP_EXE}")
SIG="$(cat "${SETUP_EXE}.sig")"

# macOS: the bundler emits the .app, the .app.tar.gz the updater consumes, and
# its .sig (minisigned because TAURI_SIGNING_PRIVATE_KEY is set). The .app is
# signed with the StarData Developer ID identity when it's in the keychain;
# notarization additionally runs when APPLE_ID + APPLE_PASSWORD are exported
# (team id from the APPLE_TEAM_ID env var). Falls back to ad-hoc otherwise.
# The macOS signing identity (Developer ID) + notary creds come from the
# environment — CI from the repo Variable MACOS_SIGNING_IDENTITY + the API-key
# Secrets; locally from scripts/release.env. No identifiers are hardcoded.
# Notarization uses an App Store Connect API key (APPLE_API_KEY_PATH/_ISSUER/
# _KEY_ID) or an app-specific password (APPLE_ID/APPLE_PASSWORD); with neither
# the app is signed but NOT notarized.
DEVID="${MACOS_SIGNING_IDENTITY:-}"
MAC_SIGN_ENV=()
NOTARIZE=0
if [ -n "${DEVID}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "${DEVID}"; then
  MAC_SIGN_ENV+=("APPLE_SIGNING_IDENTITY=${DEVID}")
  if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ]; then
    MAC_SIGN_ENV+=("APPLE_API_ISSUER=${APPLE_API_ISSUER}" "APPLE_API_KEY=${APPLE_API_KEY_ID}" "APPLE_API_KEY_PATH=${APPLE_API_KEY_PATH}")
    NOTARIZE=1
    echo ">> macOS: Developer ID sign + notarize (App Store Connect API key)"
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ]; then
    MAC_SIGN_ENV+=("APPLE_ID=${APPLE_ID}" "APPLE_PASSWORD=${APPLE_PASSWORD}" "APPLE_TEAM_ID=${APPLE_TEAM_ID}")
    NOTARIZE=1
    echo ">> macOS: Developer ID sign + notarize (app-specific password)"
  else
    echo ">> macOS: Developer ID sign only (no notary creds — a downloaded DMG will warn)"
  fi
else
  echo ">> WARNING: signing identity not in keychain — building AD-HOC (Gatekeeper will warn)" >&2
fi
# `env` is required: the MAC_SIGN_ENV array holds VAR=value strings, and bash
# only treats VAR=value as an assignment when it's a literal at parse time — an
# array element would instead be run as a command ("…: command not found").
(cd "${ROOT}" && env TAURI_SIGNING_PRIVATE_KEY="${UPDATER_KEY}" \
  TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" \
  "${MAC_SIGN_ENV[@]}" npx tauri build --bundles app)
BUNDLE_DIR="${ROOT}/src-tauri/target/release/bundle"
MAC_APP="${BUNDLE_DIR}/macos/BetterWheel.app"
MAC_TARGZ="${BUNDLE_DIR}/macos/BetterWheel.app.tar.gz"
[ -f "${MAC_TARGZ}.sig" ] || { echo "error: updater artifact sig missing — is createUpdaterArtifacts on?" >&2; exit 1; }
MAC_SIG="$(cat "${MAC_TARGZ}.sig")"

# Roll the .dmg by hand (tauri's dmg bundler drives Finder via AppleScript and
# fails in non-interactive shells), then notarize + staple it so the downloaded
# image passes Gatekeeper offline (the .app inside is already notarized).
MAC_DMG="${BUNDLE_DIR}/macos/betterwheel-${VERSION}-macos-arm64.dmg"
# Stage the .app next to an /Applications symlink so the mounted DMG offers a
# drag-to-Applications target (the standard macOS install UX).
DMG_STAGE="$(mktemp -d)"
cp -R "${MAC_APP}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -quiet -volname "BetterWheel" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${MAC_DMG}"
rm -rf "${DMG_STAGE}"
if [ "${NOTARIZE}" = "1" ]; then
  echo ">> notarizing + stapling the DMG"
  if [ -n "${APPLE_API_KEY_PATH:-}" ]; then
    xcrun notarytool submit "${MAC_DMG}" \
      --key "${APPLE_API_KEY_PATH}" --key-id "${APPLE_API_KEY_ID}" --issuer "${APPLE_API_ISSUER}" --wait
  else
    xcrun notarytool submit "${MAC_DMG}" \
      --apple-id "${APPLE_ID}" --password "${APPLE_PASSWORD}" --team-id "${APPLE_TEAM_ID}" --wait
  fi
  xcrun stapler staple "${MAC_DMG}"
fi

echo ">> generating latest.json"
LATEST="${ROOT}/src-tauri/target/latest.json"
NOTES_JSON="$(node -p 'JSON.stringify(process.argv[1])' "${NOTES}")"
cat > "${LATEST}" <<EOF
{
  "version": "${VERSION}",
  "notes": ${NOTES_JSON},
  "pub_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "platforms": {
    "windows-x86_64": {
      "signature": "${SIG}",
      "url": "https://github.com/${RELEASES_REPO}/releases/download/${TAG}/betterwheel-setup-${VERSION}.exe"
    },
    "darwin-aarch64": {
      "signature": "${MAC_SIG}",
      "url": "https://github.com/${RELEASES_REPO}/releases/download/${TAG}/betterwheel-macos-arm64.app.tar.gz"
    }
  }
}
EOF

# Asset NAMES (download URLs) come from the file basename; stage renamed copies.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp "${SETUP_EXE}" "${STAGE}/betterwheel-setup-${VERSION}.exe"
cp "${X64_EXE}" "${STAGE}/betterwheel-windows-x64.exe"
cp "${ARM64_EXE}" "${STAGE}/betterwheel-windows-arm64.exe"
cp "${MAC_DMG}" "${STAGE}/betterwheel-${VERSION}-macos-arm64.dmg"
cp "${MAC_DMG}" "${STAGE}/betterwheel-latest.dmg"   # stable, versionless link for salamacchine.it
cp "${MAC_TARGZ}" "${STAGE}/betterwheel-macos-arm64.app.tar.gz"
cp "${LATEST}" "${STAGE}/latest.json"

REL_ASSETS=(
  "${STAGE}/betterwheel-setup-${VERSION}.exe"
  "${STAGE}/betterwheel-windows-x64.exe"
  "${STAGE}/betterwheel-windows-arm64.exe"
  "${STAGE}/betterwheel-${VERSION}-macos-arm64.dmg"
  "${STAGE}/betterwheel-latest.dmg"
  "${STAGE}/betterwheel-macos-arm64.app.tar.gz"
  "${STAGE}/latest.json"
)
if [ -n "${EXISTING_PRERELEASE}" ]; then
  # Reuse the CI prerelease: replace its unsigned assets with the signed ones and
  # promote it to a full release. The updater reads releases/latest, which skips
  # prereleases, so the new version only becomes visible to clients once promoted.
  echo ">> promoting CI prerelease ${TAG} on ${RELEASES_REPO} (clobbering unsigned assets)"
  gh release upload "${TAG}" --repo "${RELEASES_REPO}" --clobber "${REL_ASSETS[@]}"
  gh release edit "${TAG}" --repo "${RELEASES_REPO}" \
    --title "BetterWheel ${VERSION}" --notes "${NOTES}" --prerelease=false
else
  echo ">> publishing ${TAG} to ${RELEASES_REPO}"
  gh release create "${TAG}" --repo "${RELEASES_REPO}" \
    --title "BetterWheel ${VERSION}" --notes "${NOTES}" "${REL_ASSETS[@]}"
fi

echo ">> done: https://github.com/${RELEASES_REPO}/releases/tag/${TAG}"
