#!/usr/bin/env bash
set -euo pipefail

# Read-only gate for a Flutter hardware-rendering bring-up.

ADB_BIN="${ADB_BIN:-}"
if [[ -z "$ADB_BIN" ]]; then
  if command -v adb >/dev/null 2>&1; then ADB_BIN=adb
  elif command -v adb.exe >/dev/null 2>&1; then ADB_BIN=adb.exe
  else printf 'ERROR: adb/adb.exe not found in PATH\n' >&2; exit 1; fi
fi
ADB=("$ADB_BIN")
if [[ -n "${ADB_SERIAL:-}" ]]; then ADB+=( -s "$ADB_SERIAL" ); fi
shell() { "${ADB[@]}" shell "$1" | tr -d '\r'; }

"${ADB[@]}" wait-for-device
[[ "$("${ADB[@]}" get-state 2>/dev/null | tr -d '\r')" == device ]] || { printf 'ERROR: ADB device is not ready\n' >&2; exit 1; }

serial="$("${ADB[@]}" get-serialno | tr -d '\r')"
compat="$(shell 'tr "\\000" "\\n" </sys/firmware/devicetree/base/compatible 2>/dev/null | sed -n "1p" || true')"
kernel="$(shell 'uname -r')"
gpu_status="$(shell 'tr -d "\\000\\r\\n" </sys/firmware/devicetree/base/gpu@ff320000/status 2>/dev/null || true')"
gpu_driver="$(shell 'if [ -e /sys/bus/platform/devices/ff320000.gpu/driver ]; then readlink -f /sys/bus/platform/devices/ff320000.gpu/driver; else echo none; fi')"
gpu_nodes="$(shell 'for p in /dev/mali0 /dev/mali /dev/dri/renderD*; do [ -e "$p" ] && echo "$p"; done')"
drm_driver="$(shell 'for p in /sys/class/drm/card0/device/driver /sys/class/drm/renderD128/device/driver; do [ -e "$p" ] && readlink -f "$p"; done')"
egl_libs="$(shell 'find /lib /lib64 /usr/lib /usr/lib64 /vendor/lib /vendor/lib64 /system/lib /system/lib64 -maxdepth 3 -type f 2>/dev/null | grep -Ei "/(libEGL|libGLES|libgbm|libvulkan|libMali|panfrost)[^/]*\\.so" | sed -n "1,80p" || true')"
compositor="$(shell 'ps 2>/dev/null | grep -Ei "(weston|wayland|sway|Xorg|compositor)" | grep -v grep || true')"

printf 'Flutter GPU preflight (read-only)\nDevice: %s (%s)\nKernel: %s\n' "$serial" "${compat:-unknown}" "$kernel"
printf 'GPU DT status: %s\nGPU driver: %s\nDRM driver: %s\n' "${gpu_status:-missing}" "$gpu_driver" "${drm_driver:-none}"
printf 'GPU/DRM nodes:\n%s\nEGL/GLES/GBM/Vulkan libraries:\n%s\nCompositor:\n%s\n' "${gpu_nodes:-none}" "${egl_libs:-none}" "${compositor:-none}"

failures=()
[[ "$gpu_status" == okay ]] || failures+=("GPU DT node is not enabled")
[[ "$gpu_driver" != none ]] || failures+=("no Mali/Panfrost GPU driver is bound")
[[ "$drm_driver" == *rockchip-drm* ]] || failures+=("Rockchip display DRM is not confirmed")
[[ "$egl_libs" == *libEGL* && "$egl_libs" == *libGLES* ]] || failures+=("EGL/GLES userspace is missing")
[[ "$egl_libs" == *libgbm* ]] || failures+=("GBM userspace is missing")
if ((${#failures[@]})); then
  printf 'RESULT: BLOCKED\nMissing gates:\n'; printf ' - %s\n' "${failures[@]}"
  printf 'No device changes were made.\n'; exit 2
fi
printf 'RESULT: GPU kernel/userspace gates passed; Flutter EGL/DRM smoke test remains.\n'
