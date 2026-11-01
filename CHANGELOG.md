# Changelog

本文件记录本仓库相对上游的变更。

> **本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本，遵循上游 GPL-2.0 许可。**
> 下列变更在 GPL-2.0 下同样公开，衍生作品须沿用 GPL-2.0。
> 详细技术说明见 [`docs/OUR-CHANGES.md`](docs/OUR-CHANGES.md)。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

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

#### 6. Windows → 鸿蒙剪贴板：界面关掉后就断了
- **文件**：`entry/src/main/ets/background/BackGroundAbility.ets` — `wireEvents()` 里的 `onClipboardData` 回调
- **症状**：主窗口开着时，Windows 复制文本能在鸿蒙上粘贴；把窗口收进托盘或退出界面后，剪贴板就不再跟随。
- **根因**：承载进程（`BackGroundAbility`）收到 `DCLP` 后只 `publish(BGEVT_CLIP)` 广播事件，
  真正写系统剪贴板的动作在 `Index.ets` 的 `setSystemClipboard()` 里 —— **界面没有运行实例就没人消费这个事件**，
  文本被静默丢弃。剪贴板属于连接态能力，却被绑在 UI 生命周期上。
- **修复**：承载进程自己直接写剪贴板（`import { pasteboard } from '@kit.BasicServicesKit'`），
  在 `curClipboard` 开启且文本非空时 `pasteboard.getSystemPasteboard().setDataSync(...)`，之后再照常广播事件供界面显示。
  写剪贴板不需要 `READ_PASTEBOARD`，只有读才需要。

### 文档

- 覆盖重写 `README.md`：顶部标注上游来源与 GPL-2.0 继承关系，补充本 fork 改动摘要、已验证环境、能力与限制。
- 新增 `docs/OUR-CHANGES.md`：改动详解（症状 / 根因 / 修法 / 代码位置 / 复现与验证）。
- 新增 `docs/BUILD.md`：鸿蒙侧构建、签名、装机、启动与常见坑。
- 新增 `.github/workflows/build.yml`：静态检查（工程结构、JSON5 可解析、无签名材料、许可证完好）。
  它**不编译 HAP** —— DevEco Studio 与 HarmonyOS SDK 无法在 GitHub 托管 runner 上匿名获取。
- 追加 `NOTICE`：声明本仓库相对上游的修改（GPL-2.0 §2(a) 要求）。
- 补齐 `.gitignore`：新增 `entry/build/`、`.hvigor/`、`entry/oh_modules/`、`oh_modules/`、`.idea/`、`*.hap`、`entry/.preview/`、`entry/.cxx/`。

### 未改动

- `LICENSE`（GPL-2.0 原文）与上游 `CONTRIBUTING.md` 未改。
- 除上述 6 项涉及的四个文件（`Index.ets`、`BackGroundAbility.ets`、`ServerDiscovery.ets`、`deskflow_client.cpp`）外，
  其余源码与配置（`AppScope/**`、`build-profile.json5`、`oh-package.json5`、`hvigorfile.ts`、`entry/src/main/cpp` 其余部分）保持上游原样。

### 已知限制

- **剪贴板只通了单向，且只支持纯文本。** Windows → 鸿蒙 自动生效（`DCLP` 分块 `Start / Data / End`）；
  鸿蒙 → Windows 需要人工点击系统 `PasteButton`，因为 `ohos.permission.READ_PASTEBOARD` 为 `user_grant`
  且 `available_level = system_basic`，普通签名无法获取，写进 `module.json5` 会导致安装失败 `code:9568289`。
  图片与文件不走剪贴板。
- **注入授权弹窗在锁屏状态下弹不出来**，必须解锁屏幕才会弹（锁屏时 hilog 只会看到 `AUTHORIZING` 卡住）。
- 仅支持 **PC / 2in1** 设备形态，非 2in1 调注入接口返回 `801`。
- **UDP 广播在 AP 客户端隔离（校园网 / 企业网）下收不到**，信标必须由服务端向已知设备 IP **单播**。
- 不要用 TCP 探测判断服务端可达性：Deskflow 服务端同一时刻只接受一个客户端，探测会挤断在用连接。

---

#### 7. 鼠标注入完全无效（px/vp 坐标系混用）

**文件**：`entry/src/main/ets/background/BackGroundAbility.ets`

**症状**：键盘注入正常（Win 键能唤出 Dock），鼠标注入无任何反应；早期版本日志里刷满
`injectMouseMove(x,y) failed ret=201`，后期连失败日志都没有。

**根因**：`display.getDefaultDisplaySync()` 的 `width/height` 单位是 **px**，而
`OH_Input_InjectMouseEventGlobal` 的坐标空间是 **vp**。真机实测
`densityPixels = 1.9`，`3120 x 2080` px 实际只有 **1642 x 1095** vp。
旧代码把 px 直接当 vp 上报 `DINF`，服务端下发的坐标全部越界（例如 y=1892 而 vp 上限是 1095），
注入接口对越界坐标静默失败或返回 201，表现为「鼠标完全不动」。

**修法**：上报前除以 `densityPixels`：

```ts
const vpW = Math.round(d.width / d.densityPixels);
const vpH = Math.round(d.height / d.densityPixels);
```

**验证**：`DINF sent=1 (1642x1095)`（修前是 `3120x2080`）；修复后
`injectMouseMove` 失败计数为 **0**，鼠标能正常移动/点击。

#### 8. 注入授权自愈把自己救死（3900006）

**文件**：`entry/src/main/cpp/protocol/deskflow_client.cpp` / `.h`

**症状**：一次瞬时 201 之后，后续所有鼠标注入永久失败；日志出现
`re-request injection auth after cancel, ret=3900006`。

**根因**：旧 `recoverInjectionPermission()` 无条件 `OH_Input_CancelInjection()` 再
`OH_Input_RequestInjection()`。`CancelInjection` 会把已有授权彻底撤销，撤了立刻重申请
会被系统判成「重复请求」返回 `INPUT_INJECTION_OPERATION_FREQUENT (3900006)`，
而 3900006 期间注入一直是 201 —— 一次瞬时失败被放大成永久失效。

**修法**：先查状态再决定动作。

- `AUTHORIZED`：不撤销（撤销无意义，反而掉进 3900006），直接等下一轮；
- `AUTHORIZING`：先等 8 秒。授权框真的在屏上时必须等（Cancel 会关掉那个框）；
  超过 8 秒仍无回调，判定为系统侧残留的**假 AUTHORIZING**，强制复位重申请；
- 限流从「5s / 8 次」放宽到「10s / 20 次」。

**验证**：真机日志 `recover: status=AUTHORIZING, start waiting (no cancel yet)` →
`AUTHORIZING stuck 21089ms with no callback, cancel and re-request` →
`re-request ... prev=1 now=0 ret=0` → `injection auth callback: AUTHORIZED(2)`，
此后注入失败计数归零。

## [Unreleased] — fork 分支

基于上游 `cy745/deskflow-harmonyos`（GPL-2.0）。以下为本 fork 的全部改动。

### 修复

## 上游历史

本仓库之前的历史请查阅上游仓库：
<https://github.com/cy745/deskflow-harmonyos/commits>
