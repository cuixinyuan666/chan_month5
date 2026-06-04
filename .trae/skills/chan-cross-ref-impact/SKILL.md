---
name: "chan-cross-ref-impact"
description: "新增或删除逻辑时，对当前代码进行交叉检索索引，若改动明显影响其它逻辑造成严重偏差，必须显式警告并中断进程，待用户确认后继续。Invoke when adding/deleting/modifying logic in any file, especially core modules."
---

# 缠论工程交叉引用影响分析 (Cross-Reference Impact Analysis)

## 触发条件 (When to Invoke)

**必须在以下任一场景发生时立即调用本 Skill：**
1. 新增/删除/修改任何核心计算模块的类、方法、属性（Bi/、Seg/、ZS/、KLine/、BuySellPoint/、Math/、Common/、Combiner/）
2. 修改 `ChanConfig.py` 或任何 `*Config.py` 中的配置项
3. 修改 `Common/CEnum.py` 中的枚举定义
4. 修改 `Common/func_util.py` 或 `Common/cache.py` 中的工具函数
5. 修改 `a_replay_trainer.py` 或 `a_replay_core/`、`a_replay_cache/` 中的任意代码
6. 修改 `DataAPI/` 中的数据格式或接口
7. 修改任何被多个模块 import 的公共类/函数/常量

## 交叉引用索引（依赖关系图谱）

### 核心计算链（自底向上，下游改动影响所有上游）

```
KLine_Unit（K线原子单位）
  └→ KLine（合并K线）
      └→ Combiner/KLine_Combiner（K线合并器）
          └→ Bi/Bi（笔）
              └→ Seg/Seg（线段）
                  └→ ZS/ZS（中枢）
                      └→ BuySellPoint/BS_Point（买卖点）
```

**影响传递规则：**
- 修改任一层级的数据结构/算法 → 必须检查所有上游层级的兼容性
- `KLine_Unit` 修改影响范围最大（全链）
- `BuySellPoint` 修改影响范围最小（仅复盘展示/判定）

### 配置链

```
ChanConfig.py（总配置）
  ├→ BiConfig.py → Bi 模块
  ├→ SegConfig.py → Seg 模块
  ├→ ZSConfig.py → ZS 模块
  ├→ BSPointConfig.py → BuySellPoint 模块
  └→ Math 指标配置 → Math 模块
```

**影响传递规则：**
- 新增/删除配置项 → 必须检查 `a_replay_trainer.py` 的持久化兼容性
- 修改默认值 → 必须检查所有模式（逐K/一次性/回放）下的行为一致性
- 删除配置项 → 已持久化的 sessions 可能加载失败

### 复盘系统依赖链

```
a_replay_trainer.py（复盘主入口）
  ├→ Chan.py（缠论引擎）
  │   └→ 上述核心计算链
  ├→ a_replay_core/
  │   ├→ a_replay_serializers.py（序列化核心计算结构）
  │   ├→ a_replay_step_utils.py（步进工具）
  │   ├→ a_replay_presenters.py（买卖点呈现/判定）
  │   ├→ a_replay_multi_xmap.py（多图坐标映射）
  │   ├→ a_replay_kline_view.py（K线视图过滤）
  │   ├→ a_replay_api_models.py（API 数据模型）
  │   ├→ a_init_perf.py（初始化性能）
  │   └→ a_perf_engine.py（性能引擎）
  ├→ a_replay_cache/
  │   ├→ a_step_rollback.py（步进回退）
  │   ├→ a_step_rollback_fast.py（快速步进增量）
  │   └→ a_kline_session_cache.py（K线会话缓存）
  └→ App/ashare_bsp_scanner_gui.py（A股BSP扫描GUI）
```

**影响传递规则：**
- 核心计算链（Bi/Seg/ZS/BSP）修改 → 必须检查 `a_replay_serializers.py` 序列化/反序列化
- 核心计算链修改 → 必须检查 `a_step_rollback.py` 的快照兼容性
- 数据模型修改 → 必须检查 `a_kline_session_cache.py` 的缓存键一致性
- `a_replay_api_models.py` 修改 → 必须检查前端 API 契约

### 通用模块全局影响

```
Common/CEnum.py（枚举定义）
  └→ 被所有模块 import → 任何修改都是全局破坏性的

Common/func_util.py（工具函数）
  └→ 被 Bi/Seg/ZS/Chan 等 import → 修改签名或行为影响全局

Common/cache.py（性能缓存）
  └→ 被 Bi/Seg 等 import → 缓存失效可能导致结果不一致

Common/ChanException.py（异常定义）
  └→ 被所有模块 import → 新增/删除异常类型需全局协调
```

## 交叉检索执行步骤

### Step 1：识别改动范围
确定被修改的符号（类名、方法名、属性名、函数名、枚举值、配置键），记录其所在的文件路径。

### Step 2：交叉引用搜索（必须并行执行）
使用 `Grep` 工具搜索以下内容（根据改动层级选择相应的搜索范围）：

| 改动层级 | 必须搜索的目录 |
|---------|-------------|
| KLine_Unit / KLine | Bi/, Seg/, ZS/, BuySellPoint/, a_replay_core/, a_replay_cache/, a_replay_trainer.py, Chan.py |
| Combiner | Bi/, Seg/, ZS/, BuySellPoint/, a_replay_core/ |
| Bi | Seg/, ZS/, BuySellPoint/, a_replay_core/ |
| Seg | ZS/, BuySellPoint/, a_replay_core/ |
| ZS | BuySellPoint/, a_replay_core/ |
| BuySellPoint | a_replay_core/, App/ |
| CEnum | 全项目 |
| Config | Bi/, Seg/, ZS/, BuySellPoint/, a_replay_trainer.py, Chan.py |
| func_util / cache | Bi/, Seg/, ZS/, BuySellPoint/, Chan.py |
| a_replay_* | a_replay_trainer.py, Chan.py, App/ |
| DataAPI | Chan.py, a_replay_trainer.py, Common/ |

### Step 3：影响判定矩阵

发现交叉引用后，按以下矩阵判定严重程度：

| 改动类型 | 影响范围 | 严重程度 | 处理方式 |
|---------|---------|---------|---------|
| 删除类/方法/属性 | 有外部引用 | 🔴 阻断 | 立即警告，中断进程 |
| 修改方法签名 | 有外部调用 | 🔴 阻断 | 立即警告，中断进程 |
| 修改返回值类型/结构 | 有外部使用 | 🔴 阻断 | 立即警告，中断进程 |
| 修改枚举值名称 | 有外部引用 | 🔴 阻断 | 立即警告，中断进程 |
| 新增必填配置项 | 无默认值 | 🔴 阻断 | 立即警告，中断进程 |
| 修改数据序列化格式 | 有持久化依赖 | 🔴 阻断 | 立即警告，中断进程 |
| 修改缓存键生成逻辑 | 有缓存依赖 | 🟡 警告 | 提醒用户，可继续 |
| 新增可选配置项 | 有默认值 | 🟢 安全 | 无需中断 |
| 新增方法/属性 | 无冲突 | 🟢 安全 | 无需中断 |
| 修改内部实现（不改签名） | 无外部行为变化 | 🟢 安全 | 无需中断 |

## 阻断警告格式

当判定为 🔴 阻断时，必须输出以下格式的警告：

```
============================================================
⚠️  交叉引用影响警告 - 进程已中断
============================================================
改动文件: {file_path}
改动内容: {change_description}
影响分析:
  - 受影响的文件: {affected_files}
  - 受影响的符号: {affected_symbols}
  - 影响原因: {impact_reason}
  - 可能后果: {potential_consequences}
============================================================
请确认是否继续此改动？(是/否/修改方案)
============================================================
```

**输出警告后，必须调用 `AskUserQuestion` 工具请求用户确认，不得自行继续。**

## 特别注意事项

### 持久化兼容性
- `a_replay_trainer.py` 使用 pickle 持久化，新增/删除字段可能导致旧 sessions 加载失败
- 修改 `ChanConfig` 默认值时，已保存的 sessions 使用旧默认值，需考虑向后兼容
- `a_kline_session_cache.py` 的缓存键依赖于配置和数据源参数，修改需同步更新

### 逐K当下性
- 含"逐K喂数据"的模式下，BSP 历史只记录当前 step 已喂入数据能判断出的买卖点
- 修改核心计算逻辑时，必须验证逐K模式下的"当下性"不被破坏
- 结构签名（用于性能缓存）变化时，必须确保输入严格限制为当前 step 已喂入数据

### 多周期兼容性
- 核心模块通常处理多个 KL_TYPE（日线、60分钟、30分钟等）
- 修改算法时必须验证在所有周期下行为一致
- 特别注意跨周期引用（如大周期笔对小周期线段的约束）

### 多模式兼容性
复盘系统支持多种模式：
- `逐K喂数据 + 逐K呈现`（模拟操盘）
- `逐K喂数据 + 一次性呈现`（首屏加载）
- 一次性加载模式

修改任何核心逻辑时，必须检查对所有模式的影响。