---
name: "chan-mode-compat"
description: "缠论复盘系统多模式兼容性检查。当修改 a_replay_trainer.py 或核心模块代码，且改动基于某一模式但可能影响其它模式时，必须调用此 Skill 逐模式验证兼容性。"
---

# 缠论复盘系统多模式兼容性检查

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：
- 修改 `a_replay_trainer.py` 中的任何代码
- 新增/修改配置项
- 修改核心计算模块（Bi/、Seg/、ZS/、KLine/、BuySellPoint/ 等）
- 用户明确说"这个改动只在 XX 模式下测试过"

## 模式全景图

本系统存在 **4 个维度** 的模式，彼此正交组合，改动时必须逐一检查：

```
┌──────────────────────────────────────────────────────────────┐
│  维度1: 图表模式 (chart_mode) — 3 种                          │
│    single / dual / multi                                     │
│                                                              │
│  维度2: 数据形态 (data_form_mode) — 4 种                       │
│    traditional / quantity / tick_traditional / tick_quantity  │
│                                                              │
│  维度3: 数据喂入 (data_feed_mode) — 2 种                       │
│    step / unified                                            │
│                                                              │
│  维度4: K线呈现 (kline_presentation_mode) — 2 种               │
│    step（步进） / instant（一次性呈现）                          │
└──────────────────────────────────────────────────────────────┘
```

---

## 维度1：图表模式 (chart_mode)

### 1.1 single（单图模式，默认）

| 项目 | 说明 |
|------|------|
| 图表数量 | 1 张 |
| 周期数量 | 1 个 |
| 缠论引擎 | 1 个 `CChan`，挂在 `APP_STATE.stepper` |
| 买卖点判定 | 单图 |
| 节奏线 | 单图 |
| 筹码分布 | 单图显示 |
| 回退缓存 | `stepper` 的快照 |

### 1.2 dual（双图模式）

| 项目 | 说明 |
|------|------|
| 图表数量 | 2 张（上下排列，可拖拽分隔条） |
| 周期数量 | 2 个（可不同，如日线+30分钟） |
| 缠论引擎 | 2 个独立 `CChan`，`stepper` + `stepper2` |
| 激活图 | 有蓝色边框高亮，Tab 键切换 |
| 步进驱动 | `step_driver`：`auto`/`k1`/`k2` |
| 同步机制 | 驱动图步进后，被动图 `_sync_stepper_to_anchor()` 到锚点时间 |
| 防未来数据 | 粗周期末根 OHLCV 修正：`_dual_rebuild_coarse_chan_anti_future()` |
| 买卖点判定 | 仅激活图 |
| 节奏线 | 仅激活图 |
| 筹码分布 | 两图独立显示 |
| 回退缓存 | 两图 stepper 的快照都要恢复 |

### 1.3 multi（多周期单图模式）

| 项目 | 说明 |
|------|------|
| 图表数量 | 1 张（多周期叠加） |
| 周期数量 | 2~5 个 |
| 缠论引擎 | 每层 1 个独立 `CChan`，`stepper` + `multi_steppers[]` |
| 驱动周期 | 自动取最细周期（`kl_granularity_rank()` 最小的） |
| 被动层 | 其余周期按从细到粗排列 |
| 同步机制 | `_sync_passives_to_anchor()` 批量同步所有被动层 |
| 防未来数据 | 粗周期末根修正 |
| 坐标映射 | 被动层 K 线 X 坐标统一映射到驱动周期 |
| 买卖点判定 | 仅驱动周期层 |
| 节奏线 | 仅驱动周期层 |
| 筹码分布 | 仅驱动周期层 |
| 回退缓存 | `AppRollbackSnapshot` 额外包含 `multi_steppers` 快照 |

---

## 维度2：数据形态 (data_form_mode)

### 2.1 traditional（传统模式，默认）

- 直接使用数据源返回的原始 K 线
- 在线/离线均可
- 步进次数 = 原始根数
- reconfig 支持 ✅

### 2.2 quantity（数量聚合模式）

- 将原始 N 根 K 线等分合并为 Q 根
- 参数：`data_form_quantity`、`data_form_quantity_alloc`（front/back）
- 在线/离线均可
- 步进次数 = Q
- 聚合后筹码分布继承原始 chip_tick_bins
- reconfig 需重建会话

### 2.3 tick_traditional（分笔合成传统模式）

- **仅离线分笔**（`a_Data/` 下 txt 文件）
- 分笔 → 1分钟 OHLCV → 目标周期
- 高精度 chip_tick_bins
- reconfig 需重建会话

### 2.4 tick_quantity（分笔合成数量模式）

- **仅离线分笔**
- 分笔 → 1分钟 → 目标周期 → 数量聚合
- 高精度 chip_tick_bins
- reconfig 需重建会话

---

## 维度3：数据喂入 (data_feed_mode)

### 3.1 step（逐步喂入，默认）

| 功能 | 状态 |
|------|------|
| 逐根 `step_load()` 增量计算 | ✅ |
| Space 步进 / Ctrl+Alt+N 连续步进 | ✅ |
| back_n / goto_step / Shift+Space 回退 | ✅ |
| 模拟交易（买入/卖出/做空/平空） | ✅ |
| 买卖点自动/手动判定 | ✅ |
| 回退缓存（轻量增量 + 全量深拷贝） | ✅ |
| 双/多周期防未来数据泄漏 | ✅ 逐根修正 |

### 3.2 unified（统一喂入）

| 功能 | 状态 |
|------|------|
| 一次性 `trigger_load()` 全量计算 | ✅ |
| 前端步进按钮 | ❌ 灰色禁用 |
| 前端交易按钮 | ❌ 灰色禁用 |
| 回退操作 | ❌ 不支持 |
| 买卖点弹窗 | ❌ 不触发 |
| 缠论结构 | ✅ 一次性全量展示 |
| 筹码分布 | ✅ 正常显示 |
| 双/多周期防泄漏 | ❌ 跳过（无步进过程） |

---

## 维度4：K线呈现 (kline_presentation_mode)

### 4.1 step（步进，默认）

- 加载后从第一根起逐步展示
- 结合 `step` 喂入模式：每步实时计算，用户可交互
- 结合 `unified` 喂入模式：全量计算后按索引切片展示

### 4.2 instant（一次性呈现）

- 加载/重配后直接显示末根完整图表，跳过逐步过程
- 结合 `step` 喂入模式：自动逐根 step 到末根，仅收集 BSP 增量，末尾构建完整图表包
- 结合 `unified` 喂入模式：统一设置 `step_idx` 到末根
- **逐K当下性**：BSP 历史只记录当前 step 已喂入数据能判断出的买卖点，写入后冻结

---

## 兼容性检查清单

修改代码后，**必须逐项确认**以下检查点：

### ✅ 图表模式兼容

- [ ] 代码中对 `APP_STATE.stepper` 的引用，在 dual/multi 模式下是否应该用 `get_active_stepper()` 代替？
- [ ] 新增状态字段是否在 `AppRollbackSnapshot` 中正确序列化/反序列化？（dual/multi 回退需要）
- [ ] dual 模式下 `stepper2` 是否被正确同步？（`_sync_stepper_to_anchor`）
- [ ] multi 模式下 `multi_steppers` 是否被正确同步？（`_sync_passives_to_anchor`）
- [ ] 粗周期末根防未来数据泄漏修正是否覆盖？（`_dual_rebuild_coarse_chan_anti_future`）
- [ ] 买卖点判定是否只基于激活图/驱动周期？

### ✅ 数据形态兼容

- [ ] 新增逻辑是否依赖原始 K 线数量？quantity 模式下数量会变
- [ ] 是否依赖在线数据源？tick_traditional/tick_quantity 仅离线
- [ ] 筹码分布逻辑是否兼容 4 种形态？（详见 `chan-chip-distribution` Skill）
- [ ] reconfig 时是否需要重建会话？（quantity/tick_* 需要）

### ✅ 数据喂入兼容

- [ ] unified 模式下不可用的功能是否做了 `if feed_mode == "unified": return` 防护？
- [ ] unified 模式下步进相关操作是否被正确禁用？
- [ ] step 模式下的增量计算逻辑是否在 unified 模式下被跳过？
- [ ] 节奏线副图（step_rhythm）是否仅在 step 模式下输出？（详见 `chan-step-rhythm` Skill）

### ✅ K线呈现兼容

- [ ] instant 模式下的"逐K当下性"是否被遵守？（BSP 只记录当前已喂入数据能判断的）
- [ ] instant 模式下是否跳过了不必要的中间步骤（持仓回放、弹窗判定等）？
- [ ] 全量结构快照（末态修正）是否与"当时当下历史"解耦？

### ✅ 持久化兼容（a_replay_trainer.py 特有）

- [ ] 新增字段是否在 `AppRollbackSnapshot` 中序列化？
- [ ] 新增字段是否在 `StepperRollbackSnapshot` 中序列化？
- [ ] 旧版 pkl 文件缺少新字段时是否有默认值兜底？
- [ ] 配置变更后 reconfig 是否正常？

### ✅ 配置项兼容

- [ ] 新增配置是否在 `ChanConfig` 中注册？（否则会报 `unknown para`）
- [ ] 新增配置在 dual/multi 模式下是否对两图/所有层都生效？
- [ ] 是否添加了弹窗说明该配置的操作逻辑和步骤？

---

## 典型错误模式

### 错误1：只改了 stepper，没改 stepper2/multi_steppers

```python
# ❌ 错误：dual 模式下 stepper2 不会被更新
self.stepper.some_new_field = value

# ✅ 正确：遍历所有 stepper
for st in [self.stepper, self.stepper2, *(self.multi_steppers or [])]:
    if st is not None:
        st.some_new_field = value
```

### 错误2：unified 模式下执行了步进操作

```python
# ❌ 错误：unified 模式下没有步进概念
def some_step_operation(self):
    self.stepper.step()  # unified 模式下会出错

# ✅ 正确：先检查喂入模式
def some_step_operation(self):
    if normalize_data_feed_mode(getattr(self.stepper, "data_feed_mode", "step")) == "unified":
        return
    self.stepper.step()
```

### 错误3：回退快照遗漏新字段

```python
# ❌ 错误：AppRollbackSnapshot 中没有新字段
class AppRollbackSnapshot:
    bsp_history: list
    # 缺少 new_field

# ✅ 正确：添加新字段并给默认值
class AppRollbackSnapshot:
    bsp_history: list
    new_field: list = []  # 新增字段，旧快照回退时用默认值
```

### 错误4：instant 模式混入了未来信息

```python
# ❌ 错误：在 instant 逐K过程中使用了全量结构
for step_idx in range(total):
    all_bsp = chan.get_all_bsp()  # 全量结构可能包含未来修正

# ✅ 正确：只收集当前 step 已喂入的买卖点
for step_idx in range(total):
    current_bsp = chan.get_latest_bsp()  # 仅当下
    bsp_snapshot.append(current_bsp)
```

---

## 执行流程

当触发此 Skill 时，AI Agent 应：

1. **识别改动范围**：确定修改了哪些文件、哪些函数
2. **判断影响面**：根据上述 4 个维度，判断改动可能影响哪些模式
3. **逐模式检查**：对每个可能受影响的模式，按检查清单逐项验证
4. **输出报告**：列出所有兼容性问题及修复建议
5. **询问用户**：对于不确定的跨模式影响，主动提出疑问