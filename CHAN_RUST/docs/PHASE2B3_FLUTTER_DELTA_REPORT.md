# Phase 2B-3: Flutter 接入 PipelineDelta

> 状态：**完成** | 日期：2026-08-13
> 目标：步进走 `chan_pipeline_append_delta` + presentation cache；**Full Path == Delta Path**。
> 禁止：改 Rust 算法、改 Delta 语义、改 Lookup 填表、二进制、字段级 patch、ZS/BS 优化。

## 1. 接入方式

| 路径 | 行为 |
|------|------|
| 默认步进 | 第 1 根 `chan_pipeline_append`（Full Snapshot 种 cache）；其后 `chan_pipeline_append_delta` + `mergeDelta` |
| `preferDelta: false` | 全程 Full（对照） |
| 旧 DLL 无符号 | 全程 Full |
| Delta 半成功 | `pipelineLen == _len+1` → `snapshot` 回填，**禁止再 append** |
| 步退 / 复位 | Rust `reset` + `cache.reset()`，再首包 Full + Delta replay |
| 十字 asOf | **仍** `buildKlineCombineBundle` 无状态短前缀 Full（未改） |

Dart 文件：

- `lib/models/pipeline_delta.dart` — JSON：`idx` + `bar_feature` + flatten 结构（无历史 `bar_features`）
- `lib/models/presentation_cache.dart` — `seedFromFull` / `mergeDelta` / `applyPipelineDelta`（只追加一行 feature，结构整包替换）
- `lib/bridge/chan_bridge.dart` — `ChanPipelineSession` 消费 Delta
- Lookup：只改 dartdoc，填表算法不变，`barFeatures` 来自 cache

## 2. 验收（002003 M1 `2004/07/19 10:47`–`2004/07/20 13:09`）

`flutter test test/pipeline_delta_session_test.dart`：**全部通过**。

| 项 | 结果 |
|----|------|
| step24→28 Full Path == Delta Path | 通过（含黄金 `buildKlineCombineBundle`） |
| reset+replay（29→28 根） | Delta 仓 == Full |
| asOf=24..28 无状态 Full == 会话 Delta 仓 | 通过 |
| History 一类 BS 双键追加 | Full/Delta 同序 |
| BS（1/2/N 买 + 1/2 卖）+ 中枢框 | `_bundleSig` 相等 |
| 副图 K0 分型判断 | 相等 |
| 十字 Lookup（weekday / combine_fx / merge_inner_seq） | 相等 |
| ML `MlFeatureFlat.flattenRow` 键与值 | 相等 |
| `mergeDelta` 错序拒绝 | `idx=1` 打空仓 → StateError |

N=200 另测：`Full Path == Delta Path` 通过。

## 3. 真实 UI profiling（Flutter FFI + decode + merge + Lookup）

同一 DLL、同一 `ChanPipelineSession.syncTo`（图表 `_bundleForVisible` 同路径）。

| 场景 | Full | Delta | Delta/Full |
|------|------|-------|------------|
| 002003 0..28 整段 sync | 108–249 ms | 49–59 ms | ~24–45% |
| 单步 27→28 | 7.3–8.1 ms | 2.7–3.2 ms | ~37–44% |
| 002003 N=200 整段 sync | 6173 ms | 2132 ms | **34.5%** |
| N=200 末步单步 | 49.9 ms | 15.5 ms | **31.1%** |
| Lookup.build N=29 | 13–220 ms（JIT 抖动） | 同左（算法未改） | — |
| Lookup.build N=200 | 1046 ms | 同左 | — |

说明：

- 单步 27→28 / N=200 末步：会话先回到 n-1（reset+replay），再测 **一根 append**（对齐连点「下一步」）。
- Lookup 仍全表填格，本阶段不优化；Delta 收益在 FFI JSON（砍掉历史 `bar_features`）。
- asOf / 首包仍走 Full，与设计一致。

## 4. 未做（按约束）

- 未改 `append` 判定 / `mark_x` / History 冻结 / asOf 语义 / V2.1 BS
- 未改 Delta JSON 形状、未接二进制、未做字段级 patch、未做 ZS/BS 优化
- 未改 Lookup 填表循环

## 5. 落盘

须将 `rust/target/release/chan_ffi.dll` 覆盖 `flutter/chan_kline/windows/native/chan_ffi.dll` 后冷启。旧 DLL 无 `chan_pipeline_append_delta` 时自动回退全程 Full。
