# Changelog

本文件记录本仓库相对上游的变更。

> **本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本，遵循上游 GPL-2.0 许可。**
> 下列变更在 GPL-2.0 下同样公开，衍生作品须沿用 GPL-2.0。
> 详细技术说明见 [`docs/OUR-CHANGES.md`](docs/OUR-CHANGES.md)。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [Unreleased] — fork 分支

基于上游 `cy745/deskflow-harmonyos`（GPL-2.0）。以下为本 fork 的全部改动。

### 修复

#### 1. 送新地址反而把连接弄死
- **文件**：`entry/src/main/ets/pages/Index.ets` — `startBg(want)`
- **症状**：鸿蒙端换服务端地址后，连接彻底消失且不再有人重建；hilog 里出现 `16000068`。
- **根因**：上游先 `requestBgStop()` 发布停止事件（承载进程被停掉），紧接着 `context.startAbility(want, {processMode:1, startupVisibility:0})`；
  `catch` 里遇到 `16000068`（ability 已存在）**只打日志就 `return`**，没有任何重试。承载进程被停 + 新启动撞「已存在」→ 承载进程彻底消失。
- **修复**：删除开头的 `requestBgStop()` 调用；`16000068` 改为延迟 **300 ms** 后用不带 `options` 的 `context.startAbility(want)` 再投一次，
  把新的 want 投递给已在运行的实例（后续由 `onNewWant` 接收）。

#### 2. 承载 Ability 缺少 `onNewWant`
- **文件**：`entry/src/main/ets/background/BackGroundAbility.ets`
- **症状**：承载进程已在运行时，`aa start` 推入的新 `host` 参数完全无效，客户端仍连旧地址。
- **根因**：上游**没有实现 `onNewWant`**。Ability 已存在时系统走 `onNewWant` 而非 `onCreate`，新参数被直接丢弃。
- **修复**：新增 `onNewWant(want, launchParam)`：
  - 无 `host` 参数 → 直接返回（不打断现有连接）；
  - 有 `host` → 调 `applyWant(want)` → `connectTo(host, port, screen, autoReconnect, invert, clipboard)`；
  - 同地址 → 仅更新 `invert` / `clipboard`，不动现有连接；
  - 异地址 → 更新时间字段、重连并持久化配置到 preferences。

#### 3. 连接重试缺失，撞上「旧 worker 还没退完」就丢请求
- **文件**：`entry/src/main/ets/background/BackGroundAbility.ets` — 新增 `doConnect(...)`
- **症状**：切换服务端地址成功率不稳定，偶发新地址永远不生效。
- **根因**：原生层 `ConnectDeskflow` 会先 `stop()` 再最多等 **1.5 秒**；仍运行则返回字符串
  `previous client is still stopping, please retry in a moment`（见 `entry/src/main/cpp/napi_init.cpp:221`）。
  上游直接把这个返回值当失败丢弃。
- **修复**：新增 `doConnect(host, port, screen, autoReconnect, attempt)`：返回串含 `still stopping` 时 **600 ms** 后递归重试，
  最多 **10 次**；**每次重试前校验 `curHost` / `curPort` 未被改过**，避免旧请求覆盖新目标。

#### 4. 服务端换 IP 后无法自愈
- **文件**：`entry/src/main/ets/net/ServerDiscovery.ets`、`entry/src/main/ets/background/BackGroundAbility.ets`
- **症状**：Windows 侧 DHCP 换 IP（如 `10.45.231.220` → `10.45.36.77`）后，鸿蒙端存着旧地址，永远连不上。
- **修复**：
  - `ServerDiscovery.ets` 新增 `DISCOVERY_PORT_BG = 47001`；`startServerDiscovery(onFound, listenPort)` 增加端口参数（默认仍为 `DISCOVERY_PORT = 47000`）。
  - `BackGroundAbility.ets` 新增 `watchBeacon()`：在 **UDP 47001** 监听信标，载荷格式 `DESKFLOW_SERVER|1|<ip>|<port>`；
    收到且地址与当前不同即重连。**主界面未打开也能工作**——纯载体冷启动（`onCreate` 无 host）同样会读偏好并开始监听。
  - 主界面进程用 47000、承载进程用 47001，避免两个进程抢绑同一 UDP 口。

#### 5. 注入权限卡死导致光标不动
- **文件**：`entry/src/main/cpp/protocol/deskflow_client.cpp`
- **症状**：重连后鼠标能穿越、光标不动；hilog 满屏 `Inject pointer event failed, ret:201`（`201` = `INPUT_PERMISSION_DENIED`）。
- **根因**：`OH_Input_QueryAuthorizedStatus` 在进程被 `aa force-stop` 后仍返回 `AUTHORIZING(1)`（系统侧残留态）；
  上游代码遇到 AUTHORIZING 就跳过申请 → 永远等不到授权回调。
- **修复**：
  - AUTHORIZING 分支改为 `OH_Input_CancelInjection()` → 重新查询状态 → 重新 `OH_Input_RequestInjection()`；
    日志 `injection stuck in AUTHORIZING, cancel and re-request`。
  - 新增 `recoverInjectionPermission()`：注入返回 `INPUT_PERMISSION_DENIED` 时自动 Cancel + Request；
    限流「两次间隔 ≥ **5000 ms**、总计 ≤ **8 次**」，注入成功时清零计数恢复额度。
  - `injectMouseMove` / `injectMouseButton` / `injectMouseWheel` / `injectKeyEvent` 四处失败分支全部接上该自愈逻辑。

### 文档

- 覆盖重写 `README.md`：顶部标注上游来源与 GPL-2.0 继承关系，补充本 fork 改动摘要、已验证环境、能力与限制。
- 新增 `docs/OUR-CHANGES.md`：改动详解（症状 / 根因 / 修法 / 代码位置 / 复现与验证）。
- 新增 `docs/BUILD.md`：鸿蒙侧构建、签名、装机、启动与常见坑。
- 新增 `.github/workflows/build.yml`：DevEco 命令行构建 HAP 的 CI 工作流。
- 追加 `NOTICE`：声明本仓库相对上游的修改（GPL-2.0 §2(a) 要求）。
- 补齐 `.gitignore`：新增 `entry/build/`、`.hvigor/`、`entry/oh_modules/`、`oh_modules/`、`.idea/`、`*.hap`、`entry/.preview/`、`entry/.cxx/`。

### 未改动

- `LICENSE`、`CONTRIBUTING.md` 与全部源码 / 配置（`entry/src/**`、`AppScope/**`、`build-profile.json5`、`oh-package.json5`、`hvigorfile.ts`）保持上游原样。

### 已知限制

- **无剪贴板同步。** 鸿蒙 → Windows 方向需要人工点击系统 `PasteButton`；
  `ohos.permission.READ_PASTEBOARD` 为 `user_grant` 且 `available_level = system_basic`，普通签名无法获取，
  写进 `module.json5` 会导致安装失败 `code:9568289`。
- **注入授权弹窗在锁屏状态下弹不出来**，必须解锁屏幕才会弹（锁屏时 hilog 只会看到 `AUTHORIZING` 卡住）。
- 仅支持 **PC / 2in1** 设备形态，非 2in1 调注入接口返回 `801`。
- **UDP 广播在 AP 客户端隔离（校园网 / 企业网）下收不到**，信标必须由服务端向已知设备 IP **单播**。
- 不要用 TCP 探测判断服务端可达性：Deskflow 服务端同一时刻只接受一个客户端，探测会挤断在用连接。

---

## 上游历史

本仓库之前的历史请查阅上游仓库：
<https://github.com/cy745/deskflow-harmonyos/commits>
