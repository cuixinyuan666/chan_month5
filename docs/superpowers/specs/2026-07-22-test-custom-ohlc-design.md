# test 自定义 OHLC 设计（CHAN_RUST）

日期：2026-07-22  
范围：CHAN_RUST（Rust 数据层 + FFI + Flutter 设置面板）

## 目标

将股票选择中的 `test` 变为可在前端任意设置 OHLC（及时间、量），持久化到 `a_Data/test`，并直接加载到 K 线图。

## 已确认决策

| 项 | 决策 |
|---|---|
| 录入方式 | 直接编辑 K 线表（时间 + O/H/L/C，可选量） |
| 持久化 | 写入 `a_Data/test` |
| 存储格式 | 独立 OHLC CSV；选 `test` 时优先直读，跳过分笔聚合 |
| 与周期关系 | 编辑器行即最终 K 线；加载时不做周期重采样 |
| UI 入口 | 选中 `test` 后设置面板出现「编辑/加载自定义 OHLC」按钮 |

## 架构

### 数据流

1. 用户选中 `test` → 设置面板显示编辑按钮  
2. 打开表格弹窗 → 编辑 →「保存并加载」或「仅保存」  
3. Flutter 经 FFI 调用 Rust 写 `a_Data/test/custom.ohlc.csv`  
4. `_loadKlines()` → `chan_load_klines`：若 `code=test` 且 CSV 存在非空 → 直读 OHLC；否则回退现有分笔链路  
5. 后续逐 K / 合并 / Kn 流水线不变（仍吃 `List<KlineBar>`）

### 分层

- **Rust `chan_data`**：`load_test_ohlc_csv` / `save_test_ohlc_csv`；`load_klines` 在 `test` 优先走 OHLC  
- **`chan_ffi`**：新增 `chan_save_test_ohlc`；增强 `chan_load_klines`  
- **Flutter `ChanBridge`**：`saveTestOhlc(...)`  
- **Flutter UI**：`test_ohlc_editor_dialog.dart`；`main.dart` 仅接线  
- **历史记录**：保存/加载自定义 OHLC 写入 `msg_history`（常驻能力，不删入口）

## 文件格式

- 路径：`a_Data/test/custom.ohlc.csv`（固定文件名）  
- 列：`time,open,high,low,close,volume`  
  - `volume` 可空，默认 0  
  - `amount` 不强制录入，落盘/入图默认 0  
- `time`：`YYYY/MM/DD HH:MM:SS`（与现有加载区间文案一致）  
- 校验：
  - `high >= max(open, close)`
  - `low <= min(open, close)`
  - 时间严格递增
  - 非空表方可保存

## 加载分支

当 `code == test`（大小写按现有白名单口径）：

1. 若 `custom.ohlc.csv` 存在且解析出 ≥1 根有效 bar → **直读**，按 begin/end 过滤；**不做**分笔聚合、**不按周期重采样**  
2. 否则 → 回退现有 `YYYYMMDD_test.txt` 分笔 → 1m → 周期链路（兼容现状）

选中 `test` 时默认加载区间：若 CSV 已存在，可用文件内首末时间填 begin/end；否则保留现有标准区间。

## UI

- 仅 `_selectedCode == 'test'` 时显示：
  - 「编辑/加载自定义 OHLC」按钮
  - 帮助图标：弹窗说明操作逻辑与步骤（符合工程设置弹窗规范）
- 编辑弹窗：
  - 可增删行表格：时间、O、H、L、C、量
  - 打开时：有 CSV 则预填；否则预填当前图上 bars，或空表 + 一行模板
  - 「保存并加载」：写盘 → `_loadKlines()`
  - 「仅保存」：只写盘
  - 「取消」
- 校验失败：弹窗内红字提示，不关窗、不写盘

## 错误与历史记录

- 非法 OHLC / 时间乱序 / 空表 → UI 内错误，不写盘  
- IO / FFI 失败 → 面板错误文案 + 历史记录  
- 历史记录示例：
  - `test 自定义OHLC：保存N根 → a_Data/test/custom.ohlc.csv`
  - `加载K0：test ... 共N根（直读custom.ohlc.csv，忽略周期聚合）`

## 测试

- Rust：CSV 读写往返；非法行报错；无 CSV 时仍走分笔（保留/兼容 `load_test_stock_four_1m_bars`）  
- Flutter：可选轻量校验单测；调试用临时代码结束后删除

## 非目标

- 不改造真实六位股票的加载链路  
- 不在自定义 OHLC 路径上做周期重采样  
- 不把合成分笔写回 `*_test.txt`  
- 不删除设置面板「一键复制/查看历史记录/复制页面快照」

## 全层同构说明

本功能仅改变 `test` 的 **K0 数据来源**（CSV 直读 vs 分笔聚合）。K1/Kn 合并、分型、中枢、BSP 等仍基于已喂入 bars 的现有 step 流水线，全层行为不变。例外原因：数据源是输入层，不是结构层——写入历史记录便于复制排查。
