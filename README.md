# RK3562 GPU and Flutter bring-up

Fail-closed tooling for temporary Mali GPU enablement and Flutter DRM/KMS
validation on a specific RK3562 Buildroot target running AArch64 Linux
5.10.160.

The validated experiment enabled the live `gpu@ff320000` node, loaded a
matching g17p0 `bifrost_kbase` driver, created `/dev/mali0`, exercised
EGL/OpenGL ES/GBM/DMA-BUF, and rendered a Flutter first frame through direct
DRM/KMS. It did not modify the DTB, boot partition, root filesystem, or system
services, and it left the device mini-app process running.

> [!WARNING]
> Kernel-module insertion and direct DRM/KMS ownership can crash, blank, or
> reboot a device. Do not run the mutating stages on a different device or
> firmware. Start with the read-only preflight, audit every payload, and have a
> tested recovery path.

## Published files

- `flutter_gpu_preflight.sh` performs a read-only ADB check of the device tree,
  GPU driver, DRM nodes, and userspace libraries.
- `enable_gpu.sh` is the original read-only state collector. Despite its legacy
  name, it does not enable the GPU.
- `restore_gpu.sh` verifies the state recorded by `enable_gpu.sh`; because that
  collector makes no remote changes, restoration is normally a no-op.
- `rk3562_gpu_flutter.sh` orchestrates guarded target-side preflight, temporary
  module loading, GPU probing, Flutter auditing/running, evidence collection,
  and cleanup.
- `mali_egl_getdisplay_compat.c` is the source for the small EGL display
  compatibility shim used during the experiment.

Proprietary kernel modules, Mali userspace libraries, Flutter engine artifacts,
device backups, device identifiers, logs, and third-party source trees are not
included. The main script intentionally pins the SHA-256 hashes of the exact
payloads used in the validated experiment; users must independently obtain and
audit compatible assets.

## Read-only preflight

On a host with Bash and ADB available:

```sh
ADB_SERIAL=<device-serial> ./flutter_gpu_preflight.sh
```

The command exits with status `2` when a required GPU boundary is not ready and
makes no device changes.

## Guarded target workflow

`rk3562_gpu_flutter.sh` is a POSIX shell script intended to run on the target.
Its default payload layout is:

```text
payload/
  bin/wpe-gpu-probe
  lib/libdrm.so.2
  mali/libEGL.so.1
  mali/libGLESv2.so.2
  mali/libgbm.so.1
  mali/libmali.so.1
  mali/libmali_hook.so.1
  mali/libwpe-mali-gbm-compat.so
  modules/x7_gpu_dt_enable.ko
  modules/bifrost_kbase.ko
```

Review the script and pinned hashes first, then run each stage explicitly:

```sh
./rk3562_gpu_flutter.sh preflight
./rk3562_gpu_flutter.sh enable
./rk3562_gpu_flutter.sh probe
./rk3562_gpu_flutter.sh flutter-audit
./rk3562_gpu_flutter.sh run-flutter <bundle>
./rk3562_gpu_flutter.sh collect
./rk3562_gpu_flutter.sh cleanup
```

The preflight requires root only because subsequent module operations do; it
checks the exact kernel release and architecture, module loading policy,
payload hashes and vermagic, Rockchip kernel symbols, live device-tree state,
and the DRM node. A failed gate stops the workflow.

Cleanup unloads only modules whose ownership marker was created by the current
script. It never uses forced module removal. Do not run cleanup while any GPU
client is active.

## Validated scope

The proof used one device and one firmware image. It is evidence for that exact
combination, not general RK3562 compatibility. The Flutter bundle was a bounded
debug/JIT smoke test; production still requires a vendor-approved boot design,
signed matching drivers, a release/AOT Flutter application, display-lifecycle
coordination, and real validation of touch, keys, rotation, suspend/resume,
thermal load, memory pressure, and repeated launch/exit.

No license is granted by this repository unless a license file is added later.
