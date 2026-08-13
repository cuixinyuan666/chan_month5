# Phase 2B-3：Presentation Lookup 增量化（profiling + 设计）

> 状态：**profiling + 设计完成，等待批准后实现** | 日期：2026-08-13  
> 范围：仅 Flutter/Dart presentation/cache。  
> **本阶段未实现** Lookup 增量。未改 Rust / append / Delta / mark_x / History / asOf / V2.1 BS / ZS·BS 算法 / FFI。

先前「2B-3 Flutter 接入 Delta」已完成（`PHASE2B3_FLUTTER_DELTA_REPORT.md`）。本文件是其后半：消除每步 `BarFeatureLookup.build` 全量重建。

---

## 1. Profiling（末步，对齐连点「下一步」）

探针：`flutter test test/phase2b3_lookup_profile_test.dart`  
数据：002003 M1 能凑满则用真数据，否则 zigzag 补到 N=2000。本次跑满 2000 根。  
Lookup 入参与 tooltip 同口径：`buildSubIndicatorCatalog` 全集 + `asOf=last`。

### 1.1 七段拆分（末步）

| N | Delta JSON | FFI 取串 | jsonDecode | fromJson | mergeDelta | **Lookup.build** | 第 2 次 Lookup | 副图准备 | tooltip 行 | ML flatten |
|---|------------|----------|------------|----------|------------|------------------|----------------|----------|------------|------------|
| 200 | 174 KB | 7 ms | 11 ms | 4 ms | **0 ms** | 900 ms（含 JIT） | **397 ms** | 94 ms（JIT） | 41 ms | 12 ms |
| 500 | 437 KB | 15 ms | 21 ms | 13 ms | **0 ms** | 527 ms | **880 ms** | 4 ms | 2 ms | 4 ms |
| 1000 | 906 KB | 23 ms | 34 ms | 20 ms | **0 ms** | 1415 ms | **1579 ms** | 4 ms | 2 ms | 3 ms |
| 2000 | 1.86 MB | 51 ms | 78 ms | 65 ms | **0 ms** | 5355 ms | **5539 ms** | 13 ms | 4 ms | 5 ms |

Lookup 占末步 Dart 成本：**85% → 96%**（N=200 → 2000）。

Delta 路径（ffi+decode+fromJson+merge）N=2000 ≈ **194 ms**。  
Lookup 第 2 次 ≈ **5539 ms** ≈ Delta 路径的 **28 倍**。

### 1.2 Lookup 是否仍全量 O(N)？

第 2 次 Lookup（JIT 后更稳）：

| N | Lookup | /N=200 | 若纯线性应约 |
|---|--------|--------|--------------|
| 200 | 397 ms | 1.0× | 1.0× |
| 500 | 880 ms | 2.2× | 2.5× |
| 1000 | 1579 ms | 4.0× | 5.0× |
| 2000 | 5539 ms | **13.9×** | 10× |

结论：**仍是每步对完整历史 `build`。** N=2000 已超线性（三型/四型对 **每一根** `collectLevelFxPoles(asOf: b.idx)`）。不是「只追加当前行」。

`mergeDelta` 恒 ≈ 0 ms，不再是墙。

### 1.3 副图 / tooltip / render

- **副图数据准备**（成交量/笔数全层 + 分型判断/ZS/BS collect）：JIT 后 **4–13 ms**，相对 Lookup 可忽略。但 paint 里 **再算一遍** 与 Lookup 内 `computeAllKnVolumeSeries` 重复。
- **tooltip 行**（`crosshairTooltipRows`）：Lookup 已建好时 **2–4 ms**。贵的是建表，不是排版。
- **render pump N=200**：`KlineChart` 首帧 **3442 ms**。原因：`_KlineCompositePainter` **构造函数**里对 **base + crosshair 两层各 `BarFeatureLookup.build` 一次**（chip 层走 empty）。十字 tooltip 路径还会 **再 build 第三次**。

### 1.4 当前调用点（每步 / 每帧）

| 位置 | 何时 | 全量 build？ |
|------|------|--------------|
| `_KlineCompositePainter(...)` base | 每次 Widget `build` | 是 |
| `_KlineCompositePainter(...)` crosshair | 每次 Widget `build` | 是 |
| `_crosshairTooltipRows` | 十字+tooltip | 是（第三次） |
| `main._buildMlLookupFor` | 跳末采样 | 是 |

十字移动：`shouldRepaint` 虽分层，**构造仍先跑 Lookup**。

---

## 2. 数据分类（设计口径）

### 2.1 永久冻结（写入后禁止回写）

与现有 History / Math 冻结同构：

- `bar_features[0..n-2]` 行（Delta 已只追加）
- 一类/二类/N 类 BS 历史点（稳定键 + 颗粒度键含 x）
- 分型判断 / 中枢判断 / 中枢确认 事件日志
- 相邻比例 / 节奏 / 斜率 历史点
- `MathSeriesFreezeStore` / `DivergenceFreezeStore` 首次非空格

Lookup `byIdx[x]` 里由上述派生的 **历史格**（`buy1_*`、`fractal_judgment_*`、`macd_*`、`zs_sure==1` 的框覆盖等）应同样冻结。

### 2.2 只追加

- 新 K0 的 `byIdx[stepIdx]` 行（OHLC + 当步 `bar_feature`）
- 当步新打点的 History 事件 → 只写 `byIdx[event.x]`
- Math 冻结仓：只填新出现的 null 格，再抄到当步行

### 2.3 当前 step 可替换（不得扫全历史重写）

结构来自 Delta 的「当步整包」，但 **投影到 Lookup 时只打脏区间**：

| 对象 | 替换范围 |
|------|----------|
| 末根 / 构建中合并框 | `x1..x2`（GG/DD、MG/MD、`combine_fx`） |
| 未确认中枢 | 该框 `x1..x2` 的 zg/zd/sure |
| `level_confirms[current x]` | 单格 |
| `k1_snapshot[current idx]` | 单格 |
| 三型/四型/趋势线读数 | **只算 asOf=当前 x**（禁止对历史 x 重跑） |
| 展示轨虚线 / active 单元 | 当前可见未冻段 |

已 `is_sure` 的中枢框、已确认分型格、已冻结 BS 格：不替换。

### 2.4 受 asOf 影响

- **十字 asOf**：层结构仍走无状态 `buildKlineCombineBundle(prefix)`（**不改 asOf 语义**）。
- 冻结特征格：`x<=asOf` 可读，`x>asOf` 不展示（与现在 Lookup 内 `if (x>asOf) continue` 同义）。
- 构建中框 / 未确认中枢：必须用 **asOf 前缀的结构**，不能用会话末态裁 x（现口径：失败=空，禁回落末态）。
- **增量仓只管会话末态（步进）**；asOf 用「冻结格过滤 + asOf bundle 覆盖脏结构字段」，禁止为挪十字而全表 `build`。

### 2.5 历史重复计算（build 里现在每步全干）

`BarFeatureLookup.build` 对 **每一根已喂入 K**：

1. 重建整张 `byIdx` Map  
2. 合并框扫 `x1..x2`；Kn GG/DD 再扫全部 bars  
3. 成交量/笔数 B/S/G 全层全序列（paint 再算一遍）  
4. BS/判断/中枢/比例/节奏：history → **全长 series** → 再写全部 bars  
5. **三型/四型**：`for dkn × for b in bars: collectLevelFxPoles(asOf: b.idx)` → 近 **O(层 × N × 确认数)**  
6. 趋势线同样按柱 asOf  
7. Math/背驰：有冻结仓则免重算序列，仍 **抄写全部 idx**  
8. `_writeZsFeaturesIntoSub` 扫所有框覆盖的所有 x  

另：Painter ×2 + tooltip ×1 把上述再乘 2～3。

---

## 3. 方案比较与最小增量建议

### 方案 B（仅外提，不改填表）

Lookup 挪到 `State` / `PresentationCache`，Painter 只收现成表。  
**收益**：每帧 2～3 次 → 1 次；算法仍 O(N)/超线性。  
**不够**：N=2000 末步仍 ~5 s。

### 方案 C（冻旧行 + 每步仍全量 build 末行）

拷贝 `byIdx[0..n-2]`，再跑现在的 `build`。  
**仍扫全输入**，三型循环仍在。几乎无 CPU 收益。

### 方案 A（推荐）：增量 `BarFeatureLookup`

不改 Rust、不改 Delta、不改 History 合并、不改 Lookup **格点语义**（键名/ML flatten 与现 `build` 一致）。

最小落地（按收益排序，可一批做完）：

1. **Lookup 实例挂在 presentation 层**（随 `PresentationCache`）  
   - `seedFromFull` / `reset` 时 `lookup.reset()`  
   - `mergeDelta` 后 `lookup.applyStep(...)`  
   - Painter / tooltip / ML **只读**，禁止在 ctor 里 `build`

2. **`applyStep` 只动脏数据**  
   - 追加 `byIdx[stepIdx]`（bar + 当步 `bar_feature`）  
   - 只重投影末合并框、未确认中枢、当步 confirm/snapshot  
   - History：只把 **本步新事件** 写入对应 x（已有 `merge*EventLog`，Lookup 不要再 `expand*ToSeries` 扫全表）  
   - 三型/四型/趋势线：只算 **当前 x**  
   - Math：只写新 idx（读冻结仓）  
   - 成交量：增量累加末根；paint 复用，禁止再 `computeAllKn*`

3. **asOf**  
   - 步进：`asOf==null` 或 `asOf==last` → 读增量仓  
   - 十字：asOf bundle 只覆盖结构脏字段；冻结格 `x<=asOf` 直接读仓  
   - 与「asOf 无状态 Full 前缀」并存：结构仍 Full 短前缀，Lookup 不再为 asOf 全量填表

4. **reset/replay**  
   与 cache 一起清空；replay 逐步 `applyStep`（或首包 Full `seed` 后再增量）

**正确性门槛（实现阶段才跑，本阶段不下代码）：**

`Incremental Lookup.at(i)` + `MlFeatureFlat.flattenRow` == `BarFeatureLookup.build` 全量，覆盖：

- 002003 step24–28  
- reset+replay  
- asOf 24–28  
- History / BS 1/2/N / ZS / 分型判断 / ML flatten  

**性能门槛：** N=200/500/1000/2000 末步 Lookup 从全表重建转为 **O(脏区间)≈O(1)～O(末框宽)**；第 2 次 Lookup 不再随 N 升到数秒。

### 明确不做

- 改 Rust PipelineState / append / Delta schema / FFI  
- 改 mark_x、discoveryX、History 双键、asOf 语义、V2.1 BS、ZS/BS 判定  
- 二进制协议、字段级 patch、ZS/BS 算法优化  

---

## 4. 实现阶段建议验收顺序（待批准）

1. 外提 Lookup 到 cache（行为仍全量 `build`，先保证次数=1）  
2. `applyStep` 追加行 + 末框/当步 confirm  
3. History 只写新 x；去掉 expand 全表  
4. 三型/四型/趋势线只算当前 x  
5. asOf 读仓过滤  
6. 对照全量 `build`：002003 24–28 + N 点抽样 flatten  
7. 重跑本文件同一套 7 段 profiler  

---

## 5. 停止点

- Profiling 已完成，Lookup 是墙（N=2000 ≈ 5.5 s/步，占 96%）。  
- 设计已明确冻结 / 追加 / 可替换 / asOf / 重复计算。  
- **最小方案 = 方案 A（增量 Lookup + 移出 Painter）。**  
- **等待批准后再改 `bar_feature_lookup.dart` / cache，不提前实现。**
