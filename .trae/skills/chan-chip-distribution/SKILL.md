---
name: "chan-chip-distribution"
description: "筹码分布功能速查与修改指南。当修改筹码相关逻辑、数据源选择、kline_all 处理、chip_tick_bins 注入/下发、前端筹码渲染、筹码峰指标时，必须调用此 Skill 确保不破坏数据一致性。"
---

# 筹码分布（Chip Distribution）功能速查与修改指南

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **修改筹码数据源选择逻辑**（如调整 `DATA_SOURCE_CHAIN_CHIP`、`use_for="chip"` 相关代码）
2. **修改 kline_all 的生成/刷新/下发逻辑**（`_refresh_stepper_chip_kline_all_base`、`_kline_all_for_chip_payload` 等）
3. **修改 chip_tick_bins 的注入逻辑**（`_enrich_kline_all_offline_chip_non_triangle`、`_ensure_offline_chip_bins_enriched`）
4. **修改前端筹码渲染**（`drawChips`、筹码峰指标 `chip_peak`、`peakRefMode` 等）
5. **修改 Rust 侧 `chip_profile` 或 `ChipBins` 结构**
6. **新增/修改筹码配置项**（`chipEnabled`、`chipBucketStep`、`chipStretchLevel`、`peakLineEnabled` 等）
7. **修改数据源同源策略**（离线强制同源 / 在线独立选择 / 兜底回退）

---

## 一、功能概述

筹码分布用于展示**历史成交量在价格维度上的累积分布**，回答："从上市至今（或某个参考日期），每个价格区间累计成交了多少量？"

### 核心数据流

```
数据源层（在线/离线）
  → 后端选择筹码数据源（_select_data_source_with_fallback use_for="chip"）
  → kline_all（全历史 K 线，1990-01-01 起）
  → 离线场景：_enrich_kline_all_offline_chip_non_triangle() 注入 chip_tick_bins
  → 下发 payload.kline_all（_kline_all_for_chip_payload 截断到会话结束日）
  → 前端 drawChips() 渲染水平柱状图 + 筹码峰延长线
  → Rust/Python chip_profile() 生成分桶 profile
```

---

## 二、关键文件与职责

| 文件 | 职责 |
|------|------|
| `a_replay_trainer.py` | 核心：数据源选择、kline_all 管理、chip_tick_bins 注入、payload 下发、前端筹码渲染 |
| `a_replay_core/a_perf_engine.py` | 性能引擎：`chip_profile()` 分桶计算（Rust/Python 双路径） |
| `a_rust_core/src/lib.rs` | Rust 加速：`chip_profile()` 高速分桶 + `ChipBins` 结构 |
| `a_replay_core/a_replay_kline_view.py` | K 线弹窗查看：`volume_chip` 视图过滤 |
| `a_replay_core/a_replay_api_models.py` | API 模型：`chip_bucket_step` 配置字段 |

---

## 三、后端核心函数速查

### 3.1 数据源选择与会话初始化

**位置**：`a_replay_trainer.py` `ChanStepper.init()` 中 `data_chip` stage（约第 5489-5534 行）

**关键逻辑**：
```python
chip_sel = self._select_data_source_with_fallback(..., use_for="chip")
# 三路分支：
# A. K线离线 → 筹码强制同源（忽略 chip_sel 在线结果）
# B. K线在线 + chip_sel 成功 → 筹码独立选择
# C. chip_sel 抛异常 → 筹码回退到 K 线同源
```

**修改时注意**：
- `self.data_src_chip_used` 必须与 `self.data_src_used` 区分
- `self.data_src_logs` 必须包含筹码源信息
- 离线同源策略不可绕过（预防 K 线/筹码价格区间不匹配）

### 3.2 筹码全历史底座管理

| 函数 | 行号 | 作用 |
|------|------|------|
| `stepper_needs_chip_kline_all()` | ~584 | 判断是否需要 kline_all |
| `_refresh_stepper_chip_kline_all_base()` | ~676 | 刷新筹码全历史底座（上市首根~最新） |
| `_fetch_offline_chip_kline_all()` | ~637 | 离线直拉全历史 K 线 |
| `_pick_wider_kline_all_for_chip()` | ~738 | 在多个候选里取时间跨度最大者 |

**修改时注意**：
- `kline_all` 是**全历史**（1990-01-01 起），不随步进变化
- `_pick_wider_kline_all_for_chip` 按 `(first_t, last_t, len)` 比较，取更长者
- 缓存命中时需检查 `_kline_all_likely_full_history()` 判断是否需要重拉

### 3.3 chip_tick_bins 注入

| 函数 | 行号 | 作用 |
|------|------|------|
| `_ensure_offline_chip_bins_enriched()` | ~606 | 懒加载：下发筹码时补全 chip_tick_bins |
| `_enrich_kline_all_offline_chip_non_triangle()` | ~1477 | 离线分笔价量直加写入 chip_tick_bins |
| `_offline_chip_bar_bucket_key()` | ~1399 | 分笔时刻 → 周期 K 线桶映射 |
| `_fold_price_side_vols()` | ~1446 | 按价位聚合，拆 S/B 两侧 |
| `_offline_chip_supported_ktypes()` | ~1358 | 支持的周期列表 |

**chip_tick_bins 结构**：
```json
{
  "p": [12.21, 12.23, 12.35],  // 价格数组（升序，4位精度）
  "s": [2200, 5200, 15000],     // 左侧 S（绿）累计量
  "b": [2800, 6800, 20000],     // 右侧 B（红）累计量
  "w": [5000, 12000, 35000]     // 兼容字段（s+b）
}
```

**修改时注意**：
- `p/s/b/w` 长度必须一致
- 支持的周期：1M/3M/5M/15M/30M/60M/DAY/WEEK/MON/QUARTER/YEAR
- 分桶 key 必须与离线合成 K 线一致（`_offline_chip_bar_bucket_key`）
- 无 chip_tick_bins 时前端回退到 OHLC 三角分摊

### 3.4 payload 下发

| 函数 | 行号 | 作用 |
|------|------|------|
| `_kline_all_for_chip_payload()` | ~788 | 截断到会话结束日，补 x 序号 |
| `_chip_kline_all_with_x()` | ~626 | 为 kline_all 补 x 序号 |
| `_chip_range_text()` | ~812 | 生成筹码范围文本（历史记录用） |
| `_chip_bars_for_perf_session()` | ~830 | 为 perf session 过滤筹码 bars |

**修改时注意**：
- 下发时截断到 `session_end_date`（避免 10 万+ 根撑爆 JSON）
- 累计筹码仍从首根截到十字线（满足"上市日→当前K"）
- `build_chart_payload_cached` 中 `include_kline_all=True` 时才下发

### 3.5 chip_profile 分桶计算

**Python 路径**（`a_perf_engine.py` L333-400）：
```python
def chip_profile(session_id, cutoff_x, bucket_step):
    # 1. 获取 chip_bars
    # 2. 优先调用 Rust chip_profile()
    # 3. Rust 失败回退 Python：
    #    - 有 chip_tick_bins → 直加
    #    - 无 chip_tick_bins → _accumulate_ohlc_triangle()
```

**Rust 路径**（`a_rust_core/src/lib.rs` L365-430）：
```rust
fn chip_profile(session_id, cutoff_x, bucket_step):
    // 与 Python 逻辑完全一致，但性能更高
    // 有 chip_tick_bins → 直加 s/b
    // 无 chip_tick_bins → accumulate_ohlc_triangle()
```

**修改时注意**：
- Python 和 Rust 两套实现必须逻辑一致
- 修改分桶算法时**两边同步修改**

---

## 四、前端渲染速查

### 4.1 渲染模式

| 模式 | 触发条件 | 精度 |
|------|---------|------|
| chip_tick_bins 直加 | 有 `chip_tick_bins` 字段 | 高（分笔级别） |
| OHLC 三角分摊 | 无 `chip_tick_bins` 字段 | 低（估算） |

**三角分摊算法**：假设每根 K 线成交量在 [low, high] 区间呈三角分布，收盘价为峰值。

### 4.2 引擎优先渲染路径

**函数**：`tryDrawChipProfileFromEngine()`（~L20268）

`drawChips()` 首先尝试走引擎优先路径，成功则直接返回，否则回退到前端手动计算：

```javascript
function drawChips(chart, s) {
  if (!chartConfig.chip.enabled) return;
  if (tryDrawChipProfileFromEngine(chart, s)) return;  // 引擎优先
  // 回退：前端手动计算 chip_profile
}
```

**引擎路径跳过条件**（任一满足则回退）：
- 双周期模式且非主图
- `chip_basis === "tick_accum_driver"`（分笔累计有 chip_tick_bins，需保留 B/S 颜色）
- 十字光标悬停（需实时按锚点重算）
- 无 `chip_profile` 数据
- `performanceEngineMode === "python_legacy"`
- bucket_step 配置不匹配

**关键辅助函数**：
| 函数 | 行号 | 作用 |
|------|------|------|
| `mapChartBarToKsAll()` | ~L19451 | 将主图 K 线映射到 kline_all 筹码底座 |
| `chipTimeComparable()` | ~L19486 | 将时间字符串解析为可比毫秒（UTC） |
| `chipTimeLe()` | ~L19500+ | 时间小于等于比较（支持毫秒和字符串回退） |

### 4.3 筹码峰指标（chip_peak）

- 局部最大值检测（严格大于左右邻居）
- 延长线从筹码区左边缘画到 K 线图左边缘
- 配置项：`peakLineEnabled`、`peakLineColor`、`peakLineWidth`、`peakLineStyle`

### 4.4 参考锚点（peakRefMode）

| 值 | 说明 |
|----|------|
| `latest_visible` | 当前视口最新可见 K 线（默认） |
| `seg_turn` | 视口内最后一个线段转折点 |
| `bi_turn` | 视口内最后一个笔转折点 |

十字光标悬停时优先级最高，动态回退筹码到该日期累积状态。

### 4.4 配置项一览

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `chipEnabled` | bool | true | 总开关 |
| `chipBucketStep` | float | 0.1 | 价格桶宽度（元） |
| `chipStretchLevel` | int (1-20) | 5 | 对比度拉伸强度 |
| `chipColor` | color | rgba(59,130,246,0.45) | 筹码填充色 |
| `sColor` | color | rgba(34,197,94,0.78) | 左侧 S（绿）颜色 |
| `bColor` | color | rgba(220,38,38,0.78) | 右侧 B（红）颜色 |
| `peakLineEnabled` | bool | true | 筹码峰延长线开关 |
| `peakRefMode` | string | latest_visible | 锚点参考模式 |
| `peakLineColor` | color | #2563eb | 延长线颜色 |
| `peakLineWidth` | float | 1.2 | 延长线粗细(px) |
| `peakLineStyle` | string | dashed | 延长线线型 |
| `chipPeakIndicatorDotColor` | color | #f59e0b | 筹码峰圆点颜色 |
| `chipPeakIndicatorDotRadius` | float | 2.5 | 筹码峰圆点半径 |

---

## 五、数据源一致性规则

### 5.1 两套独立链

```
DATA_SOURCE_CHAIN_KLINE  → 步进 K 线主序列
DATA_SOURCE_CHAIN_CHIP   → 筹码全历史 kline_all
```

### 5.2 三种同源策略

| 条件 | 筹码源 = K线源？ | 日志关键词 |
|------|-----------------|-----------|
| K线来自**离线包** | **强制是** | `"已忽略筹码链上的在线源"` |
| K线来自**在线源** + 筹码链成功 | **不一定** | `"筹码全历史：{label}"` |
| K线来自**在线源** + 筹码链全失败 | **兜底是** | `"筹码链不可用"` |

### 5.3 双周期模式

- 只有主周期（stepper）的 `kline_all` 用于筹码分布
- stepper2 的 K 线数据不参与筹码
- 前端只显示一份筹码区，基于 stepper 的 kline_all

---

## 六、修改检查清单

修改筹码相关代码后，必须逐项确认：

- [ ] `data_src_chip_used` 赋值是否正确（三种同源策略）
- [ ] `data_src_logs` 是否包含筹码源信息
- [ ] `kline_all` 下发时是否截断到 `session_end_date`
- [ ] 离线同源策略是否被绕过
- [ ] `chip_tick_bins` 的 `p/s/b/w` 长度是否一致
- [ ] 新增周期是否在 `_offline_chip_supported_ktypes()` 中
- [ ] 分桶 key 是否与离线合成 K 线一致
- [ ] Python 和 Rust 的 `chip_profile` 逻辑是否同步
- [ ] 前端 `drawChips` 是否兼容新的 chip_tick_bins 格式
- [ ] 筹码峰指标 `chip_peak` 是否兼容新逻辑
- [ ] 双周期模式是否仅 stepper 参与筹码
- [ ] 弹窗 `volume_chip` 视图是否过滤正确
- [ ] 聚合模式（`build_quantity_klines`）下 chip_tick_bins 是否正确累加
- [ ] 分笔合成模式（`build_tick_synth_session_data`）下筹码底座是否保留更宽全历史