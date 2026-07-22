# test 自定义 OHLC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 CHAN_RUST 前端在选中 `test` 时可编辑任意 OHLC，持久化到 `a_Data/test/custom.ohlc.csv`，并直读加载到 K 线图。

**Architecture:** Rust `chan_data` 负责 CSV 读写与 `load_klines` 优先分支；`chan_ffi` 暴露保存接口；Flutter 设置面板在选中 `test` 时提供表格弹窗，经 FFI 写盘后走现有 `_loadKlines()`。

**Tech Stack:** Rust (`chan_data`/`chan_ffi`)、Flutter Dart FFI、CSV 文本文件

## Global Constraints

- 仅改 `test` 数据源；六位股票加载不变
- 自定义 OHLC 加载不做周期重采样
- 无 CSV 时回退现有分笔链路
- 设置面板保留历史记录三按钮；新操作写入历史记录
- 中文 UI；设置带说明弹窗
- 无用户明确要求不 git commit

## File Structure

| 文件 | 职责 |
|---|---|
| `CHAN_RUST/rust/chan_data/src/offline.rs` | CSV 路径、读写、校验；`load_klines` 优先分支 |
| `CHAN_RUST/rust/chan_data/src/lib.rs` | export `save_test_ohlc` / 相关 API |
| `CHAN_RUST/rust/chan_ffi/src/lib.rs` | `chan_save_test_ohlc` |
| `CHAN_RUST/flutter/chan_kline/lib/bridge/chan_bridge.dart` | `saveTestOhlc` |
| `CHAN_RUST/flutter/chan_kline/lib/widgets/test_ohlc_editor_dialog.dart` | 编辑弹窗 |
| `CHAN_RUST/flutter/chan_kline/lib/main.dart` | test 按钮接线、默认区间、历史记录 |

---

### Task 1: Rust OHLC CSV 读写 + load_klines 优先分支

**Files:**
- Modify: `CHAN_RUST/rust/chan_data/src/offline.rs`
- Modify: `CHAN_RUST/rust/chan_data/src/lib.rs`
- Test: 同文件 `#[cfg(test)]`

**Interfaces:**
- Produces:
  - `pub fn test_ohlc_csv_path(data_root: &Path) -> PathBuf`
  - `pub fn load_test_ohlc_csv(path: &Path) -> Result<Vec<KlineBar>>`
  - `pub fn save_test_ohlc_csv(path: &Path, bars: &[KlineBar]) -> Result<()>`
  - `pub fn save_test_ohlc(data_root: &Path, bars: &[KlineBar]) -> Result<()>`
  - `load_klines`：`code=test` 且 CSV 非空时直读并按 begin/end 过滤

- [ ] **Step 1: 写失败测试（读写往返 + 非法 OHLC + 优先直读）**

在 `offline.rs` tests 中新增（使用 `std::env::temp_dir()` 临时目录）：

```rust
#[test]
fn test_ohlc_csv_roundtrip_and_validation() {
    let dir = std::env::temp_dir().join(format!("chan_ohlc_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("custom.ohlc.csv");

    let bars = vec![
        KlineBar {
            idx: 0,
            time_ms: 0, // save 会按 time_text 重算也可；测试用明确值
            time_text: "2026/07/10 09:30:00".into(),
            open: 3.0, high: 4.0, low: 3.0, close: 4.0,
            volume: 100.0, amount: 0.0,
            metrics: Default::default(),
        },
        KlineBar {
            idx: 1,
            time_ms: 0,
            time_text: "2026/07/10 09:31:00".into(),
            open: 2.0, high: 3.0, low: 2.0, close: 3.0,
            volume: 0.0, amount: 0.0,
            metrics: Default::default(),
        },
    ];
    save_test_ohlc_csv(&path, &bars).unwrap();
    let loaded = load_test_ohlc_csv(&path).unwrap();
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].open, 3.0);
    assert_eq!(loaded[1].close, 3.0);
    assert!(loaded[0].time_ms > 0);

    let bad = vec![KlineBar {
        idx: 0, time_ms: 0, time_text: "2026/07/10 09:30:00".into(),
        open: 5.0, high: 4.0, low: 3.0, close: 4.0, // high < open
        volume: 0.0, amount: 0.0, metrics: Default::default(),
    }];
    assert!(save_test_ohlc_csv(&path, &bad).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn load_klines_prefers_custom_ohlc_for_test() {
    let root = std::env::temp_dir().join(format!("chan_ohlc_root_{}", std::process::id()));
    let test_dir = root.join("test");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&test_dir).unwrap();
    let bars = vec![KlineBar {
        idx: 0, time_ms: 0, time_text: "2026/07/10 09:30:00".into(),
        open: 1.0, high: 2.0, low: 1.0, close: 2.0,
        volume: 10.0, amount: 0.0, metrics: Default::default(),
    }];
    save_test_ohlc(&root, &bars).unwrap();
    let out = load_klines(
        &root, "test",
        "2026/07/10 09:00:00", "2026/07/10 10:00:00",
        KlinePeriod::Day, // 周期应被忽略
    ).unwrap();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].high, 2.0);
    let _ = std::fs::remove_dir_all(&root);
}
```

- [ ] **Step 2: 跑测确认失败**

Run: `cargo test -p chan_data test_ohlc_csv_roundtrip -- --nocapture`  
Expected: FAIL（函数未定义）

- [ ] **Step 3: 实现 CSV 读写与 load 分支**

要点：
- 常量文件名 `custom.ohlc.csv`
- 表头 `time,open,high,low,close,volume`
- `time` 解析复用 `parse_datetime_bound(..., Begin)`；`time_ms` 用 `Utc.from_utc_datetime`
- `time_text` 存完整到秒：`YYYY/MM/DD HH:MM:SS`（展示可与现网一致）
- `validate_ohlc_bar`：high/low 约束 + 时间严格递增
- `load_klines` 开头：若 `folder_from_code(code)=="test"` 且 CSV 存在，尝试 `load_test_ohlc_csv`；成功且过滤后非空则返回；文件不存在则回退分笔；文件存在但过滤后空则报「区间内无 K 线」

- [ ] **Step 4: 跑测通过**

Run: `cargo test -p chan_data test_ohlc -- --nocapture`  
Expected: PASS（含原 `load_test_stock_four_1m_bars` 在无 CSV 时仍过）

- [ ] **Step 5: Commit** — 跳过（除非用户要求）

---

### Task 2: FFI `chan_save_test_ohlc`

**Files:**
- Modify: `CHAN_RUST/rust/chan_ffi/src/lib.rs`
- Modify: `CHAN_RUST/rust/chan_data/src/lib.rs`（export）

**Interfaces:**
- Consumes: `save_test_ohlc(data_root, bars)`
- Produces: `extern "C" fn chan_save_test_ohlc(req_json: *const c_char) -> *mut c_char`
- JSON 入参：`{ "data_root": "...?", "bars": [ KlineBar... ] }`
- 出参：`{ ok: true, data: { "path": "...", "count": N } }`

- [ ] **Step 1: 实现并 `cargo build -p chan_ffi --release`**
- [ ] **Step 2: 复制 DLL 到 `CHAN_RUST/flutter/chan_kline/windows/native/chan_ffi.dll`**
- [ ] **Step 3: Commit** — 跳过

---

### Task 3: Flutter Bridge + 编辑弹窗 + main 接线

**Files:**
- Modify: `CHAN_RUST/flutter/chan_kline/lib/bridge/chan_bridge.dart`
- Create: `CHAN_RUST/flutter/chan_kline/lib/widgets/test_ohlc_editor_dialog.dart`
- Modify: `CHAN_RUST/flutter/chan_kline/lib/main.dart`
- Modify: `CHAN_RUST/flutter/chan_kline/lib/history/msg_history.dart`（仅若需追加口径说明常量；否则只 append 文案）

**Interfaces:**
- `ChanBridge.saveTestOhlc({String? dataRoot, required List<KlineBar> bars}) -> ({String path, int count})`
- `showTestOhlcEditorDialog(...)` 返回 `TestOhlcEditorResult?`：`{ bars, loadAfterSave }`

- [ ] **Step 1: Bridge 增加 `saveTestOhlc`**
- [ ] **Step 2: 实现中文表格弹窗（增删行、校验、帮助说明、保存/保存并加载/取消）**
- [ ] **Step 3: `main.dart`：选中 test 显示按钮；保存后可选 `_loadKlines`；选 test 且有 CSV 时用首末时间同步区间；历史记录文案按 spec**
- [ ] **Step 4: `flutter test` 相关冒烟（若有校验纯函数可单测；否则手动路径说明）**
- [ ] **Step 5: Commit** — 跳过

---

### Task 4: 验证与收尾

- [ ] Rust 全测 `cargo test -p chan_data`
- [ ] 确认无 CSV 时原 test 分笔用例仍过
- [ ] 历史记录口径写入（加载直读标记）
- [ ] 对照 spec 自检清单

## Spec Coverage

| Spec 项 | Task |
|---|---|
| custom.ohlc.csv 格式 | 1 |
| load 优先直读 / 回退分笔 | 1 |
| 忽略周期聚合 | 1 |
| save FFI | 2 |
| 编辑按钮 + 弹窗 + 帮助 | 3 |
| 保存并加载 / 仅保存 | 3 |
| 历史记录 | 3 |
| 默认区间用 CSV 首末 | 3 |
| 测试 | 1, 4 |
