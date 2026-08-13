# Phase 2B-2: PipelineDelta 无损重建 Full Snapshot

> 状态：**完成并停止** | 日期：2026-08-13
> 唯一目标：证明 Full Snapshot 可被 Delta 无损重建。
> **未**接 Flutter UI、**未**改 Dart Lookup、**未**改二进制协议。Full Snapshot 保留。

## 1. 范围

允许：`PipelineDelta`、`PipelineState::append_delta()`、FFI `chan_pipeline_append_delta`、Delta 测试、bytes/serialization profiling。

禁止：缠论算法、`append()` 判定、`mark_x` / `discoveryX` / History / asOf / V2.1 BS、删除 Full Snapshot、Flutter / Dart Lookup / 二进制。

## 2. 设计（Hybrid Delta）

当步 Delta = **1 行 `bar_feature`** + **其余 bundle 字段当步全量**。

- `bar_features` 历史行冻结，只追加当步一行（占 Full JSON ~80%）。
- 其余字段（`levels` / 中枢 / BS / `k1_analysis` / 合并框 / active）会改旧框，本阶段不做字段级 patch，整包替换以保证无损。

重建：

```
acc = empty()
for d in deltas { apply_pipeline_delta(&mut acc, d) }
serde_json(acc) == serde_json(full_snapshot)
```

`append_delta()` = 先调用现有 `append()`（不改判定），再 `from_state` 抽 Delta。  
`chan_pipeline_append` / `chan_pipeline_snapshot` 仍返回 Full Snapshot。

## 3. 测试（无损证明）

`cargo test -p chan_data --release`：**121 passed / 0 failed**。

| 测试 | 证明 |
|------|------|
| `delta_reconstructs_full_each_step_zigzag` | 每步累加 Delta == `from_state` Full == 黄金 `run_pipeline` |
| `delta_batch_reconstruct_equals_final_full` | 空仓一次吃完全部 Delta == 末态 Full |
| `delta_does_not_rewrite_old_bar_features` | 旧 `bar_features` 行不被回写 |
| `delta_002003_steps_24_28_and_reset_replay` | 002003 step24–28；reset 后用已记录 Delta 重建到 step27 |
| `delta_json_has_single_bar_feature` | Delta JSON 无 `bar_features` 数组，只有当步 `bar_feature` |

`chan_ffi` release 编译通过（新增 `chan_pipeline_append_delta`）。未覆盖 DLL、未接 Dart。

## 4. Bytes / serialization（与 2A/2B-1 同 LCG 数据）

profiler：`cargo run --release --example profile_phase2b2 -p chan_data -- N`  
每组末行 `reconstruct JSON eq Full : true`。

| N | 末步 Full | 末步 Delta | Delta/Full | 累计 Delta/Full | Full ser | Delta ser | ser 比 |
|---|-----------|------------|------------|-----------------|----------|-----------|--------|
| 200 | 507,224 | 127,936 | **25.2%** | 26.1% | 1,499 ms | 302 ms | 20.1% |
| 500 | 1,299,978 | 325,991 | **25.1%** | 25.4% | 6,174 ms | 1,293 ms | 20.9% |
| 1000 | 2,992,205 | 656,570 | **21.9%** | 23.6% | 29,059 ms | 5,451 ms | 18.8% |
| 2000 | 6,376,637 | 1,313,303 | **20.6%** | 21.6% | 100,238 ms | 17,468 ms | **17.4%** |

N=2000 末步拆分：`bar_feature` 一行 2,734 B；`structure` 当步全量 1,310,524 B（仍含 `k1_analysis.bar_sub_snapshots` 等 O(N) 字段）。

与 2B-1 对照：Full 仍 ~6.08 MB；Delta 切掉历史 `bar_features` 后约 **1.25 MB**，体积/序列化都降到 Full 的约 1/5。

## 5. 结论与停止点

- **已证明**：按序应用 Delta 可无损重建 Full Snapshot（JSON 逐字段相等），含 002003 step24–28 与 reset 后用 Delta 重建。
- Full Snapshot 入口保留。算法 / `append` / mark_x / History / asOf / V2.1 未改。
- **2B-2 停止点已完成。** Flutter 接入见 `PHASE2B3_FLUTTER_DELTA_REPORT.md`（Lookup 填表仍未改；structure 仍 O(N)）。
