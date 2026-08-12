# Phase 2A: Snapshot / Output Profiling 报告

> 状态：**等待批准（不直接实现）** | 日期：2026-08-13
> 数据源：`profile_phase2a` N=2000 release + `flutter test test/phase2a_decode_profile_test.dart`
> 口径纠正：旧稿把 `BarFeature` 从 bundle 里再拆一次计入总计（feature 双计）。本版总计 = 真实 `chan_pipeline_append` 路径。

## 1. 测量环境

- 编译：`--release`，Rust 2021
- 输入：LCG 确定性随机游走 2000 根 K 线，产出 3 层
- 真实 FFI 路径：`append` → `bars().to_vec()` → `snapshot()` → `build_kline_combine_bundle_from_pipeline` → `serde_json::to_string(ApiOk { ok, data })`
- 额外（不计 step 总计）：`CString::new`、export/from_pipeline 子函数重跑
- Dart：末态单步 `jsonDecode` / `KlineCombineBundle.fromJson` / `collect*ByKn` / `BarFeatureLookup.build`（本轮未传 Math 冻结仓）
- 硬件：当前开发机

## 2. 分别测：append / snapshot / bundle / feature / serialization / Dart decode / render

### 2.1 Rust 真实 FFI 累计（无双计）

| 模块 | 累计耗时 (ms) | 占 step | 说明 |
|------|-------------|---------|------|
| **append** | 5,470.12 | **4.3%** | CombineEngine.feed + 分型确认 + 配对产段 + collect_k0 + 当步 snap push |
| **bars().to_vec()** | 1,110.83 | **0.9%** | `from_state` 全量克隆 K0 |
| **snapshot** | 14,525.71 | **11.5%** | `LevelState::export` × 全层 + 全历史 snaps 克隆 |
| **from_pipeline (bundle)** | 25,762.14 | **20.3%** | 含 feature / k1_combine / K0 ZS/BS 再算 / 字段映射 |
| **serialize (JSON ApiOk)** | 79,783.94 | **63.0%** | 对齐 `to_json_ok` |
| **step 合计** | 126,652.73 | 100% | |
| **CString::new** | 17,063.28 | +13.5% | FFI 必经再拷一份；未计入上表 step |
| **append / step** | | **4.32%** | |
| **step / append** | | **23.2x** | 计入 CString 后 **26.3x** |

末态 FFI JSON：**6,376,637 bytes**（~6.08 MB）。

最近 50 根均值：n=100 → 5.9 ms/step；n=2000 → **126.7 ms/step**（相对 n≈75 为 21.6x）。

### 2.2 Dart 末态单步（不是 2000 步累计）

| 模块 | ms | 说明 |
|------|-----|------|
| jsonDecode | 423.43 | 6.37 MB 文本 → Map |
| fromJson | 288.52 | `KlineCombineBundle` 整表对象化（barFeatures=2000, levels=3） |
| collect*ByKn | 17.73 | 会话 merge 同类采集 |
| **BarFeatureLookup.build** | **2,669.92** | 十字/ML 查表；本轮无 freeze，含 Math/背驰/三型四型现场算 |
| tooltip 1 根 | 50.38 | 跟手，非每步全量 |
| **Dart 合计（decode+lookup）** | **3,399.61** | |
| CustomPaint | 未测 | 默认主图相对 lookup 通常小一个数量级；painter 为私有类型 |

用户可见末态单步 ≈ Rust 127ms + CString ~8ms + Dart 3.4s ≈ **3.5s**。

## 3. append 与真实 step 总耗时的差值来源

append 只占 4.3%。其余 95.7% 全部在输出管道，不是缠论判定变慢。

```
chan_pipeline_append
  ├─ append                         4.3%   算法（本轮禁止改）
  ├─ bars().to_vec()                0.9%   可引用，不必拷
  ├─ snapshot()                    11.5%   几乎全是全历史 clone
  ├─ from_pipeline()               20.3%   feature 重建 + K0 ZS/BS 再算 + 映射
  ├─ serde_json ApiOk              63.0%   全量 JSON，79.5% 是 bar_features
  └─ CString::new                 +13.5%   再拷 6.4MB × N
Dart
  ├─ jsonDecode + fromJson         末态 0.71s
  └─ BarFeatureLookup.build        末态 2.67s（无 freeze）
```

K0 中枢/一类 BS 每步最多算三次：`collect_k0_struct_hits`（append 内）→ `export` 各层 `find_zs`/`find_buy*` → `build_k0_zs_and_bs1`（bundle 内再来一遍）。后两次是出口重复，不是新判定。

## 4. 逐函数 profiling

### 4.1 `LevelState::export` / `PipelineState::snapshot`

| 子项 | 累计 ms | 结论 |
|------|---------|------|
| clone `bar_level_snaps` / `bar_k_snaps` / `bar_seg_rows` / `bar_struct_hits` | 16,183.50（代理重跑） | **snapshot 主开销** |
| clone confirms / segments / unit_bars / combine_frames | 2,583.27 | 冻结历史整表拷 |
| `find_zs_with_confirmed` 全层 | 51.24 | 可忽略 |
| `find_buy/sell 1/2/n` 全层 | 29.06 | 可忽略 |

`export` 里的 ZS/BS 重算不是瓶颈；瓶颈是把已经 `push` 进去的逐 K 快照每步再 `clone` 一遍。

### 4.2 `build_kline_combine_bundle_from_pipeline`

| 子项 | 累计 ms | 占 bundle |
|------|---------|-----------|
| BarFeature 逐根（`levels.clone()` + hits.clone + `enrich_fractal_peak_dist`） | 13,039.13 | 50.6% |
| 字段映射 / k1_analysis / collect | ~8,488 | 32.9% |
| `build_k0_zs_and_bs1`（与 append `collect_k0` 重复） | 4,171.72 | 16.2% |
| `build_k1_combine_frames_with` | 63.49 | 0.2% |

### 4.3 BarFeature 构建

每根：`weekday_from_bar` + 字段映射 + **`bar_level_snaps[i].clone()`** + hits clone，再线性 `enrich_fractal_peak_dist`。主开销是每步对 0..n-1 全部再克隆一层 `Vec<LevelSnap>`。历史行冻结后内容不变。

## 5. 输出数据生命周期

### 5.1 永久冻结（append 后不改，只追加）

| 字段 | 所在 | 说明 |
|------|------|------|
| `confirms` / `segments` / `unit_bars` | `LevelBundleOut` | 写入后不回写 |
| 已关闭 `zs_frames`（`is_sure=true`） | 各层 | 离开定型后冻结 |
| `bar_k_snaps[i]` / `bar_level_snaps[i]` / `bar_struct_hits[i]`（i &lt; 当前） | `PipelineState` | 当步 push 后冻结 |
| `bar_features[i]`（i &lt; 当前） | bundle | 与上同源，禁止未来回写 |
| `first_dir` / `first_dir_x` | 层 | 一旦设值不改 |
| `k0_confirms` / `k0_lines` | bundle | = levels[0] 映射 |

### 5.2 当前 step（只新建一行）

当根 `bar_*_snaps`、当根 `bar_struct_hits`、当根 `BarCrosshairFeature`。

### 5.3 active（每步可漂，必须快照拷贝）

`active_unit`、未确认末枢、动态 BS 的展示 x、末合并组 `x2`。Dart 用当步覆盖，**不得回写旧冻结行**（对齐 mark_x / V2.1 / asOf）。

### 5.4 可以引用（不要拷）

`PipelineState.bars`、`engine.groups()`、内部已 push 的 snaps `Vec`、Dart 会话已持有的冻结 history。

### 5.5 必须复制（跨 FFI / 跨步隔离）

active 快照、当步新行、asOf 前缀对照用的 Full Snapshot。现状把 5.1 也整表复制了——这是浪费。

## 6. Full Snapshot vs Delta Output

### 方案 A：Full Snapshot（当前）

每步 clone 全历史 + 全量 JSON + Dart 整表 fromJson。实现简单，与 `run_pipeline` / 十字 asOf 前缀重放一致。代价：step/append=23.2x；n=2000 单步 6.4MB。

### 方案 B：Hybrid Delta（推荐）

- **步进**：只发当步冻结行 + active 快照 + 新确认/新段/新框。
- **Full Snapshot**：保留给 asOf、黄金对照、`buildKlineCombineBundle` 无状态路径、首包。
- Dart 已有 `_mergeBsHistory` / `MathSeriesFreezeStore` / `DivergenceFreezeStore`，与「历史在会话、当步只追加」同构。

| 指标 | Full | Hybrid Delta（预期） |
|------|------|----------------------|
| snapshot 全历史 clone | 11.5% | ~0 |
| feature 全表重建 | ~10% | 只建当步 |
| JSON | 63%，O(N) | O(1) 变化集 |
| Dart decode/fromJson | 末态 0.71s | 降一个数量级 |
| Lookup | 末态 2.67s 冷路径 | 需单独增量，否则用户可见步仍可能 &gt;1s |
| step/append | 23.2x | 2B-1 后 &lt;10x；2B-2 后 &lt;5x |

风险：Dart 协议要双路径（delta + full）；active 必须拷快照；禁止把动态 x 回写进旧 feature 行。

## 7. JSON serialization 是否已成为主要瓶颈

**Rust 步内：是（63%）。根因是数据量，不是 serde 实现慢。**

体积：`bar_features` 5,066,078 bytes（**79.5%**），`levels` 5.6%，`frames` 5.5%，`k1_analysis` 3.2%，`sell1_k0_frames` 3.1%，`zs_k0_frames` 2.9%。

换 MessagePack/FlatBuffers 只抠常数，不改变每步 O(N) 全量。gzip 再加 CPU，对步进不划算。

**用户可见步：JSON decode+fromJson（0.71s）已超过 Rust 整步（0.13s），但无 freeze 的 Lookup（2.67s）更大。** 只压 JSON 不够。

## 8. 优化方案（等待批准）

### 不变项

不改：`CombineEngine`、`find_zs` / `find_buy1·2·n` 判定、`mark_x` / `discoveryX`、History / asOf、V2.1 BS、逐K冻结语义、全层同构。只动输出管道与 FFI/Dart 协议。

### 按 ROI

| 优先级 | 项 | 预期 | 复杂度 | 风险 |
|--------|----|------|--------|------|
| **P0** | snapshot 不再全历史 clone（内部只读/Arc，只拷 active） | Rust −11% | 低 | 低 |
| **P0** | bar_features 只构建当步一行 | Rust bundle −10% | 中 | 低（历史行已冻结） |
| **P0** | 步进 Delta JSON；Full 留给 asOf/对照 | JSON/decode −90%+ | 高 | 中（Dart 协议） |
| **P1** | 删除 `build_k0_zs_and_bs1`，复用 collect_k0 / export 帧 | 累计 −4s | 低 | 低（只去重复出口） |
| **P1** | 去掉 CString 二次拷贝 | FFI −17s 累计 | 低 | 低 |
| **P1** | Dart Lookup 增量追加 `byIdx[n-1]`；三型/四型不要对每根重扫 | 末态单步 −2s 级 | 中 | 中（禁未来、asOf） |
| **P2** | `bars()` 引用，去掉 `to_vec` | −0.9% | 低 | 低 |

### 实施顺序

```
Phase 2B-1  去重复出口（仍 Full JSON）
  ├─ snapshot 不克隆历史 snaps
  ├─ bar_features 只建当步
  └─ 复用 K0 ZS/BS 帧，删 bundle 内重算

Phase 2B-2  Delta 协议
  ├─ FFI 步进返回变化集；Full 仍可 snapshot
  ├─ Dart 增量 merge（对齐现有 history 冻结）
  └─ 去掉 CString 双拷

Phase 2B-3  Dart Lookup 增量
  └─ byIdx 追加；Math 继续走 freeze；三型/四型按 asOf 增量
```

### 验收

- [ ] `cargo test` 全部通过（`assert_pipeline_dual_eq`）
- [ ] `profile_phase2a` N=2000 Rust step/append &lt; 10x（2B-1）、&lt; 5x（2B-2）
- [ ] Delta 与 Full 语义等价（冻结行逐字段比对；active 允许当步不同）
- [ ] 冷启动**连续单步**（禁止一键跳末）：点出现后下一步仍在；十字 asOf 不消点
- [ ] 不改 mark_x / discoveryX / History / asOf / V2.1 BS

## 9. 复现命令

```
cd CHAN_RUST/rust
$env:DUMP_JSON="1"; cargo run --release --example profile_phase2a -p chan_data -- 2000

cd CHAN_RUST/flutter/chan_kline
flutter test test/phase2a_decode_profile_test.dart
```
