#!/bin/sh

# Temporary RK3562 Mali GPU bring-up and Flutter readiness audit.
# Target: Youdao Buildroot, aarch64, Linux 5.10.160.
# This script never modifies DTB, boot partitions, rootfs libraries, or services.

set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PAYLOAD_ROOT=${GPU_PAYLOAD_ROOT:-"$SCRIPT_DIR/payload"}
STATE_ROOT=${GPU_STATE_ROOT:-"$SCRIPT_DIR/state"}
RUN_ID=${GPU_RUN_ID:-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)}
RUN_DIR="$STATE_ROOT/$RUN_ID"
CURRENT_DIR="$STATE_ROOT/current"
DRM_DEVICE=${DRM_DEVICE:-/dev/dri/card0}
FLUTTER_RUNTIME_ROOT=${FLUTTER_RUNTIME_ROOT:-"$SCRIPT_DIR/flutter"}
FLUTTER_RUN_SECONDS=${FLUTTER_RUN_SECONDS:-12}

HELPER_KO="$PAYLOAD_ROOT/modules/x7_gpu_dt_enable.ko"
KBASE_KO="$PAYLOAD_ROOT/modules/bifrost_kbase.ko"
MALI_LIB="$PAYLOAD_ROOT/mali"
RUNTIME_LIB="$PAYLOAD_ROOT/lib"
GPU_PROBE="$PAYLOAD_ROOT/bin/wpe-gpu-probe"
GPU_SHIM="$MALI_LIB/libwpe-mali-gbm-compat.so"

mkdir -p "$RUN_DIR" "$CURRENT_DIR"
LOG_FILE="$RUN_DIR/run.log"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo time-unknown)" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

module_loaded() {
    grep -q "^$1 " /proc/modules 2>/dev/null
}

gpu_dt_status() {
    tr -d '\000\r\n' </sys/firmware/devicetree/base/gpu@ff320000/status 2>/dev/null || true
}

capture_state() {
    label=$1
    out="$RUN_DIR/$label"
    mkdir -p "$out"
    uname -a >"$out/uname.txt" 2>&1 || true
    cat /proc/sys/kernel/random/boot_id >"$out/boot-id.txt" 2>&1 || true
    cat /proc/sys/kernel/tainted >"$out/kernel-taint.txt" 2>&1 || true
    cat /proc/modules >"$out/modules.txt" 2>&1 || true
    dmesg >"$out/dmesg.txt" 2>&1 || true
    printf '%s\n' "$(gpu_dt_status)" >"$out/gpu-dt-status.txt"
    ls -l /dev/mali0 /dev/dri >"$out/device-nodes.txt" 2>&1 || true
    for dev in /sys/bus/platform/devices/ff320000.gpu /sys/class/drm/card0 /sys/class/drm/card1 /sys/class/drm/renderD128 /sys/class/drm/renderD129; do
        if [ -e "$dev" ]; then
            printf '%s\n' "$dev"
            readlink -f "$dev/device/driver" 2>/dev/null || readlink -f "$dev/driver" 2>/dev/null || true
        fi
    done >"$out/drivers.txt" 2>&1
    sync
}

expected_hash() {
    case "$1" in
        modules/x7_gpu_dt_enable.ko) echo 07c6e10025fa7e6e14b61a1d259c04d4b18236db485def4d6280da946934a938 ;;
        modules/bifrost_kbase.ko) echo a06aeccd04f13038b4473c30dfb3073e4126354a03945a99509954cbe7e5607f ;;
        mali/libEGL.so.1) echo 67a28c4f732e247e865da7406e6dda043f591c16500be85a7d42db43b73a9808 ;;
        mali/libGLESv2.so.2) echo 67ff688cc4f941a32d9067400fde9b4e520d66e921b657adefe7d8304a02b474 ;;
        mali/libgbm.so.1) echo 3a6500953e33741f0d0b80ebf57daac95f546ba909950201bd6a84802786d2c4 ;;
        mali/libmali.so.1) echo 17bc5343e7281d8641deadd0519fa7726b1788f221b029dc2c2a41c6b42dd4a6 ;;
        mali/libmali_hook.so.1) echo 12f1008f72c50153702e32bc8ef8fa92c819c225254647f37689f09090d1b3c8 ;;
        mali/libwpe-mali-gbm-compat.so) echo 8eca44b1d3c3cbb03d285ab3c5cbcbf86e6ce657a76a6e9fd316ca3d5089f0d4 ;;
        bin/wpe-gpu-probe) echo 3144915c788670df57e87f6e9c53a3abb0edfd869dad90c683da3019a85295de ;;
        lib/libdrm.so.2) echo 791476ba406d4f87eb4650ab4527f7deddb8d4244a461ef9507b4dbb10c02503 ;;
        *) return 1 ;;
    esac
}

verify_payload() {
    for rel in \
        modules/x7_gpu_dt_enable.ko \
        modules/bifrost_kbase.ko \
        mali/libEGL.so.1 \
        mali/libGLESv2.so.2 \
        mali/libgbm.so.1 \
        mali/libmali.so.1 \
        mali/libmali_hook.so.1 \
        mali/libwpe-mali-gbm-compat.so \
        bin/wpe-gpu-probe \
        lib/libdrm.so.2
    do
        file="$PAYLOAD_ROOT/$rel"
        [ -f "$file" ] || die "missing payload file: $rel"
        expected=$(expected_hash "$rel")
        actual=$(sha256sum "$file" | awk '{print $1}')
        [ "$actual" = "$expected" ] || die "SHA-256 mismatch: $rel"
        printf '%s  %s\n' "$actual" "$rel" >>"$RUN_DIR/payload.sha256"
    done
}

check_required_symbols() {
    missing=0
    for symbol in \
        dev_pm_opp_set_supported_hw \
        rockchip_get_opp_data \
        rockchip_get_read_margin \
        rockchip_init_opp_table \
        rockchip_monitor_check_rate_volt \
        rockchip_monitor_dev_high_temp_adjust \
        rockchip_monitor_dev_low_temp_adjust \
        rockchip_monitor_volt_adjust_lock \
        rockchip_monitor_volt_adjust_unlock \
        rockchip_nvmem_cell_read_u8 \
        rockchip_set_intermediate_rate \
        rockchip_set_read_margin \
        rockchip_system_monitor_register
    do
        if ! awk -v name="$symbol" '$3 == name && $1 !~ /^0+$/ { found=1; exit } END { exit !found }' /proc/kallsyms; then
            log "missing kernel symbol: $symbol"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "required Rockchip kernel symbols are missing"
}

check_new_kernel_faults() {
    start_line=$1
    new_log="$RUN_DIR/dmesg-new.txt"
    sed -n "${start_line},\$p" "$RUN_DIR/dmesg-after.txt" >"$new_log" 2>/dev/null || true
    if grep -Ei 'Kernel panic|Oops:|BUG:|Unable to handle kernel|SError|Call trace:' "$new_log" >/dev/null 2>&1; then
        log "ERROR: new kernel fault signature detected; no further load action will run"
        return 1
    fi
    return 0
}

preflight() {
    : >"$RUN_DIR/payload.sha256"
    [ "$(id -u 2>/dev/null)" = 0 ] || die "root is required"
    [ "$(uname -m 2>/dev/null)" = aarch64 ] || die "target must be aarch64"
    [ "$(uname -r 2>/dev/null)" = 5.10.160 ] || die "target kernel must be exactly 5.10.160"
    [ "$(cat /proc/sys/kernel/modules_disabled 2>/dev/null)" = 0 ] || die "kernel module loading is disabled"

    for cmd in awk grep sed tr sha256sum insmod rmmod dmesg sync; do
        command_exists "$cmd" || die "required command missing: $cmd"
    done

    [ -e /sys/firmware/devicetree/base/gpu@ff320000/status ] || die "RK3562 GPU DT status property is missing"
    [ -c "$DRM_DEVICE" ] || die "DRM device is missing: $DRM_DEVICE"
    verify_payload
    grep -a -q 'vermagic=5.10.160.*aarch64' "$HELPER_KO" || die "helper vermagic mismatch"
    grep -a -q 'vermagic=5.10.160.*aarch64' "$KBASE_KO" || die "kbase vermagic mismatch"
    check_required_symbols

    addr=$(awk '$3 == "of_update_property" && $2 ~ /^[Tt]$/ && $1 !~ /^0+$/ { print "0x" $1; exit }' /proc/kallsyms)
    [ -n "$addr" ] || die "live of_update_property address is unavailable"
    printf '%s\n' "$addr" >"$RUN_DIR/of-update-property.addr"

    if module_loaded bifrost_kbase && [ ! -c /dev/mali0 ]; then
        die "bifrost_kbase is already loaded but /dev/mali0 is absent"
    fi

    capture_state preflight
    log "PREFLIGHT_OK kernel=$(uname -r) arch=$(uname -m) gpu_status=$(gpu_dt_status) drm=$DRM_DEVICE of_update_property=$addr"
}

cleanup_owned_modules() {
    if [ -f "$CURRENT_DIR/owned-kbase" ] && module_loaded bifrost_kbase; then
        if rmmod bifrost_kbase >>"$LOG_FILE" 2>&1; then
            rm -f "$CURRENT_DIR/owned-kbase"
            log "unloaded script-owned bifrost_kbase"
        else
            log "WARNING: bifrost_kbase is busy; helper will remain loaded"
            return 1
        fi
    fi
    if [ -f "$CURRENT_DIR/owned-helper" ] && module_loaded x7_gpu_dt_enable; then
        if rmmod x7_gpu_dt_enable >>"$LOG_FILE" 2>&1; then
            rm -f "$CURRENT_DIR/owned-helper"
            log "unloaded script-owned x7_gpu_dt_enable"
        else
            log "WARNING: x7_gpu_dt_enable could not be unloaded"
            return 1
        fi
    fi
    rm -f "$CURRENT_DIR/gpu-ready" "$CURRENT_DIR/probe-ok"
    return 0
}

enable_gpu() {
    preflight
    dmesg >"$RUN_DIR/dmesg-before.txt"
    before_lines=$(wc -l <"$RUN_DIR/dmesg-before.txt")
    new_start=$((before_lines + 1))

    if ! module_loaded x7_gpu_dt_enable; then
        addr=$(cat "$RUN_DIR/of-update-property.addr")
        log "loading x7_gpu_dt_enable with live symbol address"
        if ! insmod "$HELPER_KO" of_update_property_addr="$addr" >>"$LOG_FILE" 2>&1; then
            dmesg >"$RUN_DIR/dmesg-after.txt"
            capture_state helper-insmod-failed
            die "x7_gpu_dt_enable insmod failed"
        fi
        : >"$CURRENT_DIR/owned-helper"
    else
        log "x7_gpu_dt_enable already loaded; not taking ownership"
    fi

    dmesg >"$RUN_DIR/dmesg-after.txt"
    check_new_kernel_faults "$new_start" || exit 70
    status=$(gpu_dt_status)
    [ "$status" = okay ] || [ "$status" = ok ] || {
        capture_state helper-no-device
        cleanup_owned_modules || true
        die "GPU DT status did not become okay: $status"
    }
    [ -e /sys/bus/platform/devices/ff320000.gpu ] || {
        capture_state helper-no-platform-device
        cleanup_owned_modules || true
        die "ff320000.gpu platform device was not created"
    }
    capture_state helper-loaded
    log "HELPER_OK gpu_status=$status platform_device=ff320000.gpu"

    if [ "${GPU_HELPER_ONLY:-0}" = 1 ]; then
        log "HELPER_ONLY_STOP requested; kbase was not loaded"
        return 0
    fi

    if ! module_loaded bifrost_kbase; then
        log "loading matching g17p0 bifrost_kbase"
        if ! insmod "$KBASE_KO" >>"$LOG_FILE" 2>&1; then
            dmesg >"$RUN_DIR/dmesg-after.txt"
            capture_state kbase-insmod-failed
            cleanup_owned_modules || true
            die "bifrost_kbase insmod failed"
        fi
        : >"$CURRENT_DIR/owned-kbase"
    else
        log "bifrost_kbase already loaded; not taking ownership"
    fi

    wait_count=0
    while [ "$wait_count" -lt 5 ] && [ ! -c /dev/mali0 ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done
    dmesg >"$RUN_DIR/dmesg-after.txt"
    check_new_kernel_faults "$new_start" || exit 71
    [ -c /dev/mali0 ] || {
        capture_state kbase-no-mali0
        cleanup_owned_modules || true
        die "/dev/mali0 was not created"
    }
    [ -e /sys/bus/platform/devices/ff320000.gpu/driver ] || {
        capture_state kbase-not-bound
        cleanup_owned_modules || true
        die "kbase did not bind ff320000.gpu"
    }

    capture_state gpu-enabled
    : >"$CURRENT_DIR/gpu-ready"
    log "GPU_ENABLED_OK mali=/dev/mali0 wait=${wait_count}s driver=$(readlink -f /sys/bus/platform/devices/ff320000.gpu/driver 2>/dev/null || echo unknown)"
}

probe_gpu() {
    [ -f "$CURRENT_DIR/gpu-ready" ] || die "run enable successfully before probe"
    [ -c /dev/mali0 ] || die "/dev/mali0 is absent"
    [ -c "$DRM_DEVICE" ] || die "DRM device is absent: $DRM_DEVICE"
    chmod 700 "$GPU_PROBE"
    capture_state probe-before
    dmesg >"$RUN_DIR/dmesg-before-probe.txt"
    before_lines=$(wc -l <"$RUN_DIR/dmesg-before-probe.txt")
    new_start=$((before_lines + 1))
    log "running WPE Mali EGL/GLES/GBM/DRM probe on $DRM_DEVICE"
    set +e
    LD_LIBRARY_PATH="$MALI_LIB:$RUNTIME_LIB" \
    LD_PRELOAD="$GPU_SHIM" \
    "$GPU_PROBE" "$DRM_DEVICE" >"$RUN_DIR/gpu-probe.stdout" 2>"$RUN_DIR/gpu-probe.stderr"
    status=$?
    set -e
    dmesg >"$RUN_DIR/dmesg-after-probe.txt"
    sed -n "${new_start},\$p" "$RUN_DIR/dmesg-after-probe.txt" >"$RUN_DIR/dmesg-probe-new.txt" 2>/dev/null || true
    if grep -Ei 'Kernel panic|Oops:|BUG:|Unable to handle kernel|SError|Call trace:' "$RUN_DIR/dmesg-probe-new.txt" >/dev/null 2>&1; then
        capture_state probe-kernel-fault
        die "kernel fault signature is present after GPU probe"
    fi
    if [ "$status" -ne 0 ]; then
        capture_state probe-failed
        log "GPU_PROBE_FAILED status=$status"
        return "$status"
    fi
    : >"$CURRENT_DIR/probe-ok"
    capture_state probe-ok
    log "GPU_PROBE_OK status=0"
    cat "$RUN_DIR/gpu-probe.stdout"
    cat "$RUN_DIR/gpu-probe.stderr" >&2
}

flutter_audit() {
    out="$RUN_DIR/flutter-audit.txt"
    if command_exists ldd; then
        libc_version=$(ldd --version 2>&1 | sed -n '1p')
    elif [ -x /lib/libc.so.6 ]; then
        libc_version=$(/lib/libc.so.6 2>&1 | sed -n '1p')
    else
        libc_version=unknown
    fi
    {
        echo "kernel=$(uname -r)"
        echo "arch=$(uname -m)"
        echo "libc=$libc_version"
        echo "gpu_status=$(gpu_dt_status)"
        echo "mali0=$([ -c /dev/mali0 ] && echo present || echo missing)"
        echo "gpu_probe=$([ -f "$CURRENT_DIR/probe-ok" ] && echo passed || echo not-passed)"
        echo "loader=$([ -e /lib/ld-linux-aarch64.so.1 ] && echo present || echo missing)"
        echo "drm_device=$DRM_DEVICE"
        echo "drm_driver=$(readlink -f /sys/class/drm/card0/device/driver 2>/dev/null || echo unknown)"
        echo "flutter_embedder=$([ -x "$FLUTTER_RUNTIME_ROOT/bin/rk3562-flutter-smoke" ] && echo "$FLUTTER_RUNTIME_ROOT/bin/rk3562-flutter-smoke" || command -v flutter-pi 2>/dev/null || command -v flutter-client 2>/dev/null || echo missing)"
        echo "flutter_engine=$([ -f "$FLUTTER_RUNTIME_ROOT/lib/libflutter_engine.so" ] && echo "$FLUTTER_RUNTIME_ROOT/lib/libflutter_engine.so" || echo missing)"
        echo "flutter_first_frame=$([ -f "$CURRENT_DIR/flutter-ok" ] && echo passed || echo not-passed)"
        echo "icudtl=$(find "$FLUTTER_RUNTIME_ROOT" /tmp /userdisk /userdata -maxdepth 5 -name icudtl.dat 2>/dev/null | sed -n '1p')"
        echo "fontconfig=$(find "$FLUTTER_RUNTIME_ROOT/lib" /lib /usr/lib "$RUNTIME_LIB" -maxdepth 2 -name 'libfontconfig.so*' 2>/dev/null | sed -n '1p')"
        echo "libinput=$(find "$FLUTTER_RUNTIME_ROOT/lib" /lib /usr/lib "$RUNTIME_LIB" -maxdepth 2 -name 'libinput.so*' 2>/dev/null | sed -n '1p')"
        echo "libudev=$(find /lib /usr/lib "$RUNTIME_LIB" -maxdepth 2 -name 'libudev.so*' 2>/dev/null | sed -n '1p')"
        echo "libxkbcommon=$(find "$FLUTTER_RUNTIME_ROOT/lib" /lib /usr/lib "$RUNTIME_LIB" -maxdepth 2 -name 'libxkbcommon.so*' 2>/dev/null | sed -n '1p')"
        echo "input_nodes=$(find /dev/input -maxdepth 1 -name 'event*' 2>/dev/null | wc -l)"
        echo "fonts=$(find "$FLUTTER_RUNTIME_ROOT" /usr/share/fonts /userdisk -maxdepth 5 -type f \( -name '*.ttf' -o -name '*.otf' \) 2>/dev/null | wc -l)"
        echo "drm_nodes:"
        ls -l /dev/dri 2>/dev/null || true
        echo "drm_connectors:"
        for connector in /sys/class/drm/card*-*; do
            [ -e "$connector" ] || continue
            printf '%s status=' "$(basename "$connector")"
            cat "$connector/status" 2>/dev/null || echo unknown
            sed -n '1,8p' "$connector/modes" 2>/dev/null || true
        done
        echo "display_processes:"
        ps 2>/dev/null | grep -Ei 'falcon|miniapp|weston|wayland|sway|Xorg|compositor' | grep -v grep || true
    } >"$out"
    cat "$out"
    log "FLUTTER_AUDIT_COMPLETE output=$out"
}

expected_flutter_hash() {
    case "$1" in
        bin/rk3562-flutter-smoke) echo 221b585401b3c60d312ce9df36a0edf7a2ce10dff8fa23a88104348124a616d4 ;;
        lib/libflutter_engine.so) echo e3d2818cbf76f7b66f8f76cec95018560f62836d3d468e88cf252076fed8267a ;;
        lib/libflutter_elinux_gbm.so) echo 2707694beef859f68cc684b07d84a75ec6d7e134d99c9185a6731f0f25790221 ;;
        lib/libmali_egl_getdisplay_compat.so) echo e88403a3ad27133dc697e9b8061f3afbcff85ab840cdc2524ef3099692a4c9a7 ;;
        data/icudtl.dat) echo 9ae98c06cbb0ea43c5cd6b5725310c008c65e46072421a1118cb88e1de9a8b92 ;;
        *) return 1 ;;
    esac
}

verify_flutter_runtime() {
    runtime=$1
    : >"$RUN_DIR/flutter-runtime.sha256"
    for rel in \
        bin/rk3562-flutter-smoke \
        lib/libflutter_engine.so \
        lib/libflutter_elinux_gbm.so \
        lib/libmali_egl_getdisplay_compat.so \
        data/icudtl.dat
    do
        file="$runtime/$rel"
        [ -f "$file" ] || die "missing Flutter runtime file: $rel"
        expected=$(expected_flutter_hash "$rel")
        actual=$(sha256sum "$file" | awk '{print $1}')
        [ "$actual" = "$expected" ] || die "Flutter runtime SHA-256 mismatch: $rel"
        printf '%s  %s\n' "$actual" "$rel" >>"$RUN_DIR/flutter-runtime.sha256"
    done
}

run_flutter() {
    runtime=$FLUTTER_RUNTIME_ROOT
    bundle=${1:-$runtime}
    [ -f "$CURRENT_DIR/probe-ok" ] || die "GPU probe must pass before Flutter"
    [ -c /dev/mali0 ] || die "/dev/mali0 is absent"
    [ -c "$DRM_DEVICE" ] || die "DRM device is absent: $DRM_DEVICE"
    [ -d "$runtime" ] || die "Flutter runtime directory is missing: $runtime"
    [ -d "$bundle" ] || die "Flutter bundle directory is missing: $bundle"
    [ -f "$bundle/data/flutter_assets/kernel_blob.bin" ] || die "Flutter kernel blob is missing from bundle"
    [ -d "$runtime/share/X11/xkb" ] || die "XKB data is missing"
    [ -d "$runtime/share/libinput" ] || die "libinput quirks are missing"
    [ -f "$runtime/etc/fonts/fonts.conf" ] || die "fontconfig configuration is missing"
    command_exists timeout || die "required command missing: timeout"
    verify_flutter_runtime "$runtime"
    chmod 700 "$runtime/bin/rk3562-flutter-smoke"

    dmesg >"$RUN_DIR/dmesg-before-flutter.txt"
    before_lines=$(wc -l <"$RUN_DIR/dmesg-before-flutter.txt")
    new_start=$((before_lines + 1))
    log "running audited Flutter 3.27.1 DRM/GBM smoke app for ${FLUTTER_RUN_SECONDS}s"
    set +e
    timeout -s TERM "$FLUTTER_RUN_SECONDS" env \
        FLUTTER_DRM_DEVICE="$DRM_DEVICE" \
        LD_LIBRARY_PATH="$MALI_LIB:$runtime/lib" \
        LD_PRELOAD="$runtime/lib/libmali_egl_getdisplay_compat.so" \
        FONTCONFIG_FILE="$runtime/etc/fonts/fonts.conf" \
        FONTCONFIG_PATH="$runtime/etc/fonts" \
        XKB_CONFIG_ROOT="$runtime/share/X11/xkb" \
        LIBINPUT_QUIRKS_DIR="$runtime/share/libinput" \
        "$runtime/bin/rk3562-flutter-smoke" --bundle="$bundle" -n -v \
        >"$RUN_DIR/flutter.stdout" 2>"$RUN_DIR/flutter.stderr"
    status=$?
    set -e
    dmesg >"$RUN_DIR/dmesg-after-flutter.txt"
    sed -n "${new_start},\$p" "$RUN_DIR/dmesg-after-flutter.txt" >"$RUN_DIR/dmesg-flutter-new.txt" 2>/dev/null || true

    cat "$RUN_DIR/flutter.stdout"
    cat "$RUN_DIR/flutter.stderr" >&2
    if grep -Ei 'Kernel panic|Oops:|BUG:|Unable to handle kernel|SError|Call trace:' "$RUN_DIR/dmesg-flutter-new.txt" >/dev/null 2>&1; then
        capture_state flutter-kernel-fault
        die "kernel fault signature is present after Flutter run"
    fi
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ] || {
        capture_state flutter-process-failed
        die "Flutter process failed with status $status"
    }
    grep -q 'RK3562_FLUTTER_APP_STARTED' "$RUN_DIR/flutter.stdout" || die "Dart application did not start"
    grep -q 'RK3562_FLUTTER_FIRST_FRAME' "$RUN_DIR/flutter.stdout" || die "Flutter first frame was not rendered"
    : >"$CURRENT_DIR/flutter-ok"
    capture_state flutter-ok
    log "FLUTTER_FIRST_FRAME_OK drm=$DRM_DEVICE timeout_status=$status"
}

cleanup() {
    capture_state cleanup-before
    cleanup_owned_modules || die "cleanup incomplete; see log"
    capture_state cleanup-after
    log "CLEANUP_OK gpu_status=$(gpu_dt_status)"
}

collect() {
    capture_state collected
    if [ -d /sys/fs/pstore ]; then
        mkdir -p "$RUN_DIR/pstore"
        for file in /sys/fs/pstore/*; do
            [ -f "$file" ] || continue
            cp "$file" "$RUN_DIR/pstore/"
        done
    fi
    log "COLLECT_OK evidence=$RUN_DIR"
}

usage() {
    cat <<EOF
Usage: $0 {preflight|enable|probe|flutter-audit|run-flutter [bundle]|cleanup|collect}

Environment:
  GPU_PAYLOAD_ROOT  staged payload root (default: $PAYLOAD_ROOT)
  GPU_STATE_ROOT    evidence/state root (default: $STATE_ROOT)
  GPU_RUN_ID        evidence run id (default: timestamp)
  DRM_DEVICE        DRM card passed to probe (default: $DRM_DEVICE)
  GPU_HELPER_ONLY   set to 1 to stop enable after the DT helper stage
  FLUTTER_RUNTIME_ROOT  staged Flutter runtime (default: $FLUTTER_RUNTIME_ROOT)
  FLUTTER_RUN_SECONDS   smoke-test duration (default: $FLUTTER_RUN_SECONDS)
EOF
}

action=${1:-}
case "$action" in
    preflight) preflight ;;
    enable) enable_gpu ;;
    probe) probe_gpu ;;
    flutter-audit) flutter_audit ;;
    run-flutter) shift; run_flutter "${1:-}" ;;
    cleanup) cleanup ;;
    collect) collect ;;
    *) usage; exit 2 ;;
esac
