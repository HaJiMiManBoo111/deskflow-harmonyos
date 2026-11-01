> ## ⚠️ 上游来源与许可声明
>
> **本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本（fork），遵循上游 GPL-2.0 许可。**
>
> - 上游仓库：<https://github.com/cy745/deskflow-harmonyos>
> - 上游许可：**GNU General Public License v2.0**（全文见本仓库 [`LICENSE`](LICENSE)，未作任何改动）
> - 本仓库在上游基础上修复缺陷并增加自愈能力，改动清单见 [`docs/OUR-CHANGES.md`](docs/OUR-CHANGES.md) 与 [`CHANGELOG.md`](CHANGELOG.md)。
> - 按 GPL-2.0 要求，本衍生版本同样以 **GPL-2.0** 发布，源码完整公开。
> - 上游协议层源自 [`deskflow/deskflow`](https://github.com/deskflow/deskflow)（GPL-2.0），工程骨架源自 OpenHarmony 官方示例 [`NDKInputEventInterceptor`](https://gitcode.com/openharmony/applications_app_samples/tree/master/code/DocsSample/InputKit/NDKInputEventInterceptor)（Apache-2.0）。第三方组件声明见 [`NOTICE`](NOTICE)。

# Deskflow for HarmonyOS（fork）

让**鸿蒙电脑（HarmonyOS PC / 2in1）**作为 Deskflow / Barrier 协议的**客户端**，被一台 Windows 上的 Deskflow 服务端共享键鼠：鼠标从 Windows 屏幕边缘穿进鸿蒙屏，在鸿蒙上直接操作鸿蒙应用、文件与界面，再从左缘穿回 Windows。

---

## 这个 fork 解决了什么

上游能跑通「第一次连上」，但在**换地址、重连、进程重启**这些真实使用场景里会失败。本仓库针对八处具体缺陷做了修复：

| # | 问题（上游行为） | 本仓库的修复 |
|---|---|---|
| 1 | 送新地址反而把连接弄死：`startBg()` 先 `requestBgStop()` 杀掉承载进程，紧接着 `startAbility` 撞上 `16000068`（ability 已存在）后**只打日志就 return**，承载进程彻底消失且没有重试 | 删掉开头的 `requestBgStop()`；`16000068` 改为延迟 300 ms 后以无 `options` 的 `startAbility(want)` 再投一次，把新 want 投给已在运行的实例 |
| 2 | 承载 Ability **没有实现 `onNewWant`**：Ability 已运行时 `aa start` 不会重走 `onCreate`，新的 `host` 参数根本进不来 | 新增 `onNewWant(want, launchParam)`：有 `host` 就走 `applyWant(want)`；同地址只更新 invert/clipboard，异地址更新时间字段后重连并持久化配置 |
| 3 | 原生层切换地址时会返回 `"previous client is still stopping, please retry in a moment"`（`ConnectDeskflow` 会先 `stop()` 并最多等 1.5 秒），上游把它当失败直接丢弃 | 新增 `doConnect(...)`：检测到返回串含 `still stopping` 就 600 ms 后递归重试，最多 10 次；**每次重试前校验 `curHost`/`curPort` 未被改过**，避免旧请求覆盖新目标 |
| 4 | Windows 侧 DHCP 换 IP（如 `10.45.231.220` → `10.45.36.77`）后，鸿蒙端永远连着旧地址 | 新增 UDP 信标监听：`ServerDiscovery.ets` 增加 `DISCOVERY_PORT_BG = 47001` 与可指定端口的 `startServerDiscovery(onFound, listenPort)`；`BackGroundAbility.ets` 新增 `watchBeacon()`，收到地址变化即重连。**主界面没开也能自愈**（纯载体冷启动同样生效） |
| 5 | 重连后鼠标能穿越但光标不动，hilog 满屏 `Inject pointer event failed, ret:201`（`201` = `INPUT_PERMISSION_DENIED`）：`OH_Input_QueryAuthorizedStatus` 在进程被 `aa force-stop` 后仍返回 `AUTHORIZING(1)`，上游遇到 AUTHORIZING 就跳过申请，永远等不到授权回调 | 新增 `recoverInjectionPermission()`：先查状态再决定动作（`AUTHORIZED` 不撤销、`AUTHORIZING` 先等 8 秒、超时才判定为假 AUTHORIZING 并强制复位），限流 10 s / 20 次，四处注入失败分支全部接上自愈 |
| 6 | 剪贴板功能绑在界面上：承载进程收到 `DCLP` 只广播事件，真正写系统剪贴板的代码在主窗口里，**界面一关文本就被静默丢弃** | 承载进程自己调 `pasteboard.getSystemPasteboard().setDataSync(...)` 写剪贴板，之后仍广播事件供界面显示；主界面不开也能同步（写剪贴板不需要 `READ_PASTEBOARD`） |
| 7 | **鼠标注入完全无效**：`display.getDefaultDisplaySync()` 的 `width/height` 是 **px**，而 `OH_Input_InjectMouseEventGlobal` 用 **vp**；真机 `densityPixels=1.9`，`3120x2080` px 实际只有 `1642x1095` vp。旧代码把 px 当 vp 上报 `DINF`，服务端下发的坐标全部越界 | 上报前除以 `densityPixels`：`vpW = Math.round(d.width / d.densityPixels)`；`DINF` 从 `3120x2080` 变为 `1642x1095`，注入失败归零 |
| 8 | **注入授权自愈把自己救死**：一次瞬时 201 就无条件 `CancelInjection` + 立刻 `RequestInjection`，系统判成重复请求返回 `3900006`，此后注入永久 201 | 先查状态再动作：`AUTHORIZED` 不撤销；`AUTHORIZING` 先等 8 s（授权框在屏上时必须等），超时无回调才判定为假 AUTHORIZING 并强制复位；限流放宽到 10 s / 20 次 |

技术细节、复现条件与代码位置见 [`docs/OUR-CHANGES.md`](docs/OUR-CHANGES.md)。

---

## 已验证环境

本仓库的改动在下列**真机组合**上验证通过：

| 角色 | 配置 |
|---|---|
| 鸿蒙端设备 | HUAWEI MateBook Pro，型号 **HAD-W32**，**2in1** 形态 |
| 鸿蒙版本 | **HarmonyOS 7.0.0.111(SP7C00E100R13P5)**，API **26** |
| Windows 端 | Windows 11 + **Deskflow 1.26** 服务端 |
| 协议 | Barrier **v1.8**，TCP **24800** |
| 注入权限 | `ohos.permission.CONTROL_DEVICE`，由 App 调用 `OH_Input_RequestInjection` 触发系统弹窗授权 |

工程配置（随仓库提供，无需修改）：

- `build-profile.json5`：`compatibleSdkVersion "5.0.0(12)"`、`targetSdkVersion "6.0.0(20)"`
- `oh-package.json5`：`modelVersion "6.0.0"`
- 编译使用 **HarmonyOS 6.1.1（API 24）** SDK——`compileSdkVersion` 由 DevEco Studio / SDK 侧决定，
  工程文件里未显式声明该键（见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)）

---

## 能力与限制

### 可用

- 鼠标移动 / 单双击 / 拖动（窗口与桌面图标）/ 滚轮
- 键盘：可打印字符、方向键、功能键、修饰键（Shift/Ctrl/Alt）
- 双向边缘穿越（Windows 右缘 → 鸿蒙；鸿蒙左缘 → Windows）
- 断线自动重连（3 秒间隔），以及本 fork 新增的换地址自愈与注入权限自愈
- **文本剪贴板，单向：Windows → 鸿蒙自动生效**

### 限制（重要，请先读）

- **剪贴板只通了单向。** Windows → 鸿蒙：服务端在收到 `CINN` 后主动下推 `DCLP`（分块 `mark=1 Start(ASCII 大小) → 2 Data → 3 End`），客户端拼装后写入鸿蒙剪贴板，**自动**。鸿蒙 → Windows：**不可自动**。读取鸿蒙剪贴板需要 `ohos.permission.READ_PASTEBOARD`，该权限是 `user_grant` 且 `available_level = system_basic`，**普通签名拿不到**；写进 `module.json5` 会导致安装失败 `code:9568289`。唯一可行路径是用户人工点一次系统 `PasteButton`（临时授权）才推送。只支持纯文本，图片与文件不支持。
- **必须解锁屏幕。** 注入授权弹窗「允许使用您的屏幕？」在锁屏状态下**弹不出来**，锁屏时 hilog 只会看到状态卡在 `AUTHORIZING`。
- **必须是 PC / 2in1 设备形态。** 全局注入接口在非 2in1 形态上返回 `801`。
- **鸿蒙 6 / API 20+ 为最低要求**；本仓库实测于 API 26。
- 暂不支持手机、平板等非 PC 形态设备。
- 键盘映射覆盖常用键，个别媒体键与厂商自定义键未映射。

---

## 与 Windows 端配合使用

> **要现成的安装包？** 到 [Releases](https://github.com/HaJiMiManBoo111/deskflow-harmonyos/releases) 下载 `deskflow-harmonyos-v0.1.0-unsigned.zip`。里面是**未签名**的 `.hap` + 签名安装说明（`START-HERE.txt`）。发未签名版是因为签名 hap 会嵌入打包者的证书与绑定设备 UDID 的调试 profile，既泄露他人设备标识又装不到你机器上 —— 用自己的证书签一次约一分钟。

### 1. 服务端（Windows）

安装 **Deskflow 1.26**，确保服务端监听 TCP **24800**，协议为 **Barrier v1.8**。

在服务端配置中把两台机器列入 screens 与 links。示例（Windows 机器名 `JARVIS`，鸿蒙端屏幕名 `HarmonyPC`）：

```
section: screens
    JARVIS:
    HarmonyPC:
end

section: links
    JARVIS:
        right = HarmonyPC
    HarmonyPC:
        left = JARVIS
end
```

即 `JARVIS: right = HarmonyPC`、`HarmonyPC: left = JARVIS`——鼠标从 Windows 右缘出去进入鸿蒙，从鸿蒙左缘回来。屏幕名 `HarmonyPC` 需与鸿蒙端 App 里填写的「屏幕名」一致。

### 2. 鸿蒙端

1. 启动 App，先点注入授权按钮，在系统弹窗「允许使用您的屏幕？」中点允许（约 0.5 秒后弹出、约 5 秒后消失，**锁屏时不弹**）。
2. 填入服务端 IP、端口 `24800`、屏幕名 `HarmonyPC`，点「连接 Deskflow Server」。

> ⚠️ 源码里 `Index.ets` 的 `hostInput` 默认值仍是上游作者机器上的 `10.45.231.220`（`@State hostInput` 与 `pref.getSync` 两处）。这是**上游遗留的占位值，不是你自己的地址**。第一次使用请在界面上手填真实 IP；填过一次后会被写进 preferences，之后由 UDP 信标自动更新，不必再填。

---

## 服务端换 IP 自愈怎么配

Windows 侧 DHCP 换 IP 后，鸿蒙端存着旧地址就永远连不上。本 fork 靠 **UDP 信标**解决：服务端周期性往鸿蒙设备发一个 UDP 包，鸿蒙端在 `47001` 端口监听，发现地址变化即重连。

- 监听端口：**UDP 47001**（后台承载进程专用；主界面进程用 47000，两个进程各占一口互不抢绑）
- 载荷格式：`DESKFLOW_SERVER|1|<ip>|<port>`，例如 `DESKFLOW_SERVER|1|10.45.36.77|24800`
- **必须由服务端向已知设备 IP 单播。**

> **实测教训：广播在 AP 客户端隔离下无效。**
> `255.255.255.255` 与子网定向广播在**校园网 / 企业网的 AP 客户端隔离**下收不到，鸿蒙端会一直等不到信标。必须由服务端指向鸿蒙设备当前 IP **单播**发送。本项目配套的 Windows 侧脚本（如 `deskflow-beacon.ps1`）就是这样实现的。

> **实测教训：不要用 TCP 探测（probeTcp）判断服务端是否可达。**
> Deskflow 服务端同一时刻只接受一个客户端，探测连接会占掉槽位，把正在使用的连接挤断；而且探测失败时的 `unreachable` 日志常与真实状态相反。**直接连即可**——原生层自带 5 秒连接超时与重连退避。

---

## 构建

完整的鸿蒙侧构建步骤（含签名、装机、排错）见 [`docs/BUILD.md`](docs/BUILD.md)。最短路径：

```bash
# 构建
hvigorw assembleHap

# 装机（务必选 -signed.hap）
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap

# 启动
hdc shell aa start -a EntryAbility -b com.deskflow.ohospoc
```

> 选 HAP 时必须选 `-signed.hap`。选到 `-unsigned.hap` 会报 `code:9568320 error: no signature file.`——因为 `unsigned` 在字典序里排在 `signed` 前面，按文件名排序很容易选错。

### 关于 CI

仓库里的 workflow **不编译 HAP**。做了但只做静态检查：

| 检查项 | 说明 |
|---|---|
| 必要工程文件是否存在 | 缺 `hvigorfile.ts` / `build-profile.json5` / `module.json5` 等直接失败 |
| JSON5 配置能否解析 | `build-profile.json5`、`oh-package.json5`、`AppScope/app.json5`、`entry/src/main/module.json5` |
| 有没有签名材料被提交 | `*.p12` / `*.p7b` / `*.cer` / `*.jks` 与 `keyPassword` / `storePassword` 字段 |
| 许可证声明是否完好 | `LICENSE` 仍是 GPL-2.0 原文、`NOTICE` 仍含 GPL-2.0 声明 |

原因：编译需要 DevEco Studio 与 HarmonyOS SDK，而 DevEco 的完整发行包要求开发者账号登录后才能下载，无法在 GitHub 托管的公开 runner 上匿名获取（`hvigorw` 与 SDK 都不在 `ubuntu-latest` / `windows-latest` 镜像里）。

**所以这个绿色 ✓ 只代表「工程结构完整、配置可解析、没泄露签名材料」，不代表「HAP 能编出来」。** 真实编译请在本机按 [`docs/BUILD.md`](docs/BUILD.md) 执行。如果你有已装 DevEco 的自建 runner，`build.yml` 末尾有注释掉的可选 job。

---

## 文档

- [`docs/OUR-CHANGES.md`](docs/OUR-CHANGES.md) —— **本 fork 相对上游的改动详解**（核心）
- [`docs/BUILD.md`](docs/BUILD.md) —— 鸿蒙侧构建、装机与排错
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) —— 架构说明（沿用上游）
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) —— 协议编解码规范（沿用上游）
- [`docs/INPUT_INJECTION.md`](docs/INPUT_INJECTION.md) —— 输入注入实战（沿用上游）
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) —— 踩坑记录（沿用上游）
- [`CHANGELOG.md`](CHANGELOG.md) —— 变更记录

---

## 许可证与上游致谢

**本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本，遵循上游 GPL-2.0 许可。**

- 上游 `cy745/deskflow-harmonyos`：GPL-2.0。本仓库的工程结构、UI、NAPI 桥接与协议层均来自上游。
- Deskflow 协议实现源自 [`deskflow/deskflow`](https://github.com/deskflow/deskflow)：GPL-2.0。
- 工程骨架与 UI 文件头保留 OpenHarmony 示例 [`NDKInputEventInterceptor`](https://gitcode.com/openharmony/applications_app_samples/tree/master/code/DocsSample/InputKit/NDKInputEventInterceptor) 的 Apache-2.0 文件头。
- 托盘图标派生自 [Remix Icon](https://github.com/Remix-Design/RemixIcon)（Apache-2.0），详见 [`NOTICE`](NOTICE)。
- 根目录 [`LICENSE`](LICENSE) 为 GPL v2 全文，**未作任何修改**。

按 GPL-2.0，任何基于本仓库的衍生作品也必须以 GPL-2.0 发布并提供完整源码。

感谢上游作者 `cy745` 以及 Deskflow、OpenHarmony 社区的工作。
