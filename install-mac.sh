#!/bin/bash
# OnyxPoint Media Spoofer - macOS installer.
#
# ONE LINK, ANY MAC. Detects the CPU, downloads the matching build, installs to
# /Applications. The user never has to know or find out which chip their Mac has.
#
# Usage (this is the single line to give people):
#   bash <(curl -fsSL https://raw.githubusercontent.com/onyxxpointers/opm-dist-A8x4bZ-builds/main/install-mac.sh)
#
# WHY A SCRIPT AND NOT A .pkg OR .DMG:
# Neither can pick an architecture by itself, and a universal2 build is not
# achievable - numpy, pillow and pillow-heif publish zero universal2 wheels, so
# PyInstaller cannot produce one. Files fetched with curl also do not receive the
# com.apple.quarantine attribute that browsers add, so an unsigned, un-notarized
# app installed this way launches without the "Apple cannot check the app for
# malicious software" dialog. A double-clicked .pkg would hit that dialog and
# then need a trip to System Settings > Privacy & Security.
#
# Hosted in the public dist repo because the source repo is private and raw URLs
# from a private repo need authentication.

set -euo pipefail

REPO="onyxxpointers/opm-dist-A8x4bZ-builds"
APP_NAME="opmspoofer"
INSTALL_DIR="/Applications"
BUNDLE="${INSTALL_DIR}/${APP_NAME}.app"

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n\n' "$1" >&2; exit 1; }

# --- 1. platform -------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS only."

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  LABEL="Apple Silicon (M1/M2/M3/M4)" ; ASSET="${APP_NAME}-macos-arm64.zip"  ;;
  x86_64) LABEL="Intel"                        ; ASSET="${APP_NAME}-macos-x86_64.zip" ;;
  *)      die "unrecognised CPU architecture '${ARCH}'." ;;
esac

say "Detected: ${LABEL}"
info "architecture : ${ARCH}"
info "will install : ${ASSET}"

# --- 2. dependencies ---------------------------------------------------------
for tool in curl unzip; do
  command -v "$tool" >/dev/null 2>&1 || die "'${tool}' is not available."
done

# --- 3. resolve the newest release ------------------------------------------
say "Finding the latest version..."
API="https://api.github.com/repos/${REPO}/releases/latest"
RELEASE_JSON="$(curl -fsSL "$API")" || die "could not reach GitHub. Check your connection."

TAG="$(printf '%s' "$RELEASE_JSON" \
  | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$TAG" ] || die "could not read the release tag from ${API}."
info "latest release : ${TAG}"

# Confirm this release actually carries the asset for this CPU. A release built
# before macOS support was added will not, and failing here is far better than
# downloading an HTML error page and unzipping it.
if ! printf '%s' "$RELEASE_JSON" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${ASSET}\""; then
  die "release ${TAG} has no ${ASSET}. macOS builds may not be published yet."
fi

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

# --- 4. download -------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/opmspoofer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "Downloading (${LABEL} build)..."
info "$URL"
curl -fL --retry 3 --progress-bar -o "${WORK}/${ASSET}" "$URL" \
  || die "download failed."

ZIP="${WORK}/${ASSET}"
[ -s "$ZIP" ] || die "downloaded file is empty."
SIZE_MB=$(( $(stat -f%z "$ZIP") / 1048576 ))
info "downloaded : ${SIZE_MB} MB"
[ "$SIZE_MB" -ge 20 ] || die "download is only ${SIZE_MB} MB, expected 60+. Likely an error page."

unzip -tq "$ZIP" >/dev/null || die "the download is corrupt (zip integrity check failed)."
info "zip integrity : OK"

# --- 5. unpack ---------------------------------------------------------------
say "Unpacking..."
unzip -q "$ZIP" -d "$WORK/unpacked"
SRC_APP="$(find "$WORK/unpacked" -maxdepth 2 -name "${APP_NAME}.app" -type d | head -n 1)"
[ -n "$SRC_APP" ] || die "could not find ${APP_NAME}.app inside the archive."
[ -x "${SRC_APP}/Contents/MacOS/${APP_NAME}" ] \
  || die "the app's main executable is missing or not runnable."
info "bundle : ${SRC_APP}"

# --- 6. install --------------------------------------------------------------
say "Installing to ${INSTALL_DIR}..."
if [ -d "$BUNDLE" ]; then
  info "removing the previous install"
  rm -rf "$BUNDLE" 2>/dev/null || {
    info "needs administrator rights"
    sudo rm -rf "$BUNDLE"
  }
fi

cp -R "$SRC_APP" "$BUNDLE" 2>/dev/null || {
  info "needs administrator rights - enter your Mac password when asked"
  sudo cp -R "$SRC_APP" "$BUNDLE"
}

# cp -R as a non-root user can drop the executable bits; restore them explicitly.
chmod -R u+rwX,go+rX "$BUNDLE" 2>/dev/null || sudo chmod -R u+rwX,go+rX "$BUNDLE"
chmod +x "${BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
find "$BUNDLE" \( -name ffmpeg -o -name ffprobe \) -exec chmod +x {} \; 2>/dev/null || true

# --- 7. verify ---------------------------------------------------------------
say "Verifying..."
[ -d "$BUNDLE" ] || die "install failed, ${BUNDLE} does not exist."
for f in ffmpeg ffprobe; do
  FOUND="$(find "$BUNDLE" -name "$f" -type f | head -n 1)"
  [ -n "$FOUND" ] || die "${f} is missing from the installed bundle."
  [ -x "$FOUND" ] || die "${f} is present but not executable."
  info "${f} : present and executable"
done

FILE_ARCH="$(file "${BUNDLE}/Contents/MacOS/${APP_NAME}" || true)"
info "binary : ${FILE_ARCH##*: }"

# --- 8. launch ---------------------------------------------------------------
say "Installed."
info "${BUNDLE}"
printf '\nOpening the app now...\n'
open "$BUNDLE" || info "could not auto-launch; open it from your Applications folder."

cat <<'EOF'

Done. Next time just open it from your Applications folder or with Spotlight.

If macOS ever complains that the app cannot be verified, run:
    xattr -dr com.apple.quarantine /Applications/opmspoofer.app
That clears the download flag. It should not be needed when installed by this
script, because curl does not set it.

EOF
