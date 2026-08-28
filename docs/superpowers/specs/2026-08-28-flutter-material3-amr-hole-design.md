# Flutter Material 3 Demo AMR 与 `<hole>` 集成设计

日期：2026-08-28

## 目标

把 Flutter 官方 `flutter/samples` 仓库中的 `material_3_demo` 制作为可安装到当前
有道词典笔的 Falcon AMR 应用。Falcon 页面保留 DRM master，通过全屏 `<hole>` 露出
下方 overlay plane；Flutter engine、Demo bundle 和 RK3562 runner 作为 AMR 内的独立
native runtime 运行。

交付物包括 AMR、完整源码、可复现构建脚本、Windows PowerShell 安装脚本、设备端运行/
清理脚本、SHA-256 清单和真机验证证据。

## 固定目标 Profile

本轮只认证当前设备，不推导到其他词典笔：

```yaml
profile_id: youdao-rk3562-orange-v10-2025-11-13
adb_serial: MEB0400008906748
os: Buildroot 2021.11
kernel: 5.10.160
abi: aarch64
falcon:
  logical: 960x266
  direction: 270
  xoffset: 0
  yoffset: 107
touch:
  name: hyn_ts
  configured_path: /dev/input/by-path/hyn_ts
  direction: 270
  xoffset: 113
  yoffset: 0
drm:
  card: /dev/dri/card0
  connector: DSI-1
  crtc_id: 68
  falcon_plane_id: 54
  flutter_plane_id: 75
  flutter_plane_format: AR24
  flutter_plane_rect: [107, 0, 266, 960]
```

实时证据显示 `miniapp` 是 DRM master，plane 54 承载 Falcon，zpos 为 3；plane 75
空闲，支持线性 XR24/AR24、zpos 为 2。所有 id、format、zpos 和矩形在每次运行前重新
校验；不匹配时停止，不把该 profile 静默套到其他设备或固件。

## 项目与包身份

新项目独立于 WPE 浏览器，工作目录为：

```text
D:\CodexWork\flutter-rk3562\material3-amr
```

默认开发包身份：

```text
appid: 8001779591038450
version: 0.1.0
start_page: index
artifact: 8001779591038450.0_1_0.amr
```

构建前检查目标设备和本机工作区没有同 appid 的非本项目应用；若存在冲突则 fail closed，
不覆盖未知应用。版本由 `package.json` 唯一提供，产物名、manifest、安装脚本和运行日志
都从该版本派生。

## 来源与代码边界

### Falcon/DRM 基线

以本机已验证的 `WPE4YDPv2` 为参考基线，复用其以下模式而不是复用浏览器业务：

- `index` 启动页与 `frame` 生命周期页。
- `frame` 页全屏 `<hole>`。
- native JSAPI 的独立进程 start/stop/getStatus/exit 语义。
- 包内 runtime、manifest 校验、AMR 同步和打包检查。
- 同机型 GPU helper、g17p0 kbase、Mali EGL/GLES/GBM 和 probe 的 fail-closed 链路。

WPE/WebKit、浏览器 profile、cookie、网络服务、键盘桥和视频解码业务不进入新 AMR。

### Flutter Demo

从 `https://github.com/flutter/samples.git` 获取官方源码，固定到满足 Flutter 3.27.1 /
Dart 3.6 的官方历史提交，并记录 commit、许可证和源码清单。当前 `main` 使用 Dart 3.9
workspace 配置，因此不直接使用。

官方 Demo 的运行时代码保持不变。只允许在独立构建副本中：

- 移除仓库级 workspace 和仅用于分析的 path dev dependency。
- 锁定与 Dart 3.6 兼容的依赖版本。
- 对目标 runner 没有实现的 `url_launcher` 外链能力显示明确“不支持”，不得伪造成功。

Flutter framework 固定提交为 `17025dd88227cd9532c33fa78f5250d548d87e9a`，engine
固定提交为 `cb4b5fff73850b2e42bd4de7cb9a4310a78ac40d`。bundle、engine 和 runner
不允许跨版本混用。

## AMR 结构

```text
material3-amr/
  package.json
  icon.png
  src/
    app.js
    app.json
    base-page.js
    pages/index/             # 启动、状态和错误摘要
    pages/frame/             # 全屏 hole 与生命周期
    utils/flutter-lifecycle.js
    profiles/rk3562-orange-v10.js
  jsapi/
    src/jsapi_flutterdemo/   # 受限进程管理 JSAPI
    tests/
  libs/arm64-orange/
    libjsapi_flutterdemo.so
  assets/flutter-runtime/
    bin/flutter-material3-runner
    bundle/                  # Flutter assets 与 kernel/AOT 产物
    lib/                     # 精确闭合的 engine/Mali/DRM 依赖
    gpu/                     # 已审计 helper 与 kbase
    scripts/run.sh
    scripts/gpu-runtime.sh
    manifest.sha256
  profiles/
    youdao-rk3562-orange-v10-2025-11-13.yaml
  scripts/
    build-flutter-demo.sh
    build-runner.sh
    sync-generated.sh
    verify-amr-runtime.sh
    install-flutter-demo.ps1
  tests/
```

Flutter runtime 作为普通资源目录打入 AMR。native JSAPI 只负责受限地启动、停止、查询和
回收 runner；Flutter engine 不链接进 `miniapp` 或 JSAPI `.so`。

## Falcon 页面与生命周期

### `index` 页面

显示应用名称、版本、profile、最近一次状态和“启动 Flutter Demo”按钮。显式按钮进入
`frame`，不在 AMR 冷启动时自动抢占 plane，便于故障恢复和重复测试。

### `frame` 页面

只渲染一个全屏 `<hole>` 和必要的透明状态层。页面 mounted 后创建一代运行会话并调用
JSAPI `start(config)`。新的 start 先幂等停止旧实例，过期 generation 的回调不能更新
页面。

生命周期规则固定为：

- `onShow`：当前无实例时启动；已有健康实例时只恢复监测。
- `onHide`：立即请求正常停止，避免 Flutter 在不可见时继续占用 plane/GPU。
- `onUnload`：停止 watchdog，停止 runner，等待回收并清除订阅。
- Home/Back：走与 `onHide/onUnload` 相同的停止路径。
- runner 意外退出：有限退避一次；再次失败返回 `index` 并显示稳定错误码。

JSAPI 提供 `start(config)`、幂等 `stop()`、`getStatus()` 以及 `state/exit/error` 事件。
进程参数使用 argv 数组，不通过拼接 shell 接收页面输入。

## Flutter overlay runner

沿用已经进入 Dart `main()` 并完成 Mali 首帧的 Sony embedded Linux runner，但把 DRM
输出模式改成“overlay-only”：

1. 打开 card0，读取现有 connector/CRTC/plane 状态，但不取得 DRM master。
2. 校验 CRTC 68 已由 Falcon 驱动、plane 75 空闲且支持目标格式。
3. 创建 Mali GBM/EGL surface 和 scanout framebuffer。
4. 使用 runner 已有的 `--rotation 270` surface transformation 与 pointer rotation，
   将 Flutter 逻辑 view 设为 960×266，并输出到物理 266×960 buffer。
5. 仅对 plane 75 执行 atomic plane commit；必要时使用已在相同设备验证的非-modeset
   legacy plane 路径。禁止调用 `drmModeSetCrtc`，禁止修改 connector mode。
6. 将 plane 75 的 zpos 保持在 Falcon plane 54 之下；Falcon `<hole>` 之外不得露出
   Flutter framebuffer。
7. swap/retire 时延迟释放仍被 plane 引用的 framebuffer；退出时先清空 plane，再销毁
   FB、GBM、EGL 和 engine。

复用的是 WPE 已验证的非-master overlay 提交边界，而不是复制其 WebKit 渲染代码。
plane 选择、坐标变换、framebuffer 生命周期和停止顺序都需有纯逻辑/模拟 DRM 测试。

## 触摸输入

`<hole>` 不负责转发输入。Flutter runner 以只读、非阻塞方式读取目标 profile 的触摸
设备，不使用 `EVIOCGRAB`，不停止 `miniapp`，也不向其进程注入插件。

启动时先按 `/proc/bus/input/devices` 的名称解析 `hyn_ts` 对应 event 节点，再用
`EVIOCGABS` 读取实时轴范围。处理 tracking id、down/move/up/cancel 和 `SYN_REPORT`，
通过 `FlutterEngineSendPointerEvent` 发送单调时间戳事件。

坐标转换显式分为：raw evdev → Falcon logical 960×266 → Flutter logical 960×266。
测试覆盖四角、中心、边界、越界、轴交换、270° 方向、offset 和中途取消。输入 fd 短读或
设备消失时关闭输入通道并上报错误，不让输入线程访问已销毁的 engine。

## GPU 启用与安全边界

设备重启后 GPU DT 节点恢复为 `disabled`。AMR runtime 沿用已验证的临时 helper →
g17p0 kbase 路径，但每次先执行：设备序列/compatible、AArch64、内核 5.10.160、模块
SHA-256、vermagic、live `of_update_property`、DRM、已有模块所有权和 dmesg 基线检查。

helper 后必须确认 GPU platform device 且无新增 Oops/BUG/panic/SError，才加载 kbase。
只有 `/dev/mali0`、Mali-G52 renderer 和 EGL/GLES/GBM/DMA-BUF/DRM probe 全部成功，才
启动 Flutter。

发生内核故障签名、ADB 断连或设备重启时不自动重试加载。停止时只卸载由本次 runtime
创建所有权标记且不再被使用的模块；不使用强制卸载，不修改 DTB、boot、rootfs、系统库
或开机服务。

## 构建流程

1. 固定官方 Demo commit、Flutter/engine commit 和依赖锁。
2. 在 WSL/Linux 中构建 Flutter bundle；不使用缺少 Windows Dart cache 的本地
   `flutter.bat`。
3. 构建 AArch64 overlay runner 和 native JSAPI。
4. 对所有 ELF 执行 machine、interpreter、`DT_NEEDED` 和导出符号检查。
5. 将生成物同步到 `assets/flutter-runtime` 和 `libs/arm64-orange`。
6. 生成 runtime SHA-256 清单并验证不存在旧 WPE/旧 Flutter 残留。
7. 运行 JS、坐标、进程、DRM、shell 和 manifest 测试，再执行 `aiot-cli check`。
8. 使用项目固定 Node/`aiot-cli` 生成 production QuickJS AMR。
9. 解包检查 manifest、页面、JSAPI、runner、engine、bundle、GPU payload、许可证和哈希。

首轮允许 debug/JIT bundle 用于交互 bring-up；同时尝试 release/AOT。只有 release/AOT
通过后才把结果称为可发布构建，debug/JIT 结果只称为测试包。

## Windows 安装脚本

提供 `scripts/install-flutter-demo.ps1`。Flutter engine、Demo 和 runner 已封装在 AMR，
脚本不向设备系统目录“安装 Flutter”。

默认命令：

```powershell
.\scripts\install-flutter-demo.ps1 -AmrPath .\8001779591038450.0_1_0.amr -Serial MEB0400008906748
```

脚本支持：

- `-Install`：默认；校验设备、AMR 文件名、SHA-256、appid、version 后推送并安装。
- `-StartOnly`：不安装，只用显式 `--index` 入口启动已验证版本。
- `-Uninstall`：只卸载精确 appid；执行前再次显示目标，不清理其他应用数据。
- `-KeepRemoteAmr`：调试时保留 `/userdisk` 上传文件；默认安装验证后删除该单个文件。

安装顺序为：`adb devices -l` → profile 只读检查 → 本地 AMR 清单检查 → 推送到唯一文件名
→ `miniapp_cli install` → 读取已安装 manifest 校验 appid/version →
`miniapp_cli start 8001779591038450 --index` → 检查 MiniApp 进程和关键日志。

任一步失败立即返回非零退出码。脚本不自动启用 GPU；GPU 只在用户从 AMR 启动页进入
Flutter frame 时由受控 runtime 启用。

## 验证矩阵

### 离线

- 官方来源、许可证、commit 和依赖锁。
- Dart/Flutter 分析与可运行测试。
- 触摸坐标四角/中心/边界测试。
- start/stop/generation/异常退出和重复回收测试。
- overlay plane 选择、zpos、禁止 modeset 和 framebuffer retire 测试。
- AMR manifest、资源完整性、ELF/依赖和 SHA-256 检查。

### 真机

1. 首次安装、覆盖安装、`--index` 冷启动。
2. 启动页 → frame → `<hole>` 可见 Flutter 官方 Demo 首帧。
3. Flutter plane 75 有 FB，Falcon plane 54 与 `miniapp` DRM master 保持不变。
4. 点击按钮、切换 switch/checkbox、主题切换、弹层开关和连续列表滑动。
5. 四角与中心触摸方向正确，无镜像、轴交换或固定偏移。
6. 连续运行 60 秒并观察动画/滑动；无新增内核、Mali 或 GPU fault。
7. Home/Back/onHide/onUnload 后 runner 退出、plane 75 清空、原 Falcon 页面恢复。
8. 连续完成两次进入/退出，第二次显示和输入仍正常，无 zombie、残留线程或模块误卸载。
9. 安装脚本的安装、覆盖安装和 `StartOnly` 路径均通过。

自动日志不能替代人工手感。若没有用户实际触摸确认，只能声明输入事件链路通过自动验证，
不能声明触摸体验已认证。

## 完成标准

任务完成必须同时交付：

- 可审计源码与固定上游 commit。
- 可重复生成的 production AMR；若 AOT 尚有外部工具链门槛，则另附明确标记的 debug
  测试 AMR 和阻塞证据。
- `install-flutter-demo.ps1` 与设备端受控 runtime 脚本。
- AMR、runtime 和源码清单的 SHA-256。
- 当前设备上的安装、启动、hole/plane、Flutter 首帧、触摸、两次退出和内核健康证据。
- 未通过项和硬件/人工确认门槛的明确说明。
