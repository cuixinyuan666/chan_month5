---
name: "chan-adjacent-bi-ratio"
description: "相邻笔比例（ADJACENT_BI_RATIO）副图指标速查与修改指南。当修改相邻笔比例计算逻辑、前端渲染、懒加载、历史兼容映射时，必须调用此 Skill 确保与笔确认信号的联动正确。"
---

# 相邻笔比例（ADJACENT_BI_RATIO）副图指标速查与修改指南

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **修改 `calc_adjacent_bi_ratio_metrics_for_current_step`** 计算逻辑
2. **修改笔确认信号（`bi_sure_signal`）的记录/去重逻辑**
3. **修改 `_line_confirmed_on_display_x` 笔确认判定**
4. **修改 `_current_display_x_for_signal` 当前K索引计算**
5. **修改相邻笔比例前端渲染**（`drawRatioLine`、`drawRatioRefs`、`getPanelRange`）
6. **修改 `chart_lazy_layers` 中 `adjacent_bi_ratio` 懒加载**
7. **修改旧版 `retrace_ratio`/`trend_ratio` 的兼容映射**

---

## 一、功能概述

相邻笔比例是一个**逐K副图指标**，用于显示当前笔与上一笔确认笔的涨跌幅比例。

**核心公式**：
```
ratio = abs(cur_end - cur_begin) / abs(prev_end - prev_begin)
```

**设计原则**：只看上一笔确认，不按父级方向拆回调/趋势。即不再区分"回调笔"和"趋势笔"，统一用相邻确认笔的绝对幅度比。

---

## 二、关键文件

相邻笔比例逻辑**全部内聚在 `a_replay_trainer.py`** 中，无外部依赖。

---

## 三、后端计算逻辑

### 3.1 主函数

**函数**：`calc_adjacent_bi_ratio_metrics_for_current_step()`（~L4733）

**触发条件**：仅 `data_feed_mode == "step"`（逐K喂数据）

**流程**：
1. 获取当前所有笔列表（`_direct_line_list_for_level("bi")`）
2. 获取当前显示K索引（`_current_display_x_for_signal`）
3. 调用内部 `add_ratio_pair(prev_line, cur_line)` 计算比值

**输出字段**：
| 字段 | 类型 | 说明 |
|------|------|------|
| `ratio_level` | string | 固定为 `"bi"` |
| `adjacent_bi_ratio` | float | 相邻笔绝对幅度比 |
| `ratio_child_dir` | string | 当前笔方向（`"up"` / `"down"`） |
| `ratio_prev_bi_idx` | int | 前一笔索引 |
| `ratio_cur_bi_idx` | int | 当前笔索引 |

### 3.2 内部逻辑 `add_ratio_pair`

~L4748-4769，关键规则：

1. **双方必须有方向**：`prev_dir` 和 `cur_dir` 必须为 `BI_DIR.UP` 或 `BI_DIR.DOWN`
2. **前一笔必须已确认**：`prev_line.is_sure == True`
3. **当前笔刚确认时**：通过 `_line_confirmed_on_display_x` 检查是否在当前K确认，是则保留终值
4. **旧确认笔不重复出值**：`cur_line.is_sure` 但不在当前K确认 → 跳过

### 3.3 双笔补值逻辑

~L4771-4774：

```python
# 刚确认的旧笔落在下一笔内部，同一step先补旧笔终值
if len(children) >= 3 and self._line_confirmed_on_display_x(children[-2], display_x):
    add_ratio_pair(children[-3], children[-2])  # 先补旧笔终值
add_ratio_pair(children[-2], children[-1])       # 再让新笔启动实时比例
```

**作用**：当一根K线同时确认了旧笔（比如笔2）且当前笔（笔3）还在进行中时，先输出笔2的终值，再输出笔3的实时比例。防止笔2终值被跳过。

### 3.4 依赖的辅助函数

| 函数 | 行号 | 作用 |
|------|------|------|
| `_current_display_x_for_signal()` | ~4466 | 获取当前步进展示K的 x 序号 |
| `_line_confirmed_on_display_x()` | ~4707 | 判断某笔是否在当前K被确认 |
| `_bi_sure_signal_key()` | ~4476 | 生成笔确认信号的唯一 key |
| `_direct_line_list_for_level("bi")` | ~4617 | 获取当前笔列表 |

---

## 四、前端渲染速查

### 4.1 副图 panel 渲染

**入口**：`drawSubPanel(panel)` → `panel.type === "adjacent_bi_ratio"`（~L21539-21541）

**组件**：
1. `drawRatioRefs(subY)` — 绘制参考线（1.000 和 1.382）
2. `drawRatioLine(getter, subY, color)` — 绘制比例折线（蓝色 #2563eb）

**Y 轴范围**（`getPanelRange` ~L21388-21396）：
- 默认 min=0, max=1.382
- 遍历 `visibleInd` 中所有 `adjacent_bi_ratio` 值扩展范围

**标签**：`相邻笔比例:1.382`（副图左上角当前值）

### 4.2 历史记录提示

当相邻笔比例指标激活时，步进提示中追加文案：
```
相邻笔比例=上一笔确认后启动，不区分回调/趋势
```

### 4.3 旧版兼容映射

**位置**：`indicatorSubSlots` 处理（~L11391）、`normalize_chart_lazy_layers`（~L276）

旧版 `retrace_ratio`（回调比例）和 `trend_ratio`（趋势比例）自动映射为 `adjacent_bi_ratio`：
```javascript
type === "retrace_ratio" || type === "trend_ratio" ? "adjacent_bi_ratio" : type
```

---

## 五、懒加载控制

**入口**：`chart_lazy_layers["adjacent_bi_ratio"]`（~L6117）

**逻辑**：当 `_suppress_step_bundle_refresh` 为 True 时，只在副图指标启用 `adjacent_bi_ratio` 时才计算比例。

```python
need_ratio_sub = suppress_bundle and chart_lazy_sub_indicator_enabled(
    self.chart_lazy_layers, "adjacent_bi_ratio"
)
need_ratio_signal = (not suppress_bundle) or need_ratio_sub or need_step_rhythm_sub
```

**注意**：`need_ratio_signal` 为 True 时同时计算 `adjacent_bi_ratio` 和 `step_rhythm`（两者共享 `ratio_ms` 计时）。

---

## 六、数据流

```
step() 逐K喂入:
  → record_bi_sure_signals_for_current_step()  // 笔确认信号（冻结柱）
  → calc_adjacent_bi_ratio_metrics_for_current_step()
    → _direct_line_list_for_level("bi")        // 获取笔列表
    → _current_display_x_for_signal()          // 当前K索引
    → add_ratio_pair() ×1~2                    // 计算比值
    → indicator_row.update({adjacent_bi_ratio, ...})  // 写入指标历史

前端渲染:
  → indicator_history 中读取 adjacent_bi_ratio
  → drawRatioRefs() + drawRatioLine()
```

---

## 七、修改检查清单

修改相邻笔比例相关代码后，必须逐项确认：

- [ ] `calc_adjacent_bi_ratio_metrics_for_current_step` 是否仅在 `data_feed_mode == "step"` 时生效
- [ ] 前一笔是否必须已确认（`is_sure == True`）
- [ ] 当前笔刚确认时是否在当前K保留终值（`_line_confirmed_on_display_x`）
- [ ] 旧确认笔是否不会重复出值
- [ ] 双笔补值逻辑（`children[-3]/-2`）是否覆盖了同K确认场景
- [ ] 分母为 0 时（`denom <= 1e-12`）是否被跳过
- [ ] 旧版 `retrace_ratio`/`trend_ratio` 映射是否正确
- [ ] `chart_lazy_layers["adjacent_bi_ratio"]` 懒加载是否正确
- [ ] 前端 `getPanelRange` 的 Y 轴默认范围是否合理（0~1.382）
- [ ] 参考线 1.000 和 1.382 是否绘制正确
- [ ] 统一喂数据模式下是否被跳过
- [ ] `isRatioIndicatorActive()` 是否在历史记录中正确追加提示