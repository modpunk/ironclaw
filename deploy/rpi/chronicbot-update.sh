#!/usr/bin/env bash
# chronicbot-update.sh — Auto-update CHRONICbot from GitHub Releases with rollback
set -euo pipefail

REPO="kingmk3r/ChronicBot"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
INSTALL_DIR="/opt/chronicbot"
VERSION_FILE="${INSTALL_DIR}/version.txt"
UPDATE_DIR="${INSTALL_DIR}/.update"
BINARY_ASSET="ironclaw-aarch64-unknown-linux-gnu.tar.gz"
HEALTH_URL="http://localhost:8080/health"
HEALTH_RETRIES=3
HEALTH_DELAY=5

# ── Guard ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

# ── Cleanup trap ─────────────────────────────────────────────────────────
cleanup() {
  local rc=$?
  if [[ -d "${UPDATE_DIR}" ]]; then
    echo "Cleaning up staging directory ${UPDATE_DIR}"
    rm -rf "${UPDATE_DIR}"
  fi
  exit "$rc"
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────
log()  { echo "[$(date -Iseconds)] $*"; }
die()  { log "FATAL: $*" >&2; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done
}

# ── check_for_update ─────────────────────────────────────────────────────
# Sets globals: LATEST_TAG, RELEASE_JSON
check_for_update() {
  log "Querying latest release from ${API_URL}"
  RELEASE_JSON=$(curl -sfL "$API_URL") || die "Failed to query GitHub API"
  LATEST_TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name') || die "Failed to parse release tag"

  if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
    die "Could not determine latest release tag"
  fi

  local current_version=""
  if [[ -f "$VERSION_FILE" ]]; then
    current_version=$(cat "$VERSION_FILE")
  fi

  if [[ "$current_version" == "$LATEST_TAG" ]]; then
    log "Already up to date (${current_version})"
    exit 0
  fi

  log "Update available: ${current_version:-<none>} -> ${LATEST_TAG}"
}

# ── download_release ─────────────────────────────────────────────────────
download_release() {
  mkdir -p "${UPDATE_DIR}"

  # Resolve download URLs from release assets
  local binary_url checksum_url
  binary_url=$(echo "$RELEASE_JSON" | jq -r \
    --arg name "$BINARY_ASSET" \
    '.assets[] | select(.name == $name) | .browser_download_url') \
    || die "Failed to find binary asset URL"

  checksum_url=$(echo "$RELEASE_JSON" | jq -r \
    '.assets[] | select(.name == "checksums.txt") | .browser_download_url') \
    || die "Failed to find checksums asset URL"

  [[ -n "$binary_url" && "$binary_url" != "null" ]] \
    || die "Binary asset '${BINARY_ASSET}' not found in release"
  [[ -n "$checksum_url" && "$checksum_url" != "null" ]] \
    || die "checksums.txt not found in release"

  log "Downloading binary: ${BINARY_ASSET}"
  curl -sfL -o "${UPDATE_DIR}/${BINARY_ASSET}" "$binary_url" \
    || die "Failed to download binary"

  log "Downloading checksums.txt"
  curl -sfL -o "${UPDATE_DIR}/checksums.txt" "$checksum_url" \
    || die "Failed to download checksums"

  # Download WASM channel assets (*.wasm)
  local wasm_assets
  wasm_assets=$(echo "$RELEASE_JSON" | jq -r \
    '.assets[] | select(.name | endswith(".wasm")) | .name + "\t" + .browser_download_url')

  if [[ -n "$wasm_assets" ]]; then
    mkdir -p "${UPDATE_DIR}/channels"
    while IFS=$'\t' read -r name url; do
      log "Downloading WASM channel: ${name}"
      curl -sfL -o "${UPDATE_DIR}/channels/${name}" "$url" \
        || die "Failed to download WASM channel: ${name}"
    done <<< "$wasm_assets"
  fi

  # Extract binary tarball
  log "Extracting ${BINARY_ASSET}"
  mkdir -p "${UPDATE_DIR}/bin"
  tar -xzf "${UPDATE_DIR}/${BINARY_ASSET}" -C "${UPDATE_DIR}/bin" \
    || die "Failed to extract binary archive"
}

# ── verify_checksums ─────────────────────────────────────────────────────
verify_checksums() {
  log "Verifying SHA256 checksums"

  # Verify the binary tarball
  local expected actual
  expected=$(grep "${BINARY_ASSET}" "${UPDATE_DIR}/checksums.txt" | awk '{print $1}')
  [[ -n "$expected" ]] || die "No checksum found for ${BINARY_ASSET}"

  actual=$(sha256sum "${UPDATE_DIR}/${BINARY_ASSET}" | awk '{print $1}')
  if [[ "$expected" != "$actual" ]]; then
    die "Checksum mismatch for ${BINARY_ASSET}: expected=${expected} actual=${actual}"
  fi
  log "  ${BINARY_ASSET}: OK"

  # Verify each WASM channel file
  if [[ -d "${UPDATE_DIR}/channels" ]]; then
    for wasm_file in "${UPDATE_DIR}/channels"/*.wasm; do
      [[ -f "$wasm_file" ]] || continue
      local basename
      basename=$(basename "$wasm_file")
      expected=$(grep "$basename" "${UPDATE_DIR}/checksums.txt" | awk '{print $1}')
      [[ -n "$expected" ]] || die "No checksum found for ${basename}"

      actual=$(sha256sum "$wasm_file" | awk '{print $1}')
      if [[ "$expected" != "$actual" ]]; then
        die "Checksum mismatch for ${basename}: expected=${expected} actual=${actual}"
      fi
      log "  ${basename}: OK"
    done
  fi

  log "All checksums verified"
}

# ── swap_binaries ────────────────────────────────────────────────────────
swap_binaries() {
  log "Stopping chronicbot service"
  systemctl stop chronicbot || die "Failed to stop chronicbot"

  # Back up current directories
  if [[ -d "${INSTALL_DIR}/bin" ]]; then
    log "Backing up bin/ -> bin.old/"
    rm -rf "${INSTALL_DIR}/bin.old"
    mv "${INSTALL_DIR}/bin" "${INSTALL_DIR}/bin.old"
  fi

  if [[ -d "${INSTALL_DIR}/channels" ]]; then
    log "Backing up channels/ -> channels.old/"
    rm -rf "${INSTALL_DIR}/channels.old"
    mv "${INSTALL_DIR}/channels" "${INSTALL_DIR}/channels.old"
  fi

  # Install new files
  log "Installing new bin/"
  mv "${UPDATE_DIR}/bin" "${INSTALL_DIR}/bin"

  if [[ -d "${UPDATE_DIR}/channels" ]]; then
    log "Installing new channels/"
    mv "${UPDATE_DIR}/channels" "${INSTALL_DIR}/channels"
  fi

  log "Starting chronicbot service"
  systemctl start chronicbot || die "Failed to start chronicbot"
}

# ── health_check ─────────────────────────────────────────────────────────
health_check() {
  log "Running health check (${HEALTH_RETRIES} retries, ${HEALTH_DELAY}s apart)"
  local attempt
  for ((attempt = 1; attempt <= HEALTH_RETRIES; attempt++)); do
    if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
      log "Health check passed on attempt ${attempt}"
      return 0
    fi
    log "Health check attempt ${attempt}/${HEALTH_RETRIES} failed, waiting ${HEALTH_DELAY}s..."
    sleep "$HEALTH_DELAY"
  done

  log "Health check failed after ${HEALTH_RETRIES} attempts"
  return 1
}

# ── rollback ─────────────────────────────────────────────────────────────
rollback() {
  log "ROLLING BACK to previous version"

  systemctl stop chronicbot 2>/dev/null || true

  if [[ -d "${INSTALL_DIR}/bin.old" ]]; then
    rm -rf "${INSTALL_DIR}/bin"
    mv "${INSTALL_DIR}/bin.old" "${INSTALL_DIR}/bin"
    log "Restored bin/"
  fi

  if [[ -d "${INSTALL_DIR}/channels.old" ]]; then
    rm -rf "${INSTALL_DIR}/channels"
    mv "${INSTALL_DIR}/channels.old" "${INSTALL_DIR}/channels"
    log "Restored channels/"
  fi

  log "Restarting chronicbot with previous version"
  systemctl start chronicbot || log "WARNING: Failed to restart after rollback"

  die "Update to ${LATEST_TAG} failed — rolled back to previous version"
}

# ── finalize ─────────────────────────────────────────────────────────────
finalize() {
  log "Update successful — cleaning up"

  rm -rf "${INSTALL_DIR}/bin.old" "${INSTALL_DIR}/channels.old"
  echo "$LATEST_TAG" > "$VERSION_FILE"

  # .update/ is cleaned by the EXIT trap
  log "CHRONICbot updated to ${LATEST_TAG}"
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  require_cmd curl jq sha256sum tar systemctl

  check_for_update
  download_release
  verify_checksums
  swap_binaries

  if health_check; then
    finalize
  else
    rollback
  fi
}

main "$@"
