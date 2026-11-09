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

# 只算差异、一个文件都不写（给 App 的「测试连接 / 差异预览」用）
... -DiffOnly

# 覆盖前先把「将被覆盖的文件」在对端存一份快照（留最近 3 份）
... -Apply -Backup

# 结尾额外吐一段机器可读结论（App 靠它拼结论行）
... -Json
```

`-Json` 段格式固定：`===JSON=== {...} ===END===`，键为 `ok / peer / local / include /
dryRun / diffOnly / new / overwrite / same / onlyInPeer / backupDir / backupFiles /
peerAppWasLocked / peerAppStopped / peerAppRestarted / peerAppPid / hashes / error /
psExe / psVersion`。`psExe`+`psVersion` 是为了下次一眼看出「这条到底是 5.1 还是 7 跑的」——
App 用 `-File` 拉起的子进程可能落到 5.1，那套环境里部分 cmdlet 不可靠（2026-11-09 踩到
`Get-FileHash` 报 `CommandNotFoundException`，已改成纯 .NET 的 SHA256，不再依赖该 cmdlet）。

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
`4` robocopy 失败（日志在 `%TEMP%\chan_sync_logs\`）；`5` 产物指纹不一致；`6` 本机没有产物目录。
robocopy 自己的 `3`（有复制 + 目标端有额外文件）算成功，`>=8` 才算失败。

**回退**：`sync_restore.ps1` 把对端被上次同步覆盖掉的文件，从对端自己的快照里拷回对端
（撤销那次覆盖，本机仓库不动）；默认用最近一份，`-Stamp` 指定，`-Json` 给 App 解析；
退 `0/2/4`。

**产物被占用的处理（那台 App 正开着）**：`-Apply` 默认会先调 `remote_ctl.ps1 -Action stop`
关掉**代理记录在案的那一个** App——只是它自己拉起的，你手动开的窗口不动（`stop` 会校验 exe 路径），
关不掉才中止并退 `3`。想自己先关：`-AutoCloseRemoteApp 0`；推完想让它继续跑：加 `-RestartRemoteApp`，
脚本会在指纹校验通过后重新拉起，并把 `status` 交回给你读。`-DryRun` 不关任何东西，只提示。

> 四个脚本本身存为 **UTF-8 带 BOM**：远端用 Windows PowerShell 5.1 跑中文脚本时会按 ANSI 误读
> 无 BOM 的文件，甚至解析失败静默退出（2026-11-09 踩过两次）。补 BOM 对 pwsh 7 无害。

## 一·补充、App 里的「双机同步」按钮（2026-11-09 起）

设置面板（齿轮 → 面板滚到底）在「复制排查信息」下面新增 **「双机同步」**，与「电报通知 / 机器学习」同级；
按钮下方常驻一行「上次同步」。点开是独立对话框：

| 控件 | 干什么 |
| --- | --- |
| 对端项目路径 | 按主机名自动填：PCA（`LAPTOP-NA22IFPU`）→ `\\192.168.1.6\D$\2\chan_month5`；PCB（`CXY`）→ `\\192.168.1.5\chan_month5`；右边「默认」可复位 |
| 测试连接 | 只读：共享是否可达、对端代理在不在线、差异四计数、对端 App 是否占着产物 |
| 立即同步到对端 | 先算差异 → 弹确认（新增 / 覆盖 / 相同 / 对端独有不删 / 对端 App 在不在跑 / 本次不再询问）→ 真写 |
| 按快照回退 | 把对端最近一份快照里的文件拷回对端（撤销上次覆盖），带二次确认 |
| ? | 一页说明（做什么 / 步骤 / 覆盖什么 / 失败怎么办 / 不同步什么） |

实现：`lib/sync/peer_sync_service.dart` 负责找仓库根、挑 PowerShell、`Process.start` 拉起脚本并逐行透传
stdout、解析 `===JSON===`；`lib/ui/peer_sync_dialog.dart` 是界面；设置项落盘 `Directory.current` 下的
`.chan_sync_settings.json`（该文件已进排除表，不会跟着同步跑过去）。

**反向（从 PCB 点按钮推 PCA）怎么落地（2026-11-09 实测）**

反向不是把脚本反过来调就能通，卡的是**认证**：PCA 的登录账号 `86185` 是**微软账号绑定**账户，
SMB 网络登录不认「本地别名 + 密码」，一律 `System error 1326`。所以另开一个纯本地账号。

PCA 侧（每台只做一次）：

1. 共享：双击 `CHAN_RUST\scripts\开共享_双击这里.bat`（弹一次 UAC）→ `chan_month5 → 仓库根`，Everyone 全控；
   普通权限 shell 直接 `New-SmbShare` 会「拒绝访问」；
2. 专用账号：`CHAN_RUST\scripts\make_sync_account.ps1`（弹一次 UAC）→ 建本地账号 `chansync`（非管理员组），
   只给它对仓库目录的 `Modify`（`icacls /grant chansync:(OI)(CI)M /T`）。密码写在脚本里
   （`ChanSync2026!`），要换就改一处、两边重推。要撤：`Remove-LocalUser chansync` +
   `icacls <仓库根> /remove:g chansync`；
3. 代理：`remote_app_agent.ps1 -RepoRoot <仓库根>`，已挂 `HKCU\...\Run\ChanRemoteAgent`（登录即起）。
   反向真推时由它替 PCA 自己的 App「让路」（停）+ 推完再拉回。

PCB 侧（每台只做一次）：双击 `连上PCA_双击这里.bat`（桌面那份是写死绝对路径的启动器，
脚本目录那份用 `%~dp0`）。它内部先清掉到 `192.168.1.5` 的旧会话（旧会话会锁死身份，报
「目前是以其他用户名和密码进行映射的」），再 `New-SmbMapping -UserName chansync -Persistent $true`。
持久映射做好一次，重启后自动恢复，之后按钮不再问密码。

自检（不动一个文件）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File CHAN_RUST\scripts\check_reverse.ps1
```

全程写 `a_Data\remote_ctl\reverse_check.log`：清会话 → 建映射 → 列目录 → `-DiffOnly` 算差异。
`共享可达：是` 且退出码 `0` 即链路通。实测（PCB→PCA）新增 74 / 覆盖 1 / 相同 910 / 对端独有 3。

两个踩过的坑：

- **脚本必须 UTF-8 单 BOM**：双 BOM（首字节 `EF BB BF EF`）会让 Windows PowerShell 5.1 把 `param`
  块判成「非法赋值」，症状是双击后什么都不做、也没有日志；
- **桌面上的 bat 不能靠 `%~dp0` 找 ps1**：`%~dp0` 指向 bat 自己所在目录（桌面），ps1 在
  `CHAN_RUST\scripts` 下，于是静默闪退。

没做也不打算做：给代理加「任意执行命令」的动作。代理信箱在仓库内，而对端是匿名可读共享，
加这个口子等于同网段任何设备都能在 PCB 上执行代码。

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

加 `-Source desktop` 可以跳过 App、直接抓真人看到的那块屏。整屏抓图用的是
**BitBlt + `CAPTUREBLT`**，不是 `Graphics.CopyFromScreen`：后者的 BitBlt 不带 `CAPTUREBLT`，
**抓不到 `WS_EX_LAYERED` 的分层窗口**——分笔的阴阳鱼正好在独立分层窗上，2026-11-09 就是被它骗了
（点击前后两次 GDI 图字节数完全一样，误以为"没有太极"）。

### 分笔太极：拉起后必须点那一下

分笔（`tick`）刚进图时，App 会在独立分层窗上铺一张**直径等于窗口高度**的阴阳鱼，
只有「点一下 / 步进 / 播放」才收起（见 `msg_history.dart` 的【分笔太极】条目）。远程拉起后如果不管它，
那台屏幕上就**一直停在太极上**，看不到真界面——用户 2026-11-09 亲眼确认过。

代理已内置处理：`start` 在主窗口出现后**替用户点一下窗口正中**（`clicked: true`），
再抓一张整屏存到 `shots\` 一起返回（`screenshot` 字段），所以拉完就是真界面。
想保留太极（比如要截它）就传 `noClick: true`，或单用 `-Action click` 手动点：

```
# 点 App 窗口正中（收起太极）
remote_ctl.ps1 -Action click
# 指定屏幕坐标点一下
remote_ctl.ps1 -Action click -X 800 -Y 500
# 列出那台所有可见顶层窗口（含子窗/覆盖窗，用来确认到底有几个窗口）
remote_ctl.ps1 -Action windows
```

退出码：`0` 成功；`1` 远端返回失败（含“没有我启动的实例”这种）；`2` 代理未响应（超时）；
`3` 共享不可达 / 信箱目录不存在（代理没启动）。

### 白名单与约束

只认 12 个动作：`ping` / `start` / `stop` / `status` / `snapshot` / `screenshot` / `command` /
`report` / `ps` / `reload` / `click` / `windows`。**没有“执行任意脚本”这个动作**。

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
