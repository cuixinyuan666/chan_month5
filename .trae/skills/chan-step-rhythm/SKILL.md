---
name: "chan-step-rhythm"
description: "节奏线（STEP_RHYTHM）功能速查与修改指南。当修改节奏线副图指标、step_rhythm 计算逻辑、rhythm_calc_mode 三种模式、节奏线配置项、节奏线前端渲染、build_*_bundle 节奏线部分时，必须调用此 Skill 确保逻辑一致。"
---

# 节奏线（STEP_RHYTHM）功能速查与修改指南

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **修改 `calc_step_rhythm_metrics_for_current_step`** 或 `_advance_step_rhythm_after_seg_confirm` 逻辑
2. **新增/修改 rhythm_calc_mode 模式**（normal / transition / strict1382）
3. **修改 `build_parent_rhythm_entries` 或 `build_rhythm_structures`** 节奏线计算公式
4. **修改 `build_classic_bundle` / `build_new_bundle` / `build_structure_bundle`** 中节奏线部分
5. **修改节奏线前端渲染**（`drawStepRhythmLines`、副图 `step_rhythm` panel 渲染）
6. **修改节奏线配置项**（rhythmLine、calcMode、maxLayer、group1~9 样式等）
7. **修改 `chart_lazy_layers` 中 `step_rhythm` 的懒加载逻辑**

---

## 一、功能概述

节奏线（STEP_RHYTHM）是缠论中用于**预测价格走势目标位**的辅助工具，基于历史回调比例推算未来价格目标。

**核心公式**（以上升方向为例）：
```
ratio = (B - C) / (B - A)    // 回调比例
rhythm_price = D - (D - A) * ratio   // 用回调比例推算 D 之后的目标位
```

其中 A→B→C→D 为同向推进的交替子序列，C 是 B 之后的回调，D 是回调后的下一个推进。

---

## 二、关键文件与职责

| 文件 | 职责 |
|------|------|
| `a_replay_trainer.py` | 后端：节奏线计算（~L4838-4972）、bundle 构建（~L3628-4032）、前端渲染（~L21318-21360） |
| 无其他外部文件 | 节奏线逻辑全部内聚在 `a_replay_trainer.py` 中 |

---

## 三、三层计算架构

### 3.1 逐K步进副图（step_rhythm 副图）

**入口**：`calc_step_rhythm_metrics_for_current_step()`（~L4838）

**适用模式**：仅 `data_feed_mode == "step"`（逐K喂数据）

**核心逻辑**：
1. 获取当前步进的已确认笔列表（`children`）
2. 通过 `build_alternating_child_sequence()` 构建交替子序列
3. 对每个偶数索引（2, 4, 6...）的 D 点，用之前的 A-B-C 回调比计算节奏价
4. 输出 `step_rhythm_lines` 数组，每个元素包含 `value`、`ratio`、`round_current`、`round_ref`、`layer` 等

**关键状态**（`reset_step_rhythm_state` 初始化）：
- `_step_rhythm_active_dir`：当前活跃方向
- `_step_rhythm_start_bi_idx`：起始笔索引
- `_step_rhythm_start_x`：起始 x 序号
- `_step_rhythm_last_seg_key`：上一次段确认信号 key（防重复切换）

**方向切换时机**：段确认信号（`seg_sure_signal`）产生后，下一步才切换 `active_dir`。

### 3.2 全量 bundle 节奏线（主图主线）

**入口**：`build_rhythm_structures()`（~L3628）

**调用链**：
```
build_structure_bundle()
  → build_new_bundle() / build_classic_bundle()
    → build_rhythm_structures()
      → build_parent_rhythm_entries()  ×3（fract→bi, bi→seg, seg→segseg）
```

**三层父子关系**：
| 层级 | 子结构 | 父结构 | 开关 |
|------|--------|--------|------|
| 1 | 分型（fract） | 笔（bi） | `fractToBiEnabled` |
| 2 | 笔（bi） | 线段（seg） | `biToSegEnabled` |
| 3 | 线段（seg） | segseg | `segToSegsegEnabled` |

**节奏线输出**：横向线段（`x1→x2`，价格为 `y1=y2`）+ 1382 命中点（`hits`）

### 3.3 1382 命中检测

**函数**：`find_1382_hits()`（~L3466）

当 `calc_mode == "strict1382"` 时，每轮节奏线还会检测当前推进段是否突破 1382 门槛：
- 上升方向：K 线 high >= threshold
- 下降方向：K 线 low <= threshold

---

## 四、三种计算模式

| 模式 | 常量 | 行为 |
|------|------|------|
| **normal** | `RHYTHM_CALC_MODE_NORMAL` | 不检查回调是否破前低/高，全部输出 |
| **transition** | `RHYTHM_CALC_MODE_TRANSITION` | D 不能破 B（上升 D < B 或下降 D > B 则跳过） |
| **strict1382** | `RHYTHM_CALC_MODE_STRICT_1382` | transition 基础上，D 还必须突破 1382 门槛 |

**判断函数**：`rhythm_retrace_allowed()`（~L3440）

**归一化**：`normalize_rhythm_calc_mode()`，不支持的模式回退到 `normal`

---

## 五、后端核心函数速查

### 5.1 逐K副图相关

| 函数 | 行号 | 作用 |
|------|------|------|
| `reset_step_rhythm_state()` | ~4560 | 重置节奏线状态 |
| `_step_rhythm_signal_dir()` | ~4778 | 从段确认信号提取方向 |
| `_current_step_seg_signals()` | ~4794 | 获取当前步进的段确认信号 |
| `_advance_step_rhythm_after_seg_confirm()` | ~4808 | 段确认后更新方向状态 |
| `calc_step_rhythm_metrics_for_current_step()` | ~4838 | 主计算：输出 step_rhythm_lines |

**修改时注意**：
- 只在 `data_feed_mode == "step"` 时生效
- `_advance_step_rhythm_after_seg_confirm` 通过 `_step_rhythm_last_seg_key` 防重复
- 确认K本身仍按旧线段方向画到截止点，下一步再切新方向
- `step_rhythm_lines` 的 `calc_mode` 固定为 `"normal"`（不复用 `rhythm_calc_mode` 配置）

### 5.2 全量 bundle 相关

| 函数 | 行号 | 作用 |
|------|------|------|
| `build_alternating_child_sequence()` | ~3388 | 从子结构列表提取交替序列 |
| `rhythm_1382_threshold()` | ~3430 | 计算 1382 门槛价 |
| `rhythm_retrace_allowed()` | ~3440 | 判断当前轮次是否允许输出 |
| `rhythm_layer_index()` | ~3414 | 计算层级索引（round_current - round_ref） |
| `find_1382_hits()` | ~3466 | 检测 1382 突破命中 |
| `build_parent_rhythm_entries()` | ~3499 | 为一个父结构构建节奏线+1382命中 |
| `build_rhythm_structures()` | ~3628 | 三层循环构建全部节奏线 |
| `build_classic_bundle()` | ~3866 | 经典算法 bundle（含节奏线） |
| `build_new_bundle()` | ~3945 | 新算法 bundle（含节奏线） |
| `build_structure_bundle()` | ~4021 | 统一入口，根据 chan_algo 分发 |

**修改时注意**：
- `build_alternating_child_sequence` 要求子结构依次交替方向
- `build_parent_rhythm_entries` 需要至少 4 个交替子结构（A-B-C-D）
- 经典/新算法两套 bundle 函数中节奏线部分逻辑一致
- `chart_lazy_layers["rhythm"]` 控制是否懒计算节奏线

### 5.3 辅助函数

| 函数 | 行号 | 作用 |
|------|------|------|
| `normalize_rhythm_calc_mode()` | ~3409 | 归一化计算模式 |
| `rhythm_dir_text()` | ~3422 | 方向转文本 |
| `make_rhythm_display_label()` | ~3418 | 生成显示标签 |
| `format_rhythm_ratio()` | ~3461 | 格式化比例文本 |
| `reverse_bi_dir()` | ~3336 | 反转方向 |

---

## 六、前端渲染速查

### 6.1 副图 step_rhythm panel

**渲染函数**：`drawStepRhythmLines()`（~L21318）

**流程**：
1. 遍历 `visibleInd` 中每个指标的 `step_rhythm_lines`
2. 按 `key` 去重分组（同一节奏线多步输出合并为折线）
3. 按 `round_ref` 着色（`stepRhythmColor`）
4. 在副图区域绘制折线，末点标注 `label`（如 "1-0"、"2-1"）

**Y 轴范围**（`getPanelRange` ~L21397）：遍历所有 `step_rhythm_lines` 的 `value` 取 min/max

**标签**：`节奏线:3 上 12.345`（行数 + 方向 + 最新值）

### 6.2 配置项一览

**前端配置**（`chartConfig.rhythmLine`）：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enabled` | bool | true | 总开关 |
| `fractToBiEnabled` | bool | true | 分型→笔节奏线 |
| `biToSegEnabled` | bool | true | 笔→线段节奏线 |
| `segToSegsegEnabled` | bool | true | 线段→segseg节奏线 |
| `maxLayer` | int (0-9) | 9 | 最大显示层级 |
| `calcMode` | string | "normal" | 计算模式 |
| `group1~9LineColor` | color | 各不同 | 各组节奏线颜色 |
| `group1~9LineWidth` | float | 各不同 | 各组节奏线粗细 |
| `group1~9LineStyle` | string | 各不同 | 各组节奏线线型 |
| `group1~9TextColor` | color | 各不同 | 各组数字颜色 |
| `group1~9TextFontSize` | int | 各不同 | 各组数字大小 |
| `group1~9TextFontWeight` | string | 各不同 | 各组数字粗细 |

---

## 七、数据流与生命周期

```
init() → rhythm_calc_mode 从 cfg_dict 读取并归一化

step() 逐K喂入:
  → record_seg_sure_signals_for_current_step()  // 段确认信号
  → calc_step_rhythm_metrics_for_current_step()  // 副图节奏线
  → indicator_row.update(step_rhythm_metrics)    // 写入指标历史

build_chart_payload_cached():
  → get_structure_bundle()
    → build_structure_bundle() → build_*_bundle()
      → build_rhythm_structures()  // 主图节奏线
  → serialize_chan()  // 序列化到 payload

前端渲染:
  → 主图：payload.rhythm_lines（水平线 + 1382 命中点）
  → 副图：indicator history 中 step_rhythm_lines（折线）
```

---

## 八、修改检查清单

修改节奏线相关代码后，必须逐项确认：

- [ ] `calc_step_rhythm_metrics_for_current_step` 是否仅在 `data_feed_mode == "step"` 时生效
- [ ] `_advance_step_rhythm_after_seg_confirm` 是否通过 `_step_rhythm_last_seg_key` 防重复
- [ ] 确认K本身是否用旧方向画到截止点
- [ ] `build_alternating_child_sequence` 输入是否已过滤非确认子结构
- [ ] `build_parent_rhythm_entries` 是否要求至少 4 个交替子结构
- [ ] 三种 `rhythm_calc_mode` 的行为是否一致
- [ ] 经典/新算法 bundle 中的节奏线逻辑是否同步
- [ ] `chart_lazy_layers["rhythm"]` 懒加载是否被正确检查
- [ ] 副图 `step_rhythm` panel 的 Y 轴范围计算是否正确
- [ ] 节奏线 key 的去重逻辑是否正确（`step_rhythm|dir|current_bi|ref_bi|retrace_bi`）
- [ ] `rhythm_calc_mode` 配置变更后是否需要重建 bundle（`_suppress_step_bundle_refresh`）
- [ ] 统一喂数据模式下节奏线是否被正确跳过
- [ ] `reset_step_rhythm_state()` 是否在 init 和 reconfig 时被调用
- [ ] 1382 命中检测方向是否正确（上升看 high，下降看 low）