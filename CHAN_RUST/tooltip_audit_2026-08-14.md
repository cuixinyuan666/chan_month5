# CHAN_RUST Flutter 十字 tooltip 全量审计诊断记录
日期：2026-08-14  
审计对象：`flutter/chan_kline` 十字 tooltip（`kline_chart._tooltipRowsForBar` → `BarFeatureLookup.build` / `crosshairTooltipRows` + `zsCrosshairTooltipRows` + `classifyProfilePeaks` + `chip_profile_compute` / `tick_dist_profile_compute`）  
审计方法：静态只读代码走查（本机无 Flutter/Dart 工具链，未新增可运行测试代码；如后续补测，按约定测完即删）。  
判定四原则：① 全层同构（K0/K1…/KN 同口径同冻结）② 不使用未来数据（as-of 截断）③ 不回写数据（会话历史/冻结仓，写入即冻结）④ 设计思路一致（应显尽显、同源同口径）。

---

## 0. 数据流信任链（自上而下）
1. `_tooltipRowsForBar`（kline_chart.dart:755-868）
   - `asOf = _crosshairEnabled && _crosshairBarIdx!=null ? _crosshairAsOfIdx() : null`（:762）
   - `asOfBundle = _bundleForZsAsOf(asOf)`（:765）
   - 十字开启时：`tipLevels = asOfBundle?.levels ?? const []`、`tipK0Confirms = asOfBundle?.k0Confirms ?? const []`、`tipZsK0 = asOfBundle?.zsK0Frames ?? const []`（:798-806）——**失败=空，禁回落末态**。
   - 所有 `*HistoryByKn` 一律传 `widget.*`（会话冻结历史），**不现场重算**（:818-831）。
   - `cut = asOf ?? bar.idx`（:841）→ 筹码/笔数峰 `cutoffX: cut`（:846,855）。
2. `BarFeatureLookup.build(... asOf: asOf, ...)`（bar_feature_lookup.dart:101-1009）—— 主体写入 `byIdx`。
3. `crosshairTooltipRows(idx,...)`（bar_feature_lookup.dart:1158）从 `byIdx[idx]` 读数并装配。

**关键结论**：进入 `build` 的 `levels`/`k0Confirms`/`zsK0Frames` 在十字态已由 Rust `asOfBundle` 截断；其余 sub 系列全部经 `maxX: asOf` 的 `expand*ToSeries` 或 `compute*ForLevel(..., asOf)` 或冻结仓截断。信任链闭合。

---

## 1. 逐项检查结果（按 tooltip 展现顺序）

### A. 表头 & K0 核心块（:1205-1266）
| 信息 | 取值来源 | ①同构 | ②无未来 | ③不回写 | ④一致 | 证据 |
|---|---|---|---|---|---|---|
| 日期时间+星期 | `barFeatures[idx]` | — | ✅ | ✅ | ✅ | :1168,`weekdayToW` |
| K0 idx | `row['idx']` | — | ✅ | ✅ | ✅ | :1206 |
| K0 (OHLC) | 当前根 `open/high/low/close` | — | ✅ | ✅ | ✅ | :1209 |
| K0成交量(B/S/G) | `sub['volume_0']`/`buy_volume_0`…（K0=原生 bars 点值） | ✅ | ✅ | ✅ | ✅ | :1177-1179,`computeAllKnVolumeSeries` |
| K0笔数(B/S/G) | `sub['tick_count_0']`…（点值） | ✅ | ✅ | ✅ | ✅ | :1183 |
| K0筹码峰 / K0笔数峰 | `classifyProfilePeaks` + `ChipProfileCompute.compute(cutoffX:cut)` | — | ✅ | ✅ | ✅ | :843-851,见 G |
| K0合并 GG/DD/MG/MD | `combineFrames`（十字=`_effectiveK0CombineFrames`=asOfBundle.frames） | ✅ | ✅ | ✅ | ✅ | :1228-1234,见 B |
| K0合并K0 idx / 合并 idx | `barFeatures.mergeInnerSeq/mergeBoxSeq`（逐根口径） | ✅ | ✅ | ✅ | ✅ | :1236-1238 |
| K0分型确认 | `k0_confirm`（按 `sig.x` 写，非未来） | ✅ | ✅ | ✅ | ✅ | :303-318 |
| K0分型判断 | `fractal_judgment_0`（judgmentHistoryByKn 展开 `maxX:asOf`） | ✅ | ✅ | ✅ | ✅ | :626-652 |
| K0中枢 rows (zsAfterK0) | `zsCrosshairTooltipRows(asOfBundle)` | ✅ | ✅ | ✅ | ✅ | 见 C |

### B. K0 合并框写入（build:220-244）— 结构依赖注意
- 该循环本身**无显式 `asOf` 守卫**，但对所有 `x∈[f.x1,f.x2]` 写 `row['combine']`。
- 安全性来自：`combineFrames = _effectiveK0CombineFrames`（kline_chart.dart:638），十字态返回 `asOfBundle.frames`（Rust 已截断），**失败=`const []`**（禁末态框）。故 `f.x2 ≤ asOf`，循环不会覆盖未来根。
- **状态：合规（有结构依赖，见第 3 节脆弱点 1）。**

### C. 中枢 rows（zs_compute.zsCrosshairTooltipRows + computeZsFramesAtAsOf）
- `asOf!=null` 时要求 `asOfBundle` 非空，否则 `const []`（禁回落末态）；逐框 `if (asOfIdx < f.x1 || asOfIdx > f.x2) continue`（kline_chart 侧与 zs_compute 侧双重截断）。
- 输出 GG/DD/ZG/ZD、`K{kn}中枢K{kn} idx`、`seq`、`上一中枢确认`（仅首根）。
- **状态：✅ 四原则全过。**

### D. K0 层内类别 `_levelCategoryExtras(idx,0)`（:1703-1936）
读 `sub` 中已由 build 截断写入的值：
| 类别 | 键 | 截断来源 | 状态 |
|---|---|---|---|
| fxExtra | `fractal_peak_dist_0`、`K0截断` | `barFeatures` / `level_confirms`（:1722,:1730-1745） | ✅ |
| bs | `buy1_0/sell1_0`、`buy2_0/sell2_0`、`buyN_0_cls` | 会话历史 `expand*LabelsToSeries(maxX:asOf)`（:460-605） | ✅ 不回写 |
| divergence | `K0背驰_*`(12 算法) | 冻结仓 `truncateDivergenceMap(asOf)` 或 `computeDivergenceForLevel(asOf)`（:942-954） | ✅ |
| ratioRhythm | `adjacent_ratio_0`、`step_rhythm_0/0-0…` | `expandAdjacentRatioToSeries(maxX:asOf)` / `stepRhythm` 循环 `if(asOf!=null && b.idx>asOf) continue`（:684-719） | ✅ |
| otherMath | 斜率/三型/四型/趋势线/均线/通道/MACD/布林/RSI/KDJ/Demark | 全部 `compute*ForLevel(asOf)` 或冻结仓，循环 `if(asOf!=null && b.idx>asOf) continue`（:746-982） | ✅ |

### E. Kn 块 `K{n}`（n≥1，`_levelBlockRows`:1498-1571）
- `snap.level == n-1`（方案B，`totalLevels` 上界）（:1510-1518）。
- 核心：`snap.unitIdx/OHLC/volume/tick`（来自 asOfBundle 冻结段，点值，无未来）。
- 合并 GG/DD：`combine_range_high_$displayKn`（:269-301，循环无显式 asOf 守卫，但 `levels=tipLevels=asOfBundle` → snaps 已 bounded，见脆弱点 2）与 `combine_box_$displayKn`（:248-258，**有 `if(asOf!=null && x>asOf) continue` 守卫**）。
- 合并 K{n} idx：`snap.mergeInnerSeq/mergeBoxSeq`（asOf 段口径）。
- 分型确认/判断：`level_confirms[displayKn]`（由 `tipLevels.confirms` 建，:202-205、:169-175）+ `fractal_judgment_$n`（maxX:asOf）。
- **状态：✅ 四原则全过（合并 GG/DD 依赖脆弱点 2，非当前违规）。**

### F. Kn 层内类别
同 D 表，键为 `K{n}*`、`displayKn=n`；BS/背驰/比例节奏/斜率/三型/四型/趋势线/均线/通道/MACD/布林/RSI/KDJ/Demark 全部 `sub['*_$n']`，写入路径见 D 的 build 段（maxX:asOf 或冻结仓或 asOfBundle）。**✅ 全过，且与 K0 同源同口径（全层同构）。**

### G. 筹码峰 / 笔数峰
- `ChipProfileCompute.compute(bars, cutoffX:cut)` → `_prefix.profileAt(cutoffX)` 二分 `deltas[mid].idx <= cutoffX` 仅累加截止 as-of（chip_profile_compute.dart:396-433）。
- `TickDistProfileCompute.compute` → `if (bar.idx > cutoffX) break;`（tick_dist_profile_compute.dart:35-38）。
- `classifyProfilePeaks` 仅按当前根 low/high 分类（profile_peak_classify.dart），时间截断在上游已保证。
- **状态：✅ 四原则全过（仅 K0 显示，符合 AGENTS「筹码仅 K0」口径，非违规）。**

---

## 2. 四象限判定汇总
| 原则 | 结论 | 范围 |
|---|---|---|
| ① 全层同构 | **PASS** | K0/K1…/KN 共用 `build` → `crosshairTooltipRows` → `_levelCategoryExtras`；键 `K{kn}*` 统一；方案B `displayKn=level+1`；连线族 `level==displayKn`、趋势线 child=displayKn/parent=displayKn+1；背驰同号 `displayKn`。 |
| ② 不使用未来数据 | **PASS** | 十字态 `levels/k0Confirms/zsK0Frames` 经 `asOfBundle` 截断；所有 sub 经 `maxX:asOf` 或 `compute*ForLevel(asOf)` 或冻结仓截断；筹码/笔数峰 `cutoffX=asOf`；`expand*ToSeries` 均含 `if(maxX!=null && e.x>maxX) continue`。 |
| ③ 不回写数据 | **PASS** | BS/判断/中枢信号/ZS 信号全部来自会话历史（`widget.*HistoryByKn`）展开，写入即 `maxX:asOf` 冻结；数学/背驰用 `MathSeriesFreezeStore`/`DivergenceFreezeStore` 首非空冻结，参数变更清空重冻；无「整表重算消点」。 |
| ④ 设计思路一致 | **PASS** | tooltip「应显尽显、按层不按勾选」与 AGENTS 口径一致；BS 1..9 类全显、筹码仅 K0、中枢全层输出均符合既定设计；无与多数指标相悖的特例分支。 |

**未发现任何违反四项原则的信息项。**

---

## 3. 潜在脆弱点 / 设计注意（非当前违规，建议记入口径）
1. **K0 合并框写入循环（build:220-244）无显式 `asOf` 守卫**，安全性完全依赖 `_effectiveK0CombineFrames` 在十字态返回 `asOfBundle.frames`。若将来该函数改回 `widget.combineFrames`（末态）作为十字 fallback，将泄漏未来合并框。建议在循环内补 `if (asOf != null && x > asOf) continue;` 作为双保险（与 :248-258、:262 一致）。
2. **`combine_range_high_$displayKn` 计算循环（build:269-301）无 `asOf` 守卫**，安全性依赖 `tipLevels=asOfBundle`。同脆弱点 1，建议在写入 `row['combine_range_*']` 前加 `if (asOf != null && b.idx > asOf) continue;`（虽然当前因只读取 `bar.idx==asOf` 不会外显未来，但属隐式安全）。
3. **非十字态（asOf==null）** 使用 `widget.levels`（末态）与全量 `cut`，属「完整末态视图」，无未来概念（数据仅到末根），符合预期；但注意该路径下 `combineFrames=widget.combineFrames` 为末态框，与十字态行为不同——这是设计分层，非违规。

---

## 4. 测试代码说明
本机无 Flutter/Dart 工具链，本次为纯静态走查，**未新增任何测试代码**，故无需清理。如用户后续要求在 CI/本机补单测验证 as-of 截断，建议在 `test/` 下新建临时用例，测完按约定删除。

---

## 5. 结论
十字 tooltip 的全部信息项（表头、K0 核心、K0 合并、中枢 rows、K0/Kn 层内 fxExtra/BS/背驰/比例节奏/其它数学、筹码峰/笔数峰）**均满足全层同构、不使用未来数据、不回写数据、设计思路一致四项原则**。仅发现 2 处「依赖上游 asOfBundle 截断而非显式守卫」的隐式安全点，建议补守卫以消结构依赖，属健壮性增强而非缺陷修复。
