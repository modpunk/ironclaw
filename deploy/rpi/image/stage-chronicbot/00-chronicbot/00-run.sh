#!/bin/bash -e
#
# 00-run.sh — pi-gen chroot script for CHRONICbot stage
#
# This runs inside the ARM chroot during image build. It installs
# deploy files, creates the system user, applies persistent (non-runtime)
# hardening from rpi-always-on.sh, and enables first-boot provisioning.
#

# ── Install deploy files ─────────────────────────────────────────────────

# Create directory structure
install -d -m 755 "${ROOTFS_DIR}/opt/chronicbot"
install -d -m 755 "${ROOTFS_DIR}/opt/chronicbot/bin"
install -d -m 755 "${ROOTFS_DIR}/opt/chronicbot/channels"
install -d -m 755 "${ROOTFS_DIR}/etc/chronicbot"

# Copy setup and update scripts
install -m 755 files/chronicbot-setup.sh "${ROOTFS_DIR}/opt/chronicbot/chronicbot-setup.sh"
install -m 755 files/chronicbot-update.sh "${ROOTFS_DIR}/opt/chronicbot/chronicbot-update.sh"

# Copy env.example as reference
install -m 644 files/env.example "${ROOTFS_DIR}/opt/chronicbot/env.example"

# Install systemd units
install -m 644 files/chronicbot-firstboot.service "${ROOTFS_DIR}/etc/systemd/system/chronicbot-firstboot.service"
install -m 644 files/chronicbot.service "${ROOTFS_DIR}/etc/systemd/system/chronicbot.service"
install -m 644 files/chronicbot-update.service "${ROOTFS_DIR}/etc/systemd/system/chronicbot-update.service"
install -m 644 files/chronicbot-update.timer "${ROOTFS_DIR}/etc/systemd/system/chronicbot-update.timer"

# ── Apply persistent hardening from rpi-always-on.sh ─────────────────────
# We apply only the config-file and systemd-unit parts — NOT the runtime
# sysfs writes (steps 4, 5, 7, bonus) which need real hardware.

# Step 1: Kernel command line
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
if [ -f "${CMDLINE}" ]; then
  for param in "usbcore.autosuspend=-1" "consoleblank=0"; do
    if ! grep -q "$param" "${CMDLINE}"; then
      sed -i "s/$/ $param/" "${CMDLINE}"
    fi
  done
fi

# Step 2: Boot config
CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
if [ -f "${CONFIG}" ]; then
  for line in "force_turbo=1" "temp_soft_limit=70" "hdmi_blanking=0"; do
    key="${line%%=*}"
    if ! grep -q "^${key}=" "${CONFIG}"; then
      echo "$line" >> "${CONFIG}"
    fi
  done
fi

# Step 3: CPU governor service (runs at boot on real hardware)
cat > "${ROOTFS_DIR}/etc/systemd/system/cpu-performance.service" << 'UNIT'
[Unit]
Description=Lock CPU governor to performance and min_freq to max
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq); for c in /sys/devices/system/cpu/cpu*/cpufreq/; do echo performance > $c/scaling_governor; echo $MAX > $c/scaling_min_freq; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Step 6: WiFi power save off (NetworkManager config — persistent)
install -d -m 755 "${ROOTFS_DIR}/etc/NetworkManager/conf.d"
cat > "${ROOTFS_DIR}/etc/NetworkManager/conf.d/99-no-powersave.conf" << 'NM'
[connection]
wifi.powersave = 2
NM

# Step 7: Ethernet EEE off service
cat > "${ROOTFS_DIR}/etc/systemd/system/eth-no-eee.service" << 'UNIT'
[Unit]
Description=Disable Ethernet Energy Efficient Ethernet
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool --set-eee eth0 eee off
RemainAfterExit=yes
StandardError=null

[Install]
WantedBy=multi-user.target
UNIT

# Step 9: logind — ignore all power actions
install -d -m 755 "${ROOTFS_DIR}/etc/systemd/logind.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/logind.conf.d/99-no-sleep.conf" << 'LOGIND'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
IdleActionSec=infinity
LOGIND

# Step 10: Sysctl: TCP keepalive + power
install -d -m 755 "${ROOTFS_DIR}/etc/sysctl.d"
cat > "${ROOTFS_DIR}/etc/sysctl.d/99-always-on.conf" << 'SYSCTL'
# Aggressive TCP keepalives (detect dead connections fast)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# No laptop/power-save batching
vm.laptop_mode = 0
vm.dirty_writeback_centisecs = 500
SYSCTL

# Step 11: SSH server keepalive
install -d -m 755 "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/99-always-on.conf" << 'SSHD'
# Always-on: aggressive SSH keepalive
ClientAliveInterval 30
ClientAliveCountMax 5
TCPKeepAlive yes
SSHD

# ── Create system user and set permissions (inside chroot) ───────────────
on_chroot << 'CHROOT'
# Create chronicbot system user
if ! id chronicbot &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin chronicbot
fi

# Set ownership of chronicbot directories
chown -R chronicbot:chronicbot /opt/chronicbot

# Enable services
systemctl enable chronicbot-firstboot.service
systemctl enable cpu-performance.service
systemctl enable eth-no-eee.service

# Mask sleep/suspend/hibernate targets
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
  systemctl mask "$target" 2>/dev/null || true
done

# Disable bluetooth
systemctl disable bluetooth.service 2>/dev/null || true
systemctl disable hciuart.service 2>/dev/null || true
CHROOT
