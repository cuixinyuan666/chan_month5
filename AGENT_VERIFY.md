# 智能体验证（Agent Verification · 本地 Agent API）

> 与 [`ROBOT_VERIFY.md`](ROBOT_VERIFY.md)（**机器人验证**）并列的第二种验证模式。
> 本文只管**智能体验证专属**的命名、启停、接口与安全口径；
> 通用规则（确认门禁、编译与重启、提交与推送）见 [`AGENTS.md`](AGENTS.md)。

## 一、两种验证模式的分工

| | **机器人验证**（Robot Verify） | **智能体验证**（Agent Verification） |
|---|---|---|
| 入口 | `main()` 直接返回 `RobotVerifyApp`，**绕过主界面** | 主界面正常启动，额外挂一个本地 API |
| 启用方式 | `a_Data/robot_verify/session.json` → `active:true` | 环境变量 `CHAN_AGENT_API=1` |
| 交互形态 | 批次式：自动跑完套件，一次性出报告 | 长驻式：智能体**实时**读状态、发命令、截屏 |
| 可视化 | 独立窗口看进度条 | 用户在 App 里操作，agent 在旁观察/操纵 |
| 产出 | `last_report.json` / `status.json`（落盘一次性） | HTTP 实时响应 + `state.json` 持续刷新 |
| 适用场景 | CI、回归、无人值守验收 | 排查、探索、让 agent「亲眼」看图表、逐步调试 |

两者**可以并存**但通常不同时开：智能体验证运行中可通过
`POST /command {"type":"run_robot_verify"}` 触发一次机器人验证，把结果收进自己的数据流。

## 二、启用与关闭

```powershell
# 启用（配合主界面正常启动）
$env:CHAN_AGENT_API = '1'
build\windows\x64\runner\Debug\chan_kline.exe

# 关闭：不设该环境变量即可；或设为 0/false
```

- **默认关闭**。只有 `1` / `true` / `yes`（忽略大小写空白）才启用。
- 启动时机：K 线加载成功后（`main.dart` → `_loadKlines` 尾部），且**不在**机器人验证专用模式下。
- 重复调用（换股/换周期）不会重启服务、不会覆盖令牌。

## 三、安全边界

| 项 | 口径 |
|---|---|
| 监听地址 | **仅 `127.0.0.1:12321`**（`InternetAddress.loopbackIPv4`），外网不可达 |
| 令牌 | 每次启动随机生成，写入 `a_Data/agent_live/agent_api_token.txt`；所有请求需带 `X-Agent-Token` 头，否则 `401` |
| 端口冲突 | 先 `bind` 成功才写令牌；第二个实例绑定失败时不会破坏运行中实例的令牌 |
| 运行时目录 | `a_Data/agent_live/` 已 gitignore，**令牌/命令/状态/截图一律不入库** |
| 命令权限 | 与用户手动操作等价（步进、播放、换股、换周期），不新增任何 Rust/FFI 能力 |

## 四、HTTP 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 版本、FFI ABI、PID、数据根、运行时长、令牌文件路径 |
| GET | `/state` | 代码/周期/stepIdx/总根数/播放状态/指标集/筹码与笔数分布配置/截断开关/`math_config`（BOLL、唐奇安、回归 k） |
| GET | `/klines?period=&days=&limit=` | 当前会话原始 K 线（OHLCV+笔数）；`days` 从末根往前推自然日，`limit` 默认 5000、硬上限 50000 |
| GET | `/messages?limit=` | 运行消息历史末 N 条（与界面「历史记录」同源），`limit` 默认 50、硬上限 500 |
| GET | `/snapshot` | 全量会话快照：各层段、分型确认、买卖点、中枢、末根 bar_feature |
| GET | `/tooltip?idx=N` | 第 N 根 K 的十字线 tooltip 行（与画面 tooltip 同源） |
| GET | `/screenshot` | 图表 RepaintBoundary 的 PNG 截图 |
| POST | `/command` | 执行命令，见下表 |

### 命令一览（`POST /command`，body 为 JSON）

| type | 参数 | 作用 |
|---|---|---|
| `step_to` | `idx` | 步进到第 N 根（等价于点界面「步进到第 N 根」） |
| `step` | `dir`（缺省 +1） | 前进/后退一根 |
| `play` | — | 切换播放/暂停 |
| `pause` / `stop` | — | 停止播放 |
| `run_to_end` | — | 一次性走到末尾 |
| `load_code` | `code`, `period?` | 换股（可同时换周期） |
| `set_period` | `period` | 只换周期 |
| `run_robot_verify` | `period`（套件 ID，缺省 `jiyou_keypoint_20261001`） | 触发一次机器人验证并返回摘要 |
| `set_indicators` | `main_indicators`, `sub_indicators`（逗号分隔标签，支持全角逗号） | 勾选主/副图指标；只给一侧则另一侧不动，空字符串清空该侧；未知名 label 明确报错 |
| `set_config` | `config_key`, `config_value` | 改一项设置，键与合法值见下方「配置键」表 |

响应统一为 `{"ok": bool, "message": string, "data": ...}`。

### 配置键（`set_config` 的 `config_key`）

| key | 取值 | 说明 |
|---|---|---|
| `chip_enabled` | 布尔（`true/false`、`1/0`、`开/关`） | 右侧筹码开关 |
| `tick_enabled` | 同上 | 左侧笔数分布开关 |
| `chip_bucket` | ≥ 0.01 的数字（按 2 位小数） | 筹码桶宽 |
| `tick_bucket` | 同上 | 笔数分布桶宽 |
| `truncation_check` | 布尔 | 截断机制开关（会重建会话、清冻结仓后重算） |
| `boll_n` | ≥ 1 的整数 | BOLL 窗口 N |
| `donchian_n` | ≥ 1 的整数 | 唐奇安窗口 N |
| `regress_k` | > 0 的数字 | 回归通道带宽倍数 k |

> 设置面板里「筹码/笔数分布」总开关与桶宽输入框是**一处写两份**；走 API 时按 key 分开写，
> 要完全等价手动操作需同时设 `chip_enabled` + `tick_enabled`（桶宽同理：`chip_bucket` + `tick_bucket`）。

## 五、文件轮询通道（无 HTTP 客户端的 agent 用）

目录 `a_Data/agent_live/`：

| 文件 | 方向 | 说明 |
|---|---|---|
| `agent_api_token.txt` | App → agent | 当前会话令牌 |
| `state.json` | App → agent | 启动即写；每次命令执行后、每次步进合并后刷新 |
| `command.json` | agent → App | 写 `{"type": ...}` 即执行（按 mtime 判断新命令） |
| `result.json` | App → agent | 最近一条命令的执行结果 |

轮询周期 500ms。写 `command.json` 后稍等再读 `result.json` / `state.json` 即可。

## 六、PowerShell 快速验证（本机已实测）

```powershell
$token = Get-Content "D:\2\chan_month5\a_Data\agent_live\agent_api_token.txt"
$h = @{ 'X-Agent-Token' = $token }

Invoke-RestMethod -Uri 'http://127.0.0.1:12321/health'  -Headers $h
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/state'   -Headers $h
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/snapshot' -Headers $h

# 步进到第 10 根
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/command' -Method Post -Headers $h `
  -ContentType 'application/json' -Body '{"type":"step_to","idx":10}'

# 取最近 200 根 K 线 / 最近 20 条历史
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/klines?limit=200' -Headers $h
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/messages?limit=20' -Headers $h

# 切换指标 / 改参数
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/command' -Method Post -Headers $h `
  -ContentType 'application/json' -Body '{"type":"set_indicators","main_indicators":"K0,K0中枢"}'
Invoke-RestMethod -Uri 'http://127.0.0.1:12321/command' -Method Post -Headers $h `
  -ContentType 'application/json' -Body '{"type":"set_config","config_key":"boll_n","config_value":"15"}'

# 截屏存盘
Invoke-WebRequest -Uri 'http://127.0.0.1:12321/screenshot' -Headers $h -OutFile screenshot.png
```

## 七、实现与边界（诚实声明）

- 纯 Dart 新增层（`lib/agent_api/`），**不改 Rust、不改 FFI、不改缠论计算逻辑**；
  命令最终调用的都是主界面既有的按钮函数（`_stepForward`、`_loadKlines` 等）。
- 快照/工具行是**轻量组装**（OHLC + 中枢 + 分型 + 一类BS），不等同于
  `KlineChart` 内部完整 tooltip；需要逐字段比对时以画面 tooltip 为准。
- 截图是图表区域（`RepaintBoundary`），不含整个窗口边框与系统标题栏。
- `pid` 字段当前恒为 `0`：Dart 无跨平台读取当前进程 ID 的公开 API。
- `set_indicators` 的 label 一律从真实目录（`buildMainIndicatorCatalog` / `buildSubIndicatorCatalog`）反查，
  不硬编码指标名；查不到直接 `ok:false` 并逐条列出，不静默丢弃。
- `set_config` 的合法范围与 GUI 同口径（桶宽最小 0.01、2 位小数）；越界只回 `ok:false`，不改变状态。
- `/klines` 返回的是**当前会话已加载**的 K 线（与主图同源）；`period` 与会话不一致时拒绝，需先 `set_period` / `load_code`。
- 端口固定 `12321`；如与其它本地服务冲突需改代码常量 `_agentApiPort`。

---

*机器人验证见 [`ROBOT_VERIFY.md`](ROBOT_VERIFY.md)；其它协作规则见 [`AGENTS.md`](AGENTS.md)。*
