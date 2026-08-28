#!/usr/bin/env bash
set -euo pipefail

# Falcon/RK3562 GPU probe. This script is intentionally non-destructive:
# it only records the device state and refuses to patch or flash a DTB.

ADB_BIN="${ADB_BIN:-}"
if [[ -z "$ADB_BIN" ]]; then
  if command -v adb >/dev/null 2>&1; then
    ADB_BIN=adb
  elif command -v adb.exe >/dev/null 2>&1; then
    ADB_BIN=adb.exe
  else
    printf 'ERROR: adb/adb.exe not found in PATH\n' >&2
    exit 1
  fi
fi
ADB=("$ADB_BIN")
if [[ -n "${ADB_SERIAL:-}" ]]; then
  ADB+=( -s "$ADB_SERIAL" )
fi

shell() {
  "${ADB[@]}" shell "$1" | tr -d '\r'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

"${ADB[@]}" wait-for-device
[[ "$("${ADB[@]}" get-state 2>/dev/null | tr -d '\r')" == "device" ]] || die "ADB device is not ready"

serial="$("${ADB[@]}" get-serialno | tr -d '\r')"
stamp="$(date +%Y%m%d-%H%M%S)"
backup_root="${GPU_BACKUP_DIR:-$PWD/.gpu-backups}"
backup_dir="$backup_root/${serial}-${stamp}"
mkdir -p "$backup_dir"

compat="$(shell 'tr "\000" "\n" </sys/firmware/devicetree/base/compatible 2>/dev/null | sed -n "1p" || true')"
gpu_status="$(shell 'tr -d "\000\r\n" </sys/firmware/devicetree/base/gpu@ff320000/status 2>/dev/null || true')"
gpu_device="$(shell 'if [ -e /sys/bus/platform/devices/ff320000.gpu ]; then echo yes; else echo no; fi')"
gpu_driver="$(shell 'if [ -e /sys/bus/platform/devices/ff320000.gpu/driver ]; then readlink -f /sys/bus/platform/devices/ff320000.gpu/driver; else echo none; fi')"
gpu_nodes="$(shell 'for p in /dev/mali0 /dev/mali /dev/gpu; do [ -e "$p" ] && echo "$p"; done')"
gpu_modules="$(shell 'ls /sys/module 2>/dev/null | grep -Ei "mali|panfrost|bifrost|gpu" || true')"
gpu_symbols="$(shell 'grep -Ei "mali|panfrost|bifrost" /proc/kallsyms 2>/dev/null | sed -n "1,5p" || true')"
egl_libs="$(shell 'find /lib /lib64 /usr/lib -maxdepth 3 -type f 2>/dev/null | grep -Ei "/(libEGL|libGLES|libvulkan|libMali|libgbm)" | sed -n "1,40p" || true')"
overlay="$(shell 'if [ -d /sys/kernel/config/device-tree/overlays ]; then echo yes; else echo no; fi')"

cat >"$backup_dir/state.env" <<EOF
serial=$serial
compat=$compat
gpu_status=$gpu_status
gpu_device=$gpu_device
gpu_driver=$gpu_driver
gpu_nodes=$(printf '%q' "$gpu_nodes")
gpu_modules=$(printf '%q' "$gpu_modules")
overlay=$overlay
remote_changes=none
EOF
printf '%s\n' "$gpu_symbols" >"$backup_dir/kallsyms-gpu.txt"
printf '%s\n' "$egl_libs" >"$backup_dir/egl-libs.txt"

printf 'Device: %s (%s)\n' "$serial" "$compat"
printf 'GPU DT status: %s\n' "${gpu_status:-missing}"
printf 'GPU platform device: %s; driver: %s\n' "$gpu_device" "$gpu_driver"
printf 'GPU character nodes: %s\n' "${gpu_nodes:-none}"
printf 'DT overlays: %s\n' "$overlay"
printf 'State saved to: %s\n' "$backup_dir"

if [[ "$gpu_status" == "okay" && "$gpu_device" == "yes" && "$gpu_driver" != "none" && -n "$gpu_nodes" ]]; then
  printf 'GPU appears enabled at the kernel boundary. No change was needed.\n'
  exit 0
fi

if [[ "$gpu_status" != "okay" ]]; then
  printf '%s\n' \
    'GPU cannot be enabled at runtime on this firmware: the device-tree node is disabled.' \
    'A patched boot DTB plus either Rockchip mali_kbase or community Panfrost, and matching EGL/GLES/GBM userspace, are required.'
  exit 2
fi

printf '%s\n' \
  'GPU device-tree node is enabled, but the kernel driver/device node is missing.' \
  'Installing a userspace library or calling miniapp_cli setRenderConfig cannot provide hardware acceleration.'
exit 3
