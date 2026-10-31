# App 从 Telegram bot 精准取数 · 实施方案（待确认）

> 状态：**方案待用户确认**，未改任何 App 代码。
> 前置：全 A 股日线已按「一只股票一个 CSV」上传到用户自己的 Telegram bot，并附 `index.json`。

## 一、目标

App 后续加载某只股票时，不再逐日向通达信拉分笔，而是**只向 Telegram bot 取这一只股票的文件**（精准到代码），
取回后按现有 `KlineBar` 口径上图。原有通达信通道保留，可切换、可回退。

## 二、数据组织（已按此导出）

```
bot 聊天记录
├── sz000001.csv        每只股票一个文件，文件名 = 交易所前缀 + 6 位代码
├── sh600519.csv
├── ...
└── index.json          code -> { file_id, message_id, name, bars, first, last, market }
```

- 单文件体积：几十 KB ~ 几百 KB（远小于 Telegram 50MB 上限）。
- `index.json` 约 1~2 MB，App 首次启动拉一次并本地缓存。

## 三、App 侧取数流程（精准）

1. 用户在设置里填：`bot token`、`chat id`（只存本机）。
2. 首次/缓存过期时：`getFile(index_file_id)` → 下载 `index.json` → 缓存到 `a_Data/.telegram_cache/index.json`。
3. 用户选股 `000001`：
   - 查索引拿到该股票的 `file_id`；
   - `getFile(file_id)` → 下载 `sz000001.csv`（只下这一只）；
   - 解析为 `List<KlineBar>`，按用户选择的起止日期/周期过滤；
   - 交给现有加载管线（与本地/通达信同一条 `_loadKlines` 出口）。
4. 失败回退：索引缺失/文件被删/网络失败 → 提示并回退通达信协议。

## 四、改动范围（预估）

| 文件 | 改动 |
| --- | --- |
| `lib/data/telegram_data_source.dart` | 新增：Telegram Bot API 客户端（getFile/下载/索引缓存/CSV 解析） |
| `lib/settings/*` | 新增：数据源选择（本地 / 通达信 / Telegram）+ token/chat_id 设置项与说明弹窗 |
| `lib/main.dart` | `_loadKlines` 增加 Telegram 分支（复用现有 K 线装载出口） |
| `test/data/telegram_data_source_test.dart` | 新增：索引解析、CSV 解析、缺失回退的单测 |

**边界**：不改 Rust 缠论内核、不改 `chan_bridge` 管道、不改步进/冻结语义；Telegram 只是「取 K 线/分笔」的又一个数据源。

## 五、分笔数据（新增 · 2026-10-31）

- **数据源**：通达信 `0x0fc6`（带笔数、买卖方向），与 App 现有 `.tdx_protocol_cache/<code>/<date8>_<code>.txt` **同格式**。
- **导出器**：`cargo run --release -p chan_data --example export_all_ticks`（参数 `--begin/--end/--codes/--threads/--cache-root`）。
- **智能体验证驱动**：App 设 `CHAN_AGENT_API=1` 后，`POST /command`：`type=export_ticks`，字段 `code=000001,600519`（逗号分隔）、`begin/end=YYYYMMDD`、`quantity=线程数`；进度与异常：`GET /export_task?task_id=…`。
- **全历史体量（实测外推）**：3 只 × 4 交易日 ≈ 1.1 MB、5.1 万行 → 约 **94 KB/股票·日**；全 A 约 5223 只 × 5000 交易日 ≈ **2.4 TB**，Telegram 与单机磁盘均不现实。**全量拉取前必须先约定时间窗口**（例如最近 20 个交易日 ≈ 10 GB 量级）。

## 六、需要用户提供

1. `TG_BOT_TOKEN`（@BotFather 生成）
2. `TG_CHAT_ID`（与 bot 的会话 id；可先给 bot 发一条消息，再用 `getUpdates` 取）
3. 确认是否同意按上面「新增数据源、不动计算内核」的方式改 App。
