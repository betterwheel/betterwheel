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
# The macOS app is codesigned with a stable SELF-SIGNED identity ("BetterWheel
# Signing" in the login keychain — one-time setup, see CLAUDE.md). BetterWheel
# uses no Accessibility/TCC permission, so this ISN'T for permission stability
# like marie-lookapp; it's because Tauri's default ad-hoc signature makes
# Gatekeeper flag a quarantined download as "damaged" (Apple Silicon) instead of
# the bypassable "unidentified developer" dialog. It is NOT notarized: first
# install still needs right-click → Open; self-updates are fine.
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
#   - "BetterWheel Signing" self-signed code-signing cert in the login keychain
#     (Keychain Access → Certificate Assistant → Create a Certificate → name it
#     "BetterWheel Signing", type "Code Signing"; then set it to Always Trust for
#     code signing). One-time; see CLAUDE.md (desktop section).
#   - Authenticode is OPT-IN: SKIP_AUTHENTICODE=0 + the betterwheel-signing keychain
#     item (see sign-windows.sh). Default leaves Windows binaries unsigned
#     (SmartScreen warns; the updater itself only checks the minisign signature).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Releases live on this repo; it must be PUBLIC for the updater's anonymous fetch.
RELEASES_REPO="betterwheel/betterwheel.github.io"
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
# Self-signed macOS identity must exist before the (long) Windows build, so fail
# fast. No -v: the cert is an untrusted self-signed root, so it shows under
# find-identity but NOT its -v (valid) subset — codesign signs with it anyway.
MAC_SIGN_ID="BetterWheel Signing"
security find-identity -p codesigning 2>/dev/null | grep -q "${MAC_SIGN_ID}" || {
  echo "error: '${MAC_SIGN_ID}' code-signing identity not in keychain." >&2
  echo "  Create it: scripts/create-macos-signing-cert.sh  (see CLAUDE.md)" >&2
  exit 1
}
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
# its .sig (minisigned because TAURI_SIGNING_PRIVATE_KEY is set).
echo ">> building macOS bundle (app + updater artifact)"
(cd "${ROOT}" && TAURI_SIGNING_PRIVATE_KEY="${UPDATER_KEY}" \
  TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" npx tauri build --bundles app)
BUNDLE_DIR="${ROOT}/src-tauri/target/release/bundle"
MAC_APP="${BUNDLE_DIR}/macos/BetterWheel.app"
MAC_TARGZ="${BUNDLE_DIR}/macos/BetterWheel.app.tar.gz"
[ -f "${MAC_TARGZ}.sig" ] || { echo "error: updater artifact sig missing — is createUpdaterArtifacts on?" >&2; exit 1; }

# Codesign with the stable self-signed "BetterWheel Signing" identity. Tauri's
# default ad-hoc signature makes Gatekeeper flag a quarantined download as
# "damaged" on Apple Silicon; a real (even self-signed) identity downgrades that
# to the bypassable "unidentified developer" dialog. The bundler already tarred
# the ad-hoc app, so re-create the updater artifact from the SIGNED app and
# re-minisign it. This must happen before the .dmg is rolled (below) so the dmg
# ships the signed app too.
echo ">> codesigning macOS app (${MAC_SIGN_ID})"
codesign --force --deep --sign "${MAC_SIGN_ID}" "${MAC_APP}"
tar -czf "${MAC_TARGZ}" -C "${BUNDLE_DIR}/macos" "BetterWheel.app"
(cd "${ROOT}" && npx tauri signer sign -f "${UPDATER_KEY}" --password "" "${MAC_TARGZ}")
MAC_SIG="$(cat "${MAC_TARGZ}.sig")"

# Roll the .dmg by hand (tauri's dmg bundler drives Finder via AppleScript and
# fails in non-interactive shells).
MAC_DMG="${BUNDLE_DIR}/macos/betterwheel-${VERSION}-macos-arm64.dmg"
hdiutil create -quiet -volname "BetterWheel" -srcfolder "${MAC_APP}" -ov -format UDZO "${MAC_DMG}"

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
cp "${MAC_TARGZ}" "${STAGE}/betterwheel-macos-arm64.app.tar.gz"
cp "${LATEST}" "${STAGE}/latest.json"

REL_ASSETS=(
  "${STAGE}/betterwheel-setup-${VERSION}.exe"
  "${STAGE}/betterwheel-windows-x64.exe"
  "${STAGE}/betterwheel-windows-arm64.exe"
  "${STAGE}/betterwheel-${VERSION}-macos-arm64.dmg"
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
