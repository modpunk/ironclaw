#!/bin/bash -e
#
# build-image.sh — Build a custom Raspberry Pi OS image for CHRONICbot
#
# Uses pi-gen (https://github.com/RPi-Distro/pi-gen) via Docker to produce
# a minimal (Lite) Bookworm image with hardware hardening and first-boot
# provisioning baked in.
#
# Usage:
#   sudo ./build-image.sh [--output-dir /path/to/output]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy/rpi"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ── Parse arguments ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"

echo "============================================"
echo " CHRONICbot RPi Image Builder"
echo " Output: ${OUTPUT_DIR}"
echo "============================================"
echo ""

# ── 1. Clone pi-gen ──────────────────────────────────────────────────────
PIGEN_DIR="${SCRIPT_DIR}/pi-gen"

if [ -d "${PIGEN_DIR}" ]; then
  echo ">>> pi-gen directory already exists, removing..."
  rm -rf "${PIGEN_DIR}"
fi

echo ">>> Cloning pi-gen..."
git clone --depth 1 https://github.com/RPi-Distro/pi-gen.git "${PIGEN_DIR}"

# ── 2. Write pi-gen config ───────────────────────────────────────────────
echo ">>> Writing pi-gen config..."
cat > "${PIGEN_DIR}/config" << 'EOF'
IMG_NAME=chronicbot
RELEASE=bookworm
TARGET_HOSTNAME=chronicbot
FIRST_USER_NAME=chronicbot
FIRST_USER_PASS=chronicbot
LOCALE_DEFAULT=en_US.UTF-8
KEYBOARD_KEYMAP=us
TIMEZONE_DEFAULT=UTC
ENABLE_SSH=1
STAGE_LIST="stage0 stage1 stage2 stage-chronicbot"
EOF

# ── 3. Skip stages 3-5 (desktop/X11) ────────────────────────────────────
# pi-gen checks for SKIP files to skip stages; but since we use STAGE_LIST
# we only need to ensure stage3/4/5 are not listed (they aren't).
# As a belt-and-suspenders approach, also touch SKIP files:
for stage in stage3 stage4 stage5; do
  if [ -d "${PIGEN_DIR}/${stage}" ]; then
    touch "${PIGEN_DIR}/${stage}/SKIP"
    touch "${PIGEN_DIR}/${stage}/SKIP_IMAGES"
  fi
done

# ── 4. Create custom stage ───────────────────────────────────────────────
echo ">>> Creating custom stage: stage-chronicbot..."
CUSTOM_STAGE="${PIGEN_DIR}/stage-chronicbot"
CUSTOM_STEP="${CUSTOM_STAGE}/00-chronicbot"

mkdir -p "${CUSTOM_STEP}/files"

# Mark this stage for image export
touch "${CUSTOM_STAGE}/EXPORT_IMAGE"

# Package list
cat > "${CUSTOM_STEP}/00-packages" << 'EOF'
jq
postgresql
EOF

# Copy deploy files into the stage's files/ directory
echo ">>> Copying deploy files into stage..."
for f in \
  rpi-always-on.sh \
  chronicbot-setup.sh \
  chronicbot-update.sh \
  chronicbot-firstboot.service \
  chronicbot.service \
  chronicbot-update.service \
  chronicbot-update.timer \
  env.example; do
  if [ -f "${DEPLOY_DIR}/${f}" ]; then
    cp "${DEPLOY_DIR}/${f}" "${CUSTOM_STEP}/files/${f}"
  else
    echo "  WARN: ${DEPLOY_DIR}/${f} not found, skipping"
  fi
done

# Copy the chroot run script from our repo (canonical source)
cp "${SCRIPT_DIR}/stage-chronicbot/00-chronicbot/00-run.sh" "${CUSTOM_STEP}/00-run.sh"
chmod +x "${CUSTOM_STEP}/00-run.sh"

# ── 5. Build the image ──────────────────────────────────────────────────
echo ">>> Starting pi-gen build (Docker)..."
cd "${PIGEN_DIR}"
./build-docker.sh

# ── 6. Find and compress the output image ────────────────────────────────
echo ">>> Locating output image..."
IMG_FILE=$(find "${PIGEN_DIR}/deploy" -name "*.img" -type f | head -1)

if [ -z "${IMG_FILE}" ]; then
  echo "ERROR: No .img file found in ${PIGEN_DIR}/deploy/" >&2
  ls -la "${PIGEN_DIR}/deploy/" 2>/dev/null || true
  exit 1
fi

echo ">>> Found: ${IMG_FILE}"
echo ">>> Compressing with xz..."
xz -T0 -9 "${IMG_FILE}"

XZ_FILE="${IMG_FILE}.xz"
if [ ! -f "${XZ_FILE}" ]; then
  echo "ERROR: Compressed image not found at ${XZ_FILE}" >&2
  exit 1
fi

# ── 7. Copy to output location ──────────────────────────────────────────
FINAL_NAME="chronicbot-rpi4.img.xz"
cp "${XZ_FILE}" "${OUTPUT_DIR}/${FINAL_NAME}"

echo ""
echo "============================================"
echo " Image built successfully!"
echo " ${OUTPUT_DIR}/${FINAL_NAME}"
echo " Size: $(du -h "${OUTPUT_DIR}/${FINAL_NAME}" | cut -f1)"
echo "============================================"
