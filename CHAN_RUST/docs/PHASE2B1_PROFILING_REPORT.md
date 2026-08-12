# Phase 2B-1: 去重复出口（仍 Full Snapshot JSON）

> 状态：**完成并停止** | 日期：2026-08-13
> 本阶段**不进入 2B-2**（Delta / 二进制 / Dart Lookup）。
> 对照基线：`docs/PHASE2A_PROFILING_REPORT.md`（N=2000 step/append = 23.2x）

## 1. 范围

只消除 Rust 输出链的重复计算和全量 clone，不改变算法和既有语义。

允许改：`PipelineState::snapshot`、`LevelState::export`（本轮未改判定，仍每步 export）、`build_kline_combine_bundle_from_pipeline` / `from_state`、BarFeature 构建、K0 ZS/BS 重复出口。

禁止改：`mark_x` / `discoveryX` / History / asOf / V2.1 BS / `find_zs` / `find_buy1/2/n` / `CombineEngine` / `PipelineState::append` 核心判定。

约束：FFI 仍 Full Snapshot JSON；`run_pipeline` 仍是黄金参考；`append()` 仍是正确性基线。

## 2. 做了什么

| 项 | 做法 |
|----|------|
| 历史 `bar_*` 不再每 step 全量 clone | `PipelineResult` / `PipelineState` 的 `bar_level_snaps` / `bar_k_snaps` / `bar_seg_rows` / `bar_struct_hits` 改为 `Arc<Vec<_>>`；snapshot 只 `Arc::clone`；append 在唯一引用时 `Arc::make_mut().push` |
| BarFeature 当前 step 增量 | `PipelineState.bar_features` 增量仓；`ensure_bar_features()` 只为新 K 追加一行；`fractal_peak_dist` 用与全量 `enrich_fractal_peak_dist` 同口径的 `fractal_peak_dist_at` |
| 删除 bundle 内重复 K0 ZS/BS | `collect_k0_struct_hits` 顺带产出未钉 x 的 K0 帧（`compute_k0_zs_bs`）；`from_state` 复用，不再第二次 `find_zs`/`find_buy*` |
| bundle 引用已有 state | `from_state` 不再 `bars().to_vec()`；热路径 `from_snapshot` 共享 `bar_features` Arc |
| FFI 协议 | 未改。`KlineCombineBundle.bar_features` 内部是 `Arc<Vec<_>>`，serde `rc` 仍序列化成 JSON 数组 |

未改：`append` 的 propagate / 引擎 / 分型配对；黄金路径 `run_pipeline` + `from_pipeline` 仍全量建 feature、仍自己算一遍 K0 帧（对照用，非热路径）。

附带：`collect_k0` 现在一次算出六路 BS（原先只算一类，bundle 再算一遍）。append 略增，bundle 热路径不再重算。净 step 下降。

## 3. 测试

`cargo test -p chan_data --release`：**116 passed / 0 failed**。

点名复跑：

- `combine::tests::state_bundle_002003_steps_24_28`（含 reset+replay step27）
- `combine::tests::state_bundle_matches_golden_run_pipeline`
- `pipeline::tests::dual_path_002003_steps_24_28_and_active`
- `pipeline::tests::dual_path_final_eq_zigzag`
- `pipeline::tests::dual_path_each_step_and_no_future_zigzag`

全部通过。`chan_ffi` release 编译通过。本轮未覆盖 DLL、未改 Dart。

## 4. Profiling（与 2A 同口径：release LCG 随机游走，3 层）

热路径：`append` → `snapshot`（含 feature 增量）→ `from_snapshot`（复用 feature / K0 帧）→ JSON。已删除 `bars().to_vec()`。

### 4.1 N=2000 对比 2A

| 模块 | 2A (ms) | 2B-1 (ms) | 占 2B-1 step |
|------|---------|-----------|--------------|
| append | 5,470 | 5,958 | 7.2% |
| bars().to_vec() | 1,111 | **0** | 已删 |
| snapshot | 14,526 | **1,890** | 2.3% |
| bundle（from_pipeline / from_snapshot） | 25,762 | **2,336** | 2.8% |
| serialize JSON | 79,784 | 72,653 | **87.7%** |
| **step 合计** | **126,653** | **82,837** | 100% |
| CString（未计入 step） | 17,063 | 14,365 | |
| **step / append** | **23.2x** | **13.9x** | |

clone `bar_*` 代理：2A 16,184 ms → 2B-1 **1.3 ms**（Arc O(1)）。

对照（不计入总计，热路径已消除）：全量 BarFeature 重建 12,689 ms；bundle 内 K0 ZS/BS 3,587 ms。

append 从 5.47s 升到 5.96s：`collect_k0` 补上二类/三类+，避免 bundle 再算。按要求**没有去优化已约 4–7% 的 append**。

### 4.2 各 N

| N | append (ms) | snapshot | from_snapshot | JSON | step | step/append | 末态 JSON |
|---|-------------|----------|---------------|------|------|-------------|-----------|
| 200 | 129 | 42 | 30 | 1,006 | 1,207 | **9.4x** | 0.51 MB |
| 500 | 594 | 92 | 224 | 3,794 | 4,704 | **7.9x** | 1.24 MB |
| 1000 | 1,749 | 442 | 660 | 16,745 | 19,595 | **11.2x** | 2.85 MB |
| 2000 | 5,958 | 1,890 | 2,336 | 72,653 | 82,837 | **13.9x** | 6.08 MB |

JSON 仍占 step 的 80–88%；`bar_features` 仍占 JSON 体积 **79.5%**（与 2A 相同，协议未改）。

## 5. ≤10x 目标

本阶段目标：step/append 从约 24x 降到 **≤10x**。

- N=200 / 500：已 ≤10x。
- N=1000：11.2x；N=2000：**13.9x**，未到 10x。

墙在 **Full Snapshot JSON**（N=2000 占 87.7%）。2B-1 只去 clone/重复计算，协议仍每步吐全表，JSON 体积与 2A 相同（~6.08 MB），无法靠本阶段再压到 10x。

非 JSON 部分（append+snapshot+bundle）N=2000：约 10.2s / 5.96s ≈ **1.7x**。输出链重复已基本挖完。

## 6. 结论与停止点

- 测试全过；step/append **明显下降**（23.2x → 13.9x，step 126.7s → 82.8s）。
- N=2000 未到 ≤10x，原因是 FFI 仍 Full JSON，不是 append/判定。
- **停止。不自行做 2B-2**（Delta JSON / 二进制 / Dart Lookup）。
- 进入 2B-2 的前提仍是：协议允许步进 Delta（Full 留给 asOf/对照）。
