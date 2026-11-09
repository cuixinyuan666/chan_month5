# 双机同步与远程拉起（sync_to_remote.ps1 / remote_app_agent.ps1 / remote_ctl.ps1）

两台机器：本机 `LAPTOP-NA22IFPU`，另一台 `192.168.1.6`（项目在 `D:\2\chan_month5`，
本机通过管理共享 `\\192.168.1.6\D$\2\chan_month5` 读写）。

## 一、同步（本机 → 那台）

```powershell
# 只看清单，不动远端一个文件（默认行为，-Apply 才真写）
powershell -NoProfile -File CHAN_RUST\scripts\sync_to_remote.ps1 -DryRun

# 真同步（源码 + Debug 产物）
powershell -NoProfile -File CHAN_RUST\scripts\sync_to_remote.ps1 -Apply

# 只推源码 / 只推产物
... -Apply -Include code
... -Apply -Include build
```

**白名单**（不在里面的都不推）：源码层排除 `.git`、`.kilo`、`.kilocode`、`.workbuddy`、
`.codebuddy`、`.wt`、`exports`、`dist`、`CHAN_RUST\rust\target*`、`flutter\chan_kline\build`、
`.dart_tool`、三平台 `flutter\ephemeral`、`android\.gradle`、`a_Data\.tdx_protocol_cache`、
`.telegram_cache`、`agent_live`、`ml_exports`、`remote_ctl`、`robot_verify`、`robot_verify_inbox`；
文件级再排 `*.log`、`*.log.err`、`build_launch_user.*`、`tmp_build_launch_*`、三份私有配置、
`*.locked*`、`*.bak*`。产物层只推 `Debug` 那一个目录。

**三条硬口径**：

1. **不用 `/MIR`**：远端有自己的报告、调试产物、数据，镜像会删掉它们。本脚本只覆盖，不删除。
2. **必须 `/XJ`**：`linux|macos\flutter\ephemeral\.plugin_symlinks` 是符号链接，SMB 上建不了链接，
   不加 `/XJ` 会重试到上限并以退出码 11 失败。
3. **`a_Data\robot_verify` 只同步模板**：`README.md` 与 `session.json.example` 单独复制，
   `session.json` / `status.json` / `last_report.*` 一律不动——那是各机自己的验证现场。

退出码：`0` 成功；`2` 共享不可达；`3` 远端 exe/dll 被占用（那台 App 在跑，先关再推）；
`4` robocopy 失败（日志在 `%TEMP%\chan_sync_logs\`）；`5` 产物指纹不一致。
robocopy 自己的 `3`（有复制 + 目标端有额外文件）算成功，`>=8` 才算失败。

## 二、远程拉起 App（本机控制那台）

### 那台要做的一次性动作

**双击 `D:\2\chan_month5\启动远端代理.bat`**（或桌面上的 `启动远端代理.bat`）。
这个 bat 做三件事：写一行 `boot.log`（证明它真被执行）→ 调 `stop_remote_agent.ps1` 停掉旧代理
→ 后台启动 `remote_app_agent.ps1`，输出重定向到 `a_Data\remote_ctl\stdout.log`。

也可以仍用命令行（等价）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\2\chan_month5\CHAN_RUST\scripts\remote_app_agent.ps1 -RepoRoot D:\2\chan_month5
```

**必须在桌面会话里启动**：`chan_kline` 是 GUI 程序，远程 PowerShell / WinRM 落在 session 0，
窗口起不来。代理启动时会自检并打印 `会话 id`，若为 0 会警告。

它会在 `D:\2\chan_month5\a_Data\remote_ctl\` 下建 `requests` / `results` / `done` / `shots` / `log`
与 `token.txt`，每秒扫一次信箱。**不注册计划任务**；改名换代靠代理自己的 `reload` 动作
（先释放锁，再拉起自己，然后退出），不用再人工双击。

> 实测记录（2026-11-09）：这台机器对本机**只开放 SMB 文件通道**，
> `schtasks /S`、CIM/WinRM、DCOM 全部被拒（Access denied / 需 TrustedHosts + 凭据），
> 所以“进程级”远程启动只能靠这个常驻代理，不能靠远程计划任务。

### 本机发指令

```powershell
# 探活（返回主机名、会话 id、exe 是否存在、API 令牌是否就绪）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action ping

# 拉起主界面模式（带 CHAN_AGENT_API=1，可用 /state /snapshot /command）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action start -Mode ui

# 读进度（当前股票、周期、步进到第几根、冻结状态）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action status

# 截图存到远端 remote_ctl\shots\，返回文件名与字节数
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action screenshot

# 发一条命令（命令对象原样透传给 /command）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action command -Command '{"type":"step","dir":1}'

# 拉起验证模式并收报告（自动把 status/last_report 收进 robot_verify_inbox 再解析 ok）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action start -Mode verify -SuiteId early_dynamic_20261105
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action report

# 关闭（只关代理自己拉起的那个 pid）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action stop

# 看那台上 chan_kline 进程实况（pid / 是否响应 / 窗口标题 / 会话 id / 启动时刻）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action ps

# 让远端代理自己换代（改完代理脚本后用这个，不必再人工双击）
powershell -NoProfile -File CHAN_RUST\scripts\remote_ctl.ps1 -Action reload
```

`-Action screenshot` 有两条腿：先走 App 的 `/screenshot`（`method: agent_api`）；
API 没起（12321 未监听）时自动落 GDI 整屏抓图（`method: gdi_desktop`），
多显示器按虚拟桌面一次抓全。**画面看不出来就等于没查**，这条是专为诊断留的。

退出码：`0` 成功；`1` 远端返回失败（含“没有我启动的实例”这种）；`2` 代理未响应（超时）；
`3` 共享不可达 / 信箱目录不存在（代理没启动）。

### 白名单与约束

只认 10 个动作：`ping` / `start` / `stop` / `status` / `snapshot` / `screenshot` / `command` /
`report` / `ps` / `reload`。**没有“执行任意脚本”这个动作**。

- 令牌：`remote_ctl\token.txt`，本机只读、不改；对不上直接拒，请求落 `done\`。
- 单实例：`agent.lock` 独占打开，第二个实例直接退出。
- 不越权：`start` 只拉 `<RepoRoot>\CHAN_RUST\flutter\chan_kline\build\windows\x64\runner\Debug\chan_kline.exe`，不接受任意路径。
- 不误杀：`stop` 只关 `state.json` 里记录的 pid，且校验进程路径与记录的 exe 一致才动手；
  **你手动开的窗口它一概不碰**（对应 `ROBOT_VERIFY.md` 的硬约束）。
- 不装成功：代理没响应就报 `代理未响应` + 排查提示，不返回伪结果。
- 可追溯：每个请求与结果都在 `remote_ctl\log\YYYY-MM-DD.log`。

### 跨机器必须给对三个环境变量（给错必报 Bad state）

`chan_ffi.dll` 的 `default_data_root()` 是**编译期常量** `env!("CARGO_MANIFEST_DIR")`
（`CHAN_RUST\rust\chan_data\src\offline.rs:11`）。所以**把本机编好的 exe/dll 拷到那台，它仍然会去找
`C:\Users\86185\Downloads\chan\chan_month5\a_Data`**，界面首行直接报
`Bad state: a_Data 下未找到股票目录，请检查: C:\Users\86185\...`，K 线为空、`_allBars` 为空，
Agent API 也就不会启动（12321 不监听）。代理的 `start` 已固定设置下面三个，**不要删**：

| 变量 | 值 | 为什么必须这样 |
| --- | --- | --- |
| `CHAN_REPO_ROOT` | `D:\2\chan_month5` | `RobotVerifyPaths.resolveRepoRoot()` 的最高优先级；决定 `a_Data\agent_live`、`robot_verify` 落在哪 |
| `CHAN_KLINE_ROOT` | `D:\2\chan_month5\CHAN_RUST\flutter\chan_kline` | 代码里对它做 `parent×3` 得仓库根。**给成仓库根会算成 `D:\`**，令牌被写到 `D:\a_Data\agent_live`，本机请求一律 `401` |
| `CHAN_DATA_ROOT` | `D:\2\chan_month5\a_Data` | 覆盖 dll 的编译期默认根；main.dart 的 `_resolveDataRoot()` 优先读它 |

判断 API 到底有没有起来，看 `a_Data\agent_live\agent_api_token.txt` 的修改时间（dart 侧是
“先 bind 成功再写令牌”）。**不要用 `start` 返回的 `responding` 当证据**——GUI 进程还没建主窗口时
`Process.Responding` 同样是 true（本轮就被它骗过一次，真实状态是“启动即报 Bad state”）。

### 一个已知限制（很重要）

验证模式（`CHAN_ROBOT_VERIFY=1` 或 `session.json` 的 `active:true`）下，`main.dart` 直接返回
`RobotVerifyApp`，不构建主界面，所以**没有 12321 的 Agent API**——那种模式只能读
`status.json` / `last_report.json`，`status` / `snapshot` / `screenshot` / `command` 一定失败。
要这些能力，必须用 `-Mode ui` 拉起（并保证 `CHAN_AGENT_API=1`，代理已自动设置）。
