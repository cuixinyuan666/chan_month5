---
name: "chan-buy-sell-point"
description: "买卖点（BuySellPoint/BSP）逻辑速查与修改指南。当修改 CBS_Point 数据结构、CBSPointList.cal 主流程、一类/二类/三类/类二买卖点判定、bsp_history 逐K冻结、×/✓ 判定、BSP 配置项、Rust 侧 state.rs BspList、前端 drawBottomSignals 渲染时，必须调用此 Skill 确保逻辑一致。"
---

# 买卖点（BuySellPoint/BSP）逻辑速查与修改指南

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **修改 `CBS_Point` 数据结构**（`BuySellPoint/BS_Point.py`：`type`/`relate_bsp1`/`features`/`is_segbsp`/`add_type`/`add_another_bsp_prop`/`type2str`）
2. **修改 `CBSPointList` 计算主流程**（`BuySellPoint/BSPointList.py`：`cal`/`cal_seg_bs1point`/`cal_seg_bs2point`/`cal_seg_bs3point`/`add_bs`/`store_add_bsp`/`clear_store_end`/`clear_bsp1_end`/`bsp_iter`/`bsp_iter_v2`）
3. **修改一类买卖点判定**（`treat_bsp1`/`treat_pz_bsp1`：背驰判断、盘整背驰）
4. **修改二类/类二买卖点判定**（`treat_bsp2`/`treat_bsp2s`：回调比例、类二连续判定）
5. **修改三类买卖点判定**（`treat_bsp3_after`/`treat_bsp3_before`/`cal_bsp3_bi_end_idx`/`bsp3_back2zs`/`bsp3_break_zspeak`）
6. **修改 `CBSPointConfig` / `CPointConfig` 配置**（`BuySellPoint/BSPointConfig.py`：`divergence_rate`/`min_zs_cnt`/`bsp1_only_multibi_zs`/`max_bs2_rate`/`macd_algo`/`bs1_peak`/`bs_type`/`bsp2_follow_1`/`bsp3_follow_1`/`bsp3_peak`/`bsp2s_follow_2`/`max_bsp2s_lv`/`strict_bsp3`/`bsp3a_max_zs_cnt`）
7. **修改 `BSP_TYPE` 枚举**（`Common/CEnum.py`：T1/T1P/T2/T2S/T3A/T3B）
8. **修改 `MACD_ALGO` 枚举或背驰指标算法**（AREA/PEAK/FULL_AREA/DIFF/SLOPE/AMP/VOLUMN/AMOUNT/RSI 等）
9. **修改 BSP 逐K历史与 ×/✓ 判定**（`a_replay_trainer.py`：`bsp_history`/`_bsp_key`/`sync_bsp_history`/`_judge_bsp_against_all`/`after_step_update`/`_capture_bsp_history_with_status`/`_append_bsp_history_items`）
10. **修改 BSP 层级构建**（`build_level_bsp`/`empty_bsp_list`/`build_extra_zs_and_bsp`/`get_bundle_bsp_list`）
11. **修改 BSP 序列化**（`make_bsp_item`/`serialize_bsp_collection`）
12. **修改 Rust 侧 BSP 实现**（`a_rust_core/chan-core/src/state.rs` 中 `BspPoint`/`BspList`/`cal_bi_level`/`cal_seg_level`；`a_rust_core/src/lib.rs` 中 `bsp_items_from_list`/`bsp_delta_reset`/`bsp_delta_collect`）
13. **修改 BSP 前端渲染**（`drawBsp`/`drawBottomSignals`/`buildBottomSignalGroups`/`resolveBottomBspRowsForDraw`/`bottomBspRowKey`）
14. **修改 BSP 配置项或懒加载**（`bsp_levels`/`bspBi`/`bspSeg`/`bspSegseg` 样式/`showBottomBsp` 总开关）

---

## 一、功能概述

买卖点（BSP）是缠论中基于**中枢**与**背驰**理论推导出的交易信号点。本工程实现 6 种类型，覆盖一/二/三类买卖点及其变体。

### 1.1 六种买卖点类型（`BSP_TYPE` 枚举）

| 枚举 | 值 | 名称 | 触发条件简述 |
|------|----|------|------------|
| `T1` | "1" | 一类买卖点 | 末笔突破中枢 + MACD 背驰 |
| `T1P` | "1p" | 盘整一类 | 无中枢场景下的盘整背驰（PZ） |
| `T2` | "2" | 二类买卖点 | 一类后回调不破（回调率 ≤ max_bs2_rate） |
| `T2S` | "2s" | 类二买卖点 | 二类后连续的同向同段回调 |
| `T3A` | "3a" | 三类（中枢在后） | 中枢出现在 1 类之后的突破回踩 |
| `T3B` | "3b" | 三类（中枢在前） | 中枢出现在 1 类之前的突破回踩 |

**买卖方向**：`is_buy = bi.is_down()`（下降笔末端为买点，上升笔末端为卖点）。

### 1.2 三层 BSP 体系

| 层级 | base_lines | upper_lines | payload 字段 | 样式配置 |
|------|-----------|-------------|-------------|---------|
| 笔买卖点 | bi_list | seg_list | `bsp`（合并） | `bspBi` |
| 段买卖点 | seg_list | segseg_list | `bsp`（合并） | `bspSeg` |
| 2 段买卖点 | segseg_list | segsegseg_list | `bsp`（合并） | `bspSegseg` |
| 自定义高阶 | extra_lines[level-1] | extra_lines[level] | `bsp`（合并） | `bspSeg{n}` |

---

## 二、关键文件与职责

| 文件 | 职责 |
|------|------|
| `BuySellPoint/BS_Point.py` | **数据结构**：`CBS_Point` 类，单点买卖点（多类型叠加、关联 bsp1、特征字典） |
| `BuySellPoint/BSPointList.py` | **计算主流程**：`CBSPointList` 类，`cal`/`cal_seg_bs1point`/`cal_seg_bs2point`/`cal_seg_bs3point` |
| `BuySellPoint/BSPointConfig.py` | **配置类**：`CBSPointConfig`（买/卖各一份）/`CPointConfig`（14 个配置项） |
| `Common/CEnum.py` | **枚举**：`BSP_TYPE`（L58-67）、`MACD_ALGO`（L104-116） |
| `KLine/KLine_List.py` | **入口**：`cal_seg_and_zs()` 末尾调用 `bs_point_lst.cal` 和 `seg_bs_point_lst.cal`（L116-117） |
| `a_replay_trainer.py` | **层级包装/序列化/历史/判定/前端渲染**：`build_level_bsp`/`serialize_bsp_collection`/`bsp_history`/`_judge_bsp_against_all`/`drawBsp` |
| `a_rust_core/chan-core/src/state.rs` | **Rust 加速**：`BspPoint`/`BspList`/`cal_bi_level`/`cal_seg_level`（仅 T1/T1P/T2） |
| `a_rust_core/chan-core/src/enums.rs` | **Rust 枚举**：`BspType`（L23-40） |
| `a_rust_core/chan-core/src/config.rs` | **Rust 配置**：`bsp_types`/`bsp1_only_multibi_zs`/`max_bs2_rate` 等 |
| `a_rust_core/src/lib.rs` | **PyO3 绑定**：`bsp_items_from_list`/`bsp_delta_reset`/`bsp_delta_collect`（L453-555） |

---

## 三、核心数据结构

### 3.1 Python `CBS_Point`（`BuySellPoint/BS_Point.py` L11-38）

```python
class CBS_Point(Generic[LINE_TYPE]):
    bi: LINE_TYPE                 # 触发买卖点的笔/段
    klu: CKLine_Unit              # 笔末 K 线单元（定位锚点）
    is_buy: bool                  # 买/卖方向
    type: List[BSP_TYPE]          # 类型列表（支持多类型叠加，如 ["1","2"]）
    relate_bsp1: Optional[CBS_Point]  # 关联的一类买卖点（2/3 类必填）
    features: CFeatures           # 特征字典（含 divergence_rate 等）
    is_segbsp: bool               # 是否为段级别买卖点
```

**关键方法**：
| 方法 | 行号 | 作用 |
|------|------|------|
| `add_type(bs_type)` | L24 | 追加类型（多类型叠加） |
| `add_another_bsp_prop(bs_type, relate_bsp1)` | L30 | 追加类型 + 关联 bsp1（断言 klu.idx 一致） |
| `type2str()` | L27 | 类型列表转字符串（如 "1,2"） |
| `add_feat(inp1, inp2)` | L37 | 添加特征（用于机器学习） |

**构造时副作用**：`self.bi.bsp = self`（笔反向引用买卖点，便于回溯）。

### 3.2 Python `CBSPointList`（`BuySellPoint/BSPointList.py` L18-385）

```python
class CBSPointList(Generic[LINE_TYPE, LINE_LIST_TYPE]):
    bsp_store_dict: Dict[BSP_TYPE, Tuple[List, List]]  # 按 [类型][is_buy] 二维存储
    bsp_store_flat_dict: Dict[int, CBS_Point]          # 按 bi.idx 去重索引
    bsp1_list: List[CBS_Point]                         # 一类买卖点有序列表
    bsp1_dict: Dict[int, CBS_Point]                    # 一类买卖点按 bi.idx 索引
    config: CBSPointConfig
    last_sure_pos: int                                 # 最后确认段位置（增量计算用）
    last_sure_seg_idx: int
```

**存储特点**：
- 同一笔上可叠加多个类型（通过 `bsp_store_flat_dict` 去重，`add_type` 追加）
- 一类买卖点单独维护（`bsp1_list`/`bsp1_dict`），供 2/3 类关联
- 增量计算：每次 `cal` 先 `clear_store_end`/`clear_bsp1_end` 弹出未确认部分

### 3.3 Rust `BspPoint` / `BspList`（`a_rust_core/chan-core/src/state.rs` L11-95）

```rust
pub struct BspPoint {
    pub level: String,  // "bi" / "seg"
    pub x: i32,         // 锚点 K 线 idx
    pub is_buy: bool,
    pub label: String,  // "1" / "1p" / "2"
}

pub struct BspList {
    pub points: Vec<BspPoint>,
    seen: HashSet<String>,       // 去重 key（与 Python _bsp_key 一致）
    config: ChanConfig,
}
```

**Rust 实现限制**：
- 仅实现 T1/T1P/T2（不含 T2S/T3A/T3B）
- 不含背驰判断（T1 直接标记，无 MACD 计算）
- 不含 `relate_bsp1`/`features`/`is_segbsp`
- 用于性能加速场景，与 Python 逻辑对应但**字段更精简**

---

## 四、计算主流程（`CBSPointList.cal`）

**位置**：`BuySellPoint/BSPointList.py` L100-107

```python
def cal(self, bi_list, seg_list):
    self.clear_store_end()      # 弹出未确认段后的 BSP
    self.clear_bsp1_end()       # 弹出未确认段后的 bsp1
    self.cal_seg_bs1point(seg_list, bi_list)  # 一类（含盘整一类）
    self.cal_seg_bs2point(seg_list, bi_list)  # 二类 + 类二
    self.cal_seg_bs3point(seg_list, bi_list)  # 三类（3a + 3b）
    self.update_last_pos(seg_list)
```

### 4.1 一类买卖点（`cal_seg_bs1point` L157-205）

**流程**：
1. 遍历 `last_sure_seg_idx` 之后的线段
2. 对每个 seg 调用 `cal_single_bs1point`：
   - 统计 `zs_cnt`（受 `bsp1_only_multibi_zs` 控制：仅多笔中枢 vs 全部中枢）
   - 判断 `is_target_bsp`：`min_zs_cnt <= 0 or zs_cnt >= min_zs_cnt`
   - **分支 A**（有中枢 + 末笔出中枢）：`treat_bsp1`
     - `last_zs.out_bi_is_peak(seg.end_bi.idx)`：判断末笔是否为峰值
     - `last_zs.is_divergence(BSP_CONF, out_bi=seg.end_bi)`：背驰判断
     - 受 `bs1_peak` 开关控制（True 时未破峰值则非目标）
     - 输出 `T1` + `feature_dict={'divergence_rate': ...}`
   - **分支 B**（无中枢 / 盘整）：`treat_pz_bsp1`
     - 取 `bi_list[last_bi.idx-2]` 为 pre_bi
     - 必须同段、同向、未创新低/高
     - MACD 指标对比：`out_metric <= divergence_rate * in_metric`
     - 输出 `T1P`

**背驰判断**（`CZS.is_divergence`，见 [ZS/ZS.py](file:///c:\Users\Administrator\Desktop\my_file1\my_file\3\chan.py\ZS\ZS.py) L162-174）：
- 末笔必须突破中枢（`end_bi_break`）
- `in_metric = bi_in.cal_macd_metric(macd_algo)`
- `out_metric = bi_out.cal_macd_metric(macd_algo, is_reverse=True)`
- `divergence_rate > 100` 时保送（视为背驰）
- 否则 `out_metric <= divergence_rate * in_metric` 才算背驰

### 4.2 二类/类二买卖点（`cal_seg_bs2point` L207-277）

**`treat_bsp2`**（L216-242）：
1. `bsp1_bi = seg.end_bi`（一类买卖点笔）
2. `break_bi = bi_list[bsp1_bi.idx + 1]`（突破笔）
3. `bsp2_bi = bi_list[bsp1_bi.idx + 2]`（二类候选笔）
4. 受 `bsp2_follow_1` 控制：True 时必须存在真实 bsp1
5. `retrace_rate = bsp2_bi.amp() / break_bi.amp()`
6. `bsp2_flag = retrace_rate <= max_bs2_rate`
7. 命中 → 输出 `T2`，否则尝试类二（受 `bsp2s_follow_2` 控制）

**`treat_bsp2s`**（L244-277）：
- 从 `bsp2_bi` 开始，步长 2 向后扫描
- 受 `max_bsp2s_lv` 限制（最大级别数 = bias/2）
- 必须同段（或相邻未确认段）
- 区间重叠判定（首笔与二类笔、后续笔与累计区间）
- `bsp2s_break_bsp1`：类二笔不能破 bsp1 笔的极值
- `retrace_rate > max_bs2_rate` 则停止
- 命中 → 输出 `T2S`

### 4.3 三类买卖点（`cal_seg_bs3point` L279-374）

**`treat_bsp3_after`**（中枢在 1 类之后，L305-344）：
1. `first_zs = next_seg.get_first_multi_bi_zs()`：下一段首个多笔中枢
2. 受 `strict_bsp3` 控制：True 时 `first_zs.bi_in.idx == bsp1_bi_idx + 1`
3. 遍历 `next_seg.get_multi_bi_zs_lst()`，受 `bsp3a_max_zs_cnt` 限制
4. `bsp3_bi = bi_list[zs.bi_out.idx + 1]`：中枢外出笔
5. `bsp3_back2zs`：笔回到中枢区间内则跳过
6. `bsp3_break_zspeak`：笔突破中枢峰值
7. 受 `bsp3_peak` 控制：True 时必须突破峰值
8. 命中 → 输出 `T3A`

**`treat_bsp3_before`**（中枢在 1 类之前，L346-374）：
1. `cmp_zs = seg.get_final_multi_bi_zs()`：当前段最后多笔中枢
2. 受 `strict_bsp3` 控制：True 时 `cmp_zs.bi_out.idx == bsp1_bi.idx`
3. `end_bi_idx = cal_bsp3_bi_end_idx(next_seg)`：扫描终点
4. 从 `bsp1_bi.idx + 2` 步长 2 扫描到 `end_bi_idx`
5. `bsp3_back2zs` 跳过回中枢的笔
6. 命中第一个 → 输出 `T3B` 并 break

### 4.4 辅助函数（L388-413）

| 函数 | 作用 |
|------|------|
| `bsp2s_break_bsp1(bsp2s_bi, bsp2_break_bi)` | 类二笔是否破 bsp1 极值 |
| `bsp3_back2zs(bsp3_bi, zs)` | 三类笔是否回到中枢区间内 |
| `bsp3_break_zspeak(bsp3_bi, zs)` | 三类笔是否突破中枢峰值 |
| `cal_bsp3_bi_end_idx(seg)` | 计算三类扫描终点（含 one_bi_zs 跳过逻辑） |

---

## 五、`add_bs` 与存储逻辑（L124-155）

```python
def add_bs(self, bs_type, bi, relate_bsp1, is_target_bsp=True, feature_dict=None):
    is_buy = bi.is_down()
    if exist_bsp := self.bsp_store_flat_dict.get(bi.idx):
        # 同笔已存在 BSP：追加类型（断言 is_buy 一致）
        exist_bsp.add_another_bsp_prop(bs_type, relate_bsp1)
        return
    if bs_type not in self.config.GetBSConfig(is_buy).target_types:
        is_target_bsp = False
    if is_target_bsp or bs_type in [BSP_TYPE.T1, BSP_TYPE.T1P]:
        bsp = CBS_Point(bi=bi, is_buy=is_buy, bs_type=bs_type, relate_bsp1=relate_bsp1, feature_dict=feature_dict)
    else:
        return
    if is_target_bsp:
        self.store_add_bsp(bs_type, bsp)
    else:
        bsp.bi.bsp = None  # 非目标类型且非 T1/T1P：清除反向引用
    if bs_type in [BSP_TYPE.T1, BSP_TYPE.T1P]:
        self.add_bsp1(bsp)
```

**关键规则**：
- 同一笔可叠加多个类型（如既是 T1 又是 T2）
- `target_types` 由配置 `bs_type` 解析（如 "1,1p,2,2s,3a,3b"）
- T1/T1P 即使不在 `target_types` 中也会被记录到 `bsp1_list`（供 2/3 类关联）
- 非目标且非 T1/T1P 的 BSP 会被丢弃（`bsp.bi.bsp = None`）

---

## 六、BSP 逐K历史与 ×/✓ 判定

### 6.1 逐K当下性（核心规则）

**位置**：`a_replay_trainer.py` L7603-7605

```python
@staticmethod
def _bsp_key(item: dict[str, Any]) -> str:
    # 同级别/同锚点/同方向只冻结首次识别标签，未来组合标签不回写、不追加
    return f'{item["level"]}|{int(item["x"])}|{1 if item["is_buy"] else 0}'
```

**规则**：
- 同 `level|x|is_buy` 的 BSP 只记录**首次识别**的标签
- 后续演化出的组合标签（如最初是 T1，后来叠加 T2）**不回写、不追加**
- 全量结构快照可展示末态修正，但不得混入当时当下历史

### 6.2 `bsp_history` 数据结构

**位置**：`a_replay_trainer.py` L6368-6371

```python
self.bsp_history: list[dict[str, Any]] = []
self._bsp_history_seen_keys: set[str] = set()
self._bsp_history_seen_list_id: int = id(self.bsp_history)
self._bsp_history_seen_count: int = 0
```

每个 history item 字段：
```json
{
  "level": "bi" / "seg" / "segseg",
  "x": <int>,                  // 锚点 K 线 idx
  "is_buy": <bool>,
  "label": "1" / "1p" / "2" / "2s" / "3a" / "3b",
  "key": "bi|123|1",           // _bsp_key 生成
  "status": null / "correct" / "wrong",
  "anchor_x": <int>,           // 实际锚点（与 x 可能不同）
  "level_label": "笔",
  "display_label": "笔1"
}
```

### 6.3 `sync_bsp_history`（L7607-7666）

**作用**：每次步进后将当前 BSP 同步到 `bsp_history`，**只追加新出现的 key**。

**unified 模式**：直接对齐 `chart.bsp`，按 `(x, level_order, not is_buy)` 排序后去重填充。
**step 模式**：通过 `_append_bsp_history_items` 增量追加（详见 L7668+）。

### 6.4 ×/✓ 判定（`_judge_bsp_against_all` L7174-7258）

**触发时机**：`after_step_update`（L7260-7282）检测到**上一级结构变向**时触发。

**判定逻辑**：
1. 维护全量预计算快照 `bsp_all_snapshot`（含所有最终 BSP）
2. 取当前 x 之前的所有 key：`all_keys_upto`
3. 对每个 `bsp_history` 中 `status is None` 的 item：
   - 若 `key in all_keys_upto` → `status = "correct"`（✓）
   - 否则 → `status = "wrong"`（×）
4. 输出统计 `stats`（appeared/judged/correct/wrong/rate）

**判定触发级别**：`judge_trigger_level(level)` 返回触发判定的上一级结构（如 bi→seg，seg→segseg）。

### 6.5 历史快照抓取（`_capture_bsp_history_with_status` L6334）

**作用**：在 ×/✓ 判定**前**抓取 `bsp_history` 浅复制快照，因为 `_judge_bsp_against_all` 会原地改写 `status` 字段。

---

## 七、层级构建与序列化

### 7.1 `build_level_bsp`（L3681-3687）

```python
def build_level_bsp(base_lines, upper_lines, bsp_conf) -> CBSPointList:
    bsp_list = CBSPointList(bs_point_config=bsp_conf)
    try:
        bsp_list.cal(base_lines, upper_lines)
    except Exception:
        return CBSPointList(bs_point_config=bsp_conf)  # 失败兜底
    return bsp_list
```

### 7.2 `make_bsp_item` / `serialize_bsp_collection`（L4063-4109）

```python
def make_bsp_item(level: str, bsp) -> dict[str, Any]:
    label = bsp.type2str()                            # 如 "1,2"
    display_label = f"{level_label(level)}{label}"    # 如 "笔1,2"
    return {
        "x": int(bsp.klu.idx),
        "y": float(bsp.klu.low if bsp.is_buy else bsp.klu.high),
        "is_buy": bool(bsp.is_buy),
        "label": label,
        "level": level,
        "level_label": level_label(level),
        "display_label": display_label,
    }

def serialize_bsp_collection(level: str, bsp_list: Any) -> list[dict[str, Any]]:
    return [make_bsp_item(level, bsp) for bsp in bsp_list.bsp_iter()]
```

**注意**：`bsp_iter()` 遍历所有类型 × 买/卖方向，**不保证按 x 排序**。前端渲染时按 x 分组。

### 7.3 懒加载 `chart_lazy_bsp_enabled`（L326-328）

```python
def chart_lazy_bsp_enabled(layers: Any, level: str) -> bool:
    cfg = layers or {}
    return bool((cfg.get("bsp_levels") or {}).get(level, True))
```

关闭时调用 `empty_bsp_list(conf.bs_point_conf)` 返回空 `CBSPointList`。

---

## 八、配置项一览

### 8.1 后端 `CPointConfig`（14 项）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `divergence_rate` | float | inf | 背驰率阈值（>100 保送） |
| `min_zs_cnt` | int | 1 | 最小中枢数（<=0 不检查） |
| `bsp1_only_multibi_zs` | bool | True | 一类只数多笔中枢 |
| `max_bs2_rate` | float | 0.9999 | 二类最大回调率（<=1） |
| `macd_algo` | str | "peak" | MACD 算法（见 8.3） |
| `bs1_peak` | bool | True | 一类必须破峰值 |
| `bs_type` | str | "1,1p,2,2s,3a,3b" | 启用的买卖点类型 |
| `bsp2_follow_1` | bool | True | 二类必须跟随一类 |
| `bsp3_follow_1` | bool | True | 三类必须跟随一类 |
| `bsp3_peak` | bool | False | 三类必须破中枢峰值 |
| `bsp2s_follow_2` | bool | False | 类二必须跟随二类 |
| `max_bsp2s_lv` | int/None | None | 类二最大级别数 |
| `strict_bsp3` | bool | False | 三类严格模式（中枢紧邻 bsp1） |
| `bsp3a_max_zs_cnt` | int | 1 | 三类后最大中枢数（>=1） |

### 8.2 买卖方向独立配置

`CBSPointConfig` 包含 `b_conf` 和 `s_conf` 两份 `CPointConfig`，通过 `GetBSConfig(is_buy)` 获取。**修改时注意**：默认两份配置相同，但持久化后可能不同。

### 8.3 `MACD_ALGO` 算法（12 种）

| 值 | 说明 |
|----|------|
| `area` | 红绿柱面积 |
| `peak` | 峰值（默认） |
| `full_area` | 全面积 |
| `diff` | DIFF 值 |
| `slope` | 斜率 |
| `amp` | 振幅 |
| `volumn` | 成交量 |
| `amount` | 成交额 |
| `volumn_avg` | 均量 |
| `amount_avg` | 均额 |
| `turnrate_avg` | 换手率 |
| `rsi` | RSI 指标 |

### 8.4 前端配置

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `bspBi.enabled` | bool | true | 笔买卖点开关 |
| `bspBi.fontSize` | int | 14 | 字体大小 |
| `bspBi.lineColor` | color | "#94a3b8" | 引线颜色 |
| `bspBi.lineWidth` | float | 1 | 引线粗细 |
| `bspBi.lineStyle` | str | "dashed" | 引线线型 |
| `bspBi.lineDash` | list | [5, 4] | 虚线段 |
| `bspBi.showLowerExtension` | bool | true | 显示下方延伸线 |
| `bspSeg.*` | 同上 | 见 L11545 | 段买卖点样式 |
| `bspSegseg.*` | 同上 | 见 L11546 | 2 段买卖点样式 |
| `shared.showBottomBsp` | bool | true | 图底买卖点总开关 |

### 8.5 懒加载配置（`bsp_levels`）

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `bsp_levels.bi` | True | 笔买卖点计算开关 |
| `bsp_levels.seg` | True | 段买卖点计算开关 |
| `bsp_levels.segseg` | True | 2 段买卖点计算开关 |
| `bsp_levels.<custom>` | True | 自定义高阶买卖点开关 |

---

## 九、前端渲染

### 9.1 渲染入口

```javascript
function drawBsp(arr, s) {
  return drawBottomSignals({ bsp: arr || [], rhythm: [] }, s);
}
```

### 9.2 `drawBottomSignals`（L21813+）

**流程**：
1. 检查 `chartConfigStore.shared.showBottomBsp`，关闭则直接返回
2. `resolveBottomBspRowsForDraw(chart)`：合并 `chart.bsp` 与 `bspHistory`（逐K模式优先用 history）
3. `buildBottomSignalGroups(chart, bspArr)`：按 x 分组，构建渲染项
4. 视口过滤：`x >= s.xMin && x <= s.xMax`
5. 排序：`priority → sortKey → text`
6. 超过 `compactLimit=3` 个时折叠为数字（hover 展开）
7. 绘制：买点用 `buyColor`（红），卖点用 `sellColor`（绿），前缀 `✓/×/·` 表示状态

### 9.3 `bottomBspRowKey`（L21697）

```javascript
function bottomBspRowKey(p) {
  const lvl = String(p.level || "");
  const x = Math.floor(Number(p.anchor_x != null ? p.anchor_x : p.x));
  const buy = p.is_buy ? 1 : 0;
  return `${lvl}|${x}|${buy}`;
}
```

**与后端 `_bsp_key` 一致**：用于合并判定状态。

### 9.4 状态前缀

| status | 前缀 | 含义 |
|--------|------|------|
| `"correct"` | ✓ | 判定正确 |
| `"wrong"` | × | 判定错误 |
| `null` | · | 未判定 |

---

## 十、Python 与 Rust 实现对照

| 项 | Python (`BuySellPoint/`) | Rust (`a_rust_core/chan-core/src/state.rs`) |
|----|--------------------------|---------------------------------------------|
| 数据结构 | `CBS_Point`（完整字段） | `BspPoint`（仅 level/x/is_buy/label） |
| 列表 | `CBSPointList` | `BspList` |
| 类型支持 | T1/T1P/T2/T2S/T3A/T3B | **仅 T1/T1P/T2** |
| 背驰判断 | `is_divergence` + MACD 算法 | **无背驰判断**（直接标记 T1） |
| 二类判断 | `retrace_rate <= max_bs2_rate` | 同 Python |
| 类二/三类 | 完整实现 | **未实现** |
| relate_bsp1 | 支持 | **不支持** |
| features | 支持 | **不支持** |
| 去重 key | `level|x|is_buy` | 同 Python（`format!("{}|{}|{}", ...)`） |
| PyO3 绑定 | - | `bsp_items_from_list`/`bsp_delta_reset`/`bsp_delta_collect` |

**修改时注意**：
- 修改 T1/T1P/T2 逻辑时，**必须同步 Rust**
- 修改 T2S/T3A/T3B 逻辑时，**不需要同步 Rust**（Rust 未实现）
- 修改背驰算法时，**不需要同步 Rust**（Rust 不做背驰判断）
- 修改 `_bsp_key` 格式时，**必须同步 Rust** 的 `bsp_key_for`/`BspList::add`

---

## 十一、数据流与生命周期

```
init() → bs_point_conf / seg_bs_point_conf 从 cfg_dict 读取并构造 CBSPointConfig

逐K步进（trigger_step=True）:
  add_single_klu(klu)
    → cal_seg_and_zs()
      → cal_seg(bi_list, seg_list, ...)
      → zs_list.cal_bi_zs(bi_list, seg_list)
      → update_zs_in_seg(bi_list, seg_list, zs_list)  # 绑定 bi_in/bi_out/bi_lst
      → cal_seg(seg_list, segseg_list, ...)
      → segzs_list.cal_bi_zs(seg_list, segseg_list)
      → update_zs_in_seg(seg_list, segseg_list, segzs_list)
      → seg_bs_point_lst.cal(seg_list, segseg_list)  # 段买卖点（依赖 segzs_list）
      → bs_point_lst.cal(bi_list, seg_list)          # 笔买卖点（依赖 zs_list）

复盘层级构建（a_replay_trainer.py）:
  build_structure_bundle() / build_classic_bundle() / build_new_bundle()
    → build_level_bsp(bi_list, seg_list, conf.bs_point_conf)        # 笔买卖点
    → build_level_bsp(seg_list, segseg_list, conf.seg_bs_point_conf)# 段买卖点
    → build_level_bsp(segseg_list, segsegseg_list, conf.seg_bs_point_conf)  # 2 段
    → build_extra_zs_and_bsp(extra_lines, conf, lazy)               # 自定义高阶

逐K历史与判定:
  step() 后:
    → sync_bsp_history()  # 同步 bsp_history（追加新 key）
    → after_step_update()  # 检测上一级结构变向
      → _judge_bsp_against_all(reason, levels)  # ×/✓ 判定
        → 对照 bsp_all_snapshot
        → 更新 bsp_history[*].status

payload 下发:
  serialize_bsp_collection(level, bsp_list)  →  payload["bsp"]（合并多层级）
  字段: x/y/is_buy/label/level/level_label/display_label

前端渲染:
  drawBsp(chart.bsp, s)
    → drawBottomSignals(...)
      → resolveBottomBspRowsForDraw(chart)  # 合并 chart.bsp + bspHistory
      → buildBottomSignalGroups(chart, bspArr)  # 按 x 分组
      → 视口过滤 + 排序 + 折叠
      → 绘制 ✓/×/· 前缀 + 标签
```

---

## 十二、修改检查清单

修改买卖点相关代码后，必须逐项确认：

### 数据结构层
- [ ] `CBS_Point` 构造时是否设置 `bi.bsp = self`（反向引用）
- [ ] `add_another_bsp_prop` 是否断言 `relate_bsp1.klu.idx` 一致
- [ ] `type2str` 是否按 `value` 拼接（如 "1,2"）
- [ ] 非目标且非 T1/T1P 的 BSP 是否清除 `bi.bsp`（避免悬空引用）

### 计算主流程层
- [ ] `cal` 是否先 `clear_store_end` / `clear_bsp1_end` 再计算
- [ ] `cal` 顺序是否为 1→2→3（2/3 类依赖 bsp1_list）
- [ ] `update_last_pos` 是否取 `seg.end_bi.get_begin_klu().idx`（与 ZS 的 `start_bi.idx` 不同）
- [ ] `seg_need_cal` 是否用 `seg.end_bi.get_end_klu().idx > last_sure_pos`

### 一类买卖点层
- [ ] `cal_single_bs1point` 是否区分有中枢（T1）vs 无中枢（T1P）
- [ ] `bsp1_only_multibi_zs` 是否影响 `zs_cnt` 统计（多笔中枢 vs 全部中枢）
- [ ] `bs1_peak` 是否控制 `out_bi_is_peak` 检查
- [ ] `is_divergence` 是否检查末笔突破中枢（`end_bi_break`）
- [ ] `divergence_rate > 100` 是否保送（视为背驰）
- [ ] `treat_pz_bsp1` 是否检查同段、同向、未创新低/高

### 二类/类二层
- [ ] `treat_bsp2` 是否取 `bi_list[bsp1_bi.idx + 2]` 为 bsp2_bi
- [ ] `bsp2_follow_1` 是否检查 bsp1 存在
- [ ] `retrace_rate = bsp2_bi.amp() / break_bi.amp()` 是否正确
- [ ] `max_bs2_rate <= 1` 断言是否生效
- [ ] `treat_bsp2s` 是否受 `max_bsp2s_lv` 限制（bias/2）
- [ ] `treat_bsp2s` 是否检查区间重叠（首笔 + 累计区间）
- [ ] `bsp2s_break_bsp1` 是否阻止类二破 bsp1 极值

### 三类层
- [ ] `treat_bsp3_after` 是否取 `next_seg.get_first_multi_bi_zs()`
- [ ] `strict_bsp3` 是否检查 `first_zs.bi_in.idx == bsp1_bi_idx + 1`
- [ ] `bsp3a_max_zs_cnt` 是否限制扫描中枢数
- [ ] `bsp3_back2zs` 是否跳过回中枢的笔
- [ ] `bsp3_peak` 是否控制 `bsp3_break_zspeak` 检查
- [ ] `treat_bsp3_before` 是否取 `seg.get_final_multi_bi_zs()`
- [ ] `cal_bsp3_bi_end_idx` 是否跳过 `is_one_bi_zs()`

### 配置与 target_types 层
- [ ] `bs_type` 字符串解析是否支持 "1,1p,2,2s,3a,3b" 六种
- [ ] `parse_target_type` 是否断言类型合法
- [ ] `macd_algo` 是否在 12 种合法值中
- [ ] 买/卖方向配置是否独立（`b_conf` / `s_conf`）
- [ ] `max_bs2_rate <= 1` 断言
- [ ] `bsp3a_max_zs_cnt >= 1` 断言

### 逐K历史与判定层
- [ ] `_bsp_key` 格式是否为 `level|x|is_buy`
- [ ] `sync_bsp_history` 是否只追加新 key（不回写已存在 key）
- [ ] `_judge_bsp_against_all` 是否在 `after_step_update` 检测变向后触发
- [ ] ×/✓ 判定是否对照 `bsp_all_snapshot`（全量预计算）
- [ ] `_capture_bsp_history_with_status` 是否在判定前抓取快照（防止 status 被原地改写）
- [ ] 同级别、同锚点、同方向是否只保留首次识别标签
- [ ] 未来演化出的组合标签是否不回写、不追加

### 层级构建与序列化层
- [ ] `build_level_bsp` 异常时是否返回空 `CBSPointList`
- [ ] `chart_lazy_bsp_enabled` 关闭时是否调用 `empty_bsp_list`
- [ ] `make_bsp_item` 字段是否完整：`x/y/is_buy/label/level/level_label/display_label`
- [ ] `bsp_iter()` 是否遍历所有类型 × 买/卖方向
- [ ] 前端 `bottomBspRowKey` 是否与后端 `_bsp_key` 一致

### 前端渲染层
- [ ] `shared.showBottomBsp` 总开关是否生效
- [ ] 逐K模式是否优先用 `bspHistory`（含 ×/✓ 状态）
- [ ] 双周期模式是否合并 `chart.bsp` 与 `bspHistory`
- [ ] 视口过滤是否 `x >= s.xMin && x <= s.xMax`
- [ ] 超过 `compactLimit=3` 是否折叠为数字
- [ ] 状态前缀是否正确：`✓` (correct) / `×` (wrong) / `·` (null)
- [ ] 买点用 `buyColor`，卖点用 `sellColor`
- [ ] 各层级样式开关（`bspBi.enabled` 等）是否生效

### Rust 同步层（若修改了 Python 计算逻辑）
- [ ] T1/T1P 逻辑改动是否同步到 `state.rs::cal_bi_level`
- [ ] T2 逻辑改动是否同步到 `state.rs::cal_seg_level`
- [ ] `bsp_key_for` 格式是否与 Python `_bsp_key` 一致
- [ ] `BspList::add` 去重逻辑是否一致
- [ ] `BspType` 枚举是否与 Python `BSP_TYPE` 一致
- [ ] T2S/T3A/T3B 改动**不需要**同步 Rust
- [ ] 背驰算法改动**不需要**同步 Rust
- [ ] PyO3 绑定 `bsp_items_from_list`/`bsp_delta_reset`/`bsp_delta_collect` 是否兼容

### 配置项适配层
- [ ] 后端默认配置（L5363-5377）是否同步更新
- [ ] 前端默认配置（`DEFAULT_CHAN_CONFIG`）是否同步
- [ ] 新增配置项是否需要持久化（`a_replay_trainer.py` 可持久化）
- [ ] 新增配置项是否需要弹窗说明（按 AGENTS.md 规则 7）
- [ ] 新增 `BSP_TYPE` 是否需要同步前端 `getBspDisplayLabel`
- [ ] 新增 `MACD_ALGO` 是否需要同步 `Bi.cal_macd_metric` 实现

### 多模式兼容层
- [ ] 逐K模式下 BSP 历史是否只记录当前 step 已喂入数据能判断的买卖点
- [ ] 一次性呈现模式下 BSP 是否来自全量计算
- [ ] unified 模式下 `sync_bsp_history` 是否直接对齐 `chart.bsp`
- [ ] 双周期模式下 BSP 是否仅主周期参与 ×/✓ 判定
- [ ] 模拟操盘模式下 ×/✓ 判定是否在结构变向时触发
