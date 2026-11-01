# 鸿蒙侧构建与部署

> 本仓库是 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos) 的衍生版本，遵循上游 GPL-2.0 许可。

本文说明如何从源码构建 HAP 并装到鸿蒙 PC 上。构建流程与上游一致，本 fork 未改动任何构建配置。

---

## 1. 依赖

| 项 | 要求 |
|---|---|
| 开发工具 | **DevEco Studio**（自带 `hvigorw` 构建器与 `ohpm` 包管理器），建议 6.x |
| SDK | HarmonyOS **6 / API 20+**（编译使用 6.1.1 / API 24 SDK） |
| 设备 | HarmonyOS **6 / API 20+** 的 **PC 或 2in1** 设备（非 2in1 调注入接口返回 `801`） |
| 设备状态 | 已开启「开发者模式」并允许 USB 调试 / 无线调试 |
| 命令行工具 | `hdc`（随 DevEco Studio 的 SDK 提供，位于 `SDK/toolchains/`） |

工程现有配置（**不需要修改**）：

- `build-profile.json5`：`compatibleSdkVersion "5.0.0(12)"`、`targetSdkVersion "6.0.0(20)`
- `compileSdkVersion` 未在工程文件中显式声明，由 DevEco Studio 按所装 SDK 决定（实测 6.1.1 / API 24）
- `oh-package.json5`：`modelVersion "6.0.0"`
- `hvigor/hvigor-config.json5`：`modelVersion "6.0.0"`
- `entry/build-profile.json5`：`abiFilters ["x86_64", "arm64-v8a"]`，Native 入口 `./src/main/cpp/CMakeLists.txt`

---

## 2. 构建

### 2.1 在 DevEco Studio 里（推荐首次使用）

1. **打开工程**：`File → Open`，选择仓库根目录（含 `hvigorfile.ts` 的那一层）。
2. **等待同步**：DevEco 会提示安装/同步依赖，点 `Sync Now`。首次同步会拉取 `@ohos/hypium`、`@ohos/hamock`。
3. **配置签名**：
   - `File → Project Structure → Signing Configs`
   - 勾选 **`Automatically generate signature`**
   - 登录华为开发者账号，连接已开启调试的设备，让 DevEco 自动生成调试证书（`.cer` / `.p7b` / `.p12`）并写回 `build-profile.json5`
   - 生成的签名材料默认落在用户主目录 `~/.ohos/config/`，**不入库**
4. **构建**：菜单 `Build → Build Hap(s)/APP(s) → Build Hap(s)`，或命令行 `hvigorw assembleHap`。

> ⚠️ 自动签名写回的 `signingConfigs` 段包含**本机绝对路径与密钥密码**，**不要提交**。
> `.gitignore` 已忽略 `*.p12`、`*.p7b`、`*.cer`、`*.jks`、`*.keystore`、`*.key`、`*.pem` 等，
> 但**盖不住 `build-profile.json5` 这个文件本身**（它必须入库）。仓库里的版本已手工剥掉
> `signingConfigs` 段，本地开发请执行一次让 git 忽略后续改动：
>
> ```bash
> git update-index --skip-worktree build-profile.json5
> # 需要恢复跟踪：git update-index --no-skip-worktree build-profile.json5
> ```
>
> 没有 `signingConfigs` 时 `hvigorw assembleHap` 仍能产出**未签名** hap；装机前需在 DevEco 里签名或自行补签。

### 2.2 纯命令行

在仓库根目录执行：

```bash
hvigorw assembleHap
```

需要额外参数时（与上游一致的完整写法）：

```bash
hvigorw assembleHap --mode module -p product=default
```

> `hvigorw` 不在 PATH 时，用 DevEco Studio 安装目录下的 `tools/hvigor/bin/hvigorw`（Windows 为 `hvigorw.bat`）。

产物路径：

```
entry/build/default/outputs/default/entry-default-signed.hap
entry/build/default/outputs/default/entry-default-unsigned.hap
```

---

## 3. 装机

确认设备已连接（`hdc list targets` 能看到设备）：

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

`-r` 表示覆盖安装（replace）。

### ⚠️ 坑：一定要选 `-signed.hap`

**必须选 `entry-default-signed.hap`。** 如果选到 `entry-default-unsigned.hap`，会报：

```
code:9568320 error: no signature file.
```

**为什么容易选错**：`unsigned` 在字典序里排在 `signed` **前面**。
- 按文件名排序时，`entry-default-unsigned.hap` 先出现，手快就选错；
- 用 `ls entry/build/default/outputs/default/` 看列表时同理；
- Shell 通配 `entry-default-*.hap` 会先把 unsigned 展开。

安全做法：显式写全名，或用通配后筛选：

```bash
# 显式全名（推荐）
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap

# 或：从通配里筛掉 unsigned
hdc install -r "$(ls entry/build/default/outputs/default/entry-default-*signed.hap | grep -v unsigned)"
```

---

## 4. 启动

```bash
hdc shell aa start -a EntryAbility -b com.deskflow.ohospoc
```

- `-a EntryAbility`：主界面 Ability
- `-b com.deskflow.ohospoc`：bundleName（见 `AppScope/app.json5`）

承载连接的独立进程由 `BackGroundAbility` 承担，主界面点「连接」时会自动拉起（`processMode: 1` 独立进程），**不需要手动启动**。

如需直接向承载进程投递地址（例如脚本化代拉），可显式带参数启动：

```bash
hdc shell aa start -a BackGroundAbility -b com.deskflow.ohospoc --ps host 10.45.36.77 --ps port 24800
```

> 承载进程已在运行时，这条命令**不会**重建进程，而是触发 `onNewWant` 换目标（本 fork 修复点，见 [`docs/OUR-CHANGES.md`](OUR-CHANGES.md) 第 1、2 条）。

---

## 5. 注入权限弹窗

首次连接后，App 会调 `OH_Input_RequestInjection` 申请 `ohos.permission.CONTROL_DEVICE`，系统弹出：

> **「允许使用您的屏幕？」**

行为：

- 约 **0.5 秒**后弹出
- 约 **5 秒**后自动消失
- **必须点「允许」**，否则所有注入事件返回 `201`（`INPUT_PERMISSION_DENIED`），表现为「鼠标能穿越但光标不动」

### ⚠️ 坑：锁屏时不会弹

**注入授权弹窗在锁屏状态下弹不出来。** 锁屏时 hilog 只会看到状态卡在 `AUTHORIZING`，什么都不会发生。
→ **先解锁屏幕**，再触发连接/注入。

如果已经卡住，日志会显示自动恢复尝试：

```
injection stuck in AUTHORIZING, cancel and re-request
injection denied(201), recovering permission (attempt N)
```

解锁屏幕后弹窗会重新出现，点允许即可恢复。详见 [`docs/OUR-CHANGES.md`](OUR-CHANGES.md) 第 5 条。

---

## 6. 排错

查看日志（域 `0x0000`，标签包含 `DeskflowBg` / `DeskflowDisc` / `DeskflowClient`）：

```bash
hdc shell hilog | grep -i deskflow
```

| 现象 | 原因 | 处理 |
|---|---|---|
| `code:9568320 error: no signature file.` | 装成了 `-unsigned.hap` | 改用 `entry-default-signed.hap` |
| 安装成功但注入全 `201` | 未授权 / 锁屏弹不出弹窗 | 解锁屏幕，让弹窗出现并点「允许」 |
| 调注入接口返回 `801` | 设备形态不是 2in1 | 必须用 PC / 2in1 设备 |
| `Install Failed: error: failed to install bundle. code:9568289` | 在 `module.json5` 里加了受限权限（如 `READ_PASTEBOARD`） | 移除该权限；普通签名拿不到 `system_basic` 权限 |
| 连接不上服务端 | 服务端未监听 TCP 24800 / 防火墙 / 屏幕名不一致 | 检查 `JARVIS: right = HarmonyPC` 配置与端口 |
| 换地址后一直连旧 IP | 上游缺陷（本 fork 已修） | 确认使用的是本仓库版本；见 [`docs/OUR-CHANGES.md`](OUR-CHANGES.md) |
| 卸载重装后要重新授权 | 系统侧权限随进程状态复位 | 正常现象，重新点允许即可 |

更多历史踩坑见 [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md)。

---

## 7. CI 构建（可选）

仓库提供 `.github/workflows/build.yml`，在 GitHub Actions 上用 DevEco 命令行构建 HAP。
该工作流**只做编译**，不包含签名材料 —— 签名证书需通过仓库 Secrets 注入，否则只能得到 `-unsigned.hap`。
未配置 Secrets 时工作流会跳过签名步骤并在 summary 中说明。

---

## 许可

本工程构建配置来自上游 [`cy745/deskflow-harmonyos`](https://github.com/cy745/deskflow-harmonyos)（**GPL-2.0**）。
本仓库为同许可衍生版本，改动仅在文档与 README，未修改构建配置与源码。
