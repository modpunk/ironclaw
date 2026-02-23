#!/usr/bin/env bash
#
# chronicbot-setup.sh — Main bootstrap/setup script for CHRONICbot on Raspberry Pi
#
# Two modes:
#   --firstboot   Headless (steps 1-7). Called by systemd on first boot.
#   default       Interactive (steps 1-8). Called by user via SSH or curl|bash.
#
# curl|bash usage:
#   curl -sfL https://raw.githubusercontent.com/kingmk3r/ChronicBot/main/deploy/rpi/chronicbot-setup.sh | sudo bash -s -- --setup
#
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
GITHUB_REPO="kingmk3r/ChronicBot"
INSTALL_DIR="/opt/chronicbot"
CONFIG_DIR="/etc/chronicbot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null || echo /tmp)"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/deploy/rpi"
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
STAGING_DIR="/tmp/chronicbot-install"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[chronicbot-setup] $*"; }
warn() { echo "[chronicbot-setup] WARN: $*"; }
die()  { echo "[chronicbot-setup] FATAL: $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [[ -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
  exit "$rc"
}
trap cleanup EXIT

# ── detect_environment ───────────────────────────────────────────────────────
detect_environment() {
  log "Detecting environment..."

  # Must be root
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo)."
  fi

  # Check for Raspberry Pi hardware
  if [[ -f /proc/cpuinfo ]]; then
    if grep -qE 'BCM2711|BCM2712' /proc/cpuinfo 2>/dev/null; then
      log "Detected Raspberry Pi 4/5 (BCM2711/BCM2712)"
    else
      warn "Not running on Raspberry Pi 4/5 hardware. Continuing anyway."
    fi
  else
    warn "/proc/cpuinfo not found. Cannot verify hardware."
  fi

  # Check firstboot marker
  if [[ -f "${CONFIG_DIR}/firstboot.done" ]]; then
    log "First boot already completed (${CONFIG_DIR}/firstboot.done exists)"
  fi

  # Detect TTY
  if [ -t 0 ]; then
    HAS_TTY=true
    log "TTY detected — interactive mode available"
  else
    HAS_TTY=false
    log "No TTY — non-interactive mode (use --setup to force interactive prompts)"
  fi
}

# ── harden_system ────────────────────────────────────────────────────────────
harden_system() {
  log "Hardening system (always-on configuration)..."

  local harden_script="${SCRIPT_DIR}/rpi-always-on.sh"

  if [[ ! -f "${harden_script}" ]]; then
    log "rpi-always-on.sh not found locally, downloading from GitHub..."
    harden_script="/tmp/rpi-always-on.sh"
    curl -sfL -o "${harden_script}" "${RAW_URL}/rpi-always-on.sh" \
      || die "Failed to download rpi-always-on.sh from ${RAW_URL}/rpi-always-on.sh"
  fi

  bash "${harden_script}"
  log "System hardening complete"
}

# ── install_dependencies ─────────────────────────────────────────────────────
install_dependencies() {
  log "Installing system dependencies..."

  apt-get update -qq
  apt-get install -y -qq postgresql jq curl

  # Create system user
  if id chronicbot &>/dev/null; then
    log "System user 'chronicbot' already exists"
  else
    useradd --system --no-create-home --shell /usr/sbin/nologin chronicbot
    log "Created system user 'chronicbot'"
  fi

  # Wait for PostgreSQL to be ready
  log "Ensuring PostgreSQL is running..."
  systemctl enable --now postgresql
  local retries=10
  while ! sudo -u postgres pg_isready -q 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      die "PostgreSQL failed to start"
    fi
    sleep 1
  done

  # Create PostgreSQL user (ignore error if already exists)
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='chronicbot'" | grep -q 1; then
    log "PostgreSQL user 'chronicbot' already exists"
  else
    sudo -u postgres createuser --no-password chronicbot
    log "Created PostgreSQL user 'chronicbot'"
  fi

  # Create database (ignore error if already exists)
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='chronicbot'" | grep -q 1; then
    log "PostgreSQL database 'chronicbot' already exists"
  else
    sudo -u postgres createdb --owner=chronicbot chronicbot
    log "Created PostgreSQL database 'chronicbot'"
  fi

  # Ensure pg_hba.conf has peer auth for chronicbot
  local pg_hba
  pg_hba=$(sudo -u postgres psql -tAc "SHOW hba_file")
  if [[ -n "${pg_hba}" && -f "${pg_hba}" ]]; then
    if ! grep -qE '^local\s+chronicbot\s+chronicbot\s+peer' "${pg_hba}" 2>/dev/null; then
      # Insert before the first existing local line to ensure it takes priority
      sed -i '/^# TYPE/a local   chronicbot      chronicbot                              peer' "${pg_hba}" 2>/dev/null \
        || echo "local   chronicbot      chronicbot                              peer" >> "${pg_hba}"
      systemctl reload postgresql
      log "Added peer auth for chronicbot to pg_hba.conf"
    else
      log "pg_hba.conf already has peer auth for chronicbot"
    fi
  else
    warn "Could not locate pg_hba.conf — verify PostgreSQL peer auth manually"
  fi

  log "Dependencies installed"
}

# ── download_latest_release ──────────────────────────────────────────────────
download_latest_release() {
  log "Fetching latest release from GitHub..."

  mkdir -p "${STAGING_DIR}"

  local release_json
  release_json=$(curl -sfL "${API_URL}") \
    || die "Failed to query GitHub API at ${API_URL}. Check network connectivity."

  RELEASE_TAG=$(echo "${release_json}" | jq -r '.tag_name')
  if [[ -z "${RELEASE_TAG}" || "${RELEASE_TAG}" == "null" ]]; then
    die "No releases found for ${GITHUB_REPO}. Publish a release first."
  fi

  log "Latest release: ${RELEASE_TAG}"

  # Parse asset URLs
  local binary_name binary_url checksums_url
  binary_name=$(echo "${release_json}" | jq -r \
    '.assets[] | select(.name | (contains("aarch64") and endswith(".tar.gz") and (contains("wasm") | not))) | .name' \
    | head -1)
  binary_url=$(echo "${release_json}" | jq -r \
    --arg name "${binary_name}" \
    '.assets[] | select(.name == $name) | .browser_download_url')
  checksums_url=$(echo "${release_json}" | jq -r \
    '.assets[] | select(.name == "checksums.txt") | .browser_download_url')

  if [[ -z "${binary_name}" || "${binary_name}" == "null" || -z "${binary_url}" || "${binary_url}" == "null" ]]; then
    die "No aarch64 binary asset found in release ${RELEASE_TAG}. Available assets: $(echo "${release_json}" | jq -r '.assets[].name' | tr '\n' ', ')"
  fi

  # Download binary
  log "Downloading binary: ${binary_name}"
  curl -sfL -o "${STAGING_DIR}/${binary_name}" "${binary_url}" \
    || die "Failed to download ${binary_name}"

  # Download WASM channel assets
  local wasm_assets
  wasm_assets=$(echo "${release_json}" | jq -r \
    '.assets[] | select(.name | endswith("-wasm32-wasip2.tar.gz")) | .name + "\t" + .browser_download_url')

  if [[ -n "${wasm_assets}" ]]; then
    while IFS=$'\t' read -r name url; do
      [[ -z "${name}" ]] && continue
      log "Downloading WASM channel: ${name}"
      curl -sfL -o "${STAGING_DIR}/${name}" "${url}" \
        || die "Failed to download WASM channel: ${name}"
    done <<< "${wasm_assets}"
  else
    log "No WASM channel assets found in release"
  fi

  # Download and verify checksums
  if [[ -n "${checksums_url}" && "${checksums_url}" != "null" ]]; then
    log "Downloading checksums.txt"
    curl -sfL -o "${STAGING_DIR}/checksums.txt" "${checksums_url}" \
      || die "Failed to download checksums.txt"

    log "Verifying SHA256 checksums..."
    local errors=0
    for file in "${STAGING_DIR}"/*.tar.gz; do
      [[ -f "${file}" ]] || continue
      local fname
      fname=$(basename "${file}")
      local expected actual
      expected=$(grep "${fname}" "${STAGING_DIR}/checksums.txt" | awk '{print $1}')
      if [[ -z "${expected}" ]]; then
        warn "No checksum entry for ${fname} — skipping verification"
        continue
      fi
      actual=$(sha256sum "${file}" | awk '{print $1}')
      if [[ "${expected}" != "${actual}" ]]; then
        log "CHECKSUM MISMATCH: ${fname}"
        log "  expected: ${expected}"
        log "  actual:   ${actual}"
        errors=$((errors + 1))
      else
        log "  ${fname}: OK"
      fi
    done
    if [[ ${errors} -gt 0 ]]; then
      die "Checksum verification failed for ${errors} file(s). Aborting."
    fi
    log "All checksums verified"
  else
    warn "No checksums.txt in release — skipping verification"
  fi

  # Store binary name for install_files
  BINARY_TARBALL="${binary_name}"
}

# ── install_files ────────────────────────────────────────────────────────────
install_files() {
  log "Installing files..."

  mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/channels"

  # Extract binary tarball and find the ironclaw binary
  local extract_dir="${STAGING_DIR}/extract-bin"
  mkdir -p "${extract_dir}"
  tar -xzf "${STAGING_DIR}/${BINARY_TARBALL}" -C "${extract_dir}" \
    || die "Failed to extract binary tarball: ${BINARY_TARBALL}"

  local ironclaw_bin
  ironclaw_bin=$(find "${extract_dir}" -name 'ironclaw' -type f | head -1)
  if [[ -z "${ironclaw_bin}" ]]; then
    die "Could not find 'ironclaw' binary inside ${BINARY_TARBALL}"
  fi

  cp "${ironclaw_bin}" "${INSTALL_DIR}/bin/ironclaw"
  chmod 755 "${INSTALL_DIR}/bin/ironclaw"
  log "Installed ironclaw binary to ${INSTALL_DIR}/bin/ironclaw"

  # Extract WASM channel tarballs
  for wasm_tar in "${STAGING_DIR}"/*-wasm32-wasip2.tar.gz; do
    [[ -f "${wasm_tar}" ]] || continue
    local wasm_name
    wasm_name=$(basename "${wasm_tar}")
    log "Extracting WASM channel: ${wasm_name}"
    tar -xzf "${wasm_tar}" -C "${INSTALL_DIR}/channels/" \
      || warn "Failed to extract WASM channel: ${wasm_name}"
  done

  # Set ownership
  chown -R chronicbot:chronicbot "${INSTALL_DIR}"

  # Create symlink
  ln -sf "${INSTALL_DIR}/bin/ironclaw" /usr/local/bin/chronicbot
  log "Created symlink: /usr/local/bin/chronicbot -> ${INSTALL_DIR}/bin/ironclaw"

  # Write version
  echo "${RELEASE_TAG}" > "${INSTALL_DIR}/version.txt"
  chown chronicbot:chronicbot "${INSTALL_DIR}/version.txt"
  log "Installed version: ${RELEASE_TAG}"
}

# ── install_services ─────────────────────────────────────────────────────────
install_services() {
  log "Installing systemd services..."

  local service_files=("chronicbot.service" "chronicbot-update.service" "chronicbot-update.timer")

  for svc in "${service_files[@]}"; do
    local src="${SCRIPT_DIR}/${svc}"
    if [[ ! -f "${src}" ]]; then
      log "${svc} not found locally, downloading from GitHub..."
      src="${STAGING_DIR}/${svc}"
      curl -sfL -o "${src}" "${RAW_URL}/${svc}" \
        || die "Failed to download ${svc} from ${RAW_URL}/${svc}"
    fi
    cp "${src}" "/etc/systemd/system/${svc}"
    log "Installed /etc/systemd/system/${svc}"
  done

  # Install update script
  local update_script="${SCRIPT_DIR}/chronicbot-update.sh"
  if [[ ! -f "${update_script}" ]]; then
    log "chronicbot-update.sh not found locally, downloading from GitHub..."
    update_script="${STAGING_DIR}/chronicbot-update.sh"
    curl -sfL -o "${update_script}" "${RAW_URL}/chronicbot-update.sh" \
      || die "Failed to download chronicbot-update.sh"
  fi
  cp "${update_script}" "${INSTALL_DIR}/chronicbot-update.sh"
  chmod +x "${INSTALL_DIR}/chronicbot-update.sh"
  chown chronicbot:chronicbot "${INSTALL_DIR}/chronicbot-update.sh"
  log "Installed ${INSTALL_DIR}/chronicbot-update.sh"

  systemctl daemon-reload
  systemctl enable chronicbot-update.timer
  log "Enabled chronicbot-update.timer (daily update checks)"

  # Do NOT enable chronicbot.service yet — needs .env
  log "chronicbot.service installed but NOT enabled (needs .env configuration)"
}

# ── mark_firstboot_done ─────────────────────────────────────────────────────
mark_firstboot_done() {
  mkdir -p "${CONFIG_DIR}"
  touch "${CONFIG_DIR}/firstboot.done"
  log "First boot marked as complete: ${CONFIG_DIR}/firstboot.done"
}

# ── interactive_setup ────────────────────────────────────────────────────────
interactive_setup() {
  log "Starting interactive setup..."

  # Prompt for Anthropic API key (required)
  local api_key=""
  while [[ -z "${api_key}" ]]; do
    read -rp "Anthropic API key: " api_key
    if [[ -z "${api_key}" ]]; then
      echo "  API key is required. Please enter your Anthropic API key."
    fi
  done

  # Prompt for Telegram bot token (optional)
  local telegram_token=""
  read -rp "Telegram bot token (Enter to skip): " telegram_token

  # Prompt for agent name
  local agent_name=""
  read -rp "Agent name [chronicbot]: " agent_name
  agent_name="${agent_name:-chronicbot}"

  # Prompt for HTTP port
  local http_port=""
  read -rp "HTTP port [8080]: " http_port
  http_port="${http_port:-8080}"

  # Write .env file
  log "Writing ${INSTALL_DIR}/.env..."
  cat > "${INSTALL_DIR}/.env" <<ENVFILE
DATABASE_BACKEND=postgres
DATABASE_URL=postgres:///chronicbot
LLM_BACKEND=anthropic
ANTHROPIC_API_KEY=${api_key}
SELECTED_MODEL=claude-sonnet-4-20250514
AGENT_NAME=${agent_name}
GATEWAY_ENABLED=true
GATEWAY_HOST=0.0.0.0
GATEWAY_PORT=${http_port}
RUST_LOG=ironclaw=info,tower_http=info
HEARTBEAT_ENABLED=true
ENVFILE

  if [[ -n "${telegram_token}" ]]; then
    echo "TELEGRAM_BOT_TOKEN=${telegram_token}" >> "${INSTALL_DIR}/.env"
  fi

  chmod 600 "${INSTALL_DIR}/.env"
  chown chronicbot:chronicbot "${INSTALL_DIR}/.env"
  log "Configuration written to ${INSTALL_DIR}/.env (mode 600)"

  # Attempt to mark onboarding as complete
  if sudo -u chronicbot "${INSTALL_DIR}/bin/ironclaw" config set --no-onboard onboard_completed true 2>/dev/null; then
    log "Onboarding marked as completed"
  else
    log "Skipped onboard flag (ironclaw config command not available or failed)"
  fi

  # Enable and start the service
  systemctl enable --now chronicbot.service
  log "chronicbot.service enabled and started"

  # Print access info
  local ip_addr
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip_addr="${ip_addr:-<unknown>}"

  echo ""
  echo "============================================"
  echo " CHRONICbot is running!"
  echo " Web UI: http://${ip_addr}:${http_port}"
  echo "============================================"
  echo ""
}

# ── usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

CHRONICbot bootstrap and setup script for Raspberry Pi.

Options:
  --firstboot   Headless mode (steps 1-7 only, no interactive prompts).
                Used by systemd on first boot.
  --setup       Force interactive setup even without a TTY.
                Use with: curl | sudo bash -s -- --setup
  --help        Show this help message.

Without flags, runs all steps including interactive setup if a TTY is detected.
EOF
  exit 0
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  local mode="default"
  local force_setup=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --firstboot)
        mode="firstboot"
        shift
        ;;
      --setup)
        force_setup=true
        shift
        ;;
      --help|-h)
        usage
        ;;
      *)
        warn "Unknown argument: $1"
        shift
        ;;
    esac
  done

  echo ""
  echo "============================================"
  echo " CHRONICbot Setup"
  echo " Mode: ${mode}"
  echo "============================================"
  echo ""

  # Step 1: Detect environment
  detect_environment

  # Step 2: Harden system
  harden_system

  # Step 3: Install dependencies
  install_dependencies

  # Step 4: Download latest release
  download_latest_release

  # Step 5: Install files
  install_files

  # Step 6: Install services
  install_services

  # Step 7: Mark firstboot done
  mark_firstboot_done

  # Step 8: Interactive setup (only if not --firstboot and TTY or --setup)
  if [[ "${mode}" != "firstboot" ]]; then
    if [[ "${HAS_TTY}" == "true" || "${force_setup}" == "true" ]]; then
      interactive_setup
    else
      echo ""
      log "Skipping interactive setup (no TTY detected)."
      log "To complete setup, SSH into the Pi and run:"
      log "  sudo $(realpath "$0" 2>/dev/null || echo chronicbot-setup.sh) --setup"
      echo ""
    fi
  fi

  # Summary
  echo ""
  echo "============================================"
  echo " Setup Summary"
  echo "============================================"
  echo " Version:    $(cat "${INSTALL_DIR}/version.txt" 2>/dev/null || echo 'N/A')"
  echo " Binary:     ${INSTALL_DIR}/bin/ironclaw"
  echo " Channels:   ${INSTALL_DIR}/channels/"
  echo " Config:     ${INSTALL_DIR}/.env"
  echo " Services:   chronicbot.service, chronicbot-update.timer"
  echo " Firstboot:  ${CONFIG_DIR}/firstboot.done"
  echo "============================================"
  echo ""
}

main "$@"
