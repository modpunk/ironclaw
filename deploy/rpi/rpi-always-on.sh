#!/usr/bin/env bash
#
# rpi-always-on.sh — Disable ALL sleep, power-save, and economy modes on Raspberry Pi OS.
#
# Usage:  sudo bash rpi-always-on.sh
#
# Idempotent: safe to run multiple times.
# Reboot recommended after first run for kernel cmdline + config.txt changes.
#

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (sudo bash $0)"
  exit 1
fi

echo "============================================"
echo " RPi Always-On Configuration Script"
echo "============================================"
echo ""

# ─── 1. KERNEL COMMAND LINE ──────────────────────────────────────────────────
echo ">>> [1/12] Kernel command line (/boot/firmware/cmdline.txt)"
CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
  for param in "usbcore.autosuspend=-1" "consoleblank=0"; do
    if ! grep -q "$param" "$CMDLINE"; then
      sed -i "s/$/ $param/" "$CMDLINE"
      echo "  Added: $param"
    else
      echo "  Already set: $param"
    fi
  done
else
  echo "  WARN: $CMDLINE not found (not RPi OS?)"
fi

# ─── 2. BOOT CONFIG ─────────────────────────────────────────────────────────
echo ">>> [2/12] Boot config (/boot/firmware/config.txt)"
CONFIG="/boot/firmware/config.txt"
if [ -f "$CONFIG" ]; then
  for line in "force_turbo=1" "temp_soft_limit=70" "hdmi_blanking=0"; do
    key="${line%%=*}"
    if ! grep -q "^${key}=" "$CONFIG"; then
      echo "$line" >> "$CONFIG"
      echo "  Added: $line"
    else
      echo "  Already set: $line"
    fi
  done
else
  echo "  WARN: $CONFIG not found (not RPi OS?)"
fi

# ─── 3. CPU GOVERNOR SERVICE ────────────────────────────────────────────────
echo ">>> [3/12] CPU governor → performance (systemd service)"
cat > /etc/systemd/system/cpu-performance.service << 'UNIT'
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
systemctl daemon-reload
systemctl enable cpu-performance.service 2>/dev/null
echo "  Done"

# ─── 4. APPLY CPU GOVERNOR NOW ──────────────────────────────────────────────
echo ">>> [4/12] Apply CPU governor now"
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
  done
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
    echo "$MAX" > "$f" 2>/dev/null || true
  done
  echo "  Locked at ${MAX}kHz"
else
  echo "  SKIP: cpufreq not available"
fi

# ─── 5. USB AUTOSUSPEND OFF ─────────────────────────────────────────────────
echo ">>> [5/12] USB autosuspend → disabled"
echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
for dev in /sys/bus/usb/devices/*/power/control; do
  echo on > "$dev" 2>/dev/null || true
done
echo "  Done"

# ─── 6. WIFI POWER SAVE OFF ─────────────────────────────────────────────────
echo ">>> [6/12] WiFi power save → off"
iw dev wlan0 set power_save off 2>/dev/null || true
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-no-powersave.conf << 'NM'
[connection]
wifi.powersave = 2
NM
echo "  Done (NetworkManager + runtime)"

# ─── 7. ETHERNET EEE OFF ────────────────────────────────────────────────────
echo ">>> [7/12] Ethernet EEE → off"
ethtool --set-eee eth0 eee off 2>/dev/null || true
cat > /etc/systemd/system/eth-no-eee.service << 'UNIT'
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
systemctl daemon-reload
systemctl enable eth-no-eee.service 2>/dev/null
echo "  Done"

# ─── 8. MASK SLEEP/SUSPEND/HIBERNATE ────────────────────────────────────────
echo ">>> [8/12] Mask sleep/suspend/hibernate targets"
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
  systemctl mask "$target" 2>/dev/null || true
done
echo "  Done"

# ─── 9. LOGIND: IGNORE ALL IDLE/POWER ACTIONS ───────────────────────────────
echo ">>> [9/12] logind → ignore all power actions"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-no-sleep.conf << 'LOGIND'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
IdleActionSec=infinity
LOGIND
systemctl restart systemd-logind 2>/dev/null || true
echo "  Done"

# ─── 10. SYSCTL: TCP KEEPALIVE + POWER ──────────────────────────────────────
echo ">>> [10/12] Sysctl: TCP keepalive, laptop_mode, dirty writeback"
cat > /etc/sysctl.d/99-always-on.conf << 'SYSCTL'
# Aggressive TCP keepalives (detect dead connections fast)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# No laptop/power-save batching
vm.laptop_mode = 0
vm.dirty_writeback_centisecs = 500
SYSCTL
sysctl -p /etc/sysctl.d/99-always-on.conf 2>/dev/null || true
echo "  Done"

# ─── 11. SSH SERVER KEEPALIVE ────────────────────────────────────────────────
echo ">>> [11/12] SSHD keepalive"
SSHD_CONF="/etc/ssh/sshd_config"
SSHD_DROP="/etc/ssh/sshd_config.d/99-always-on.conf"
mkdir -p /etc/ssh/sshd_config.d
cat > "$SSHD_DROP" << 'SSHD'
# Always-on: aggressive SSH keepalive
ClientAliveInterval 30
ClientAliveCountMax 5
TCPKeepAlive yes
SSHD
# Clean up any old inline additions from previous manual setup
sed -i '/^# Always-on: aggressive keepalive$/d' "$SSHD_CONF" 2>/dev/null || true
sed -i '/^ClientAliveInterval 30$/d' "$SSHD_CONF" 2>/dev/null || true
sed -i '/^ClientAliveCountMax 5$/d' "$SSHD_CONF" 2>/dev/null || true
sed -i '/^TCPKeepAlive yes$/d' "$SSHD_CONF" 2>/dev/null || true
# Make sure drop-in dir is included
if ! grep -q "^Include /etc/ssh/sshd_config.d/" "$SSHD_CONF" 2>/dev/null; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONF"
fi
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
echo "  Done (via sshd_config.d drop-in)"

# ─── 12. DISABLE BLUETOOTH ──────────────────────────────────────────────────
echo ">>> [12/12] Disable Bluetooth"
systemctl disable --now bluetooth.service 2>/dev/null || true
systemctl disable --now hciuart.service 2>/dev/null || true
echo "  Done"

# ─── RUNTIME PM: WAKE ALL SUSPENDED DEVICES ─────────────────────────────────
echo ""
echo ">>> Bonus: Wake any runtime-suspended devices"
for f in /sys/bus/*/devices/*/power/control; do
  current=$(cat "$f" 2>/dev/null) || continue
  if [ "$current" = "auto" ]; then
    echo on > "$f" 2>/dev/null || true
  fi
done
echo "  Done"

# ─── VERIFY ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Verification"
echo "============================================"
printf "CPU governor:     %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
printf "CPU min freq:     %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo N/A)"
printf "CPU max freq:     %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo N/A)"
printf "USB autosuspend:  %s\n" "$(cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null || echo N/A)"
printf "WiFi powersave:   %s\n" "$(iw dev wlan0 get power_save 2>/dev/null || echo N/A)"
printf "Sleep target:     %s\n" "$(systemctl is-enabled sleep.target 2>&1)"
printf "Suspend target:   %s\n" "$(systemctl is-enabled suspend.target 2>&1)"
printf "Hibernate target: %s\n" "$(systemctl is-enabled hibernate.target 2>&1)"
printf "Bluetooth:        %s\n" "$(systemctl is-active bluetooth.service 2>&1)"
printf "SSH keepalive:    %s\n" "$(grep '^ClientAliveInterval' /etc/ssh/sshd_config.d/99-always-on.conf 2>/dev/null || echo N/A)"
printf "Temp:             %s\n" "$(vcgencmd measure_temp 2>/dev/null || echo N/A)"
printf "Throttled:        %s\n" "$(vcgencmd get_throttled 2>/dev/null || echo N/A)"
echo ""
echo "============================================"
echo " All done."
echo " Reboot recommended for kernel cmdline"
echo " and config.txt changes to take effect."
echo "============================================"
