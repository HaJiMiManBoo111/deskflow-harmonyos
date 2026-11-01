# 本 fork 相对上游的改动详解

> **本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本，遵循上游 GPL-2.0 许可。**
> 本文逐条说明我们改了什么、为什么改、改在哪个函数、怎么验证。

## 0. 一句话总结

上游能在**理想路径**上跑通第一次连接；我们在真实使用中遇到的失败都集中在**连接生命周期**和**权限生命周期**两处。
本 fork 的 8 项改动全部围绕这两处。第 1–5、7、8 项是修复，第 6 项是把已有的剪贴板通道从 UI 层移进承载进程
（通道本身是上游就有的 `DCLP`，我们没新增协议）。

| # | 改动 | 文件 | 涉及符号 |
|---|---|---|---|
| 1 | 送新地址不再杀死承载进程 | `entry/src/main/ets/pages/Index.ets` | `startBg()` |
| 2 | 承载 Ability 支持新 want | `entry/src/main/ets/background/BackGroundAbility.ets` | `onNewWant()` |
| 3 | 连接重试，避开旧 worker 未退完 | `entry/src/main/ets/background/BackGroundAbility.ets` | `doConnect()` |
| 4 | 服务端换 IP 自愈（UDP 信标） | `entry/src/main/ets/net/ServerDiscovery.ets`、`entry/src/main/ets/background/BackGroundAbility.ets` | `DISCOVERY_PORT_BG`、`startServerDiscovery()`、`watchBeacon()` |
| 5 | 注入权限卡死自愈 | `entry/src/main/cpp/protocol/deskflow_client.cpp` | `recoverInjectionPermission()`、四处 `inject*` 失败分支、握手后授权段 |
| 6 | 剪贴板不再依赖界面存活 | `entry/src/main/ets/background/BackGroundAbility.ets` | `onClipboardData()` 回调内的 `pasteboard.setDataSync()` |

架构前提：连接**不由主界面持有**，而由独立进程里的 `BackGroundAbility` 承载（`startAbility` 时 `processMode: 1` = `NEW_PROCESS_ATTACH_TO_PARENT`、`startupVisibility: 0` = `STARTUP_HIDE`），这样托盘/隐藏时不会被冻结。主界面与承载进程之间通过 `commonEvent` 交换状态。理解了这一点，下面 4 个 ArkTS 改动才说得通。

---

## 1. 送新地址反而把连接弄死

**文件**：`entry/src/main/ets/pages/Index.ets`，函数 `startBg(want)`

### 上游行为

```
startBg(want):
    requestBgStop()                       // ① 发布停止事件 → 承载进程被停掉
    context.startAbility(want, {processMode:1, startupVisibility:0})
      .catch(e => {
          if (e.code === 16000068) {      // ② ability 已存在
              log(...); return;           // ③ 只打日志，没有任何重试
          }
      })
```

### 症状

用户在界面上改服务端地址、再点连接后，**连接彻底消失**，而且不会自己恢复。hilog 里能看到 `16000068`。

### 根因

`16000068` 的含义是「目标 ability 已在运行」。上游的三步凑成了一个死局：

1. 先 `requestBgStop()` 把**承载进程停掉**（它才是持连接的那个）；
2. 紧接着 `startAbility(want, options)`，其中 `processMode: 1` 要求**新进程**；
3. 系统发现 ability 已存在 → 返回 `16000068` → 上游**只打日志就 return**。

结果：旧的承载进程被停掉，新的没起来，也没有人重试 —— **承载进程彻底消失，再也没人建连接**，新的 `host` 自然永远送不进去。

### 本 fork 的修法

```ts
// 不再先 requestBgStop：承载进程本来就该被复用。
const options: StartOptions = {
  processMode: 1,        // NEW_PROCESS_ATTACH_TO_PARENT
  startupVisibility: 0   // STARTUP_HIDE
};
context.startAbility(want, options).catch((e: BusinessError) => {
  if (e.code === 16000068) {
    // 承载进程已在跑：进程不需要重建，直接投递 want 触发 onNewWant 换目标
    setTimeout(() => {
      context.startAbility(want).catch(...);   // 不带 options
    }, 300);
    return;
  }
  ...
});
```

三个要点：

1. **删掉开头的 `requestBgStop()`**。承载进程本来就该被复用，不需要先杀再启动。
2. `16000068` 不再放弃，而是**延迟 300 ms 重投**。延迟是为了让上一次启动的状态稳定下来。
3. 重投时**不带 `options`** —— 这一次的目的不是新建进程，而是把新 want 投递给已在运行的实例（由 `onNewWant` 接收，见第 2 条）。带 `processMode: 1` 会再次要求新进程，继续撞 `16000068`。

> 注意：`requestBgStop()` 函数本身**保留**，因为「断开连接」按钮仍然要用它（`onDisconnect()` 调它）。只是 `startBg()` 不再调。

---

## 2. 承载 Ability 缺少 `onNewWant`

**文件**：`entry/src/main/ets/background/BackGroundAbility.ets`

### 上游行为

上游只实现了 `onCreate(want, launchParam)` 来读取 `host` 参数。**没有 `onNewWant`**。

### 症状

承载进程已经在运行时，`aa start -a BackGroundAbility -b com.deskflow.ohospoc --ps host <新IP>` 跑完看起来"成功"，
但客户端仍然连着旧地址。

### 根因

HarmonyOS Ability 的生命周期：Ability **已存在**时再次 `startAbility`，系统调用的是 **`onNewWant`**，**不会**重走 `onCreate`。
上游没实现 `onNewWant` → 新 want 携带的 `host` 被系统投递到一个不存在的回调，直接丢弃。

第 1 条把 `16000068` 改成"重投 want"之后，**必须有 `onNewWant` 来接**，否则重投也白投。

### 本 fork 的修法

新增：

```ts
onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  hilog.info(DOMAIN, TAG, 'BackGroundAbility onNewWant');
  const host = want.parameters?.['host'] as string;
  if (!host) {
    hilog.info(DOMAIN, TAG, 'onNewWant without host, ignored');
    return;                        // 没有地址就不打断现有连接
  }
  this.applyWant(want);
}
```

`applyWant(want)` 解析参数后进入 `connectTo(...)`，语义是：

| 情况 | 行为 |
|---|---|
| 无 `host` 参数 | 直接返回，不打断现有连接 |
| 同 `host` + 同 `port` | 不动现有连接，只更新 `invert` / `clipboard` 开关 |
| 异 `host` 或 异 `port` | 更新 `curHost` / `curPort` / `curScreen` 等时间字段 → `doConnect(...)` 重连 → `persistConfig(...)` 持久化 |

另有两点设计细节：

- **`invert` / `clipboard` 传 `undefined` 表示"沿用偏好里的值"**。want 里显式给了才覆盖。否则每次启动器代拉都会把滚轮方向重置成默认值，表现为"用户明明开了反转，一开机又被拉回默认"。
- **`persistConfig()` 必须回写**。否则主界面下次仍按旧 IP 自动连接，会把本进程已建立好的连接顶掉——Windows 端重启后 DHCP 换 IP 时必现。

---

## 3. 连接重试，避开"旧 worker 还没退完"

**文件**：`entry/src/main/ets/background/BackGroundAbility.ets`，新增 `doConnect(...)`

### 症状

切换服务端地址时成功率不稳定，偶发"新地址永远不生效、旧地址继续连着"。

### 根因

原生层 `ConnectDeskflow` 的流程是：先 `stop()` 旧连接，然后**最多等 1.5 秒**；如果旧 worker 还没退完，就返回字符串：

```
previous client is still stopping, please retry in a moment
```

（产生位置：`entry/src/main/cpp/napi_init.cpp:221`）

这是**可重试**的瞬态错误，但上游把这个返回值当成失败直接丢弃 —— 那次换地址请求就白白丢了。

### 本 fork 的修法

```ts
private doConnect(host, port, screen, autoReconnect, attempt): void {
  ...
  const ret: string = deskflow.connectDeskflow(host, port, screen, w, h);
  if (ret.indexOf('still stopping') >= 0 && attempt < 10) {
    setTimeout(() => {
      // 期间地址又被改掉了就放弃这次重试
      if (this.curHost === host && this.curPort === port) {
        this.doConnect(host, port, screen, autoReconnect, attempt + 1);
      }
    }, 600);
  }
}
```

- **判定**：返回串包含 `still stopping` 才重试，其它返回值（成功 / 不可恢复错误）不重试。
- **节奏**：600 ms 一次，最多 10 次（约 6 秒窗口，覆盖原生 1.5 秒等待的多个周期）。
- **防覆盖**：**每次重试前校验 `curHost` / `curPort` 没被改过**。这是关键——否则用户在重试窗口内又改了一次地址，旧的递归链会把新目标覆盖掉。

`connectTo()` 与 `watchBeacon()` 都走这个统一入口，所以信标自愈和手动连接共享同一套重试逻辑。

---

## 4. 服务端换 IP 自愈（UDP 信标）

**文件**：`entry/src/main/ets/net/ServerDiscovery.ets`、`entry/src/main/ets/background/BackGroundAbility.ets`

### 问题

Windows 侧 DHCP 换 IP（如 `10.45.231.220` → `10.45.36.77`）后，鸿蒙端 preferences 里存着旧地址，**永远连不上**，必须人工改地址。
如果主界面没打开（纯载体冷启动），更是完全无从下手。

### 改动 A：`ServerDiscovery.ets` 支持指定监听端口

```ts
export const DISCOVERY_PORT: number = 47000;      // 主界面进程
export const DISCOVERY_PORT_BG: number = 47001;   // 后台承载进程

export function startServerDiscovery(onFound: ServerFoundHandler,
                                     listenPort: number = DISCOVERY_PORT): void
```

为什么要两个口：主界面与承载进程是**两个独立进程**，抢同一个 UDP 口只会有一个 `bind` 成功。
所以承载进程用 `47001` 独立监听，Windows 侧信标两个口都发。

载荷解析（`sock.on('message', ...)`）格式固定：

```
DESKFLOW_SERVER|1|<ip>|<port>
```

`parts.length >= 4 && parts[0] === 'DESKFLOW_SERVER'` 才认为是有效信标。

### 改动 B：`BackGroundAbility.ets` 新增 `watchBeacon()`

```ts
private watchBeacon(): void {
  if (this.beaconStarted) { return; }     // 幂等，只绑一次
  this.beaconStarted = true;
  startServerDiscovery((host: string, port: number) => {
    if (host === this.curHost && port === this.curPort) {
      return;                             // 没变，什么都不做
    }
    this.connectTo(host, port, this.curScreen, this.curAutoReconnect,
      this.curInvert, this.curClipboard);
  }, DISCOVERY_PORT_BG);
}
```

**没有连主界面也能工作**：`onCreate` 里如果 want 没带 `host`，会走 `loadPrefsThenWatch()` ——
先读 preferences 拿上次地址（有就连），**然后照样 `watchBeacon()`**。所以纯载体冷启动、或 want 里地址已过期，都能靠信标自愈，而不是一直干等主界面。

`watchBeacon()` 在三条路径上都会被调用：有 host 的 `onCreate`、无 host 的 `loadPrefsThenWatch()`、以及 `connectTo()` 里重连之后。

### 实测教训 1：AP 客户端隔离下广播无效

**UDP 广播（`255.255.255.255` 与子网定向广播）在校园网 / 企业网的 AP 客户端隔离下收不到。**
鸿蒙端会一直等不到信标，表现为"自愈完全没生效"。

→ **必须由服务端向已知设备 IP 单播。** 本项目配套的 Windows 侧脚本就是这么做的：维护一张已知设备 IP 表，
逐个 `SendTo`。这不是实现缺陷，是网络环境约束。

### 实测教训 2：不要用 TCP 探测判断可达性

**不要加 `probeTcp()` 之类的探测。**

1. **Deskflow 服务端同一时刻只接受一个客户端**。探测连接本身会占掉客户端槽位，把正在使用的连接挤断 —— 自愈反而造成断连。
2. 探测失败时打的 `unreachable` 日志**常与真实状态相反**（服务端可能只是槽位被占，而不是不可达），会误导排查。

→ **直接连即可**。原生层自带 **5 秒连接超时 + 重连退避**，连不上会自己重试。

代码里这一段有注释明确写了这个约束，改动时不要"优化"回去。

---

## 5. 注入权限卡死自愈

**文件**：`entry/src/main/cpp/protocol/deskflow_client.cpp`

### 症状

重连之后**鼠标能穿越、光标不动**；hilog 满屏：

```
Inject pointer event failed, ret:201
```

`201` = `INPUT_PERMISSION_DENIED`（`Check Permi:ohos.permission.CONTROL_DEVICE fail`）。

### 根因（两个叠加）

1. **残留态**：进程被 `aa force-stop` 后重启，`OH_Input_QueryAuthorizedStatus` 仍返回 `AUTHORIZING(1)`（系统侧卡住的残留状态），
   实际上并没有任何授权流程在跑，也**永远不会再回调**。
2. **上游逻辑**：上游遇到 `AUTHORIZING` 就认为"正在授权中，等回调就好"，于是**跳过申请**。既然回调不会来，就永远等不到授权 → 所有注入返回 201。

另外，上游还有一条相关注释：**不能每次重连都重新申请**授权 —— 实测重连时再调一次 `OH_Input_RequestInjection`
会返回 `INPUT_INJECTION_AUTHORIZING(3900005)`，系统同样停在"授权中"且不再回调。所以修复不能简单粗暴地在每次连接时都申请。

### 本 fork 的修法 A：握手后的授权判断

```cpp
Input_InjectionStatus authStatus = UNAUTHORIZED;
Input_Result queryRet = OH_Input_QueryAuthorizedStatus(&authStatus);
if (queryRet == INPUT_SUCCESS && authStatus == AUTHORIZED) {
    DF_LOGI("injection already authorized, skip request");
} else if (queryRet == INPUT_SUCCESS && authStatus == AUTHORIZING) {
    DF_LOGW("injection stuck in AUTHORIZING, cancel and re-request");
    OH_Input_CancelInjection();                  // ① 复位系统侧残留态
    Input_InjectionStatus st2 = UNAUTHORIZED;
    OH_Input_QueryAuthorizedStatus(&st2);        // ② 重查（此时应为 UNAUTHORIZED）
    Input_Result rr = OH_Input_RequestInjection(OnInjectAuthCallback);   // ③ 重新申请
    DF_LOGI("re-request after cancel: prevStatus=%{public}d now=%{public}d ret=%{public}d",
        static_cast<int>(authStatus), static_cast<int>(st2), rr);
} else {
    Input_Result authRet = OH_Input_RequestInjection(OnInjectAuthCallback);
    ...
}
```

关键：AUTHORIZING 分支不再是"等"，而是 **Cancel → 重查 → 重新申请** 三步。`CancelInjection` 会把系统状态从
`AUTHORIZING` / `AUTHORIZED` 复位成 `UNAUTHORIZED`，之后重新申请才能真的触发弹窗。

### 本 fork 的修法 B：`recoverInjectionPermission()` 运行时自愈

授权可能在运行中丢失（例如进程被强杀后残留、或用户撤销）。所以除了握手时判断，注入失败时也要能自愈：

```cpp
bool DeskflowClient::recoverInjectionPermission()
{
    // 限流：两次自愈间隔至少 5s，总共最多 8 次，避免刷屏式反复弹窗。
    const int64_t now = ...;
    const int64_t last = m_permRecoverLastMs.load();
    if (last != 0 && now - last < 5000) { return false; }
    if (m_permRecoverCount.load() >= 8) { return false; }

    m_permRecoverLastMs.store(now);
    m_permRecoverCount.fetch_add(1);
    DF_LOGW("injection denied(201), recovering permission (attempt %{public}d)",
        m_permRecoverCount.load());
    OH_Input_CancelInjection();
    Input_InjectionStatus st = UNAUTHORIZED;
    Input_Result qr = OH_Input_QueryAuthorizedStatus(&st);
    DF_LOGI("after cancel: queryRet=%{public}d status=%{public}d", qr, static_cast<int>(st));
    Input_Result rr = OH_Input_RequestInjection(OnInjectAuthCallback);
    DF_LOGI("re-request injection auth after cancel, ret=%{public}d", rr);
    return rr == INPUT_SUCCESS || rr == INPUT_INJECTION_AUTHORIZED;
}
```

限流参数：

| 参数 | 值 | 原因 |
|---|---|---|
| 两次自愈最小间隔 | **5000 ms** | 授权弹窗生命周期约 5 秒，太密会连续弹窗干扰用户 |
| 自愈总次数上限 | **8 次** | 防止不可恢复场景下无限刷日志 / 弹窗 |
| 额度重置 | 注入成功时计数清零 | 正常恢复后重新获得完整额度 |

接入点（四处失败分支全部接上）：

| 函数 | 判定 |
|---|---|
| `injectMouseMove` | `ret == INPUT_PERMISSION_DENIED` → `recoverInjectionPermission()` |
| `injectMouseButton` | 同上 |
| `injectMouseWheel` | 同上 |
| `injectKeyEvent` | 同上 |

**为什么必须四处都接**：用户可能先动鼠标、也可能先敲键盘。只接鼠标路径的话，键盘先触发失败时仍会一直 201 而不自愈。

### 已知限制：锁屏时弹不出授权框

**注入授权弹窗在锁屏状态下弹不出来。** 锁屏时 hilog 只会看到状态卡在 `AUTHORIZING`，自愈逻辑会不停 Cancel/Request 但用户看不到弹窗。
**必须解锁屏幕**，弹窗才会出现（约 0.5 秒后弹出、约 5 秒后消失）。这是系统行为，客户端无法绕过。

---

## 6. 剪贴板：从界面移进承载进程

### 症状

主窗口开着时，Windows 复制文本能在鸿蒙上直接粘贴；把窗口收进托盘或退出界面后，剪贴板就不再跟随，且没有任何报错。

### 根因

上游（以及本 fork 修此问题之前）的剪贴板链路把「接收」和「写入系统剪贴板」拆在了两个进程层级：

- `entry/src/main/ets/background/BackGroundAbility.ets` 的 `onClipboardData` 回调只做一件事：`publish(BGEVT_CLIP)` 广播事件。
- 真正调用 `pasteboard.createData(...)` / `getSystemPasteboard().setDataSync(...)` 的 `setSystemClipboard()` 写在
  `entry/src/main/ets/pages/Index.ets` 里。

于是**界面没有运行时实例，就没人消费这个广播**，收到的文本被静默丢弃。
剪贴板本质上是连接态能力（连接在承载进程里），却被绑到了 UI 生命周期上。

### 本 fork 的修法

`BackGroundAbility.ets` 自己写剪贴板，不再依赖界面：

```ts
import { pasteboard } from '@kit.BasicServicesKit';

deskflow.onClipboardData((text: string) => {
  if (this.curClipboard && text.length > 0) {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'set system clipboard fail: %{public}s', JSON.stringify(e));
    }
  }
  this.publishStatus(BGEVT_CLIP, text);   // 仍广播，供界面显示
});
```

`this.curClipboard` 由 `BGEVT_CLIP_SYNC` 事件维护，与界面里的开关联动。

### 为什么这里不需要 `READ_PASTEBOARD`

写入系统剪贴板与读取是两个不同权限：`setDataSync` 属**写**，普通应用可直接调；
只有**读**（`getDataSync`）才需要 `ohos.permission.READ_PASTEBOARD`。

### 方向性结论

| 方向 | 是否自动 | 机制 |
|---|---|---|
| Windows → 鸿蒙 | **自动** | 服务端在 `CINN` 后主动下推 `DCLP`（分块 `mark=1 Start(ASCII 长度) → 2 Data → 3 End`，见 `deskflow_client.cpp:301-345`），客户端拼装后写入鸿蒙剪贴板 |
| 鸿蒙 → Windows | **不可自动** | 读取鸿蒙剪贴板需要 `ohos.permission.READ_PASTEBOARD`（`user_grant` + `available_level = system_basic`），普通签名拿不到；写进 `module.json5` 会 `code:9568289` 安装失败。唯一路径是用户人工点一次系统 `PasteButton` 拿临时授权 |

只支持纯文本。图片、文件不走剪贴板（`DFTR` / `DDRG` 消息在客户端是空实现）。

### 复现与验证

1. 连上之后关闭主窗口（承载进程仍在）。
2. Windows 侧复制一段中文文本。
3. 鸿蒙侧在任意输入框长按 → 粘贴，文本应出现。
4. `hilog -T DeskflowPoC` 应能看到 `DCLP` 进、`set system clipboard` 无 error。

> 注：**锁屏状态下注入与剪贴板都不生效**，验证前必须解锁屏幕。


---

## 附：验证方式

改动均在以下真机上验证：

| 项 | 值 |
|---|---|
| 设备 | HUAWEI MateBook Pro，型号 **HAD-W32**，2in1 形态 |
| 系统 | HarmonyOS **7.0.0.111(SP7C00E100R13P5)**，API **26** |
| 服务端 | Windows 11 + Deskflow **1.26** |
| 协议 | Barrier **v1.8**，TCP **24800** |

逐条验证方法：

1. **改动 1 + 2**：App 已连接状态下改服务端 IP 再点连接 → 连接应切到新地址；hilog 里能看到 `carrier already running (16000068), deliver want to it` 与 `BackGroundAbility onNewWant`。
2. **改动 3**：快速连续点击连接 / 在旧连接正在断开时换地址 → hilog 里能看到 `ret=...still stopping...` 与递增的 `attempt=`，最终连上。
3. **改动 4**：主界面不开，服务端换 IP 后单播信标 → 承载进程 hilog 打出 `beacon <new>:24800 (current <old>:24800)` 并重连。
4. **改动 5**：`aa force-stop` 后重启并重连 → hilog 出现 `injection stuck in AUTHORIZING, cancel and re-request`；注入仍在失败时出现 `injection denied(201), recovering permission (attempt N)`；解锁屏幕后弹窗 → 光标恢复。

---

## 许可

**本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本，遵循上游 GPL-2.0 许可。**
上述所有改动同样以 GPL-2.0 发布。根目录 [`LICENSE`](../LICENSE) 为 GPL v2 全文，未作改动。

## 7. 鼠标注入完全无效：px / vp 坐标系混用

**文件**：`entry/src/main/ets/background/BackGroundAbility.ets`（`doConnect`）

### 症状

键盘注入正常（按 Win 键能唤出 Dock），**鼠标注入完全没反应**。早期版本 hilog 刷满
`injectMouseMove(x,y) failed ret=201`；后期连失败日志都不出现，只有 `CINN` 到达。

### 根因

`display.getDefaultDisplaySync()` 的 `width` / `height` 单位是 **px**，
而 `OH_Input_InjectMouseEventGlobal` 的坐标空间是 **vp**（逻辑像素）。

真机（HUAWEI MateBook Pro，3120×2080 屏）：

```
display: px=3120 x 2080  densityPixels=1.9  densityDPI=304
→ vp 实际只有 1642 x 1095
```

旧代码把 `3120 x 2080` 当成 vp 上报 `DINF`。服务端按这个「屏幕尺寸」算坐标，
下发的 y 可能高达 1892，而 vp 上限只有 1095 —— 越界坐标注入要么静默失败、
要么返回 201，表现为鼠标完全不动。

### 修法

```ts
const d = display.getDefaultDisplaySync();
const vpW = Math.round(d.width / d.densityPixels);
const vpH = Math.round(d.height / d.densityPixels);
const ret: string = deskflow.connectDeskflow(host, port, screen, vpW, vpH);
```

### 复现与验证

```bash
hdc shell hilog -x | grep 'DINF'
# 修前: QINF -> DINF sent=1 (3120x2080)
# 修后: QINF -> DINF sent=1 (1642x1095)
hdc shell hilog -x | grep -c 'injectMouseMove.*failed'
# 修后为 0
```

> 注意：`docs/INPUT_INJECTION.md` 第 2 节说「不要乘 densityPixels，直接使用 vp 坐标」——
> 那句话的本意是「不要把 vp 再乘一次变成 px」，但 `d.width` 本身就是 px，必须先除。
> 上游作者当时没在 2in1 上验证到这一点。

## 8. 注入授权自愈把自己救死（3900006）

**文件**：`entry/src/main/cpp/protocol/deskflow_client.cpp`（`recoverInjectionPermission`）、
`entry/src/main/cpp/protocol/deskflow_client.h`

### 症状

一次瞬时 201 之后，后续所有鼠标注入**永久失败**。日志：

```
injection denied(201), recovering permission (attempt 1)
injection auth callback: UNAUTHORIZED(0)
after cancel: queryRet=0 status=0
re-request injection auth after cancel, ret=3900006   ← Repeated request
```

### 根因

旧实现无条件 `OH_Input_CancelInjection()` 再 `OH_Input_RequestInjection()`。
`CancelInjection` 会把已有授权**彻底撤销**，撤了立刻重申请会被系统判成
「重复请求」返回 `INPUT_INJECTION_OPERATION_FREQUENT (3900006)`，
而 3900006 期间注入一直是 201 —— 一次瞬时失败被放大成永久失效。

### 修法

先查状态再决定动作：

```cpp
Input_InjectionStatus st = UNAUTHORIZED;
OH_Input_QueryAuthorizedStatus(&st);
if (st == AUTHORIZED) {
    // 系统说已授权却仍 201：授权挂在别的会话上，撤销无意义
    return false;
}
if (st == AUTHORIZING) {
    if (m_authPendingSinceMs == 0) { m_authPendingSinceMs = now; return false; }
    if (now - m_authPendingSinceMs < 8000) return false;   // 授权框真在屏上，必须等
    // 超过 8s 无回调 = 系统侧假 AUTHORIZING，强制复位
    m_authPendingSinceMs = 0;
}
OH_Input_CancelInjection();
OH_Input_RequestInjection(OnInjectAuthCallback);
```

限流从「5 s / 8 次」放宽到「10 s / 20 次」。

### 复现与验证

```bash
hdc shell hilog -x | grep -E 'recover:|auth callback'
# recover: status=AUTHORIZING, start waiting (no cancel yet)
# recover: AUTHORIZING stuck 21089ms with no callback, cancel and re-request
# re-request injection auth after cancel: prev=1 now=0 ret=0
# injection auth callback: AUTHORIZED(2)
```

之后 `grep -c 'injectMouseMove.*failed'` 为 0。

