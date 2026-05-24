# replay_trainer.py 操作说明

本文件是缠论量化回放训练服务器，基于 FastAPI 实现，内置 HTML 前端（访问 `http://127.0.0.1:8000/` 即可使用），支持缠论K线回放、买卖点判定、模拟交易等功能。

---

## 一、运行方式

```bash
python replay_trainer.py
```

启动后默认监听 `127.0.0.1:8000`。启动时若发现 8000 端口被占用，会自动尝试清理旧进程。

打开浏览器访问 `http://127.0.0.1:8000/` 即可使用内置前端界面。

---

## 二、模块化文件结构

`a_replay_trainer.py` 已拆分为以下模块化目录：

### 2.1 目录总览

```
chan.py/
├── a_replay_trainer.py      # 主入口：FastAPI 服务 + HTML 前端 + 全部业务逻辑
├── a_replay_cache/           # 复盘内存缓存包（以空间换时间）
│   ├── __init__.py
│   ├── a_step_rollback.py    # 回退快照：全量深拷贝快照（StepperRollbackSnapshot / AppRollbackSnapshot）
│   └── a_step_rollback_fast.py # 高性能步进快照：轻量增量快照（AppStepDelta），避免递归 deepcopy
├── a_replay_core/            # replay_trainer 拆分核心包
│   ├── __init__.py
│   ├── a_replay_api_models.py   # API 请求/响应模型（InitReq / ReconfigReq / StepReq 等）
│   ├── a_replay_kline_view.py   # K线数据视图过滤（kline / volume_chip / all）
│   ├── a_replay_presenters.py   # 交易事件消息格式化（买入/卖出/做空/平空提示文案）
│   ├── a_replay_serializers.py  # 缠论数据序列化（K线/笔/段/中枢/买卖点 → JSON）
│   └── a_replay_step_utils.py   # 步进工具函数（单根K线快速序列化）
└── a_Script/                 # 依赖与脚本
    └── a_requirements.txt    # 项目依赖清单
```

### 2.2 各模块职责

| 模块 | 文件 | 职责 |
|------|------|------|
| **a_replay_cache** | `a_step_rollback.py` | 定义 `StepperRollbackSnapshot`（步进器全量快照，含 chan/indicators/structure_bundle 深拷贝）、`AppRollbackSnapshot`（应用全量快照，含双图+账户+交易事件）、`AppLightSnapshot`（轻量快照），提供 `capture_stepper_snapshot()` / `restore_stepper_snapshot()` 等深拷贝回退能力 |
| | `a_step_rollback_fast.py` | 定义 `AppStepDelta`（单步增量快照），用浅拷贝+冻结 dict 替代递归 deepcopy；`capture_app_step_delta()` 步进前抓取，`overlay_app_step_delta()` 回退时覆盖；PaperAccount 转 tuple 快照避免深拷贝；大幅降低步进回退 CPU 开销 |
| **a_replay_core** | `a_replay_api_models.py` | 所有 Pydantic 请求体模型：`InitReq`、`ReconfigReq`、`StepReq`、`BackNReq`、`GotoStepReq`、`IndicatorBacktestReq`、`SessionKlineViewReq`、`JudgeBspReq`；含回退缓存参数、数据形态/喂入模式等字段 |
| | `a_replay_kline_view.py` | `kline_view_rows_filtered()`：按视图类型（kline=OHLC / volume_chip=量+筹码分桶 / all=全字段）过滤 K 线数据，供 `/api/session_kline_view` 弹窗查看 |
| | `a_replay_presenters.py` | `msg_buy()` / `msg_sell()` / `msg_short()` / `msg_cover()`：交易结果中文文案；`trade_events_same_bar_flip()`：检测同根K线反手（平多→开空 / 平空→开多） |
| | `a_replay_serializers.py` | `serialize_chan_with_cache()`：将缠论结构包序列化为前端 JSON，含 K线/分型/笔/段/中枢/买卖点/节奏线/指标；`serialize_klu_iter_fast()`：批量 K 线快速序列化 |
| | `a_replay_step_utils.py` | `serialize_klu_unit_fast()`：单根 K 线快速序列化（步进增量追加用），仅输出 x/t/o/h/l/c/v 七字段 |
| **a_Script** | `a_requirements.txt` | 项目依赖：baostock、matplotlib、numpy、pandas、requests 及可选数据源库（ashare/adata/pytdx/yfinance） |

---

## 三、环境依赖

除 `a_Script/a_requirements.txt` 外，还需额外安装：

```bash
pip install fastapi uvicorn akshare tushare pydantic
```

可选数据源库（缺失时会有提示但不影响主功能）：

- `ashare` 或 `ashares`：Ashare 行情库
- `adata`：AData 数据源
- `pytdx`：通达信数据源
- `yfinance`：雅虎财经

---

## 三、数据源优先级

默认优先级顺序：

```
AKShare > AKShare-腾讯历史 > Ashare > AData > pytdx > BaoStock > 离线数据 > Tushare > 新浪财经 > 腾讯财经 > 雅虎财经 > 东方财富 > GitHub-CSV
```

前端可通过【系统配置】面板调整数据源优先级，设置后 K 线与筹码数据源同步更新。

---

## 四、前端配置体系

前端使用三层配置，分别存储在 `localStorage`，关机/换页面不丢失：

### 4.1 sessionConfig（会话配置）

记录当前复盘会话相关参数：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `code` | string | "600340" | 股票代码 |
| `begin` | string | "2018-01-01" | 开始日期 |
| `end` | string | "" | 结束日期（空表示至今） |
| `cash` | string | "10000" | 初始资金 |
| `autype` | string | "qfq" | 复权类型：qfq/hfq/none |
| `theme` | string | "light" | 主题：light/dark/eye-care |
| `chipEnabled` | bool | true | 是否显示筹码分布 |
| `chipStretchLevel` | string | "5" | 筹码拉伸级别 |
| `chipBucketStep` | string | "0.1" | 筹码分桶步长 |
| `fractZsEnabled` | bool | true | 显示分型中枢 |
| `biZsEnabled` | bool | true | 显示笔中枢 |
| `segZsEnabled` | bool | true | 显示段中枢 |
| `segsegZsEnabled` | bool | true | 显示2段中枢 |
| `stepN` | string | "5" | 连续步进/回退的根数 |
| `kType` | string | "daily" | K线周期 |
| `chartMode` | string | "single" | 图表模式：single/dual |
| `kType2` | string | "weekly" | 双周期模式下的第二周期 |
| `dualLayout` | string | "vertical" | 双周期布局：vertical/horizontal |
| `activeChartId` | string | "chart1" | 当前激活图表 |

### 4.2 systemConfig（系统配置）

记录全局系统参数：

| 字段 | 类型 | 说明 |
|------|------|------|
| `bspJudgeMode` | string | 买卖点判定模式：`auto`（自动）或 `manual`（手动） |
| `shortcuts` | dict | 快捷键配置 |
| `dataSourcePriority` | list | 数据源优先级数组 |

### 4.3 chartConfig（图表显示配置）

记录图表外观样式，包括主题（theme）、十字光标（crosshair）、分型（fract）、笔（bi）、段（seg）、2段（segseg）、中枢（zs系列）、K线（candle）、买卖点（bsp系列）、节奏线（rhythmLine）、节奏命中（rhythmHit）等绘制样式。

---

## 五、前端界面布局

```
+----------+----------------------------------------+
|          |                                        |
|  左侧面板  |           右侧图表区域                   |
| (360px)  |          (Canvas 渲染)                   |
|          |                                        |
| - 股票代码 |                                        |
| - 日期区间 |                                        |
| - 初始资金 |                                        |
| - 快捷按钮 |                                        |
|          |                                        |
+----------+----------------------------------------+
```

**左侧面板包含：**

1. **主标签栏**：复盘训练 / 回测 两个主标签，切换不同功能视图
2. **顶部工具栏**：缠论配置、图表显示设置、系统配置、全屏按钮
3. **会话控制区**：加载会话、重新训练、结束训练、退出
4. **步进控制区**：上一根K线、下一根K线、步进N根、后退N根
5. **交易区**：买入（全仓）、卖出（全量）、做空（全仓）、平空（全量）
6. **账户信息**：当前持仓、现金、盈亏等
7. **数据源状态**：当前使用的数据源标签与日志

---

## 六、前端快捷键

### 6.1 快捷键总览（按功能分类）

#### 会话管理

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `Ctrl+I` | 加载会话 | 根据当前代码、日期和资金初始化，首次加载需拉取历史数据 |
| `Ctrl+R` | 重新训练 | 清空当前会话并恢复到可重新配置的初始状态 |

#### K线步进与回退

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `Space` | 步进到下一根K线 | 若当前K线命中买卖点或节奏提示，会合并弹窗提示 |
| `Shift+Space` | 回退一根K线 | 重建到上一根K线（与后退N根 N=1 相同） |
| `Ctrl+Alt+N` | 连续步进N根 | 按"步进数量 N"设置值连续推进，**遇到买卖点自动停止** |
| `Ctrl+Alt+M` | 后退N根 | 按设置值回退，**自动重建缠论结构**到更早状态 |
| `C` / `center` | 居中到最新K线 | 视图快速定位到最新位置 |

#### 交易操作

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `PageUp` | 买入（全仓） | 以当前收盘价用全部可用现金买入（按手，每手100股） |
| `PageDown` | 卖出（全量） | 以当前价格全部卖出；T+1约束下当天买入的不可卖 |
| （可自定义） | 做空（全仓） | 以当前收盘价用全部可用现金做空，默认无快捷键 |
| （可自定义） | 平空（全量） | 以当前价格全部平空，默认无快捷键 |

#### 双周期切换

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `Tab` | 切换激活图表 | 双周期模式下在 chart1/chart2 间切换，切换后步进/交易操作作用于新激活图 |

#### 视图控制

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `Ctrl+Enter` | 生成水平射线 | 在十字光标当前价位画一条水平射线（贯穿整个图表） |
| `Ctrl+Alt+↑` | 纵向放大 | 放大图表纵轴（价格方向更精细） |
| `Ctrl+Alt+↓` | 纵向缩小 | 缩小图表纵轴 |
| `Ctrl+Alt+←` | 横向放大 | 放大图表横轴（时间方向更稀疏） |
| `Ctrl+Alt+→` | 横向缩小 | 缩小图表横轴 |
| `Ctrl+↑` | 十字光标上移 | 微调光标价格向上一个单位 |
| `Ctrl+↓` | 十字光标下移 | 微调光标价格向下一个单位 |
| `F11` | 全屏切换 | 图表区域全屏/退出全屏 |

#### 面板开关

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `L` | 打开缠论配置面板 | 调整笔/段/中枢/指标等算法参数 |
| `P` | 打开图表显示设置 | 调整样式、颜色、显示项、坐标轴等 |
| `Shift+P` | 打开系统配置 | 维护快捷键配置、数据源优先级、判定模式 |

#### 买卖点判定模式

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `Z` | 切换为**自动**判定模式 | 步进时按上一级结构变向自动判定 ×/✓ |
| `S` | 切换为**手动**判定模式 | 不自动判定，需手动触发检查 |
| `J` | 手动检查买卖点 | 仅手动模式下可用，触发一次三层 ×/✓ 判定 |

> **注意**：`S` 键在全局上下文 = 切换手动模式；在面板上下文中 = 保存配置。系统根据当前焦点自动区分。

#### 弹窗确认

| 快捷键 | 功能 | 适用场景 |
|--------|------|---------|
| `Enter` | 确认弹窗 | 买卖点提示弹窗 / 交易结算弹窗 |

#### 面板内保存（上下文敏感）

| 快捷键 | 功能 | 适用场景 |
|--------|------|---------|
| `S` | 保存并应用 | 缠论配置面板 / 图表显示设置面板 / 系统配置面板内有效 |

### 6.2 快捷键机制详解

#### 三种按键类型

| 类型 | 示例 | 匹配方式 |
|------|------|---------|
| **组合键** | `Ctrl+Alt+N` | 必须同时按下所有修饰键 + 主键 |
| **单键** | `Space`, `Z`, `J` | 单独按下即触发 |
| **连续序列** | `c`,`e`,`n`,`t`,`e`,`r` | 依次在 1.5 秒内键入（如输入 "center" 触发居中） |

#### 上下文隔离

每个快捷键声明了其生效的**上下文 (context)**：

| context | 含义 | 示例 |
|---------|------|------|
| `global` | 任何时候都响应 | Space, Ctrl+I, Z, J |
| `chanSettings` | 仅在缠论配置面板打开时 | S (保存) |
| `chartSettings` | 仅在图表显示设置面板打开时 | S (保存) |
| `systemSettings` | 仅在系统配置面板打开时 | S (保存) |
| `bspPrompt` | 仅在买卖点提示弹窗出现时 | Enter (确认) |
| `settlement` | 仅在交易结算弹窗出现时 | Enter (关闭) |

#### 冲突处理

- 同一快捷键命中多个操作时，按 `SHORTCUT_ACTIONS` 数组**定义顺序**，越靠前优先级越高
- 面板上下文的 `S` 优先于全局的 `S`（因为面板打开时焦点在其内部）
- 自定义界面会实时检测冲突并提示

### 6.3 快捷键自定义规则

在【系统配置】→【快捷键配置】中修改：

```
支持格式：
  - 单键：space, a, f11
  - 组合键：ctrl+a, ctrl+alt+shift+n
  - 连续序列：center, buy
  - 多快捷键：ctrl+i, alt+i （同一功能多个入口，逗号或换行分隔）

别名支持：
  spacebar → space,  esc → escape,  return → enter
  pgup → pageup,  pgdn → pagedown
  cmd/meta/command/win → meta（Mac Command 键）

限制：
  - Backspace 用于删除已录入的快捷键，不录为快捷键本身
  - 序列缓冲区最多 12 个按键
  - 序列超时 1500ms（1.5秒内未完成输入则清空缓冲区）
```

保存后立即生效，无需重启。

---

## 七、缠论配置面板

按 `L` 或点击【缠论配置...】按钮打开，包含以下配置分组：

### 7.1 主逻辑 (Algo)

| 配置项 | 字段名 | 类型 | 选项/默认值 | 说明 |
|--------|--------|------|------------|------|
| 缠论主逻辑 | `chan_algo` | select | classic(原缠论) / new(新缠论) | 新缠论使用"新K线->分型->笔->段->2段"递推逻辑 |

### 7.2 笔配置 (Bi)

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 笔是否严格 | `bi_strict` | checkbox | 开启后分型间必须至少有一根独立K线 |
| 笔算法 | `bi_algo` | select | normal(常规) / fx(分型) |
| 分型检查 | `bi_fx_check` | select | strict(严格) / normal(常规) |
| 缺口当K线 | `gap_as_kl` | checkbox | 是否将缺口视为一根K线 |
| 笔终点是极值 | `bi_end_is_peak` | checkbox | 笔结束点是否必须是区间内最高/最低点 |
| 允许次极值 | `bi_allow_sub_peak` | checkbox | 是否允许笔在次极值处结束 |

### 7.3 线段配置 (Seg)

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 线段算法 | `seg_algo` | select | chan(标准缠论) / simple(简单线段) |
| 左端点方法 | `left_seg_method` | select | peak(极值) / all(所有) |

### 7.4 中枢配置 (ZS)

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 中枢算法 | `zs_algo` | select | normal(常规) / mac(MAC算法) |
| 中枢合并 | `zs_combine` | checkbox | 是否自动合并重叠的中枢 |
| 合并模式 | `zs_combine_mode` | select | zs(按中枢) / peak(按极值) |
| 一笔中枢 | `one_bi_zs` | checkbox | 是否允许由单笔构成的中枢 |

### 7.5 均线与指标配置 (Ind)

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 均线周期 | `mean_metrics` | text | 如 `5,10,20`，逗号分隔 |
| 趋势线周期 | `trend_metrics` | text | 如 `20,60` |
| MACD 快线 | `macd_fast` | number | 默认 12 |
| MACD 慢线 | `macd_slow` | number | 默认 26 |
| MACD 信号 | `macd_signal` | number | 默认 9 |
| BOLL 周期 | `boll_n` | number | 布林带计算周期 |
| 计算 Demark | `cal_demark` | checkbox | 是否计算 Demark 指标 |
| 计算 RSI | `cal_rsi` | checkbox | 是否计算 RSI 指标 |
| RSI 周期 | `rsi_cycle` | number | RSI 计算周期，默认 14 |
| 计算 KDJ | `cal_kdj` | checkbox | 是否计算 KDJ 指标 |
| KDJ 周期 | `kdj_cycle` | number | KDJ 计算周期，默认 9 |

### 7.6 买卖点配置 (BSP)

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 背驰比率阈值 | `divergence_rate` | text | 判定背驰的阈值，默认 inf |
| 最小中枢数量 | `min_zs_cnt` | number | 产生1类买卖点所需的最小中枢数量 |
| 1类点需多笔中枢 | `bsp1_only_multibi_zs` | checkbox | 1类买卖点是否仅在由多笔构成的中枢后产生 |
| 2类点最大回撤率 | `max_bs2_rate` | number | 2类买卖点允许的最大回撤比例 (0-1) |

### 7.7 配置保存与生效

修改完成后按 `S` 或点击【保存并应用】按钮，配置立即生效：
- 若未加载会话：配置暂存，加载时传入
- 若已加载会话：调用 `/api/reconfig` 重新计算，不重拉数据

---

## 八、图表显示设置面板

按 `P` 或点击【图表显示设置...】按钮打开，包含以下分组：

### 8.1 主题 (theme_section)

| 配置项 | 字段名 | 选项 |
|--------|--------|------|
| 主题 | `theme` | 白色(light) / 黑色(dark) / 护眼(eye-care) |

### 8.2 十字光标 (crosshair)

可配置宽度、颜色、字体大小。

### 8.3 K线与分型 (fx / fract)

可配置宽度、颜色、虚线样式。

### 8.4 笔/段/2段 (bi / seg / segseg)

可配置确定态/不确定态的线宽与颜色。

### 8.5 中枢显示 (fractZs / biZs / segZs / segsegZs)

可配置是否显示各级别中枢，以及宽度和颜色。

### 8.6 K线蜡烛 (candle)

可配置蜡烛宽度与上涨/下跌颜色。

### 8.7 买卖点 (bspBi / bspSeg / bspSegseg)

可配置各级别买卖点的字号、线宽、颜色、虚线样式。

### 8.8 节奏线 (rhythmLine)

可配置5组节奏线的颜色、线宽、线型、字体大小等。

### 8.9 筹码分布 (chip)

可配置是否启用筹码分布、拉伸级别、分桶步长。

### 8.10 指标 (indicators)

可配置主图/副图指标槽位，如 MACD、KDJ、RSI、BOLL、趋势线等。

### 8.11 X 轴设置 (xAxis)

用于控制图表底部时间轴的显示方式：

#### 手动设置模式

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 文字大小 | `fontSize` | number | X轴刻度文字大小（8-24） |
| 文字方向(度) | `rotation` | number | 文字旋转角度（-180 到 180），如 -45 表示向左倾斜45度 |
| 文字粗细 | `fontWeight` | select | normal(常规) / bold(加粗) |
| 刻度间隔 | `interval` | number | 每隔多少根K线显示一个日期标签（1-100） |

#### 自动设置模式

自动模式会根据图表缩放密度（K线图放大/缩小）动态调整显示效果：

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 最小字体大小 | `autoMinFontSize` | number | 密集时最小字体（默认10） |
| 最大字体大小 | `autoMaxFontSize` | number | 稀疏时最大字体（默认14） |
| 密集时旋转角度 | `autoDenseRotation` | number | K线密集时旋转角度（默认-90，即垂直） |
| 稀疏时旋转角度 | `autoSparseRotation` | number | K线稀疏时旋转角度（默认-35） |
| 密集时字体粗细 | `autoDenseFontWeight` | select | 密集时 normal(常规) / bold(加粗) |
| 稀疏时字体粗细 | `autoSparseFontWeight` | select | 稀疏时 normal(常规) / bold(加粗) |

**自动逻辑说明：**
- 当K线图进行**缩小**时，X轴日期自动切换为**最小字体**（`autoMinFontSize`），角度为 **-90度（垂直）**，确保密集日期可读
- 当K线图进行**放大**时，X轴日期自动切换为**最大字体**（`autoMaxFontSize`），角度变缓（`autoSparseRotation`），可显示更完整信息
- **非分钟周期**（日线、周线、月线、季线、年线）只显示日期，不显示具体时间

### 8.12 Y 轴设置 (yAxis)

用于控制图表右侧价格轴的显示方式：

#### 手动设置模式

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 文字大小 | `fontSize` | number | Y轴刻度文字大小（8-24） |
| 文字粗细 | `fontWeight` | select | normal(常规) / bold(加粗) |
| 刻度间隔(价格) | `interval` | number | 价格轴刻度步长（0.001-100） |

#### 自动设置模式

自动模式会根据图表纵向缩放密度动态调整精度和样式：

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 最小字体大小 | `autoMinFontSize` | number | 密集时最小字体（默认11） |
| 最大字体大小 | `autoMaxFontSize` | number | 稀疏时最大字体（默认14） |
| 密集时字体粗细 | `autoDenseFontWeight` | select | 密集时 normal(常规) / bold(加粗) |
| 稀疏时字体粗细 | `autoSparseFontWeight` | select | 稀疏时 normal(常规) / bold(加粗) |
| 最大小数位数 | `autoMaxDigits` | number | 价格小数最大显示位数（默认6） |

**自动逻辑说明：**
- 当图表进行**放大**时，Y轴精度**更细致**（显示更多小数位）
- 当图表进行**缩小**时，Y轴精度**更粗略**（自动减少小数位）
- 字体大小和粗细也会随缩放密度自适应调整，确保在看清刻度数值的前提下显示最详细的价格信息

### 8.13 合并K线线框 (klineCombineFrame)

根据分型合并后的K线范围绘制独立线框层，便于观察笔与分型的关系：

| 配置项 | 字段名 | 类型 | 说明 |
|--------|--------|------|------|
| 启用线框 | `enabled` | checkbox | 是否绘制合并K线线框 |
| 线框颜色 | `color` | color | 线框颜色（默认 #6366f1） |
| 线框粗细 | `lineWidth` | number | 线宽（0.1-5，默认1.2） |
| 线框线型 | `lineStyle` | select | solid(实线) / dashed(虚线) / dotted(点线) |

---

## 九、核心类说明

### 9.1 ChanStepper

步进器，负责K线迭代与缠论计算：

| 属性 | 说明 |
|------|------|
| `chan` | 当前缠论对象 `CChan` |
| `step_idx` | 当前步进索引 |
| `code` | 股票代码 |
| `k_type` | K线周期类型 |
| `kline_all` | 全历史K线列表 |
| `indicators` | 指标引擎（MACD/KDJ/RSI/BOLL/Demark） |

### 9.2 PaperAccount

模拟账户，支持做多与做空（单持仓，多空互斥）：

| 属性 | 说明 |
|------|------|
| `initial_cash` | 初始资金 |
| `cash` | 当前现金 |
| `position` | 持仓股数（正=多仓，负=空仓，0=空仓） |
| `avg_cost` | 平均成本（开仓价） |
| `last_open_step` | 最近一次开仓步进索引（多/空通用） |
| `last_trade_step` | 最近一次成交步进索引 |

**交易规则：**
- 单持仓：同时只能持有一个方向（多或空），多空互斥
- T+1：当天开仓的仓位当天不能平仓（`step_idx >= last_open_step + 1`）
- 每步最多一笔：每个步进索引最多发生一次买卖成交
- 同步反手：平多当步可立即开空，平空当步可立即开多（不受"每步一笔"限制）
- 按手买入：`hands = int(cash // (price * 100))`，每手100股

**做多方法：**
| 方法 | 说明 |
|------|------|
| `buy_with_all_cash(price, step_idx)` | 全仓做多，返回 `{hands, shares, cost}` |
| `can_sell(step_idx)` | 检查是否可卖出（T+1） |
| `sell_all(price, step_idx)` | 全仓平多，返回 `{shares, proceeds, pnl}` |

**做空方法：**
| 方法 | 说明 |
|------|------|
| `short_with_all_cash(price, step_idx)` | 全仓做空，返回 `{shares, proceeds}` |
| `can_cover(step_idx)` | 检查是否可平空（T+1） |
| `cover_all(price, step_idx)` | 全仓平空，返回 `{shares, cost, pnl}` |

### 9.3 AppState

全局会话状态，管理双周期图表、交易事件、买卖点历史、节奏提示等。

---

## 十、API 接口列表

### 10.1 初始化会话

**POST** `/api/init`

初始化缠论回放会话，是所有操作的起点。

**请求体 (InitReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `code` | string | 是 | 股票代码，如 `sz.000001` |
| `begin_date` | string | 是 | 开始日期，格式 `YYYY-MM-DD` |
| `end_date` | string | 否 | 结束日期，格式 `YYYY-MM-DD` |
| `initial_cash` | float | 否 | 初始资金，默认 10000 |
| `autype` | string | 否 | 复权类型：`qfq`（默认）/`hfq`/`none` |
| `chan_config` | dict | 否 | 缠论配置参数 |
| `k_type` | string | 否 | 周期类型，默认 `daily` |
| `chart_mode` | string | 否 | 图表模式：`single`（默认）或 `dual` |
| `k_type_2` | string | 否 | 双周期模式下的第二周期 |
| `active_chart_id` | string | 否 | 激活图表：`chart1`（默认）或 `chart2` |
| `confirm_offline` | bool | 否 | 确认使用离线数据，默认 False |
| `data_source_priority` | list | 否 | 自定义数据源优先级 |
| `data_form_mode` | string | 否 | 数据形态模式：`traditional` / `quantity` / `tick_traditional` / `tick_quantity` |
| `data_form_quantity` | int | 否 | 聚合数量 |
| `data_feed_mode` | string | 否 | 喂入模式：`step`（默认，逐步喂入）/ `unified`（统一喂入，仅看图） |
| `rollback_cache_depth` | int | 否 | 轻量快照队列最大长度，默认 96 |
| `rollback_full_snapshot_interval` | int | 否 | 全量快照间隔步数，默认 8 |
| `rollback_capture_max_bars` | int | 否 | 单根数据集K线数阈值，<=此值时强制每步全量快照，默认 800 |

**返回：** 包含缠论结构数据、账户状态、K线信息等的完整 payload

**异常：** 若需要离线数据确认，返回 409 状态码，detail 包含离线确认信息

---

### 10.2 重新配置

**POST** `/api/reconfig`

在不重新加载数据的情况下，用新缠论配置重新计算结构。

**请求体 (ReconfigReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `chan_config` | dict | 是 | 新的缠论配置参数 |
| `data_form_mode` | string | 否 | 数据形态模式 |
| `data_form_quantity` | int | 否 | 聚合数量 |
| `data_feed_mode` | string | 否 | 喂入模式：`step` / `unified` |
| `rollback_cache_depth` | int | 否 | 轻量快照队列最大长度 |
| `rollback_full_snapshot_interval` | int | 否 | 全量快照间隔步数 |
| `rollback_capture_max_bars` | int | 否 | 单根数据集K线数阈值 |

---

### 10.3 步进

**POST** `/api/step`

向前推进一根K线，更新缠论结构。

**请求体 (StepReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `judge_mode` | string | 否 | 判定模式：`auto`（默认）或 `manual` |
| `active_chart_id` | string | 否 | 激活图表 ID |
| `n` | int | 否 | 连续步进根数，默认 1（单根步进） |

---

### 10.4 买卖点判定

**POST** `/api/judge_bsp`

对当前缠论结构执行买卖点判定。

**请求体 (JudgeBspReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `reason` | string | 否 | 判定原因描述，默认 `manual_check` |

---

### 10.5 买入

**POST** `/api/buy`

以当前价格全仓买入（按手买入，每手100股）。

---

### 10.6 卖出

**POST** `/api/sell`

以当前价格全部持仓卖出。

---

### 10.7 做空

**POST** `/api/short`

以当前价格做空（按整手卖出，每手100股）。与做多共用同一资金池，单持仓模式（多空互斥）。

---

### 10.8 平空

**POST** `/api/cover`

平掉所有做空头寸，按当前价格买回。

---

### 10.9 后退N步

**POST** `/api/back_n`

回退指定步数并重建缠论结构。

**请求体 (BackNReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `n` | int | 是 | 步数，必须 >= 1 |

---

### 10.10 跳转到指定步

**POST** `/api/goto_step`

跳转到指定步进索引，用于从回测成交记录快速定位到对应历史K线位置。

**请求体 (GotoStepReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `step_idx` | int | 是 | 目标步进索引 |

---

### 10.11 查看K线数据

**POST** `/api/session_kline_view`

查看当前会话的K线数据（含合并K线框），供前端独立绘制。

**请求体 (SessionKlineViewReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `chart_id` | string | 否 | 图表ID（chart1/chart2），默认 chart1 |

---

### 10.12 指标+买卖点组合回测

**POST** `/api/indicator_backtest`

基于指标条件+买卖点组合进行策略回测。支持自定义入场/离场条件、双周期模式。

**别名：** `/api/strategy_backtest`（兼容旧路径，功能相同）

**请求体 (IndicatorBacktestReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `code` | string | 是 | 股票代码 |
| `begin_date` | string | 是 | 开始日期 |
| `end_date` | string | 是 | 结束日期 |
| `k_type` | string | 否 | K线周期，默认 day |
| `k_type_2` | string | 否 | 双周期模式下的第二周期 |
| `autype` | string | 否 | 复权类型（qfq/hfq/none），默认 qfq |
| `initial_cash` | float | 否 | 初始资金，默认 100000 |
| `chan_config` | object | 否 | 缠论配置 |
| `chart_mode` | string | 否 | 图表模式（single/dual），默认 single |
| `step_driver` | string | 否 | 步进驱动（auto/k1/k2），默认 auto |
| `entry_conditions` | array | 是 | 入场条件列表 |
| `entry_combine` | string | 否 | 入场条件组合方式（and/or），默认 and |
| `exit_conditions` | array | 否 | 离场条件列表 |
| `exit_combine` | string | 否 | 离场条件组合方式（and/or），默认 and |
| `exit_hold` | int | 否 | 持仓最大K线数，超时强制离场 |
| `confirm_offline` | bool | 否 | 是否确认使用离线数据 |
| `data_source_priority` | array | 否 | 数据源优先级列表 |
| `data_form_mode` | string | 否 | 数据形态模式 |
| `data_form_quantity` | int | 否 | 数量模式下的K线数量 |

**返回示例：**
```json
{
  "code": "000001",
  "name": "平安银行",
  "chart_mode": "single",
  "k_type": "day",
  "bars": 500,
  "initial_cash": 100000.0,
  "final_equity": 105200.0,
  "total_pnl": 5200.0,
  "total_return_pct": 5.2,
  "trade_count": 12,
  "win_count": 7,
  "loss_count": 5,
  "win_rate_pct": 58.33,
  "trades": [...]
}
```

---

### 10.13 获取状态

**GET** `/api/state`

获取当前会话的完整状态 payload。

---

### 10.14 结束会话

**POST** `/api/finish`

标记训练结束，但保持数据可用。

---

### 10.15 设置数据源优先级

**POST** `/api/set_data_source_priority`

**请求体：**

```json
{
  "priority": ["AKShare", "BaoStock", "离线数据"]
}
```

---

### 10.16 检测数据源

**POST** `/api/check_data_source`

探测指定数据源是否能正常获取测试股票的日线数据。

**请求体：**

```json
{
  "name": "AKShare"
}
```

返回 `{ok: true/false, name: "xxx", message: "..."}`

---

### 10.17 重置会话

**POST** `/api/reset`

重置所有状态，清空账户、历史记录等。

---

### 10.18 退出服务

**POST** `/api/exit`

关闭服务器进程。

---

## 十一、周期类型 (KL_TYPE)

| 字符串 | 枚举值 | 说明 |
|--------|--------|------|
| `1min` | K_1M | 1分钟 |
| `3min` | K_3M | 3分钟 |
| `5min` | K_5M | 5分钟 |
| `15min` | K_15M | 15分钟 |
| `30min` | K_30M | 30分钟 |
| `60min` | K_60M | 60分钟 |
| `daily` | K_DAY | 日线 |
| `weekly` | K_WEEK | 周线 |
| `monthly` | K_MON | 月线 |
| `quarterly` | K_QUARTER | 季线 |
| `yearly` | K_YEAR | 年线 |

---

## 十二、数据形态与喂入模式

### 12.1 概述

`a_replay_trainer.py` 支持 **4 种数据形态模式** 和 **2 种数据喂入模式**，两者可自由组合，影响 K 线的生成方式和缠论引擎的步进行为。

### 12.2 数据形态模式 (data_form_mode)

数据形态模式决定 K 线在进入缠论引擎**之前**如何被加工处理。由 `normalize_data_form_mode()` 归一化，可选值：`traditional`、`quantity`、`tick_traditional`、`tick_quantity`。

#### 12.2.1 traditional（传统模式，默认）

直接使用数据源返回的原始 K 线，不做任何聚合或合成。

| 特性 | 说明 |
|------|------|
| 数据来源 | 在线数据源（AKShare/BaoStock 等）或离线分笔合成 |
| K 线数量 | 等于数据源返回的原始根数 |
| 适用场景 | 标准复盘训练、逐根 K 线步进 |
| 筹码分布 | 在线源走三角分摊，离线源走 chip_tick_bins 直加 |

#### 12.2.2 quantity（数量聚合模式）

将原始 N 根 K 线按用户指定的数量 Q **等分合并**为 Q 根新 K 线。

| 特性 | 说明 |
|------|------|
| 聚合算法 | `aggregate_klu_by_quantity()`：前 Q-1 组各取 `N//Q` 根，第 Q 组取余数 |
| OHLCV 规则 | open=首根开盘价，close=末根收盘价，high/low=组内极值，volume=组内求和 |
| 参数范围 | Q ∈ [1, N]，Q=1 全部合并为 1 根，Q=N 不聚合 |
| 适用场景 | 长期趋势分析（Q=50~100）、波段复盘（Q=20~30）、极端压力测试（Q=5） |
| 筹码分布 | 聚合后的 K 线继承原始 chip_tick_bins（累加合并） |
| 双周期兼容 | 细周期数量模式时，粗周期末根防泄漏优先使用 `_replay_klus_master_raw` |

> 详细算法见 §二十一（数量模式逻辑说明）。

#### 12.2.3 tick_traditional（分笔价格合成传统模式）

从 `a_Data/` 下的分笔 txt 文件合成 K 线，按时间顺序排列。

| 特性 | 说明 |
|------|------|
| 数据来源 | **仅离线分笔**（`a_Data/六位代码/YYYYMMDD_代码.txt`） |
| 合成路径 | 分笔 → 内存 1 分钟 OHLCV → 目标周期 K 线 |
| K 线数量 | 等于合成后的自然根数 |
| 筹码分布 | 高精度 chip_tick_bins（分笔价量直加，不走三角分摊） |
| 适用场景 | 有离线分笔数据、需要高精度筹码分布的场景 |
| 限制 | 必须存在日期区间内的分笔文件，否则报错 |

#### 12.2.4 tick_quantity（分笔价格合成数量模式）

从分笔 txt 合成 K 线后，再按数量 Q 聚合。

| 特性 | 说明 |
|------|------|
| 数据来源 | **仅离线分笔** |
| 合成路径 | 分笔 → 1 分钟 → 目标周期 → 数量聚合 |
| 筹码分布 | 高精度 chip_tick_bins（聚合时累加合并） |
| 适用场景 | 离线分笔 + 需要压缩 K 线数量的场景 |

#### 12.2.5 四种数据形态对比

| 维度 | traditional | quantity | tick_traditional | tick_quantity |
|------|------------|----------|-----------------|---------------|
| 数据来源 | 在线/离线均可 | 在线/离线均可 | 仅离线分笔 | 仅离线分笔 |
| K 线加工 | 无 | 等分聚合 | 分笔合成 | 分笔合成+聚合 |
| 筹码精度 | 取决于数据源 | 取决于数据源 | 高（分笔直加） | 高（分笔直加） |
| 步进次数 | = 原始根数 | = Q（可大幅减少） | = 合成根数 | = Q |
| 离线依赖 | 否 | 否 | **是** | **是** |
| reconfig 支持 | ✅ | ✅（重建会话） | ✅（重建会话） | ✅（重建会话） |

### 12.3 数据喂入模式 (data_feed_mode)

控制 K 线如何喂给缠论引擎，由 `normalize_data_feed_mode()` 归一化，可选值：`step`、`unified`。

#### 12.3.1 step（逐步喂入，默认）

通过 `CChan.step_load()` 逐根喂入 K 线，每根 K 线触发一次完整的缠论重算。

| 特性 | 说明 |
|------|------|
| 喂入方式 | 逐根 `step_load()`，支持增量计算 |
| 步进控制 | ✅ 支持 Space 步进、Ctrl+Alt+N 连续步进 |
| 回退支持 | ✅ 支持 back_n / goto_step / Shift+Space |
| 模拟交易 | ✅ 买入/卖出/做空/平空全部可用 |
| 买卖点判定 | ✅ 自动/手动判定均可用 |
| 回退缓存 | ✅ 轻量增量 + 全量深拷贝双层快照 |
| 适用场景 | 交互式复盘训练、模拟操盘 |

#### 12.3.2 unified（统一喂入）

通过 `CChan.trigger_load()` 一次性喂入全部 K 线，缠论结构一次性计算完毕。

| 特性 | 说明 |
|------|------|
| 喂入方式 | 一次性 `trigger_load()`，全量计算 |
| 步进控制 | ❌ 不支持（K 线已全部喂入） |
| 回退支持 | ❌ 不支持 |
| 模拟交易 | ❌ 买入/卖出/做空/平空按钮灰色，API 返回 400 |
| 买卖点判定 | ❌ 不支持（无步进过程） |
| 回退缓存 | ❌ 不适用 |
| 适用场景 | 仅查看缠论结构全貌、快速浏览、截图导出 |

#### 12.3.3 两种喂入模式对比

| 维度 | step（默认） | unified |
|------|-------------|---------|
| 前端步进按钮 | ✅ 可用 | ❌ 灰色禁用 |
| 前端交易按钮 | ✅ 可用 | ❌ 灰色禁用 |
| 快捷键 Space | ✅ 步进 | ❌ 无效 |
| 快捷键 Ctrl+Alt+N | ✅ 连续步进 | ❌ 无效 |
| 回退操作 | ✅ 支持 | ❌ 不支持 |
| 买卖点弹窗 | ✅ 自动/手动 | ❌ 不触发 |
| 筹码分布 | ✅ 正常显示 | ✅ 正常显示 |
| 缠论结构 | ✅ 逐步呈现 | ✅ 一次性全量 |
| 性能 | 每步轻量计算 | 一次性全量计算 |
| 双/多周期防泄漏 | ✅ 逐根修正 | ❌ 跳过（无步进） |

### 12.4 模式组合矩阵

数据形态模式 × 数据喂入模式 = 8 种组合，各组合的可用功能：

| 形态 \ 喂入 | step | unified |
|-------------|------|---------|
| **traditional** | 全功能复盘训练 ✅ | 仅看图，缠论全量展示 |
| **quantity** | 聚合后逐根步进 ✅ | 聚合后全量展示 |
| **tick_traditional** | 分笔合成后逐根步进 ✅ | 分笔合成后全量展示 |
| **tick_quantity** | 分笔合成+聚合后步进 ✅ | 分笔合成+聚合后全量展示 |

> **推荐组合**：`traditional` + `step`（标准复盘训练）、`traditional` + `unified`（快速浏览缠论结构）。

---

## 十三、离线数据支持

本服务器支持从 `a_Data` 目录读取离线数据：

- **仅分笔落盘**：`a_Data/六位代码/YYYYMMDD_六位代码.txt`，无独立 1 分钟离线文件
- **内存聚合**：分笔先合成内部 1 分钟 OHLCV，再聚合为请求周期
- **自动扫描**：按代码子目录 `os.listdir` 匹配文件名，新增股票只需加目录与 txt
- **自动探测**：init 时 `offline_bundle_exists` 检测日期区间内是否有分笔文件

---

## 十四、回退缓存机制

### 14.1 概述

回退缓存是步进回退（`back_n` / `goto_step`）的**性能核心**。每次步进时系统自动抓取快照，回退时从最近的快照恢复，避免从头重建。

### 14.2 分层快照架构

系统采用**轻量增量 + 稀疏全量**双层快照策略：

```
步进 N 步
  ├─ 每步：抓取轻量增量快照 (AppStepDelta) → 存入 _rollback_light 队列
  └─ 每 interval 步：额外抓取全量深拷贝快照 (AppRollbackSnapshot) → 存入 _rollback_full 字典

回退到目标步 target：
  ① 先查 _rollback_target_hits（精确命中表）
  ② 再查 _rollback_full（最近的全量快照）
  ③ 从全量快照恢复后，用轻量快照逐步前向补到 target
```

### 14.3 快照类型对比

| 类型 | 类名 | 存储位置 | 抓取频率 | 恢复方式 |
|------|------|---------|---------|---------|
| **轻量增量** | `AppStepDelta` | `_rollback_light` (deque, maxlen=96) | 每步 | 浅拷贝字段覆盖，O(列表长度) |
| **全量深拷贝** | `AppRollbackSnapshot` | `_rollback_full` (dict) | 每 8 步 | `copy.deepcopy` 递归恢复 |
| **精确命中** | `AppRollbackSnapshot` | `_rollback_target_hits` (dict) | 到达过的目标步 | 直接 deepcopy 恢复，无需补步 |

### 14.4 轻量增量快照 (AppStepDelta)

位于 [a_step_rollback_fast.py](file:///c:\Users\Administrator\Desktop\my_file1\my_file\3\chan.py\a_replay_cache\a_step_rollback_fast.py)，核心设计：

- **浅拷贝列表**：`trade_events`、`bsp_history`、`bsp_judge_logs`、`rhythm_hit_history` 等用 `list(...)` 浅拷贝
- **冻结 bsp_history**：每个 item dict 浅拷贝隔离，防止原地改写穿透快照
- **PaperAccount 转 tuple**：`(cash, position, avg_cost, last_open_step, last_trade_step, initial_cash)` 逐字段写回
- **零递归走访**：不遍历 chan 对象树，单步开销恒定

### 14.5 回退缓存参数

可在 `build_payload()` 返回的 `rollback_config` 中查看当前状态：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `cache_depth` | 96 | 轻量快照队列最大长度（`_rollback_max`），超出时自动丢弃最旧的 |
| `full_snapshot_interval` | 8 | 全量快照间隔步数，>1 时每步只产生轻量 delta，间隔步才做全量 deepcopy |
| `capture_max_bars` | 800 | 单根数据集 K 线数阈值，<= 此值时强制每步全量快照 |

### 14.6 回退流程

```
/api/back_n (n=5)
  → cur = active_stepper.step_idx
  → target = max(0, cur - n)
  → rebuild_to_step(target)
      → 查找最近的全量快照（step_idx <= target）
      → 从全量快照恢复 chan + 状态
      → 从轻量快照逐步前向补到 target
      → 双周期模式下同步重建两图
```

### 14.7 性能考量

| 场景 | 开销 | 说明 |
|------|------|------|
| 步进（每步） | O(列表长度) 浅拷贝 | 轻量 delta，不遍历 chan 树 |
| 全量快照（每 8 步） | O(chan 树大小) deepcopy | 递归走访笔/段/中枢链表 |
| 回退（近距离） | O(补步数) | 从轻量快照逐步恢复 |
| 回退（远距离） | O(chan 树大小) deepcopy | 从全量快照一次性恢复 |

---

## 十五、使用流程示例

1. **启动服务**：`python replay_trainer.py`
2. **打开前端**：浏览器访问 `http://127.0.0.1:8000/`
3. **配置会话**：输入股票代码、日期范围、初始资金
4. **加载会话**：按 `Ctrl+I` 或点击【加载会话】
5. **步进回放**：按 `Space` 逐步回放K线
6. **调整配置**：按 `L` 打开缠论配置，按 `P` 打开图表设置
7. **买卖点判定**：
   - 自动模式：步进时自动判定（默认）
   - 手动模式：按 `S` 切换为手动，按 `J` 检查买卖点
8. **模拟交易**：按 `PageUp` 买入，`PageDown` 卖出；做空/平空可在系统配置中设置快捷键
9. **连续步进**：按 `Ctrl+Alt+N` 连续步进N根
10. **后退回放**：按 `Ctrl+Alt+M` 回退N根，按 `Shift+Space` 回退一根
11. **结束训练**：点击【结束训练】
12. **重置会话**：按 `Ctrl+R` 开始新股票

---

## 十五、图表模式 (chart_mode)

`a_replay_trainer.py` 支持 **3 种图表模式**，由 `normalize_replay_chart_mode()` 归一化，可选值：`single`、`dual`、`multi`。

### 15.1 三种图表模式概览

| 维度 | single（单图） | dual（双图） | multi（单品种多周期单图） |
|------|--------------|-------------|--------------------------|
| 图表数量 | 1 个 | 2 个（上下排列） | 1 个（多周期叠加） |
| 股票品种 | 1 个 | 1 个 | 1 个 |
| 周期数量 | 1 个 | 2 个（可不同） | 2~5 个（可不同） |
| 步进驱动 | 唯一周期 | 驱动周期（step_driver） | 最细周期（自动确定） |
| 激活图切换 | 无 | Tab 键 | 无（单图） |
| 缠论引擎 | 1 个 CChan | 2 个独立 CChan | 每层 1 个独立 CChan |
| 时间同步 | 无 | 锚点时间对齐 | 锚点时间对齐 |
| 防未来数据 | 无 | 粗周期末根修正 | 粗周期末根修正 |
| 坐标映射 | 无 | 无 | X 轴统一映射到驱动周期 |
| 筹码分布 | 单图显示 | 两图独立显示 | 单图显示（驱动周期） |
| 买卖点判定 | 单图 | 激活图 | 驱动周期层 |
| 节奏系统 | 单图 | 激活图 | 驱动周期层 |

### 15.2 single（单图模式，默认）

最基础的模式，一个股票一个周期一张图。

| 特性 | 说明 |
|------|------|
| 前端布局 | 单张 K 线图，无图切换按钮 |
| 步进逻辑 | 唯一 stepper 控制步进 |
| 适用场景 | 标准复盘训练、单周期分析 |

### 15.3 dual（双图模式）

同一股票的两个不同周期分别显示在上下两张图中，详见 §二十（单品种双周期操作规则）。

| 特性 | 说明 |
|------|------|
| 前端布局 | 上下两张图，图1在上、图2在下，中间有分隔条可拖拽调整比例 |
| 激活图 | 有蓝色边框高亮，Tab 键切换 |
| 步进驱动 | `step_driver` 参数控制：`auto`（自动选细周期）、`k1`（图1驱动）、`k2`（图2驱动） |
| 同步机制 | 驱动图步进后，被动图步进到锚点时间，粗周期末根 OHLCV 防泄漏修正 |
| 独立配置 | 两图可分别设置缠论参数和画线样式 |
| 适用场景 | 跨周期分析（如日线+30分钟线联动）、多周期买卖点确认 |

### 15.4 multi（单品种多周期单图模式）

同一股票的 **2~5 个不同周期**叠加显示在**同一张图**中，是 dual 模式的扩展。

#### 15.4.1 核心概念

```
驱动周期（driver）：最细粒度的周期，控制步进节奏
被动层（passive layers）：其余周期，跟随驱动周期同步
```

- 驱动周期由系统自动确定：按 `kl_granularity_rank()` 排序，取最细周期
- 被动层按从细到粗排列，每层有独立的 CChan 引擎
- 所有层的 K 线 X 坐标统一映射到驱动周期的步进索引

#### 15.4.2 初始化参数

在【会话配置】中设置 `chart_mode` 为 `multi`，并勾选 `k_types_multi`（至少 2 个周期）：

```json
{
  "chart_mode": "multi",
  "k_types_multi": ["day", "60min", "30min", "15min", "5min"]
}
```

| 参数 | 说明 |
|------|------|
| `k_types_multi` | 周期列表，最少 2 个，最多 5 个（`MULTI_CHART_MAX_LAYERS`） |
| 驱动周期 | 自动取最细周期（如 5min） |
| 被动层 | 其余周期按从细到粗排列 |

#### 15.4.3 步进逻辑

```
1. 驱动周期 stepper.step() → 载入下一根 K 线
2. 对每个被动层 stepper：
   → 步进到驱动周期的锚点时间
   → 粗周期末根 OHLCV 防未来数据修正
3. 所有层的缠论结构独立计算
4. 坐标映射：remap_overlay_chart_to_driver_x()
   → 将被动层的 K 线索引映射到驱动周期的 X 轴
5. 买卖点判定仅基于驱动周期层
```

#### 15.4.4 前端显示

| 特性 | 说明 |
|------|------|
| 图表数量 | **1 张图**，所有周期叠加显示 |
| K 线显示 | 驱动周期的 K 线正常显示，被动层 K 线以半透明/细线叠加 |
| 缠论结构 | 每层的笔/段/中枢以不同颜色区分，可独立开关 |
| 图例 | 显示各层颜色对应关系 |
| 筹码分布 | 仅显示驱动周期的筹码 |
| 节奏线 | 仅基于驱动周期计算 |

#### 15.4.5 回退缓存

multi 模式的回退快照 (`AppRollbackSnapshot`) 额外包含：

```python
multi_steppers: Optional[list[StepperRollbackSnapshot]]
```

回退时同时恢复所有被动层 stepper 的状态，确保各层步进索引一致。

#### 15.4.6 与 dual 模式的关键差异

| 维度 | dual | multi |
|------|------|-------|
| 图表数量 | 2 张独立图 | 1 张叠加图 |
| 周期上限 | 2 个 | 5 个 |
| 激活图概念 | 有（Tab 切换） | 无 |
| 坐标系统 | 各自独立 X 轴 | 统一映射到驱动周期 X 轴 |
| 前端复杂度 | 两张图各自渲染 | 单图多层叠加渲染 |
| 适用场景 | 两周期对比分析 | 多周期共振分析、层级联立观察 |

#### 15.4.7 使用限制

- 最多 5 个周期（`MULTI_CHART_MAX_LAYERS`），超出报错
- 周期不可重复，重复的自动去重
- unified 喂入模式下 multi 模式正常工作（一次性全量计算所有层）
- 仅支持单品种，不支持跨品种叠加

---

## 十六、ReplayChan 特殊说明

`ReplayChan` 是 `CChan` 的子类，专门用于回放场景：

- 构造函数接收 `replay_klus_master` 参数，传入内存缓存的K线单元列表
- `load()` 方法从内存快照 deepcopy 后喂给迭代器，避免重复请求行情
- 数据层与配置层解耦，笔/线段/中枢/买卖点随 ChanConfig 重新计算

## 十七、新缠论模式 (CHAN_ALGO_NEW) 买卖点显示说明

### 20.1 新缠论与经典缠论的买卖点计算差异

当缠论主逻辑 (`chan_algo`) 设置为 `new`（新缠论）时，买卖点的计算方式与经典模式 (`classic`) **完全不同**：

| 对比项 | 经典模式 (classic) | 新缠论模式 (new) |
|--------|-------------------|------------------|
| **笔买卖点来源** | CChan 内置的 `kl_list.bs_point_lst` | 通过 `build_level_bsp(bi_list, seg_list)` 从重建的线段列表计算 |
| **段买卖点来源** | CChan 内置的 `kl_list.seg_bs_point_lst` | 通过 `build_level_bsp(seg_list, segseg_list)` 从重建的线段列表计算 |
| **2段买卖点来源** | 通过 `build_level_bsp(segseg_list, segsegseg_list)` 额外计算 | 同样通过 `build_level_bsp(segseg_list, segsegseg_list)` 计算 |
| **层级构建基础** | 使用 CChan 原生的 bi_list / seg_list / segseg_list | 从K线重新构建：分型→笔→段→2段→隐藏层 |

### 20.2 新缠论模式下的完整数据流

步进K线时，买卖点的显示经过以下步骤：

```
步进 (api_step)
  → stepper.step() — 推进一根K线
  → structure_bundle = None — 清除缓存
  → sync_bsp_history()
    → _current_bsp_snapshot()
      → get_structure_bundle() — 缓存失效，触发重建
        → build_new_bundle(chan) — 新缠论专用构建
          → build_new_bi_list(kl_list)          → 分型列表 (fract_list)
          → build_new_seg_list(fract_list)      → 笔列表 (bi_list)
          → build_new_seg_list(bi_list)         → 段列表 (seg_list)
          → build_new_seg_list(seg_list)        → 2段列表 (segseg_list)
          → build_new_seg_list(segseg_list)     → 隐藏层 (segsegseg_list)
          → build_level_bsp(bi_list, seg_list, conf.bs_point_conf)         → 笔买卖点
          → build_level_bsp(seg_list, segseg_list, conf.seg_bs_point_conf) → 段买卖点
          → build_level_bsp(segseg_list, segsegseg_list, ...)             → 2段买卖点
      → 从 bundle 提取 bsp 数据
    → 写入 bsp_history
  → 返回 payload 给前端
  → 前端 drawBsp(bsp_history) 渲染
```

### 20.3 步进时可能不显示买卖点的原因

如果在**新缠论模式**下步进K线时没有显示买卖点，可能由以下原因导致：

#### 原因一：层级结构链尚未形成（最常见）

新缠论采用"分型→笔→段→2段"递推结构，每一级都依赖上一级的输出：

- **笔买卖点**需要：至少有 **1个笔 + 1个段** 才能开始计算
- **段买卖点**需要：至少有 **1个段 + 1个2段** 才能开始计算
- **2段买卖点**需要：至少有 **1个2段 + 1个隐藏层段** 才能开始计算

在步进的**初期阶段**（通常前几十根K线），由于数据量不足以形成完整的结构链，买卖点列表为空是**正常现象**。继续步进更多K线后，买卖点会逐渐出现。

#### 原因二：CBSPointList.cal() 计算异常被静默捕获

`build_level_bsp()` 函数内部调用 `CBSPointList.cal(base_lines, upper_lines)` 时，如果发生任何异常（如线段列表属性不兼容、中枢数量不足等），会被 `try/except` 静默捕获并返回空的 `CBSPointList`：

```python
# replay_trainer.py 第2666-2672行
def build_level_bsp(base_lines: Any, upper_lines: Any, bsp_conf) -> CBSPointList:
    bsp_list = CBSPointList(bs_point_config=bsp_conf)
    try:
        bsp_list.cal(base_lines, upper_lines)
    except Exception:  # ← 任何异常都被静默吞掉
        return CBSPointList(bs_point_config=bsp_conf)
    return bsp_list
```

这意味着如果新缠论构建的线段列表与 `CBSPointList.cal()` 的预期不完全兼容，买卖点会**静默失败**而不报错。

#### 原因三：买卖点配置参数限制

新缠论的买卖点计算受以下配置参数影响（参见 §7.6）：

| 配置项 | 说明 | 对新缠论的影响 |
|--------|------|---------------|
| `min_zs_cnt` | 产生1类买卖点所需的最小中枢数量 | 如果设置过大，可能长期无法产生1类点 |
| `bsp1_only_multibi_zs` | 1类点是否仅在多笔中枢后产生 | 开启后要求更严格的中枢条件 |
| `max_bs2_rate` | 2类点最大回撤率 | 过小的值可能导致2类点无法判定 |
| `divergence_rate` | 背驰比率阈值 | 设置为 inf 时禁用背驰检测 |

#### 原因四：非 trigger_step 模式的全量快照

`rebuild_bsp_all_snapshot()` 方法用于生成全量买卖点快照（用于 ×/✓ 判定对照），它使用 `trigger_step=False` 的全量模式重新计算。如果该快照为空，则自动判定模式下不会触发任何买卖点提示。

### 20.4 排查建议

如果在新缠论模式下长时间步进后仍无买卖点显示，可按以下顺序排查：

1. **确认已步进足够多的K线**：建议至少步进 **60-100 根** K线后再观察
2. **检查缠论配置**：按 `L` 打开缠论配置面板，确认 `chan_algo` 为 `new`
3. **检查买卖点配置**：确认 `min_zs_cnt` 不设置得过大（建议 1-3）
4. **切换到经典模式对比**：将 `chan_algo` 改为 `classic`，确认经典模式下是否有买卖点显示
5. **手动触发判定**：按 `J` 或点击【检查买卖点】按钮，手动触发一次判定
6. **查看浏览器控制台**：按 F12 打开开发者工具，查看是否有 JavaScript 错误

### 20.5 技术细节说明

- 新缠论模式的买卖点**不是**由 `CChan` 内部计算的，而是由 `replay_trainer.py` 中的 `build_new_bundle()` 函数在每次获取结构包时**实时重建**
- 每次步进后 `structure_bundle` 被设为 `None`，下次访问时强制重新构建，确保买卖点基于最新的K线状态
- 新缠论使用的 `SimpleLineList` 是一个最小化的 list 子类，仅提供 `exist_sure_seg()` 方法，可能与 `CBSPointList.cal()` 的完整接口存在细微差异

## 十八、数量模式 (data_form_mode = "quantity") 逻辑说明

### 21.1 概念

数量模式是一种**K线聚合模式**，将原始拉取的 N 根 K 线按用户指定的数量 Q **等分合并**为 Q 根新 K 线后，再送入缠论引擎计算。

与"传统模式"（直接使用原始K线）不同，数量模式在数据进入 `ReplayChan` **之前**就完成了聚合。

### 21.2 核心算法：aggregate_klu_by_quantity()

位于 [replay_trainer.py 第263行](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L263-L296)：

```
输入：原始K线列表 klus（共N根），目标数量 Q
输出：聚合后的新K线列表（Q根）

算法步骤：
1. 若 Q >= N → 不聚合，原样返回 deepcopy
2. base = N // Q      （每组基础根数）
3. rem  = N % Q       （余数）
4. 前 Q-1 组各取 base 根
5. 第 Q 组取 base + rem 根（余数全归最后一组）
6. 每组聚合规则：
   - 时间(time)    → 取该组最后一根的时间
   - 开盘价(open)  → 取该组第一根的开盘价
   - 最高价(high)  → 取该组所有K线的最高值
   - 最低价(low)   → 取该组所有K线的最低值
   - 收盘价(close) → 取该组最后一根的收盘价
   - 成交量(volume)→ 该组所有K线成交量求和
   - 成交额(turnover)→ 该组所有K线成交额求和
   - MACD/BOLL     → 设为 None（后续由指标引擎重新计算）
```

#### 示例

假设原始日线有 **247 根** K 线，设置数量 Q = **50**：

| 分组 | 包含原始K线数 | 说明 |
|------|-------------|------|
| 第1~49组 | 各 4 根 | 247 // 50 = 4 |
| 第50组 | 11 根 | 4 + (247 % 50 = 47) |

最终得到 **50 根**聚合后的K线，每根代表约 5 个交易日的行情压缩。

### 21.3 完整数据流

```
/api/init 或 /api/reconfig
  ↓ data_form_mode="quantity", data_form_quantity=Q
ChanStepper.init()
  ↓ raw_master = 原始K线列表（N根）
  ↓ raw_kline_count = N
  ↓ aggregate_klu_by_quantity(raw_master, Q)  ← 核心聚合
  ↓ _replay_klus_master = 聚合后的Q根K线
  ↓ ReplayChan(replay_klus_master=聚合后的列表)
  ↓ chan.step_load() → 逐根喂给缠论引擎
  ↓ 缠论基于Q根聚合K线进行笔/段/中枢/买卖点计算
```

### 21.4 参数说明

| 参数 | 字段名 | 类型 | 默认值 | 范围 | 说明 |
|------|--------|------|--------|------|------|
| 数据形态模式 | `data_form_mode` | string | `"traditional"` | `traditional` / `quantity` | 选择传统或数量模式 |
| 聚合数量 | `data_form_quantity` | int | 等于总K线数N | 1 ~ N | 数量模式下生效；1=全部合并为1根，N=不聚合 |

**参数归一化逻辑** ([normalize_data_form_quantity](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L240-L250))：
- 非整数 → 强制转 int
- < 1 → 修正为 1
- > 总K线数 N → 修正为 N
- 未传或异常 → 默认等于 N（即不聚合）

### 21.5 与 reconfig 的交互

当通过 `/api/reconfig` 切换到数量模式时：

1. 更新 `session_params` 中的 `data_form_mode` 和 `data_form_quantity`
2. 清空模拟交易记录和账户
3. 调用 `rebuild_to_step(target_step)`：
   - **重新执行** `stepper.init()`，此时会用新的聚合参数重建 `_replay_klus_master`
   - 从头开始步进到当前 `target_step` 位置
   - 重建缠论结构、买卖点快照、节奏历史等

**注意**：切换数量模式会**完全重新构建**整个会话的K线数据，不会保留之前的步进状态中的中间结果。

### 21.6 双周期模式下的特殊处理

在双周期 (`chart_mode=dual`) 模式下，数量模式有一个重要的防泄漏优化：

[`_collect_fine_klus_for_coarse_tail()`](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3557-L3594) 方法中：

```python
use_raw = (
    fine.data_form_mode == "quantity"
    and fine._replay_klus_master_raw       # 使用聚合前的原始数据
    and len(fine._replay_klus_master_raw) <= 100_000  # 数据量不过大
)
```

当细周期处于**数量模式**时，粗周期末根K线的重算会优先使用细周期的**原始未聚合K线**（`_replay_klus_master_raw`），而非聚合后的K线。这避免了以下问题：

> 如果细周期已将多日K线聚合成一根，粗周期用这根聚合K线来重算末根HLV时，可能丢失了当日内的价格波动细节。

同时 [`build_payload()`](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L4092-L4099) 中也有对应裁剪逻辑，防止数量模式下分组把未来数据带回末根显示。

### 21.7 前端入口

数量模式的配置位于【系统配置】面板的「数据形态」分组中：

| 配置项 | UI名称 | 说明 |
|--------|--------|------|
| `mode` | 数据形态 | 下拉选择：传统 / 数量 |
| `quantity` | 数量 | 数字输入框，范围 1 ~ 当前会话总K线数N |

**约束条件**：必须先加载会话（`/api/init`）才能使用数量模式，因为需要知道总K线数 N 来确定范围。前端会在未加载会话时禁用数量输入并提示"请先加载会话后再使用数量模式"。

### 21.8 典型使用场景

| 场景 | 推荐设置 | 效果 |
|------|---------|------|
| 长期趋势分析 | Q=50~100 | 将几年日线压缩为几十根，快速观察大级别走势 |
| 波段复盘训练 | Q=20~30 | 减少步进次数，聚焦关键转折点 |
| 压力测试缠论稳定性 | Q=极小值(如5) | 极端聚合下观察笔/段是否仍能正确形成 |
| 正常回放 | traditional 或 Q=N | 不聚合，逐根K线步进（默认行为） |

## 十九、离线数据使用规则

### 22.1 概述

离线数据是内置的本地数据源，存储在 `a_Data/` 目录下（与 `replay_trainer.py` 同级）。当所有在线数据源均不可用时，系统可自动回退到离线数据。

**核心设计原则：仅分笔 txt 落盘，各周期均在内存中由分笔聚合得到。**

### 22.2 目录结构

```
a_Data/
├── 600340/
│   ├── 20240101_600340.txt
│   ├── 20240102_600340.txt
│   └── ...
├── 001312/
│   └── ...
└── ...
```

**文件夹命名规则**（offline_folder_from_code，见 _replay_trainer.py）：

| 输入代码 | 文件夹名 | 规则 |
|---------|---------|------|
| `sh.600340` | `600340` | 去掉市场前缀，取数字 6 位（不足左补 0） |
| `sz.001312` | `001312` | 同上 |
| `688687` | `688687` | 纯数字规范为 6 位 |

### 22.3 数据源优先级中的位置

离线数据在默认优先级链中排第 **7 位**：

```
AKShare > AKShare-腾讯历史 > Ashare > AData > pytdx > BaoStock > **离线数据** > Tushare > 新浪 > 腾讯 > 雅虎 > 东方财富 > GitHub-CSV
```

用户可通过【系统配置】面板调整优先级，将"离线数据"提前或置后。

### 22.4 数据获取流程（COfflineInline 类）

位于 `a_replay_trainer.py` 中 `COfflineInline` / `_offline_list_tick_paths`：

```
用户请求任意周期K线（如日线）
    ↓
① 检查 a_Data/{六位代码}/ 是否存在
    ↓
② 列出该目录下匹配 YYYYMMDD_{六位代码}.txt 且日期在闭区间内的文件
    ↓ 有匹配？
   ├─ 是 → 加载分笔 → 内存合成 1 分钟桶 → 再合成目标周期 ✅
   └─ 否 → 抛出 ValueError（未找到离线分笔数据）❌
```

**关键点**：落盘仅分笔；分钟/日/周/月等均为运行时聚合。

### 22.5 周期合成规则

[_offline_rows_to_ktype()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1829-L1855) 实现了完整的周期合成链：

| 目标周期 | 合成路径 | 说明 |
|---------|---------|------|
| 1分钟 | 分笔聚合得到的内存 1 分钟 OHLCV | `_offline_ticks_to_1m` |
| 3分钟 | 内存 1 分钟按 3 根分组合并 | OHLCV 聚合 |
| 5分钟 | 内存 1 分钟按 5 根分组合并 | - |
| 15分钟 | 内存 1 分钟按 15 根分组合并 | - |
| 30分钟 | 内存 1 分钟按 30 根分组合并 | - |
| 60分钟 | 内存 1 分钟按 60 根分组合并 | - |
| 日线 | 内存 1 分钟按自然日聚合 | 取当日首根 open、末根 close、全日 high/low |
| 周线 | 日线按ISO周聚合 | - |
| 月线 | 日线按自然月聚合 | - |
| 季线 | 日线按自然季聚合 | - |
| 年线 | 日线按自然年聚合 | - |

**每根合成K线的聚合规则** ([_offline_merge_bar_group](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1719-L1725))：
- **开盘价(open)** = 组内第一根的 open
- **收盘价(close)** = 组内最后一根的 close
- **最高价(high)** = 组内所有 K 线的最高值
- **最低价(low)** = 组内所有 K 线的最低值
- **成交量(volume)** = 组内所有 K 线求和
- **成交额(turnover)** = 组内所有 K 线求和

### 22.6 分笔数据格式

**文件命名**：`a_Data/{六位代码}/YYYYMMDD_{六位代码}.txt`（如 `a_Data/600340/20240101_600340.txt`）

**文件内容**：每行一条成交记录，由 [_offline_load_ticks()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1671-L1695) 解析，包含时间、价格、成交量三列。

分笔数据会被先合成为1分钟K线（[_offline_ticks_to_1m](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1698-L1716)），再进入后续周期合成流程。

### 22.7 自动探测机制

在会话初始化（/api/init）之前，系统会调用 offline_bundle_exists() 探测离线包是否可用：

`
探测逻辑：
1. 检查 a_Data/{六位代码}/ 目录是否存在
2. 列出目录下匹配 YYYYMMDD_{六位代码}.txt 且日期在闭区间内的文件
3. 至少命中一个文件 → 返回 True（离线包可用）
`

### 22.9 在线源失败后的确认弹窗机制

这是离线数据最关键的用户交互设计：

#### 触发条件（[第3078-3086行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3078-L3086)）

当满足以下**全部条件**时，抛出 `OfflineDataConfirmRequired` 异常：

1. 当前在线数据源请求失败（抛出异常）
2. **下一个**待尝试的数据源是 `离线数据`
3. 用户**未设置** `confirm_offline=True`（即尚未确认过）
4. 探测到离线包确实存在（`offline_bundle_exists()` 返回 True）

#### 异常处理（api_init 第11649行）

```python
except OfflineDataConfirmRequired as exc:
    raise HTTPException(
        status_code=409,          # HTTP 409 Conflict
        detail={
            "type": "offline_confirm",
            "display_code": "600340",     # 显示用股票代码
            "failed_label": "AKShare",    # 失败的数据源名称
            "reason_tag": "网络问题",      # 失败原因分类
            "reason_detail": "...",        # 详细错误信息
        },
    )
```

前端收到 **HTTP 409** 后弹出确认对话框：
> 「在线数据源 {failed_label} 获取失败（{reason_tag}），是否使用本地离线数据？」

用户点击「确认」后，前端重新发起 `/api/init` 请求，此时 `confirm_offline=True`，跳过确认直接使用离线数据。

#### 失败原因分类（[classify_fetch_error_tag](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L354-L370)）

| 触发异常关键词 | 分类标签 |
|-------------|---------|
| timeout / timed out | 网络问题 |
| connection / network / resolve / 10060 / 10054 | 网络问题 |
| connection aborted / ssl / 403 / 404 / 502 / 503 | 网络问题 |
| 包含中文"网络"/"连接" | 网络问题 |
| 其他所有异常 | 数据源异常 |

### 22.10 筹码数据的离线同源策略

当K线来自离线包时，筹码分布有特殊处理（[第3232-3261行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3232-L3261)：

**强制同源规则**：若K线使用的是离线数据（`OFFLINE_INLINE_SRC`），则**忽略**筹码链上的在线数据源结果，强制将筹码也设为离线同源。

> 原因：避免出现「K线是分笔合成的精确日线，但筹码却用了某在线源的粗略日线」导致的不一致。

#### chip_tick_bins 非三角分摊模式

当以下条件同时满足时，调用 [_enrich_kline_all_offline_chip_non_triangle()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L516-L580) 为每根K线写入精确的筹码分布：

1. 数据源为离线 (`OFFLINE_INLINE_SRC`)
2. 当前周期在支持列表中（1分钟~年级别均支持）
3. 存在日期范围内的分笔 txt 文件

**写入逻辑**：
- **分笔数据**：按分笔的 (价格, 成交量, 方向) 直加汇总到对应K线的分桶中
- **前端渲染**：读取 `chip_tick_bins` 字段直接绘制，不走 OHLC 三角分摊算法

### 22.11 支持的周期列表

离线数据支持的完整周期（[_offline_chip_supported_ktypes](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L420-L437)）：

| 周期 | 枚举值 | 支持K线 | 支持筹码(chip_tick_bins) |
|------|--------|--------|------------------------|
| 1分钟 | K_1M | ✅ | ✅ |
| 3分钟 | K_3M | ✅ | ✅ |
| 5分钟 | K_5M | ✅ | ✅ |
| 15分钟 | K_15M | ✅ | ✅ |
| 30分钟 | K_30M | ✅ | ✅ |
| 60分钟 | K_60M | ✅ | ✅ |
| 日线 | K_DAY | ✅ | ✅ |
| 周线 | K_WEEK | ✅ | ✅ |
| 月线 | K_MON | ✅ | ✅ |
| 季线 | K_QUARTER | ✅ | ✅ |
| 年线 | K_YEAR | ✅ | ✅ |

**注意**：所有周期的K线均从1分钟数据合成，无原生高周期离线文件。

### 22.12 会话缓存与会话键

[ChanStepper.init()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3196-L3198) 中通过 `session_key` 判断是否可复用已加载的数据：

```python
session_key = (code, begin_date, end_date, autype, k_type, prio_fp)
# 其中 prio_fp = (data_source_priority元组, confirm_offline布尔值)
```

**重要**：`confirm_offline` 是 session_key 的组成部分。这意味着：
- 首次 init 未确认离线 → 得到一个 session_key
- 用户确认后二次 init（confirm_offline=True）→ session_key 变化 → **强制重新加载数据**
- `rebuild_to_step()` 重建时会保持 `confirm_offline` 与首次一致，避免误触发重新拉取

### 22.13 使用建议

| 场景 | 建议 |
|------|------|
| 日常复盘 | 保持默认优先级，在线源正常时自动使用在线数据 |
| 网络环境差 | 将"离线数据"优先级提前，或预下载离线包 |
| 历史数据补全 | 某些在线源早期数据缺失时，离线数据可作为补充 |
| 批量回测 | 离线数据避免网络延迟，速度更快 |
| 筹码精度要求高 | 优先使用有分笔数据的离线包（chip_tick_bins 更精确） |

## 二十、单品种双周期操作规则

### 23.1 概述

双周期模式（`chart_mode = "dual"`）允许**同一只股票**同时显示**两个不同周期**的K线图表（如日线 + 周线），两个图表独立计算缠论结构但**时间锚定联动**。

### 23.2 核心概念

| 概念 | 说明 |
|------|------|
| **stepper (图1)** | 主步进器，对应 `chart1`，默认使用 `k_type` 周期 |
| **stepper2 (图2)** | 辅助步进器，对应 `chart2`，使用 `k_type_2` 周期 |
| **active_stepper (激活图)** | 当前用户操作的图表对应的步进器，买卖/交易以此为准 |
| **passive_stepper (被动图)** | 非激活的图表，随激活图的时间锚点自动同步 |
| **coarse (粗周期)** | 两个周期中**粒度更粗**的那个（如日线 vs 5分钟 → 日线是粗周期） |
| **fine (细周期)** | 两个周期中**粒度更细**的那个（如日线 vs 5分钟 → 5分钟是细周期） |
| **anchor_time (锚点时间)** | 激活图当前所在K线的时间，被动图同步到此时间 |

### 23.3 初始化流程

在 `/api/init` 中设置 `chart_mode = "dual"` 时：

```
1. stepper.init(代码, 日期, ..., k_type="daily")        → 图1: 日线
2. stepper2.init(代码, 日期, ..., k_type="weekly")       → 图2: 周线
3. APP_STATE.chart_mode = "dual"
4. APP_STATE.active_chart_id = "chart1"                   → 默认激活图1
```

**关键点**：`stepper` 和 `stepper2` 是**两个完全独立的 ChanStepper 实例**，各自拥有独立的：
- K线数据（各自从数据源拉取）
- 缠论对象 (`ReplayChan`)
- 结构包 (`structure_bundle`)
- 指标历史 (`indicator_history`)
- 步进索引 (`step_idx`)

两者共享的只有：同一只股票代码、相同的日期范围、相同的缠论配置。

### 23.4 粗细周期的自动识别

[_resolve_dual_coarse_fine()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3503-L3517) 负责识别哪个是粗周期、哪个是细周期：

```python
识别逻辑（优先级从高到低）：
① 按 KL_TYPE 枚举的粒度排名比较
   排名: 1分钟=1 < 3分钟=2 < 5分钟=3 < ... < 日线=7 < 周线=8 < ... < 年线=11
   排名大者 → 粗周期

② 若两周期类型相同（极少见），按已载入K线根数判断
   根数少者 → 粗周期（因为粗周期天然K线数少）

③ 根数相同或任一为0 → 无法区分，返回 None
```

**示例**：

| 图1周期 | 图2周期 | coarse(粗) | fine(细) | 原因 |
|--------|--------|-----------|---------|------|
| daily | 5min | daily | 5min | 日线排名7 > 5分钟排名3 |
| weekly | daily | weekly | daily | 周线排名8 > 日线排名7 |
| daily | daily | - | - | 同周期，无法区分 |

### 23.5 步进同步机制（核心）

这是双周期模式最关键的交互逻辑。当用户在**激活图**上执行步进操作时：

#### /api_step 处理流程 ([第11740行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L11740-L11772))

```
用户按下 Space（步进）
    ↓
① 确定 active_stepper（根据 active_chart_id）
② 确定 passive_stepper（另一个非激活的）
③ active_stepper.step()          → 激活图前进一根K线
    ↓ 成功？
   ├─ 是 ↓
   │  ④ _sync_stepper_to_anchor(passive_stepper, anchor_time)
   │     → 被动图步进到与激活图当前时间对齐的位置
   │  ⑤ _dual_rebuild_coarse_chan_anti_future(anchor_time)
   │     → 用细周期数据修正粗周期末根K线的 OHLCV（防未来数据泄漏）
   │  ⑥ sync_bsp_history()       → 同步买卖点历史
   │  ⑦ sync_rhythm_history()    → 同步节奏提示
   │  ⑧ after_step_update()      → 触发买卖点判定（非手动模式时）
   └─ 否 → 到达末尾，返回"已到最后一根K线"
```

#### 时间锚定同步 (_sync_stepper_to_anchor)

位于 [第3462行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3462-L3490)：

```python
同步算法：
t_anchor = 激活图的当前K线时间
while 被动图当前时间 < t_anchor:
    被动图.step()     # 前进一根
# 当被动图当前时间 >= t_anchor 时停止
# （包含优先：若被动图已有等于锚点的K线则停在该根）

同步后副作用：
- 清空被动图的 structure_bundle 缓存（下次访问时重建）
- 确保 passive_stepper 的时间不会超过 active_stepper
```

**效果举例**（日线 + 5分钟）：

| 操作 | 激活图(日线)位置 | 被动图(5分钟)位置 | 说明 |
|------|-----------------|-------------------|------|
| 初始状态 | 2024-01-05 | 2024-01-05 14:55 | 已对齐 |
| Step ×1 | 2024-01-08 | 步进至 2024-01-08 14:55 | 被动图追到周一收盘 |
| Step ×1 | 2024-01-09 | 步进至 2024-01-09 14:55 | 继续追 |

### 23.6 防未来数据泄漏机制

这是双周期模式的**核心设计难点**。

#### 问题场景

假设：粗周期=日线，细周期=5分钟。当前时间是 2024-01-08 **11:30**（盘中）。

如果直接用日线原始数据的最后一根（代表完整一天），该日线的 high/low/close/volume 包含了 **11:30 之后的数据**（下午盘）。这在实时回放中属于"未来数据"，会导致：
- 当日最高价可能还未出现
- 收盘价还是未知数
- 成交量还在累积中

#### 解决方案：三级防护

**第一层：展示层修正** — [_apply_partial_last_bar()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3519-L3541)

在 `build_payload()` 返回给前端时执行：

```
粗周期最后一根K线的:
  open  → 保持不变（周期首价已确定）
  high  → 取细周期在 (上一根粗K时间, 锚点] 内的最高价
  low   → 取细周期在同区间的最低价
  close → 取细周期同区间最后一根的收盘价
  volume→ 取细周期同区间成交量求和
```

**第二层：结构层重建** — [_dual_rebuild_coarse_chan_anti_future()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3591-L3663)

不仅修改展示数据，还**真正重建**粗周期的 `ReplayChan` 对象：

```
1. 从粗周期 master 数据中取出最后一根原始K线
2. 用细周期截至锚点的数据重新计算 OHLCV
3. 创建新的 CKLine_Unit 替换原最后一根
4. 用修改后的 master 列表重建 ReplayChan
5. 从头步进到当前位置 (saved step_idx)
6. 结果：笔/段/中枢/买卖点 全部基于修正后的数据
```

**第三层：数量模式兼容** — [_collect_fine_klus_for_coarse_tail()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3556-L3589)

当细周期处于数量模式时，优先使用 `_replay_klus_master_raw`（聚合前的原始K线），确保有足够的细粒度数据用于重算粗周期末根。

### 23.7 激活图切换

#### 后端切换逻辑

| 方法 | 说明 |
|------|------|
| [`get_active_stepper()`](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3439-L3441) | 根据 `active_chart_id` 返回对应步进器 |
| [`get_passive_stepper()`](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3443-L3447) | 返回非激活的步进器（单周期返回 None） |
| [`_normalize_chart_id()`](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3435-L3437) | 校正 chart_id，非双周期强制返回 chart1 |

前端通过 `StepReq.active_chart_id` 字段指定当前操作的图表ID，后端据此决定哪个 stepper 执行 step()。

#### 前端切换方式

1. **鼠标悬停**：鼠标移入某个子图区域自动切换为激活图（可右键锁定）
2. **按钮切换**：工具栏显示「图1激活」「图2激活」按钮（默认隐藏）
3. **右键锁定**：右键点击子图后锁定激活状态，悬停不再切换

### 23.8 交易规则

双周期模式下，**模拟交易始终以激活图为准**：

```python
# api_buy / api_sell 中：
active_stepper = APP_STATE.get_active_stepper()
price = active_stepper.current_price()        # 取激活图的最新收盘价
step_idx = active_stepper.step_idx             # 记录激活图的步进索引
```

这意味着：
- 在日线图激活时买入 → 以日线最新收盘价成交
- 切换到5分钟图激活后卖出 → 以5分钟最新收盘价成交
- 交易记录中的 `step_idx` 对应的是当时激活图的步进位置

### 23.9 重建与回退

#### rebuild_to_step 中的双周期处理

[第3975-3992行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3975-L3992)：

```
rebuild_to_step(target_step):
  1. stepper.init(...)           → 重建图1
  2. if chart_mode == "dual":
       stepper2.init(...)        → 重建图2（使用 k_type_2）
  3. stepper.step() × target_step
  4. if dual: stepper2.step() + sync_to_anchor(stepper2, stepper.current_time())
  5. _dual_rebuild_coarse_chan_anti_future(...)
```

#### back_n 回退

[api_back_n](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L11838-L11852) 使用的是**当前激活图**的步进索引来计算目标位置：

```python
cur = APP_STATE.get_active_stepper().step_idx   # 取激活图当前位置
target = max(0, cur - n)
APP_STATE.rebuild_to_step(target)               # 双图一起重建
```

**注意**：back_n 总是基于激活图后退，被动图会随之同步重建到对应锚点。

### 23.10 买卖点判定与节奏提示

| 功能 | 作用范围 | 说明 |
|------|---------|------|
| `after_step_update()` | 仅**激活图** | 检测激活图的结构变向并触发买卖点判定 |
| `sync_bsp_history()` | 全局 | 将激活图当前步进的买卖点追加到全局历史 |
| `sync_rhythm_history()` | 仅**激活图** | 从激活图的结构包中提取节奏命中通知 |
| `judge_bsp` | 全局 | 对照全量快照做 ×/✓ 判定 |

**重要**：买卖点判定和节奏提示**仅基于激活图**的结构数据。被动图的结构变化不触发判定。

### 23.11 配置独立性

| 配置项 | 是否独立 | 说明 |
|--------|---------|------|
| 缠论配置 (chan_config) | ❌ 共享 | 两图使用同一套笔/段/中枢参数 |
| 图表样式 (chartConfig) | ✅ 独立 | 两图各有独立的画线颜色、粗细等配置 |
| 数据形态 (data_form_mode) | ✅ 独立 | 两图可分别设为传统或数量模式 |
| 周期类型 (k_type / k_type_2) | ✅ 独立 | 各自的K线周期 |
| 数据源 | ✅ 独立拉取 | 但受离线同源策略约束 |

### 23.12 前端布局

| 配置项 | 字段名 | 选项 | 默认值 | 说明 |
|--------|--------|------|--------|------|
| 图表模式 | `chartMode` | single / dual | single | 单图或双图 |
| 第二周期 | `kType2` | 所有KL类型 | weekly | 双图模式下第二个周期 |
| 排列方式 | `dualLayout` | vertical / horizontal | vertical | 上下排列或左右排列 |
| 激活图表 | `activeChartId` | chart1 / chart2 | chart1 | 当前激活的子图 |

#### UI 表现

- **垂直排列** (`vertical`)：上图 chart1，下图 chart2，各占约 50% 高度
- **水平排列** (`horizontal)`：左图 chart1，右图 chart2，各占约 50% 宽度
- 双图共用同一个 Canvas 元素，内部按区域裁剪渲染
- 十字光标在两图间联动（X轴时间对齐）

### 23.13 典型应用场景

| 场景 | 推荐组合 | 用法说明 |
|------|---------|---------|
| 日内波段 + 日线趋势 | 5分钟 + 日线 | 在5分钟图步进操作，日线图观察大级别方向 |
| 波段买卖点确认 | 30分钟 + 周线 | 30分钟找入场点，周线确认趋势是否配合 |
| 多级别联立分析 | 15分钟 + 60分钟 | 观察小级别笔是否在大级别段的中枢内 |
| 新缠论结构验证 | 日线 + 周线 | 对比两个级别的新缠论递推结构一致性 |

### 23.14 注意事项与限制

1. **性能开销**：双周期模式下每次步进需要维护两个独立的缠论计算引擎，CPU 和内存开销约为单周期的 **2 倍**
2. **防未来函数重建代价**：`_dual_rebuild_coarse_chan_anti_future` 会重建整个粗周期 Chan，在长序列下可能有明显延迟
3. **数量模式兼容性**：细周期数量模式时需额外读取 raw 数据，且限制 raw ≤ 100,000 条
4. **买卖点判定单一性**：判定只基于激活图，切换激活图后之前的判定记录不变但新判定基于新激活图
5. **reconfig 同时生效**：修改缠论配置后 reconfig，**两个周期都会**用新配置重建
6. **不支持不同股票**：双周期必须是**同一代码**的不同周期，不能是两只不同的股票

## 二十一、筹码分布设计逻辑

### 24.1 概述

筹码分布（Chip Distribution）是 `replay_trainer.py` 中用于展示**历史成交量在价格维度上的累积分布**的可视化功能。它回答的核心问题是：**"从上市至今（或某个参考日期），每个价格区间累计成交了多少量？"**

### 24.2 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    筹码分布数据流                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  数据源层                                                    │
│  ├─ 离线分笔 (a_Data/六位代码/*.txt) ─┐                      │
│  │   格式: 时间 价格 成交量           │                        │
│  └─ （无独立 1 分钟离线文件）─────────┤                        │
│                                     ↓                        │
│  后端处理层 (_enrich_kline_all_     _fold_price_vols()        │
│    offline_chip_non_triangle)      → 按4位精度聚合价量        │
│                                     ↓                        │
│  kline_all[].chip_tick_bins        {"p":[价格数组],          │
│    = {p, w}                         "w":[权重数组]}          │
│                                     ↓                        │
│  前端渲染层 (drawChips)             → 三角分摊 / 直加         │
│                                     ↓                        │
│  Canvas 右侧水平柱状图              + 筹码峰延长线            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 24.3 底层数据来源（离线分笔）

#### 离线分笔数据（唯一落盘粒度）

**文件位置**：`a_Data/{六位代码}/YYYYMMDD_{六位代码}.txt`

**文件格式**（每行一条 Tick）：
```
时间          价格       成交量
09:25:00      12.35      1000
09:30:01      12.36      500
...
```

**处理流程** ([_enrich_kline_all_offline_chip_non_triangle](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L516-L578))：

```
1. 扫描 a_Data/{六位代码}/ 目录下所有匹配 {YYYYMMDD}_{六位代码}.txt 的文件
2. 逐行读取 (时间, 价格, 成交量) 元组
3. 按 _offline_chip_bar_bucket_key() 将 tick 归入对应 K 线周期的桶
   例: 日线桶 = (年, 月, 日), 5分钟桶 = (年, 月, 日, 时, 分//5)
4. 对每个桶内的所有 tick:
   - 按 _fold_price_vols() 将价格四舍五入到 4 位小数后按价合并成交量
   - 结果: p=[10.01, 10.02, ...], w=[15000, 23000, ...]
5. 写入对应 kline_all 条目的 chip_tick_bins 字段
```

#### （已移除）离线路径不再提供 1 分钟 txt 兜底

数据落盘仅为分笔；若缺分笔文件请补齐 `a_Data/{六位代码}/YYYYMMDD_*.txt`。

#### 什么是"点质量化"

**物理类比**：物理学中计算天体运行时，地球被简化为一个"质点"——有**质量**但没有**体积/大小**。同理，这里把一根1分钟K线的成交量（有大小）压缩成价格维度上的一个**无体积的点**（收盘价）。

**问题本质**：1分钟K线只提供 OHLCV 五个值，丢失了"每笔成交具体发生在什么价格"的信息：

```
真实情况（如果有分笔数据）：
时间      价格     成交量
09:30:01  12.30    500手
09:30:03  12.31    200手
09:30:05  12.29    800手    ← 大量成交在低位
...       ...      ...
09:30:59  12.32    100手
─────────────────────
合计               1900手 分布在 12.29~12.32 多个价格上

但1分钟K线只给你：
{"o":12.30, "h":12.33, "l":12.28, "c":12.32, "v":1900}
↑ 你不知道这1900手具体分布在哪些价格上
```

**点质量化的做法**：

> **假设这根1分钟K线的全部成交量，都以收盘价这一个价格成交。**

即把整根K线的量 **压缩到收盘价这一个点上**：

```
        1900手
          ●  ← 全部堆积在 c=12.32 这一个价格点位
         ↑
       12.32 (收盘价 = "点")
```


（离线实现已删除「仅 1 分钟文件」分支；下方仅为概念说明。）



| 概念 | 来源 | 类比 |
|------|------|------|
| **质量 (mass)** | 成交量 `v` | 物理学中的"质量"，代表总量大小 |
| **点 (point)** | 单一价格 `c` | 几何学中的"点"，无大小、无体积 |
| **点质量 (point-mass)** | 收盘价×成交量 | 有质量但价格维度上无分布的质点模型 |

**精度对比**：

| 数据源 | 精度 | 假设 |
|--------|------|------|
| 分笔 Tick | **逐笔级**，真实记录每笔成交的价格和量 | 无假设，最精确 |
| 1分钟K线 | 分钟级，收盘价代表整分钟 | 假设该分钟所有成交集中在收盘价 |
| 在线日线/周线 | 仅 OHLCV | 需前端三角分摊（见24.5节） |

#### 支持的周期

[_offline_chip_supported_ktypes()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L420-L437) 定义了可合成 `chip_tick_bins` 的周期：

```python
支持: 1分钟、3分钟、5分钟、15分钟、30分钟、60分钟、
      日线、周线、月线、季度线、年线
不支持: 自定义分钟数（如 7 分钟等非标准周期）
```

### 24.4 后端数据结构

#### chip_tick_bins 字段格式

写入 `kline_all` 数组中每一根 K 线对象：

```json
{
  "x": 120,
  "t": "2024-01-08",
  "o": 12.30,
  "h": 12.55,
  "l": 12.20,
  "c": 12.45,
  "v": 100000,
  "chip_tick_bins": {
    "p": [12.21, 12.23, 12.35, 12.40, 12.50],
    "s": [2200, 5200, 15000, 9000, 3000],
    "b": [2800, 6800, 20000, 19000, 5000],
    "w": [5000, 12000, 35000, 28000, 8000]
  }
}
```

- `p`（prices）：该根 K 线期间内出现过的**去重价格列表**（升序）
- `s`（S）：左侧绿色 S 的累计量（与 `p` 同长度）
- `b`（B）：右侧红色 B 的累计量（与 `p` 同长度）
- `w`（weights）：兼容字段，通常等于 `s + b`
- `p/s/b/w` 长度必须一致；为空或不合法则前端回退到三角分摊

#### 数据传递链路

```
ChanStepper.init()
  → _select_data_source_with_fallback(use_for="chip")   // 独立的数据源链
  → kline_all = chip_sel.kline_all                      // 全历史K线（1990-01-01 起）
  → 若离线源成功 + 有分笔/1m数据:
      _enrich_kline_all_offline_chip_non_triangle()     // 注入 chip_tick_bins
  → build_payload()
      → serialize_chan(kline_all=stepper.kline_all)     // 传给前端
      → chart["kline_all"] = [...]                       // JSON 中包含 chip_tick_bins
```

**关键点**：
- `kline_all` 是**全历史** K 线（从 1990-01-01 到结束日期），不随步进位置变化
- K 线主序列 (`kline`) 和筹码全历史 (`kline_all`) 使用**两套独立的数据源优先级链**
- 当 K 线来自离线包时，筹码**强制同源**（忽略筹码链上的在线源），避免数据不一致

### 24.5 前端渲染算法（两种模式）

#### 模式 1：chip_tick_bins 直加模式（高精度）

当 K 线携带 `chip_tick_bins` 字段时（离线分笔/1分钟场景），前端直接累加：

```javascript
for (const k of useKs) {
  const tb = k.chip_tick_bins;
  for (let j = 0; j < tb.p.length; j++) {
    const priceIdx = Math.floor(tb.p[j] * stepMul);  // 价格→桶索引
    // 离线直加模式：优先用 s/b 拆左右；否则兼容 w
    if (tb.s && tb.b) {
      arrS[priceIdx] += tb.s[j];                      // 左侧 S(绿)
      arrB[priceIdx] += tb.b[j];                      // 右侧 B(红)
    } else {
      arr[priceIdx] += tb.w[j];                       // 兼容旧字段：总量当作右红 B
    }
  }
}
```

**特点**：无需任何假设，真实反映每个价格上的累计成交量。

#### 模式 2：OHLC 三角分摊模式（在线数据兜底）

当 K 线**没有** `chip_tick_bins` 字段时（在线日线/周线等），前端用三角分布算法估算：

```javascript
// 核心逻辑 (drawChips 第9838-9890行)
const low = Math.min(k.l, k.h);
const high = Math.max(k.l, k.h);
const mode = Math.min(high, Math.max(low, k.c));  // 收盘价 = 峰值位置

// 从 low 到 high 的每个价格桶，计算分配权重 w(p):
if (p <= mode):
  w(p) = (p - low) / (mode - low);       // 左半边: 从 0 线性增长到峰值
else:
  w(p) = (high - p) / (high - mode);     // 右半边: 从峰值线性衰减到 0

// 最终: arr[p] += (w(p) / sumW) * vol;
```

**三角分摊示意**（以一根日K为例）：

```
成交量
  ▲
  │         /\                    ← close(收盘价)=峰值
  │        /  \                   ← high/low=两端归零
  │       /    \
  │______/______\_____▶ 价格
       low  c   high
```

**假设前提**：
- 该根 K 线的所有成交量在价格区间 [low, high] 上呈**三角分布**
- **收盘价为概率密度峰值**（认为大部分成交发生在接近收盘价的位置）
- 这是一种**近似估算**，精度远低于分笔直加模式

### 24.6 截止时间与参考锚点

筹码分布的**累积范围**由参考K线（Reference K）决定，而非当前步进位置：

#### 锚点选择优先级 ([drawChips 第9788-9810行](file:///c:\Users\Administrator/Desktop\my_file1/my_file/3/chan.py/replay_trainer.py#L9788-L9810))

```
优先级 1: 十字光标所在K线（鼠标悬停且启用十字光标时）
优先级 2: peakRefMode 配置值:
  - "latest_visible"  → 当前视口最新可见K线（默认）
  - "seg_turn"       → 视口内最后一个线段转折点对应的K线
  - "bi_turn"        → 视口内最后一个笔转折点对应的K线
优先级 3: kline_all 最后一根K线（最终兜底）
```

#### 累积过滤

```javascript
const refT = String(refK.t || "");          // 锚点时间的字符串表示
const useKs = ksAll.filter((k) =>           // 只取 <= 锚点的K线
  String(k.t || "") <= refT
);
```

**效果**：
- 默认情况下，筹码显示的是**截至最新可见K线的全部历史累积**
- 用十字光标悬停到某根历史K线上时，筹码会**动态回退**到该日期的累积状态
- 切换 peakRefMode 到 "bi_turn"/"seg_turn" 时，锚点自动跟随最近的笔/段转折点

### 24.7 可视化拉伸（stretchLevel）

#### 目的

原始筹码数据通常呈现**极端偏态分布**（少数价格集中了大量成交量，其余价格上成交量极低），直接绘制会导致：
- 峰值过高，其他价位几乎不可见
- 无法观察支撑/压力带的细微结构

#### 算法 ([getChipStretchExponent](file:///c:\Users\Administrator/Desktop\my_file1/my_file/3/chan.py/replay_trainer.py#L7934-L7939))

```javascript
function getChipStretchExponent() {
  const level = Number(chartConfig.chip.stretchLevel || 5);
  // level 1  → exp=1.00 (不拉伸，线性)
  // level 5  → exp=0.68 (中等拉伸)
  // level 10 → exp=0.28 (强拉伸)
  // level 20 → exp=-0.52 (极强拉伸)
  const exp = 1.0 - 0.08 * (level - 1);
  return clamp(exp, 0.08, 1.0);
}

// 渲染时应用
const stretchVol = (v) => Math.pow(Math.max(0, v), stretchExp);
// exp < 1 时: 大值被压缩，小值被相对放大（增强对比度）
```

**拉伸效果示例**（某价格桶原始值 vs 拉伸后）：

| level | exp | 原始=100000 | 原始=1000 | 原始=100 |
|-------|-----|------------|-----------|---------|
| 1 | 1.00 | 100000 | 1000 | 100 |
| 5 | 0.68 | 10219 | 203 | 51 |
| 10 | 0.28 | 380 | 16 | 8 |
| 20 | -0.52 | 0.31 | 0.06 | 0.03 |

**注意**：拉伸仅影响**视觉渲染**，不改变底层数据。

### 24.8 筹码峰检测与延长线

#### 峰值检测算法 ([第9928-9938行](file:///c:\Users\Administrator\Desktop\my_file1/my_file/3/chan.py/replay_trainer.py#L9928-L9938))

```javascript
const peaks = [];
for (let i = 1; i < tickCount - 1; i++) {
  const cur = arr[i];
  // 局部最大值: 同时大于左右邻居
  if (!(cur > arr[i - 1] && cur > arr[i + 1])) continue;
  const p = (minTick + i) / stepMul;  // 还原为实际价格
  if (p < s.yMin || p > s.yMax) continue;  // 只保留可见区域内的峰
  peaks.push(p);
}
```

**特点**：
- 使用**严格大于**（>）判断，相邻相等值不会产生多个峰
- 边界桶（i=0 或 i=tickCount-1）不可能成为峰
- 只检测 Y轴可见范围内的峰（节省绘制开销）

#### 延长线绘制

```
对每个检测到的峰价格 p:
  从筹码区左边缘(xL) 画水平线到 K 线图左边缘(PAD_L)
  样式: 可配置颜色/粗细/线型（实线/虚线/点线）
  开关: peakLineEnabled 控制是否显示
```

**用途**：筹码峰延长线叠加在K线图上，直观展示**历史密集成交区的支撑/压力位**。

### 24.9 前端配置项一览

| 配置字段 | 类型 | 范围 | 默认值 | 说明 |
|----------|------|------|--------|------|
| `enabled` | bool | - | true | 总开关 |
| `bucketStep` | float | 0.001~1 | 0.1 | 价格桶宽度（元）。越小越精细但越稀疏 |
| `stretchLevel` | int | 1~20 | 5 | 对比度拉伸强度。1=线性，越大对比度越强 |
| `color` | color | CSS色值 | rgba(59,130,246,0.45) | 筹码填充色 |
| `peakLineEnabled` | bool | - | true | 筹码峰延长线开关 |
| `peakRefMode` | string | latest_visible / seg_turn / bi_turn | latest_visible | 锚点参考模式 |
| `peakLineColor` | color | CSS色值 | #2563eb | 延长线颜色 |
| `peakLineWidth` | float | 0.1~6 | 1.2 | 延长线粗细(px) |
| `peakLineStyle` | string | dashed / solid / dotted | dashed | 延长线线型 |

### 24.10 bucketStep（价格桶宽度）的选择策略

| 股票价格范围 | 推荐 bucketStep | 说明 |
|-------------|-----------------|------|
| < 5元（低价股）| 0.01~0.05 | 细粒度，能分辨几分钱的筹码集中区 |
| 5~20元 | 0.05~0.1 | 默认值，平衡精度和数据密度 |
| 20~100元 | 0.1~0.2 | 中等粒度 |
| > 100元（高价股/茅台类）| 0.5~1.0 | 避免桶数量爆炸导致内存压力 |
| 指数/ETF | 0.001~0.01 | 极细粒度，指数点位变化幅度小 |

**技术约束**：`tickCount = ceil((allMax - allMin) / bucketStep)`，过小的 bucketStep 会导致桶数组过大。

### 24.11 性能考量

| 因素 | 影响 | 优化措施 |
|------|------|---------|
| kline_all 数据量 | 全历史可能数千~数万根K线 | 前端只遍历 useKs（<=锚点的子集） |
| chip_tick_bins 大小 | 分笔数据每根K线可能有数十个价格点 | 已在后端按4位精度聚合 |
| bucketStep 过小 | 桶数组过大 | 限制最小 0.001 |
| stretchLevel 计算 | 每帧对每个桶做 Math.pow | 仅对可见Y范围内的桶计算 maxVVisible |
| 峰值检测 | O(tickCount) | 每帧一次，复杂度可控 |

### 24.12 数据源优先级与同源策略

#### 两套独立链

```python
DATA_SOURCE_CHAIN_KLINE  # 用于步进K线主序列
DATA_SOURCE_CHAIN_CHIP   # 用于筹码全历史 kline_all
```

两套链使用**相同的优先级顺序**，但**各自独立回退**，因此最终可能选中不同的数据源。

#### 同源强制规则

当 **K线来自离线包**时，筹码**强制与K线同源**（[第3232行](file:///c:\Users\Administrator\Desktop\my_file1/my_file/3/chan.py/replay_trainer.py#L3232-L3241)）：

```python
if k_sel.data_src == OFFLINE_INLINE_SRC:
    self.data_src_chip_used = k_sel.data_src  # 强制同源
    # 即使筹码链上已有成功的在线源也忽略
    # 原因: 避免"K线是分笔合成的日线，筹码却是在线日线"的不一致
```

**原因**：离线K线可能是通过分笔数据合成的（如1分钟→日线），其OHLC与标准在线日线有微小差异。若筹码走在线源，会导致K线价格区间与筹码价格区间不完全匹配。

### 24.13 使用注意事项

1. **离线分笔数据是获得高精度筹码的前提**
   - 无分笔数据时退化为1分钟收盘点质量化（仍有 chip_tick_bins）
   - 无离线数据时退化为前端三角分摊（精度最低）
   
2. **筹码不随步进而更新**
   - `kline_all` 是固定的全历史快照
   - 步进只改变缠论结构和指标，不改变筹码底层数据
   - 但可通过十字光标查看任意历史时点的筹码状态

3. **双周期模式下两个图表共享同一份 kline_all**
   - 筹码数据基于 stepper 的 kline_all（主周期）
   - 不存在"日线筹码"和"5分钟筹码"的区别

4. **reconfig（重配置）时会重新拉取筹码数据**
   - 因为 session_key 包含 chan_config，配置变更视为新会话
   - 若只是修改画线样式（不涉及数据），不会触发重新拉取

## 二十二、数据源一致性规则

### 25.1 双周期（stepper / stepper2）的数据源是否一致？

**结论：不一定一致，两者独立选择。**

双周期模式下，`stepper` 和 `stepper2` 是两个**完全独立**的 `ChanStepper` 实例，各自调用 `init()` 时分别执行完整的数据源选择流程：

```
stepper.init(代码, 日期, ..., k_type="daily")
  → _select_data_source_with_fallback(use_for="kline")   → 可能选中 AKShare
  → _select_data_source_with_fallback(use_for="chip")    → 可能选中 BaoStock

stepper2.init(代码, 日期, ..., k_type="5min")
  → _select_data_source_with_fallback(use_for="kline")   → 可能选中 pytdx（与图1不同）
  → _select_data_source_with_fallback(use_for="chip")    → 可能选中 Tushare
```

**原因**：两套链使用**相同的优先级顺序**，但按**同一顺序各自独立回退**。由于不同周期（如日线 vs 5分钟）在不同数据源上的可用性不同，最终可能命中不同的实际源。

| 场景 | stepper (日线) | stepper2 (5分钟) | 是否一致 |
|------|---------------|-----------------|---------|
| 所有源都正常 | AKShare | AKShare | ✅ 一致 |
| AKShare 无5分钟 | AKShare | pytdx | ❌ 不一致 |
| 离线包有日线无5分钟 | 离线数据 | AKShare | ❌ 不一致 |

**对用户的影响**：
- 两图的K线数据可能来自**不同的数据源**，OHLC可能存在微小差异
- 前端左下角「数据源状态」区域会分别显示两图的实际数据源标签

### 25.2 筹码分布的数据源是否总和 K 线的数据源一致？

**结论：分三种情况，并非总是强制一致。**

核心逻辑位于 [第3229-3245行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3229-L3245)：

#### 情况 A：K线来自离线包 → **筹码强制同源** ✅

```python
if k_sel.data_src == OFFLINE_INLINE_SRC:
    self.data_src_chip_used = k_sel.data_src    # 强制 = K线源
    # 即使筹码链上已有成功的在线源也忽略
```

**原因**：离线K线可能是通过分笔数据合成的（如1分钟→日线），其OHLC值与标准在线日线存在微小差异。若筹码走在线源，会导致：

```
离线合成日线: o=12.30, h=12.55, l=12.20, c=12.45  （基于分笔聚合）
在线标准日线:   o=12.31, h=12.54, l=12.19, c=12.44  （交易所官方）
                                              ↑ 差异导致筹码价格区间错位
```

此时前端日志显示：`"筹码全历史与离线K线同源（已忽略筹码链上的在线源：AKShare）"`

#### 情况 B：K线来自在线源，筹码链成功 → **筹码独立选择** ⚠️

```python
else:  # k_sel.data_src 不是离线源
    self.kline_all = chip_sel.kline_all           # 用筹码链的结果
    self.data_src_chip_used = chip_sel.data_src   # 可能 ≠ K线源
```

**示例**：

| 链 | 优先级顺序 | 第一个成功的源 |
|----|-----------|--------------|
| **K线链** | AKShare → Ashare → BaoStock → ... | **AKShare**（第1个就成功）|
| **筹码链** | AKShare → Ashare → BaoStock → ... | **BaoStock**（AKShare拉全历史超时，第3个成功）|

结果：K线用 AKShare，筹码用 BaoStock。**两者不一致但均合法。**

前端日志显示：`"K线: AKShare, 筹码全历史: BaoStock"`

#### 情况 C：K线来自在线源，筹码链**全部失败** → **筹码回退到K线同源**

```python
except RuntimeError as exc:
    self.data_src_chip_used = k_sel.data_src     # 兜底 = K线源
    self.data_source_logs.append("筹码全历史与K线同源（筹码链不可用）")
```

当所有数据源的筹码全历史拉取都失败时（如网络问题、权限限制），系统自动将 `kline_all` 设为K线链的结果，筹码源标记为与K线同源。

### 25.3 三种情况汇总表

| 条件 | 筹码源 = K线源？ | 日志关键词 | 说明 |
|------|-----------------|-----------|------|
| K线来自**离线包** | **✅ 强制是** | `"已忽略筹码链上的在线源"` | 防止合成K线与在线筹码价格不匹配 |
| K线来自**在线源** + 筹码链**成功** | **❌ 不一定** | `"筹码全历史：{label}"` | 各自独立回退，可能不同 |
| K线来自**在线源** + 筹码链**全失败** | **✅ 兜底是** | `"筹码链不可用"` | 无可用筹码源时复用K线数据 |

### 25.4 双周期下的筹码数据源

双周期模式下，**只有主周期（stepper）的 `kline_all` 用于筹码计算**。`stepper2` 的 K线数据不参与筹码分布。

```
stepper.kline_all      → 用于筹码分布（chart1 + chart2 共用此份）
stepper2.kline_all     → 仅用于步进和缠论结构计算，不参与筹码
```

因此：
- 双周期的**筹码数据源只取决于 stepper 的数据源选择结果**
- 与 stepper2 用什么数据源无关
- 前端只显示一份筹码区，且基于 stepper 的 kline_all

### 25.5 如何在界面上确认当前数据源

前端左下角「数据源状态」区域显示格式：

```
数据源: AKShare
日志:
  - [K线] try AKShare for sz.000001 2018-01-01 -> latest ✓
  - [筹码] try AKShare for sz.000001 1990-01-01 -> latest ✓
  - 筹码全历史：AKShare          ← 情况B：独立成功
  或
  - 筹码全历史与离线K线同源（已忽略筹码链上的在线源：AKShare）  ← 情况A：强制同源
  或
  - 筹码全历史与K线同源（筹码链不可用：Connection timeout）       ← 情况C：兜底同源
```

双周期模式下额外显示第二图表的K线源：

```
图表1(K线): AKShare        图表2(K线): pytdx
筹码源: BaoStock（基于图表1）
```

## 二十三、使用逻辑总结

### 26.1 完整操作流程（从启动到结束）

```
┌──────────────────────────────────────────────────────────────┐
│                    典型复盘训练流程                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ① 启动服务                                                  │
│     python replay_trainer.py                                 │
│     → 浏览器打开 http://127.0.0.1:8000/                      │
│                                                              │
│  ② 首次配置（一次性）                                         │
│     ├─ 左侧面板：输入 股票代码 / 开始日期 / 初始资金          │
│     ├─ 【系统配置】→ 数据源优先级（按需调整）                  │
│     └─ 【图表显示设置】→ 主题 / 指标槽位 / 筹码参数等        │
│                                                              │
│  ③ 加载会话 (Ctrl+I)                                         │
│     → 后端拉取 K线 + 筹码全历史数据                           │
│     → 离线数据时可能弹出确认弹窗（409）                       │
│     → 首次加载较慢（需计算全量缠论结构）                      │
│                                                              │
│  ④ 步进回放                                                   │
│     Space × N  → 逐根推进                                    │
│     或 Ctrl+Alt+N → 连续步进（遇买卖点自动停）               │
│     每步触发：                                               │
│       ├─ 缠论结构更新（笔/段/中枢/买卖点）                   │
│       ├─ 指标重算（MACD/KDJ/RSI/BOLL/Demark）                │
│       └─ 自动模式下：买卖点 ×/✓ 判定                         │
│                                                              │
│  ⑤ 观察与分析                                                │
│     ├─ 十字光标悬停 → 查看该K线的详细信息                    │
│     │   └─ 筹码分布动态回退到该时点的累积状态                │
│     ├─ Ctrl+↑/↓ 微调十字光标价格                             │
│     ├─ Ctrl+Enter 在关键价位画水平射线                       │
│     └─ Ctrl+Alt+方向键 缩放图表观察细节                      │
│                                                              │
│  ⑥ 交易模拟                                                  │
│     PageUp 买入 → PageDown 卖出                              │
│     做空/平空可在系统配置中设置快捷键                          │
│     规则：单持仓（多空互斥）/ T+1 / 每步最多一笔              │
│     弹窗显示结算信息，Enter 确认关闭                          │
│                                                              │
│  ⑦ 中途调整                                                  │
│     ├─ L → 改缠论参数（笔严格度、中枢算法等）→ S 保存       │
│     │   └─ reconfig：不重拉数据，仅重算结构                 │
│     ├─ P → 改画线样式（颜色/粗细/可见性）→ S 保存           │
│     │   └─ 仅前端生效，不涉及后端                           │
│     ├─ Z/S → 切换自动/手动判定模式                          │
│     └─ Ctrl+Alt+M → 回退到某个关键位置重新分析              │
│                                                              │
│  ⑧ 结束                                                     │
│     点击【结束训练】或【退出】                               │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 26.2 核心状态机

应用始终处于以下某一状态：

| 状态 | 含义 | 可执行操作 |
|------|------|-----------|
| **未初始化** | 服务刚启动，未加载任何会话 | 仅可 `Ctrl+I` 加载 |
| **就绪 (ready)** | 已加载数据，可正常操作 | 步进/交易/配置 全部可用 |
| **已结束 (finished)** | 训练已标记结束 | 仅可 `Ctrl+R` 重置后重新开始 |

**状态转换**：
```
未初始化 ──Ctrl+I──→ 就绪 ──【结束训练】──→ 已结束
                                ↑                    │
                                └──── Ctrl+R ←────────┘
                                  （重置回到未初始化）
```

### 26.3 步进时的完整事件链

每次按下 `Space`（或调用 `/api/step`），后端按序执行：

```
1. 确定激活图 (active_chart_id)
   单周期 → 唯一的 stepper
   双周期 → 根据 active_chart_id 选 stepper 或 stepper2

2. active_stepper.step()
   → CChan.step_load() 载入下一根K线
   → 重算分型 → 笔 → 段 → 中枢 → 买卖点
   → 更新指标 (MACD/KDJ/RSI/BOLL/Demark)

3. [双周期] 同步被动图
   → passive_stepper 步进到锚点时间
   → 防未来数据修正粗周期末根OHLCV

4. sync_bsp_history()
   → 将当前步进的买卖点追加到全局历史记录

5. sync_rhythm_history()
   → 从结构包中提取节奏命中通知

6. [自动模式] after_step_update()
   → 检测上一级结构是否变向
   → 变向时对照全量快照判定 ×/✓
   → 若有判定结果则合并到返回 payload

7. build_payload()
   → 序列化全部数据返回前端渲染
```

### 26.4 数据加载与缓存策略

#### 会话缓存机制 (`_data_session_key`)

```python
session_key = (code, begin_date, end_date, autype, chan_cfg_hash,
               k_type, data_form_mode, data_form_quantity)
```

- **相同 session_key** → 复用已缓存的 K线和筹码数据，不重新拉取
- **session_key 变化**（如改了 chan_config）→ 视为新会话，重新拉取
- **reconfig（仅改缠论参数）** → 不改变 session_key 的缓存命中逻辑，
  但会用新参数重建 ReplayChan 对象

#### 什么情况触发重新拉取？

| 操作 | 是否重新拉取数据 | 说明 |
|------|-----------------|------|
| 改股票代码 | ✅ 是 | 新代码 = 新数据 |
| 改日期范围 | ✅ 是 | 时间区间变了 |
| 改复权类型 | ✅ 是 | qfq/hfq 影响价格 |
| 改K线周期 | ✅ 是 | 不同周期需不同数据 |
| 改数量模式/聚合数 | ✅ 是 | 影响K线合成方式 |
| **仅改缠论参数 (reconfig)** | ❌ 否 | 只重建 Chan 结构对象 |
| **仅改画线样式** | ❌ 否 | 纯前端变更 |

### 26.5 买卖点判定的两种模式对比

| 维度 | 自动模式 (Z) | 手动模式 (S) |
|------|-------------|-------------|
| **触发时机** | 每次步进后自动检测 | 需按 `J` 手动触发 |
| **检测条件** | 上一层结构方向发生变化 | 同（但由用户控制何时检测） |
| **判定依据** | 对照当前时刻的全量快照 | 同 |
| **输出** | ×(无效) / ✓(有效) 标记 | 同 |
| **适用场景** | 快速回放、批量扫描 | 精细研究、逐根确认 |
| **切换副作用** | 手动→自动时会补判之前漏判的 | 无 |

### 26.6 常见问题速查

| 现象 | 可能原因 | 解决方法 |
|------|---------|---------|
| 加载后无数据显示 | 数据源无该股票/日期范围 | 换数据源或检查代码格式 |
| 步进到某根后卡住 | 已到达最后一根K线 | 提示"已到最后一根K线"属正常 |
| 买卖点不显示 | 新缠论模式 + 未走到足够深度 | 见§二十一说明；或切换为经典缠论 |
| 买入按钮灰色 | 现金不足或已持仓 | 检查账户余额 |
| 卖出按钮灰色 | 无持仓 or T+1约束 | 确认非当天买入的仓位 |
| 做空按钮灰色 | 现金不足或已持仓（含多仓） | 多空互斥，需先平多 |
| 平空按钮灰色 | 无空仓 or T+1约束 | 确认非当天开仓的空仓 |
| 筹码区空白 | chipEnabled=false 或 kline_all 为空 | 检查设置面板中筹码开关 |
| 筹码峰偏移严重 | 在线数据三角分摊精度不足 | 使用离线分笔数据提升精度 |
| 双周期图2无数据 | kType2 设置的周期该数据源不支持 | 换数据源或换周期 |
| reconfig 后结构不变 | chan_config 字段名错误被忽略 | 检查字段是否匹配 §7 定义的名称 |
| 409 离线确认弹窗 | 检测到离线数据但未确认 | 勾选确认或取消勾选离线优先级 |

---

## 二十四、指标+买卖点组合回测

### 24.1 概述

指标+买卖点组合回测是 `replay_trainer.py` 提供的**独立统计回测功能**，支持自定义入场/离场条件，可组合多个指标信号与买卖点类型进行策略回测。

**核心特点**：
- **不影响当前复盘会话**：回测使用独立的临时 ChanStepper，不修改 APP_STATE
- **支持双周期联动**：双周期模式下可分别检测两图信号
- **防未来数据泄漏**：粗周期使用细周期截至锚点的数据重算末根
- **灵活的条件组合**：入场/离场条件支持 AND/OR 组合，支持持仓超时强制离场

### 24.2 API 接口

**POST** `/api/indicator_backtest`（别名：`/api/strategy_backtest`）

#### 请求体 (IndicatorBacktestReq)

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `code` | string | 是 | - | 股票代码，如 `sz.000001` |
| `begin_date` | string | 是 | - | 开始日期，格式 `YYYY-MM-DD` |
| `end_date` | string | 是 | - | 结束日期 |
| `initial_cash` | float | 否 | 100000.0 | 初始资金 |
| `autype` | string | 否 | "qfq" | 复权类型：qfq/hfq/none |
| `chan_config` | dict | 否 | {} | 缠论配置 |
| `k_type` | string | 否 | "day" | 主周期类型 |
| `chart_mode` | string | 否 | "single" | 图表模式：single/dual |
| `k_type_2` | string | 否 | null | 双周期模式下的第二周期 |
| `step_driver` | string | 否 | "auto" | 步进驱动：auto/k1/k2 |
| `entry_conditions` | array | 是 | - | 入场条件列表（至少一条） |
| `entry_combine` | string | 否 | "and" | 入场条件组合方式：and/or |
| `exit_conditions` | array | 否 | [] | 离场条件列表 |
| `exit_combine` | string | 否 | "and" | 离场条件组合方式：and/or |
| `exit_hold` | int | 否 | null | 持仓最大K线数，超时强制离场 |
| `confirm_offline` | bool | 否 | false | 是否确认使用离线数据 |
| `data_source_priority` | array | 否 | null | 自定义数据源优先级 |
| `data_form_mode` | string | 否 | "traditional" | 数据形态模式 |
| `data_form_quantity` | int | 否 | null | 聚合数量 |
| `data_feed_mode` | string | 否 | "step" | 喂入模式：`step` / `unified` |

### 24.3 条件格式说明

每条条件为一个字典，包含以下字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `type` | string | 条件类型：`indicator` / `bsp` |
| `indicator` | string | 指标名称（type=indicator 时）：macd / kdj / rsi / boll |
| `signal` | string | 指标信号（type=indicator 时），如 macd_golden_cross / kdj_j_oversold 等 |
| `bsp_type` | string | 买卖点类型（type=bsp 时），如 b1 / s1 / b2 / s2 / b3 / s3 |
| `bsp_level` | string | 买卖点级别（type=bsp 时），如 bi / seg / segseg |
| `chart` | string | 适用图表（双周期时）：chart1 / chart2 / any，默认 any |

**支持的指标信号示例**：
- MACD：`macd_golden_cross`（金叉）、`macd_death_cross`（死叉）、`macd_above_zero`（零轴上）、`macd_below_zero`（零轴下）
- KDJ：`kdj_j_oversold`（J超卖）、`kdj_j_overbought`（J超买）、`kdj_golden_cross`（金叉）
- RSI：`rsi_oversold`（超卖）、`rsi_overbought`（超买）
- BOLL：`boll_touch_lower`（触下轨）、`boll_touch_upper`（触上轨）、`boll_mid_up`（中轨向上）

### 24.4 策略逻辑

```
对每一步（由 step_driver 决定驱动周期）：

① 离场检查：
   - 若已持仓 且 exit_conditions 满足 → 以当前价卖出（reason: exit_formula）
   - 若已持仓 且 exit_hold 超时 → 以当前价卖出（reason: exit_hold）
   - 两者同时满足 → reason: exit_formula+hold

② 入场检查：
   - 若空仓 且 entry_conditions 满足 → 以当前价全仓买入（按手取整）

③ 记录权益曲线：cash + 持仓市值

④ 循环结束后，若有持仓 → 以最后一根收盘价强制平仓（reason: eof）
```

### 24.5 返回值格式

```json
{
  "code": "sz.000001",
  "name": "平安银行",
  "chart_mode": "single",
  "k_type": "day",
  "k_type_2": null,
  "step_driver": "auto",
  "bars": 1523,
  "initial_cash": 100000.00,
  "final_equity": 123456.78,
  "total_pnl": 23456.78,
  "total_return_pct": 23.46,
  "trade_count": 15,
  "win_count": 8,
  "loss_count": 7,
  "win_rate_pct": 53.33,
  "entry_combine": "and",
  "exit_combine": "and",
  "exit_hold_bars": null,
  "entry_conditions": [...],
  "exit_conditions": [...],
  "hold_bars_basis": "driver",
  "warning": null,
  "trades": [
    {
      "buy_idx": 42,
      "sell_idx": 47,
      "buy_t": "2024-03-15",
      "sell_t": "2024-03-22",
      "buy_price": 12.35,
      "sell_price": 12.88,
      "shares": 800,
      "pnl": 424.00,
      "sell_reason": "exit_formula",
      "driver_step": 47
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `code` | string | 股票代码 |
| `name` | string | 股票名称 |
| `chart_mode` | string | 回测时使用的图表模式 |
| `k_type` | string | 主周期类型 |
| `k_type_2` | string/null | 第二周期（双周期模式） |
| `step_driver` | string | 步进驱动方式 |
| `bars` | int | 总 K 线数 |
| `initial_cash` | float | 初始资金 |
| `final_equity` | float | 最终权益 |
| `total_pnl` | float | 总盈亏金额 |
| `total_return_pct` | float | 总收益率（%） |
| `trade_count` | int | 总交易次数 |
| `win_count` | int | 盈利次数 |
| `loss_count` | int | 亏损次数 |
| `win_rate_pct` | float | 胜率（%） |
| `entry_combine` | string | 入场条件组合方式 |
| `exit_combine` | string | 离场条件组合方式 |
| `exit_hold_bars` | int/null | 持仓超时K线数 |
| `trades` | array | 每笔交易的明细 |
| `warning` | string/null | 警告信息（如K线过多） |

#### trades 数组元素说明

| 字段 | 说明 |
|------|------|
| `buy_idx` | 买入时的 chart1 步进索引 |
| `sell_idx` | 卖出时的 chart1 步进索引 |
| `buy_t` | 买入日期 |
| `sell_t` | 卖出日期 |
| `buy_price` | 买入价格 |
| `sell_price` | 卖出价格 |
| `shares` | 买入股数（按手取整） |
| `pnl` | 该笔盈亏金额 |
| `sell_reason` | 卖出原因：exit_formula / exit_hold / eof |
| `driver_step` | 驱动周期的步进索引 |

### 24.6 交易规则

| 规则 | 说明 |
|------|------|
| **单持仓** | 同时只能持有一笔仓位，新买入前必须先卖出 |
| **按手买入** | `shares = int(cash // price)`，每手100股自动取整 |
| **不足一手跳过** | 若现金不足以买入1手（100股），则放弃该次买入信号 |
| **末尾强制平仓** | 回测结束时若仍有持仓，以最后一根收盘价强制卖出 |
| **无 T+1 约束** | 回测模式不考虑 T+1 限制（与模拟交易不同） |

### 24.7 典型调用示例

#### 前端 JavaScript 调用

```javascript
const resp = await fetch("/api/indicator_backtest", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    code: "sz.000001",
    begin_date: "2020-01-01",
    end_date: "2024-12-31",
    initial_cash: 100000,
    autype: "qfq",
    k_type: "day",
    entry_conditions: [
      { type: "indicator", indicator: "boll", signal: "boll_touch_lower" },
      { type: "bsp", bsp_type: "b1", bsp_level: "bi" }
    ],
    entry_combine: "and",
    exit_conditions: [
      { type: "indicator", indicator: "boll", signal: "boll_touch_upper" }
    ],
    exit_hold: 20
  })
});
const result = await resp.json();
console.log(`总收益率: ${result.total_return_pct}%`);
```

#### Python requests 调用

```python
import requests

resp = requests.post("http://127.0.0.1:8000/api/indicator_backtest", json={
    "code": "sz.000001",
    "begin_date": "2020-01-01",
    "end_date": "2024-12-31",
    "initial_cash": 100000,
    "k_type": "day",
    "entry_conditions": [
        {"type": "indicator", "indicator": "macd", "signal": "macd_golden_cross"},
        {"type": "bsp", "bsp_type": "b1", "bsp_level": "bi"}
    ],
    "entry_combine": "or",
    "exit_hold": 10
})
data = resp.json()
print(f"总收益: {data['total_pnl']}, 胜率: {data['win_rate_pct']}%")
for t in data["trades"]:
    print(f"  {t['buy_t']} 买@{t['buy_price']} → {t['sell_t']} 卖@{t['sell_price']}, 盈亏: {t['pnl']}, 原因: {t['sell_reason']}")
```

### 24.8 与旧版 BOLL 回测的差异

| 维度 | 旧版 BOLL 回测 | 新版指标回测 |
|------|--------------|------------|
| API 路径 | `/api/boll_backtest` | `/api/indicator_backtest` |
| 入场条件 | 仅 BOLL 下轨触碰 | 任意指标+买卖点组合 |
| 离场条件 | 固定持有N根 | 自定义离场条件+超时 |
| 条件组合 | 不支持 | AND/OR 灵活组合 |
| 双周期 | 两图同时满足 | 可分别指定 chart1/chart2 |
| 步进驱动 | 固定 | auto/k1/k2 可选 |

---

## 二十五、节奏系统

### 28.1 概述

节奏系统是基于缠论结构层级关系的**技术分析工具**，用于预测价格在未来可能触及的关键价位。其核心思想是利用历史回调比例来推算当前推进段的潜在支撑/压力位。

**命名来源**：
- **节奏线 (Rhythm Line)**：基于历史回调比例绘制的水平价位线
- **1382**：指黄金分割扩展系数 **1.382**，用于计算确认阈值

### 28.2 核心概念

#### 结构层级关系

节奏系统建立在缠论结构的父子层级之上：

```
父级结构（Parent）：如一个上涨段（Seg）
  └─ 子级结构（Child）：包含在该段范围内的笔（Bi）序列
       └─ 交替序列（Alternating Sequence）：按方向交替排列的子线
            └─ 推进峰值端点：与父级同方向的子线端点
```

#### 交替子线序列构建

[`build_alternating_child_sequence()`](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L2447-L2462) 从子线列表中提取方向交替的序列：

```
输入：父级方向=UP，子线=[↑, ↓, ↑, ↓, ↑, ↓, ↑]
输出：seq[0]=↑(第一个同向), seq[1]=↓, seq[2]=↑, seq[3]=↓, seq[4]=↑, seq[5]=↓, seq[6]=↑

规则：
  1. 从第一个与父级同方向的子线开始
  2. 之后每根子线方向必须与前一根相反
  3. 跳过不符合交替规则的子线
```

**最少需要 5 个元素**才能生成节奏线（即至少 3 个推进峰值 + 2 个回调）。

### 28.3 节奏线计算公式

对于**上涨父级结构**（`parent_dir = UP`）：

```
已知变量：
  a0 = 父级起始值（起点价格）
  b_j = 第 j 个推进峰值端点（偶数索引 seq[2j] 的终点值）
  c_j = 第 j 个回调端点（奇数索引 seq[2j+1] 的终点值）
  d_k = 第 k 个当前推进峰值端点（待预测）

计算步骤：
  ① 回调比率 ratio = (b_j - c_j) / (b_j - a0)
     （表示第 j 次回调占整个推进幅度的比例）

  ② 节奏价格 rhythm_price = d_k - (d_k - a0) × ratio
     （将历史回调比率应用到当前推进段）

  ③ 1382 阈值 threshold = c_j + (b_j - c_j) × 1.382
     （回调幅度的 1.382 倍扩展，作为确认触发线）
```

对于**下跌父级结构**（`parent_dir = DOWN`），公式镜像：

```
  ① ratio = (c_j - b_j) / (a0 - b_j)
  ② rhythm_price = d_k + (a0 - d_k) × ratio
  ③ threshold = c_j - (c_j - b_j) × 1.382
```

### 28.4 图示说明（以上涨段为例）

```
价格
  ↑
  │         b₁ ────┐
  │        /  \     │
  │       /    c₁   │ ← 回调低点
  │      /          │
  │  a₀─┘           │
  │                 d₂ ───── 节奏线2（用ratio₁计算）
  │                / \
  │               /   c₂
  │              /
  │  ───────────────────────── threshold₁ = c₁ + (b₁-c₁)×1.382
  │                     （1382确认线）
  └────────────────────────→ 时间/K线索引

节奏线含义：
  - 节奏线2的价格 = d₂ - (d₂-a₀) × ratio₁
  - 若后续K线最高价 >= threshold₁ → 触发1382命中通知
```

### 28.5 节奏线生成规则

[`build_parent_rhythm_entries()`](file:///c:\Users\Administrator\Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L2514-L2660) 的生成逻辑：

| 参数 | 说明 |
|------|------|
| `round_current` (k) | 当前正在预测的第 k 轮推进 |
| `round_ref` (j) | 参考历史回调的第 j 轮 |
| **生成条件** | `1 <= j <= k`（可用历史轮次参考当前及之前的轮次） |
| **最少子线数** | `len(seq) >= 5`（至少3个推进+2个回调） |
| **最大轮次** | `max_round = (len(seq) - 3) // 2` |

**生成的节奏线数量**：对于一个有 n 个元素的交替序列，最多生成 `max_round × (max_round + 1) / 2` 条节奏线（三角矩阵）。

示例（seq 有 7 个元素，max_round = 2）：

| round_current (k) | round_ref (j) | 标签 | 说明 |
|-------------------|---------------|------|------|
| 1 | 1 | 节奏线1 | 用第1轮回调比率预测第1轮推进 |
| 2 | 1 | 节奏线2_1 | 用第1轮回调比率预测第2轮推进 |
| 2 | 2 | 节奏线2 | 用第2轮回调比率预测第2轮推进 |

### 28.6 1382 命中检测

[`find_1382_hits()`](file:///c:\Users\Administrator\Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L2500-L2512) 在节奏线生成后检测实际K线是否触及确认阈值：

```
检测逻辑：
  从 c_line_for_hit（产生阈值的回调线）结束位置开始，
  遍历后续每一根 K 线：

  上涨父级：若 K 线最高价(H) >= threshold → 记录一次命中
  下跌父级：若 K 线最低价(L) <= threshold → 记录一次命中

命中记录内容：
  {
    "x": K线索引,
    "y": 触及价格,
    "time": K线时间,
    "price_field": "H" 或 "L",  // 使用了最高价还是最低价
    "price_value": 实际价格值
  }
```

**去重机制**：每个命中有一个唯一 key = `{parent_key}|1382|{level}|{round_ref}|{x}`，避免重复记录同一位置的命中。

### 28.7 节奏线数据结构

#### 节奏线对象 (lines 数组元素)

```json
{
  "key": "seg|0|120|150|UP|line|2|1",
  "level": "bi",
  "parent_level": "seg",
  "parent_key": "seg|0|120|150|UP",
  "parent_label": "段",
  "display_label": "节奏线2_1",
  "round_current": 2,
  "round_ref": 1,
  "color_group": "rhythm1",
  "dir": "UP",
  "ratio": 0.382,
  "label_left": "2_1",
  "label_right": "0.382",
  "x1": 130,
  "y1": 15.50,
  "x2": 148,
  "y2": 15.50
}
```

| 字段 | 说明 |
|------|------|
| `key` | 唯一标识 |
| `level` | 当前级别（bi/seg/segseg） |
| `parent_level` | 父级级别 |
| `display_label` | 显示标签（如"节奏线2"、"节奏线2_1"） |
| `round_current` | 当前轮次 k |
| `round_ref` | 参考轮次 j |
| `color_group` | 颜色分组（rhythm1~rhythmN，对应前端配置） |
| `dir` | 方向 UP/DOWN |
| `ratio` | 历史回调比率 |
| `x1`, `y1` | 起点坐标（K线索引, 价格） |
| `x2`, `y2` | 终点坐标（K线索引, 价格） |

#### 1382 命中对象 (hits 数组元素)

```json
{
  "key": "seg|0|120|150|UP|1382|bi|2|145",
  "x": 145,
  "y": 14.80,
  "level": "bi",
  "parent_level": "seg",
  "parent_key": "seg|0|120|150|UP",
  "display_label": "笔1382",
  "round_ref": 2,
  "color_group": "rhythm2",
  "dir": "UP",
  "threshold": 14.75
}
```

### 28.8 支持的结构级别组合

节奏系统支持以下**父子级别组合**（由 [`RHYTHM_LEVEL_PAIRS`](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py) 定义）：

| 父级 (Parent) | 子级 (Child) | 说明 |
|--------------|-------------|------|
| 段 (seg) | 笔 (bi) | 在段内根据笔的交替序列构建节奏线 |
| 2段 (segseg) | 段 (seg) | 在2段内根据段的交替序列构建节奏线 |

**注意**：
- 节奏线**仅在激活图**上计算和显示
- 每次步进后通过 `sync_rhythm_history()` 同步到全局历史
- 命中通知会合并到 payload 中，前端可弹窗提示

### 28.9 前端渲染配置

节奏线的样式可在【图表显示设置】→【节奏线 (rhythmLine)】中配置（参见 §8.8）：

| 配置项 | 说明 |
|--------|------|
| 颜色 | 按 color_group 分组（rhythm1~rhythm5 各自独立颜色） |
| 线宽 | 节奏线水平线的粗细 |
| 线型 | solid/dashed/dotted |
| 字体大小 | 标签文字大小 |

节奏命中的样式在【节奏命中 (rhythmHit)】中配置。

### 28.10 使用场景与限制

| 场景 | 适用性 | 说明 |
|------|--------|------|
| 波段趋势确认 | ✅ 推荐 | 趋势行情中节奏线提供的支撑/压力位参考价值较高 |
| 震荡市 | ⚠️ 有限 | 反复穿越节奏线导致信号频繁，需结合其他指标过滤 |
| 新缠论模式 | ✅ 支持 | 基于 build_new_bundle 的结构包计算 |
| 经典缠论模式 | ✅ 支持 | 基于 CChan 原生结构计算 |

**限制**：
- 至少需要 **5 根有效子线** 才能生成第一条节奏线
- 节奏线是**水平线**，不代表价格一定会到达该位置
- 1382 命中仅表示价格触及了扩展阈值，**不构成买卖建议**
- 双周期模式下仅基于**激活图**的结构计算

---

## 二十六、Goto Step

### 29.1 概述

`/api/goto_step` 提供将当前复盘会话**跳转到指定步进索引**的功能，主要用于从 BOLL 回测成交记录快速定位到对应的历史K线位置。

### 29.2 API 接口

**POST** `/api/goto_step`

#### 请求体 (GotoStepReq)

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `step_idx` | int | 是 | 0 | 目标步进索引（0 = 第一根可见K线） |

### 29.3 跳转逻辑

[`api_goto_step()`](file:///c:\Users\Administrator\Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L12694-L12734) 的处理流程：

```
输入目标 step_idx = target

① 安全检查
   - target < 0 → 修正为 0
   - 会话未就绪 → 400 错误
   - 会话已结束 → 400 错误

② 获取当前位置 cur = active_stepper.step_idx

③ 三种情况分支：

   情况 A: target == cur
     → 已在目标位置，直接返回当前 payload
     → message: "已在目标步进 step={target}"

   情况 B: target < cur（向后跳转 / 回退）
     → 调用 rebuild_to_step(target)
     → 一次性重建到目标位置（高效）
     → 清空节奏命中缓存
     → message: "已跳转到 step={target}"

   情况 C: target > cur（向前跳转）
     → 先 rebuild_to_step(0) 回到起点
     → 然后 for 循环 step() × target 次
     → 每步执行完整的事件链（同步/判定/更新）
     → 若中途到达末尾则提前终止
     → message: "已跳转到 step={实际到达位置}"
```

### 29.4 与 back_n 的区别

| 维度 | goto_step | back_n |
|------|-----------|--------|
| **目标指定方式** | 绝对位置（跳到第 N 根） | 相对位置（后退 N 根） |
| **向前跳转** | ✅ 支持 | ❌ 仅支持后退 |
| **实现方式（向后）** | rebuild_to_step | rebuild_to_step（相同） |
| **实现方式（向前）** | 逐步 step() 循环 | 不适用 |
| **性能（向前远距离）** | 较慢（需逐步步进） | 不适用 |
| **典型用途** | 从回测结果跳转到历史位置 | 复盘时回退几步重新观察 |

### 29.5 典型使用场景

#### 场景 1：从 BOLL 回测结果跳转

```javascript
// 假设回测返回的 trades 数组
const trade = bollResult.trades[0];  // 第一笔交易

// 跳转到该笔交易的买入位置
await fetch("/api/goto_step", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ step_idx: trade.buy_idx })
});
// 前端自动滚动到该K线位置并高亮显示
```

#### 场景 2：快速定位到关键日期

```python
import requests

# 先通过 /api/state 获取当前状态找到目标索引
state = requests.get("http://127.0.0.1:8000/api/state").json()

# 找到目标日期对应的 step_idx（假设已找到 idx=500）
requests.post("http://127.0.0.1:8000/api/goto_step", json={"step_idx": 500})
```

### 29.6 注意事项

1. **向前跳转的性能开销**：若 target 远大于当前位置（如从 0 跳到 1000），需要循环调用 1000 次 `step()`，每次都会重建缠论结构、同步双周期、检测买卖点等，**耗时较长**
2. **双周期同步**：跳转后会自动执行 `_sync_stepper_to_anchor` 和 `_dual_rebuild_coarse_chan_anti_future`，确保两图时间对齐且无未来数据
3. **节奏命中清空**：每次跳转会清空 `_rhythm_notice_hits` 缓存，下次步进时重新计算
4. **买卖点历史保留**：跳转不会清空 `bsp_history` 和 `trade_events`，但新增的判定会追加到现有历史中
5. **边界保护**：target 自动 clamp 到 `[0, 最大步进数]` 范围内

---

## 二十七、数据源链回退

### 30.1 概述

数据源链回退是 `replay_trainer.py` 的核心容错机制，确保在某数据源不可用时能**自动切换到下一个可用源**，保证服务持续可用。

### 30.2 架构设计

#### 两套独立链

系统维护**两条独立的数据源优先级链**（定义在 [replay_trainer.py 全局变量区域](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py)）：

```python
DATA_SOURCE_CHAIN_KLINE = [
    ("AKShare", DATA_SRC.AKSHARE),
    ("AKShare-腾讯历史", ...),
    ("Ashare", ...),
    # ... 共 12 个数据源
]

DATA_SOURCE_CHAIN_CHIP = [
    # 与 KLINE 链相同的顺序
    # 但各自独立回退，最终可能选中不同源
]
```

**为什么需要两套链？**
- K线主序列只需拉取用户指定的日期范围
- 筹码全历史需要拉取从 1990-01-01 到结束日期的**全量数据**
- 不同数据源在全量拉取时可能有不同的超时/限制表现

#### 选择器接口

[`_select_data_source_with_fallback()`](file:///c:\Users\Administrator\Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L3069-L3109) 是统一的数据源选择入口：

```python
def _select_data_source_with_fallback(
    self,
    begin_date, end_date, autype, chan_cfg_dict,
    use_for="kline",           # "kline" 或 "chip"
    chain_override=None,       # 可覆盖默认链
    offline_confirm_suppressed=False,  # 是否抑制离线确认弹窗
) -> DataSourceSelection:
```

### 30.3 回退流程详解

```
_select_data_source_with_fallback() 执行流程：

for idx, (label, data_src) in enumerate(data_chain):
  │
  ├─ ① 尝试从当前源获取数据
  │   _fetch_from_single_source(data_src, ...)
  │
  ├─ ② 成功？
  │   ├─ 是 → 返回 DataSourceSelection(
  │   │        data_src=data_src,
  │   │        label=label,
  │   │        logs=[成功日志],
  │   │        replay_klus_master=...,
  │   │        kline_all=...,
  │   │        stock_name=...
  │   │      )
  │   │   第一个源成功 → 日志："数据源已连接：{label}"
  │   │   后续源成功 → 日志："数据源切换成功：{label}（前序源不可用，已自动降级）"
  │   │
  │   └─ 否 ↓
  │
  ├─ ③ 异常类型判断
  │   ├─ OfflineDataConfirmRequired → 直接抛出（不继续尝试后续源）
  │   │
  │   └─ 其他异常 ↓
  │
  ├─ ④ 记录失败日志
  │   errors.append(f"{label} 失败：{detail}")
  │   logs.append(f"数据源尝试失败：{label}")
  │
  └─ ⑤ 检查下一个是否为离线源 + 是否需要确认
      ├─ 下一个是离线源 AND 未抑制确认 AND 离线包存在
      │   → 抛出 OfflineDataConfirmRequired（HTTP 409）
      │
      └─ 否则 → continue（尝试下一个源）

全部源都失败 → raise RuntimeError("全部数据源均不可用：...")
```

### 30.4 DataSourceSelection 返回结构

```python
class DataSourceSelection:
    data_src: Any              # 枚举值，实际使用的数据源
    label: str                 # 显示名称，如 "AKShare"
    logs: list[str]            # 选择过程的日志列表
    replay_klus_master: list   # 步进用的K线单元列表（已聚合/原始）
    kline_all: list            # 筹码全历史K线列表
    stock_name: str            # 股票名称
```

### 30.5 默认优先级顺序（完整列表）

| 优先级 | 名称 | 数据源枚举 | 特点 |
|--------|------|-----------|------|
| 1 | AKShare | DATA_SRC.AKSHARE | 首选，数据全面 |
| 2 | AKShare-腾讯历史 | - | AKShare 备用接口 |
| 3 | Ashare | DATA_SRC.ASHARE | 备选 |
| 4 | AData | DATA_SRC.ADATA | 备选 |
| 5 | pytdx | DATA_SRC.PYTDX | 通达信，速度快 |
| 6 | BaoStock | DATA_SRC.BAO_STOCK | 稳定但需登录 |
| 7 | **离线数据** | OFFLINE_INLINE_SRC | 本地文件，无需网络 |
| 8 | Tushare | DATA_SRC.TUSHARE | 需 token |
| 9 | 新浪财经 | DATA_SRC.SINA | 公开接口 |
| 10 | 腾讯财经 | DATA_SRC.TENCENT | 公开接口 |
| 11 | 雅虎财经 | DATA_SRC.YAHOO | 海外市场 |
| 12 | 东方财富 | DATA_SRC.EAST_MONEY | 公开接口 |
| 13 | GitHub-CSV | DATA_SRC.GITHUB_CSV | 自定义CSV |

### 30.6 用户自定义优先级

前端可通过【系统配置】→【数据源优先级】面板调整顺序：

```javascript
// 发送请求
POST /api/set_data_source_priority
{
  "priority": ["AKShare", "pytdx", "离线数据", "BaoStock"]
}

// 后端处理
apply_data_source_priority(priority)
→ 重新排序 DATA_SOURCE_CHAIN_KLINE 和 DATA_SOURCE_CHAIN_CHIP
→ 两套链保持相同顺序
```

**约束**：
- 必须传入数组
- 数组元素必须是有效的数据源名称
- 未知名称会被忽略（但不报错）
- 设置后立即生效，下次 init 时使用新顺序

### 30.7 离线数据的特殊处理

离线数据在回退链中有**特殊的确认机制**（详见 §22.9）：

```
触发条件（四者缺一不可）：
  ① 当前在线源请求失败
  ② 链中下一个待尝试的是离线数据
  ③ 用户尚未确认使用离线数据（confirm_offline=False）
  ④ offline_bundle_exists() 探测到离线包确实存在

满足条件 → 抛出 OfflineDataConfirmRequired
→ HTTP 409 + detail 包含确认信息
→ 前端弹出确认对话框
→ 用户确认后重新发起请求（confirm_offline=True）
→ 跳过确认，直接使用离线数据
```

### 30.8 错误分类与日志

[`classify_fetch_error_tag()`](file:///c:\Users\Administrator\Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L354-L370) 将异常分为两类：

| 分类标签 | 触发关键词 | 含义 |
|---------|-----------|------|
| **网络问题** | timeout, connection, ssl, 403/404/502/503, 10060/10054 | 网络层问题，换源可能解决 |
| **数据源异常** | 其他所有异常 | 数据本身问题（如代码不存在、日期无数据） |

**日志输出示例**：

```
[DataSource] try AKShare for sz.000001 2018-01-01 -> latest
[DataSource] failed AKShare: Connection timeout
[DataSource] try Ashare for sz.000001 2018-01-01 -> latest
[DataSource] selected Ashare
数据源切换成功：Ashare（前序源不可用，已自动降级）
```

### 30.9 性能与可靠性考量

| 因素 | 影响 | 优化措施 |
|------|------|---------|
| 链长度过长 | 首次尝试失败时逐个重试耗时久 | 默认13个源，通常前3个就能成功 |
| 全量筹码拉取 | 可能超时（尤其免费源） | 独立链允许K线先成功，筹码继续尝试 |
| 离线探测 | 每次 init 都检查目录存在性 | 文件系统操作，毫秒级 |
| 网络抖动 | 偶发超时被误判为源不可用 | 下次 init 时会重新尝试该源 |

---

## 二十八、API 返回值

### 31.1 通用返回格式

所有 API 接口在成功时返回 JSON 对象，失败时返回 HTTP 错误状态码 + JSON 错误详情：

**成功响应**：
```json
{
  // ... 业务数据字段
  "message": "操作成功描述"
}
```

**错误响应**：
```json
{
  "detail": "错误原因描述"
}
```

| HTTP 状态码 | 含义 | 触发场景 |
|------------|------|---------|
| 200 | 成功 | 操作正常完成 |
| 400 | 请求错误 | 参数缺失/无效、业务规则校验失败 |
| 409 | 冲突 | 需要用户确认（离线数据确认） |

### 31.2 各接口返回值详解

#### /api/init — 初始化会话

**成功返回** (`build_payload()` 生成的完整 payload)：

```json
{
  "ready": true,
  "finished": false,
  "step_idx": 1,
  "current_time": "2024-01-08",
  "stock_name": "中国平安",

  "account": {
    "initial_cash": 10000.0,
    "cash": 10000.0,
    "position": 0,
    "avg_cost": 0.0,
    "total_pnl": 0.0
  },

  "kline": [ /* 当前可见K线子集 */ ],
  "kline_all": [ /* 全历史K线（含 chip_tick_bins）*/ ],

  "chan": { /* 缠论结构数据 */ },
  "indicators": { /* 指标数据 */ },
  "bsp_history": [ /* 买卖点历史 */ ],

  "chart_mode": "single",
  "active_chart_id": "chart1",

  "data_source_label": "AKShare",
  "data_source_logs": ["数据源已连接：AKShare"],
  "data_source_chip_label": "AKShare",

  "message": "加载成功：中国平安，当前数据源 AKShare，单周期(daily)。"
}
```

**特殊情况返回 (HTTP 409)**：
```json
{
  "detail": {
    "type": "offline_confirm",
    "display_code": "600340",
    "failed_label": "AKShare",
    "reason_tag": "网络问题",
    "reason_detail": "Connection timeout"
  }
}
```

#### /api/step — 步进

**成功返回**：
```json
{
  "ready": true,
  "step_idx": 2,
  "current_time": "2024-01-09",
  "kline": [ /* 更新后的K线 */ ],
  "chan": { /* 重新计算的缠论结构 */ },
  "indicators": { /* 更新后的指标 */ },
  "bsp_history": [ /* 追加新的买卖点记录 */ ],
  "message": "步进成功"
}

// 或到达末尾时：
{
  "message": "已到最后一根K线"
}
```

#### /api/judge_bsp — 买卖点判定

**成功返回**：
```json
{
  "ready": true,
  "bsp_history": [ /* 更新后的买卖点历史（含新判定结果）*/ ],
  "judge_notice": true,
  "last_judge_stats": {
    "total_checked": 5,
    "valid_count": 2,
    "invalid_count": 3
  },
  "last_judge_x": 120,
  "last_judge_time": "2024-03-15",
  "message": "买卖点判定完成"
}
```

#### /api/buy — 买入

**成功返回**：
```json
{
  "ready": true,
  "account": {
    "initial_cash": 10000.0,
    "cash": 1234.5,      // 扣除买入成本后剩余
    "position": 80,       // 买入股数（按手取整）
    "avg_cost": 10.95,   // 平均成本
    "total_pnl": 0.0
  },
  "trade_events": [{
    "side": "buy",
    "step_idx": 5,
    "x": 120,
    "price": 10.95,
    "shares": 80
  }],
  "message": "买入成功：{\"shares\":80,\"cost\":8760,\"remaining\":1234.5}"
}
```

**失败返回 (HTTP 400)**：
```json
{
  "detail": "现金不足"  // 或 "请先初始化会话" / "当前会话已结束"
}
```

#### /api/sell — 卖出

**成功返回**：
```json
{
  "ready": true,
  "account": {
    "cash": 2108.5,       // 卖出后现金增加
    "position": 0,        // 清仓
    "avg_cost": 10.95,
    "total_pnl": 174.0    // 本次盈亏
  },
  "trade_events": [
    // ... 之前的交易记录
    {
      "side": "sell",
      "step_idx": 15,
      "x": 380,
      "price": 12.13,
      "shares": 80
    }
  ],
  "message": "卖出结果：{\"shares\":80,\"pnl\":174.0,\"reason\":\"正常卖出\"}"
}
```

**失败返回 (HTTP 400)**：
```json
{
  "detail": "无持仓"  // 或 "T+1约束：当天买入的股票不能当天卖出"
}
```

#### /api/back_n — 后退N步

**成功返回**：
```json
{
  "ready": true,
  "step_idx": 45,       // 后退后的新位置
  "current_time": "2024-02-28",
  "chan": { /* 重建后的缠论结构 */ },
  "message": "自动重建回放：已后退 10 根（目标 step=45）"
}
```

#### /api/goto_step — 跳转到指定位置

**成功返回**（三种情况的 message 不同）：
```json
// 已在目标位置
{ "message": "已在目标步进 step=100" }

// 向后跳转
{ "message": "已跳转到 step=50" }

// 向前跳转
{ "message": "已跳转到 step=200" }
```

#### /api/boll_backtest — BOLL回测

详见 §27.5 节。

#### /api/state — 获取状态

返回与 `/api/step` 相同格式的完整 payload（不含 message 字段差异）。

#### /api/reconfig — 重新配置

**成功返回**：
```json
{
  "ready": true,
  "chan": { /* 用新配置重算的缠论结构 */ },
  "account": {
    "initial_cash": 10000.0,
    "cash": 10000.0,     // reconfig 会重置账户
    "position": 0,
    "avg_cost": 0.0,
    "total_pnl": 0.0
  },
  "message": "配置更新成功，已按新逻辑重新计算并清除模拟持仓。"
}
```

#### /api/set_data_source_priority — 设置数据源优先级

**成功返回**：
```json
{
  "message": "数据源优先级已更新：[\"AKShare\",\"pytdx\",\"离线数据\"]"
}
```

#### /api/check_data_source — 检测数据源

**成功返回**：
```json
// 数据源可用
{ "ok": true, "name": "AKShare", "message": "AKShare 可拉取日线样本（5 根）" }

// 数据源不可用
{ "ok": false, "name": "Tushare", "message": "API token 未配置" }
```

#### /api/reset — 重置会话

**成功返回**：返回初始状态的 payload（所有字段归零/归空）。

#### /api/finish — 结束训练

**成功返回**：
```json
{
  "ready": true,
  "finished": true,
  "message": "训练结束"
}
```

#### /api/exit — 退出服务

成功返回后服务器进程终止，无返回体（连接断开）。

### 31.3 build_payload() 核心字段说明

所有涉及状态查询的接口（init/step/state/goto_step/back_n 等）都通过 [`build_payload()`](file:///c:\Users\Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py) 生成返回值：

| 字段组 | 字段 | 类型 | 说明 |
|--------|------|------|------|
| **状态** | `ready` | bool | 会话是否就绪 |
| | `finished` | bool | 是否已结束 |
| | `step_idx` | int | 当前步进索引 |
| | `current_time` | string | 当前K线时间 |
| | `stock_name` | string | 股票名称 |
| **账户** | `account` | object | 模拟账户状态（见上文） |
| **K线** | `kline` | array | 当前视口可见K线（随步进变化） |
| | `kline_all` | array | 全历史K线（固定不变，含筹码数据） |
| **缠论** | `chan` | object | 缠论结构（笔/段/中枢/买卖点） |
| **指标** | `indicators` | object | MACD/KDJ/RSI/BOLL/Demark |
| **历史** | `bsp_history` | array | 买卖点历史记录 |
| | `trade_events` | array | 交易事件记录 |
| | `rhythm_hit_history` | array | 节奏命中历史 |
| **图表** | `chart_mode` | string | single/dual |
| | `active_chart_id` | string | chart1/chart2 |
| | `chan2` | object/null | 第二图表的缠论数据（双周期模式） |
| **数据源** | `data_source_label` | string | K线数据源名称 |
| | `data_source_chip_label` | string | 筹码数据源名称 |
| | `data_source_logs` | array[string] | 数据源选择日志 |
| **判定** | `judge_notice` | bool | 是否有新的判定通知 |
| | `last_judge_stats` | object | 最近一次判定统计 |
| **缓存** | `rollback_config` | object | 回退缓存状态（cache_depth / full_snapshot_interval / capture_max_bars / light_count / full_count） |
| **数据形态** | `data_form` | object | 数据形态信息（mode / quantity / feed_mode / raw_count / current_count） |
| **消息** | `message` | string | 操作结果描述 |


---

# 快速上手指南

- [快速上手指南](#快速上手指南)
  - [写在前面](#写在前面)
  - [如何开始](#如何开始)
  - [框架核心能力](#框架核心能力)
    - [关于“当前帧”的详细说明](#关于当前帧的详细说明)
    - [关于is\_sure标记](#关于is_sure标记)
    - [你需要做的](#你需要做的)
  - [可能遇到的问题](#可能遇到的问题)
    - [运行报错](#运行报错)
    - [运行完啥也没有](#运行完啥也没有)
    - [README里面有些文件为啥仓库里面没有](#readme里面有些文件为啥仓库里面没有)
    - [关于完整版](#关于完整版)
    - [为啥信号会消失](#为啥信号会消失)
    - [画图为啥不能交互](#画图为啥不能交互)
    - [关于动态图](#关于动态图)
    - [CChan类序列化/deepcopy时报递归溢出](#cchan类序列化deepcopy时报递归溢出)
    - [报k线时间相关错误](#报k线时间相关错误)
    - [我觉得线段画的不太对](#我觉得线段画的不太对)
    - [其他问题](#其他问题)
  - [不可绕过的步骤](#不可绕过的步骤)
    - [CChanConfig重点关注配置](#cchanconfig重点关注配置)
  - [取出缠论元素](#取出缠论元素)
    - [CKLine-合并K线](#ckline-合并k线)
      - [CKLine\_Unit-单根K线](#ckline_unit-单根k线)
    - [bi\_list-笔管理类](#bi_list-笔管理类)
      - [CBi- 笔类](#cbi--笔类)
    - [CSegListComm-线段管理类](#cseglistcomm-线段管理类)
      - [CSeg：线段类](#cseg线段类)
    - [CZSList-中枢管理类](#czslist-中枢管理类)
      - [CZS：中枢类](#czs中枢类)
    - [CBSPointList-买卖点管理类](#cbspointlist-买卖点管理类)
      - [CBS\_Point：买卖点类](#cbs_point买卖点类)
  - [数据接入速成班](#数据接入速成班)
    - [CCommonStockApi子类实现](#ccommonstockapi子类实现)
    - [CTime](#ctime)
    - [初始化和结束](#初始化和结束)
    - [接入数据源](#接入数据源)
  - [线段](#线段)
    - [虚段](#虚段)
  - [中枢](#中枢)
  - [策略实现 \& 回测](#策略实现--回测)
    - [从外部喂K线](#从外部喂k线)
    - [更新小级别触发大级别重算](#更新小级别触发大级别重算)
  - [开源版本指标添加](#开源版本指标添加)
    - [指标画图](#指标画图)
  - [机器学习接入](#机器学习接入)
    - [机器学习分支和主分支区别](#机器学习分支和主分支区别)
  - [一致性](#一致性)
    - [如何防止未来信息](#如何防止未来信息)
  - [打赏](#打赏)


<p align="center">
<img src="./Image/chan.py_image_1.svg" width="300"/>
</p>

```
             ██████╗██╗  ██╗ █████╗ ███╗   ██╗   ██████╗ ██╗   ██╗
            ██╔════╝██║  ██║██╔══██╗████╗  ██║   ██╔══██╗╚██╗ ██╔╝
            ██║     ███████║███████║██╔██╗ ██║   ██████╔╝ ╚████╔╝
            ██║     ██╔══██║██╔══██║██║╚██╗██║   ██╔═══╝   ╚██╔╝
            ╚██████╗██║  ██║██║  ██║██║ ╚████║██╗██║        ██║
             ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝        ╚═╝
```


## 写在前面
- 为什么会有这个项目：我想自动化买卖股票 → 需要一套比较好的，容易程序化描述股票走势的理论 → 找到缠论 → 实现后顺便开源部分
- 为啥会开源：借助群众的力量，帮我优化找bug，顺便回馈群众～
- 开源部分包含什么：
  - 缠论元素（笔，线段，中枢，买卖点）的计算
- 开源部分不包含什么：
  - 策略：因为定制化很强
  - 交易引擎：因为不通用
  - 机器学习相关（特征/模型）
- **不包含策略，不包含策略，不包含策略**（再次强调）
- 关于开发/新增特性：
  - 不要找我开发，我不是外包
  - 如果特性对我有用，我会立马开发
  - 欢迎提交PR
- 什么东西不会发到开源版里
  - 非通用的，定制化的东西
  - 我解释/答疑起来会很麻烦的东西
  - 策略
    - 当然典型的策略的用法会放进demo里面
    - 也欢迎PR demo策略
- 免责声明：
  - 本人没读完原著
  - 本人不完全理解缠论交易思想
  - 实现细节可能不完全符合你所想
    - 可能实现的是我理解的缠论
  - README是完整版的描述，可能与开源版本不符
- 讨论组：<a href="https://t.me/zen_python">Telegram</a>
  - 为什么用TG：因为后进来的朋友可以看到以前的讨论（啥时候墙内也有类似的，我再开个讨论的）
  - 没法科学上网，没有tg账号：有问题可以邮件联系我
- 欢迎star，满足一下我的虚荣心
- 如有打赏，万分感谢！
- 视频介绍：[20230909交流会录屏](https://www.bilibili.com/video/BV1nu411c7oG/);


## 如何开始
`python3 main.py`即可体验


## 框架核心能力
一言以蔽之：
- 根据给定范围的K线，算出当前静态范围下的缠论元素
  - 框架对于各种元素都提供了不同的参数配置
- 基于上述能力，提供增加K线时的增量更新缠论元素
- 支持开发自己的数据源接入这个计算（参见[数据接入速成班](#数据接入速成班)）
- 支持让你取出算好的元素组装你自己的策略（参见[取出缠论元素组织策略](#取出缠论元素组织策略)）


### 关于“当前帧”的详细说明
框架支持计算指定时间范围内K线所组成的缠论元素，也支持逐根K线投喂更新已有的缠论元素；

任何时刻（比如每新增一根K线），都可以通过框架CChan这个类获得当下（到目前给定的K线为止）下所有缠论的元素（各种元素获取参见下文）；

> 而对于最重要的买卖点，可以理解成每次计算出来的都是当下的“形态学”买卖点；只不过有些买卖点不是已经确定的，可能在将来消失；

所以随着K线的新增，你可能会发现某个位置的买点突然消失的，或者一个买卖点的位置一直在变动；

举个例子：
- 在某下降线段尾部单边下跌的一笔中（即每根新增K线的低点都比上一根更低），那么每新增一根K线，这根K线都可能在“当下”被标识为一类买卖点，而上一根K线的标识被取消；
- 如果某根K线之后开始反弹，那么在最低点这根K线被跌破之前，新投喂K线后这根最低点的K线会一直被**持续**标记为一买
- 直到形态上认为这个一买不再成立

<img src="./Image/frame.png" />

### 关于is_sure标记
框架会对所有元素都标明是否已经确定（或者说已经完成），可以参见各个类的is_sure属性；

is_sure=False在画图结果中表现为虚线（虚笔，虚段，虚线中枢）；

对于is_sure=True的元素，在后续K线新增的过程中，这些元素不会再被变更，也不可能会被标记为is_sure=False;

而且is_sure=False的元素只可能出现在所有K线的头部或者尾部；

### 你需要做的
根据上面所言，框架会一直给你提示当下这一“帧”里面的缠论元素分别是什么样子；

随着K线的投喂，可能很多K线都曾经在某个时候被标记为“当下”的买卖点（而且这些买卖点大部分is_sure=False）；

对于那些不确定是否将来最终会成立的买卖点，你需要自己开发策略判断这些买卖点是否最终会成立，或者当下是否需要交易（比如考虑买卖点的背驰度，中枢数之类的）；

> 其中需要特别说明的是，由于走势的多义性，而框架在任何一个时刻只能给出一种缠论元素的计算结果，所以必然存在某些将来成立的买卖点，在K线新增的全过程中，一次都不曾被标记为买卖点过；（当然破解方法也比较简单，每根K线进来后跑两组不同的缠论计算参数）

> 而我比较偷懒，把这块策略判断的实现企图通过机器学习模型来解决；


## 可能遇到的问题
### 运行报错
依赖最低版本为python3.11；由于本项目是高度计算密集型，鉴于python3.11发布且运算速度大幅提升，实测相比于python 3.8.5计算时间缩短约16%，故后续开发均基于python3.11；

### 运行完啥也没有
某些系统画图窗口可能会在程序运行完后自动关闭，常用解法：
- 在jupyter notebook之类应用上运行
- 在代码最后加上一句`input()`

### README里面有些文件为啥仓库里面没有
README.md文件主要为个人完整版撰写，对于开源版，主要查考此 quick_guide.md 即可；

另外，画图/CChanConfig等配置，框架里面一些定义解释可以参考README，其他的看 README 意义不大。

### 关于完整版
首先，完整版和开源版的区别参见[写在前面](#写在前面)章节，差异部分主要为个人策略和交易引擎**定制开发**的代码，不具备可泛化性，各位拿了也没啥用！

> 另外机器学习模型相关的代码和一些特征，也由于并非所有知识产权都归属于我，所以是没法对外提供的。
> 关于这部分的思路，B站发的[交流会视频](https://www.bilibili.com/video/BV1iB421k74C/)基本已经介绍过了，感兴趣的可以去看看。

其次，开源的部分提供了所有可以用到的基座和演示代码，已经足够大家自行用于组装自己的策略。

最后，不要再找我买完整版代码了，内部自用策略，而且此项目开发时间已超过一千小时，按照时薪计算也不是大家可以负担得起的。

### 为啥信号会消失
大家所说的信号，应该就是框架计算出来的买卖点（bsp）；

因为框架计算得永远都是“当前帧”下的缠论元素，随着K线的增加，原有的买卖点可能会被证明不成立（比如跌破一买），那么原本位置会被标记为买卖点的K线将不再被标记为bsp；


### 画图为啥不能交互
框架提供的默认画图能力其实是对接的matplotlib这个库，如果你希望在别的画图引擎上实现（比如某些web页面，或者ploty这种可交互的库），欢迎PR代码~

框架提供了一个画图元素类PlotMeta，里面提供了各种元素在绘图时的坐标信息（比如已经完成了K线时间到X轴坐标的转化了），方便自行对接到不同的画图引擎上；

### 关于动态图
问：使用 main.py 里面画动态图特别吃内存，32G都不够用，而且会越来越卡；
答：动图是一个纯实验性功能，内存泄露是已知问题，只是作为演示，多年没优化过了，欢迎各位感兴趣的提PR进行优化～

### CChan类序列化/deepcopy时报递归溢出
原因：框架里面很多缠论元素类都有一个next/pre成员指向了上一个/下一个元素，python导出时可能会遇到递归导致溢出问题；
解决方法：加一行配置，增加系统递归深度

```python
sys.setrecursionlimit(0x100000)
```

对于pickle_dump，可以使用框架提供的：
```python
chan.chan_dump_pickle("chan.pkl")

chan_new = CChan.chan_load_pickle("chan.pkl")
```

### 报k线时间相关错误
常见报错类似：`kline time err, cur=2024/01/01 00:05, last=2024/01/01`

处理方法：如果数据级别为天级别以下（不包含天级别），且K线时间可能出现0点0分数据，那么在数据源类中返回的K线时间CTime中，把auto设置为False即可；

根本原因：一般日线K的时间都不包含小时信息，或者为0点0分，为了处理天级别+分钟级别K线时间对齐问题，auto 设置为 True（这是默认设置）则会自动将天的小时分钟信息设置为23:59，从而保证当天的分钟线为对应日期的次级别K线；但是对于数字货币类的分钟K线，如果也出现0点0分，则会有误判；

### 我觉得线段画的不太对
线段逻辑简要说明可以参考[线段](#线段)一章，如果不太能理解划段的结果，可以在画图开关里面打开`plot_eigen`开关绘制出特征序列辅助分析。

如果还有问题，只能联系作者了。。

### 其他问题
如需作者排查，尽量提供可以直接运行的主函数文件和数据文件；


## 不可绕过的步骤
很多用户使用，其实不需要细看整个代码是怎么实现了，假装相信框架没BUG，通过直接提取框架计算好的缠论元素来组装策略（具体内部元素结构的设计参见[B站视频](https://www.bilibili.com/video/BV1nu411c7oG/)）；

但是即便如此，以下三部分建议先读README文件了解下；

- 了解CChan这个类的输入参数及格式
- 了解CChanConfig接受的配置：默认配置基本可用，关注自己想了解的即可
- 如果涉及画图，了解画图的两个配置
  - plot_config：需要画什么
  - plot_para：画的每种元素单独配置

然后通过画图，可能找到一些不合理的地方（笔段中枢买卖点算错或漏算之类的），再具体去看实际实现细节或者反馈给作者。

这些README里面都有细讲。。

### CChanConfig重点关注配置
CChanConfig里面提供了很多的配置，其中很多人最容易被影响到自己计算结果的主要是这几个，它们的含义最好再仔细阅读一下readme相关解释：
- bi_strict：是否只用严格笔，默认为 Ture，其中这里的严格笔只考虑顶底分形之间相隔几个合并K线
- bi_fx_check：检查笔顶底分形是否成立的方法
- bi_end_is_peak: 笔的尾部是否是整笔中最低/最高, 默认为 True
- divergence_rate：1类买卖点背驰比例，即离开中枢的笔的 MACD 指标相对于进入中枢的笔，默认为 0.9
- min_zs_cnt：1类买卖点至少要经历几个中枢，默认为 1
- max_bs2_rate：2类买卖点那一笔回撤最大比例，默认为 0.618
    - 注：如果是 1.0，那么相当于允许回测到1类买卖点的位置
- zs_algo: 中枢算法，涉及到中枢是否允许跨段

## 取出缠论元素
- CChan这个类里面有个变量`kl_datas`，这是一个字典，键是 KL_TYPE（即级别，具体取值参见Common/CEnum），值是 CKLine_List 类；
- CKLine_List是所有元素取值的入口，关键成员是：
  - lst: List[CKLine]：所有的合并K线
  - bi_list：CBiList 类，管理所有的笔
  - seg_list：CSegListComm 类，管理所有的线段
  - zs_list：CZSList 类，管理所有的中枢
  - bs_point_lst：CBSPointList 类，管理所有的买卖点
  - 其余大部分人可能不关注的
    - segseg_list：线段的线段
    - segzs_list：线段中枢
    - seg_bs_point_lst：线段买卖点


### CKLine-合并K线
成员包括：
- idx：第几根
- CKLine.lst可以取到所有的单根K线变量 CKLine_Unit
- fx：FX_TYPE，分形类型
- dir：方向
- pre,next：前一/后一合并K线
- high：高点
- low：低点

#### CKLine_Unit-单根K线
成员包括：
- idx：第几根
- time
- low/close/open/high
- klc：获取所属的合并K线（即CKLine）变量
- sub_kl_list: List[CKLine_Unit] 获取次级别K线列表，范围在这根K线范围内的
- sup_kl: CKLine_Unit 父级别K线（CKLine_Unit）


### bi_list-笔管理类
成员包含：
- bi_list: List[CBi]，每个元素是一笔

这个类的实现基本可以不用关注，除非你想实现自己的画笔算法

#### CBi- 笔类
成员包含：
- idx：第几笔
- dir：方向，BI_DIR类
- is_sure：是否是确定的笔
- klc_lst：List[CKLine]，该笔全部合并K线
- seg_idx：所属线段id
- parent_seg:CSeg 所属线段
- next/pre：前一/后一笔

可以关注一下这里面实现的一些关键函数：
- _high/_low
- get_first_klu/get_last_klu：获取笔第一根/最后一根K线
- get_begin_klu/get_end_klu：获取起止K线
  - 注意一下：和get_first_klu不一样的地方在于，比如下降笔，这个获取的是第一个合并K线里面high最大的K线，而不是第一个合并K线里面的第一根K线；
- get_begin_val/get_end_val：获取笔起止K线的价格
  - 比如下降笔get_begin_val就是get_begin_klu的高点


### CSegListComm-线段管理类
- lst: List[CSeg] 每一个成员是一根线段

这个类的实现基本可以不用关注，除非你想实现自己的画段算法，参照提供的几个demo，实现这个类的子类即可；

#### CSeg：线段类
成员包括：
- idx
- start_bi：起始笔
- end_bi：终止笔
- is_sure：是否已确定
- dir：方向，BI_DIR类
- zs_lst: List[CZS] 线段内中枢列表
- pre/next：前一/后一线段
- bi_list: List[CBi] 线段内笔的列表

关注的一些关键函数和CBi里面一样，都已实现同名函数，如：
- _high/_low
- get_first_klu/get_last_klu
- get_begin_klu/get_end_klu
- get_begin_val/get_end_val


### CZSList-中枢管理类
- zs_lst: List[CZS] 中枢列表


#### CZS：中枢类
成员包括：
- begin/end：起止K线CKLine_Unit
- begin_bi/end_bi：中枢内部的第一笔/最后一笔
- bi_in：进中枢的那一笔（在中枢外面）
- bi_out：出中枢的那一笔（在中枢外面，不一定存在）
- low/high：中枢的高低点
- peak_low/peak/high：中枢内所有笔的最高/最低值
- bi_lst：中枢内笔列表
- sub_zs_lst：子中枢（如果出现过中枢合并的话）


### CBSPointList-买卖点管理类
- lst：List[CBS_Point] 所有的买卖点


#### CBS_Point：买卖点类
成员包括：
- bi：所属的笔（买卖点一定在某一笔末尾）
- Klu：所在K线
- is_buy：True为买点，False为卖点
- type：List[BSP_TYPE] 买卖点类别，是个数组，比如2，3类买卖点是同一个


## 数据接入速成班
### CCommonStockApi子类实现
参考`DataAPI/BaoStockAPI.py`，实现一个类继承自`CCommonStockApi`，接受输入参数为：
- code
- k_type: KL_TYPE类型
- begin_date/end_date：能不能为None，应该是什么格式自行决定，会通过CChan类的初始化参数传进来；

并在该类里面实现一个关键方法：

`get_kl_data(self)`：该方法为一个生成器，yield 返回每一根K线信息 `CKLine_Unit`，K线类可以通过`CKLine_Unit(item_dict)`来实例化；

| 当然你也可以直接返回一个有序的数组，每个元素为`CKLine_Unit`，只不过性能可能会差一些；

```python
class C_YOUR_OWN_DATA_CLS(CCommonStockApi):
    def __init__(self, code, k_type=KL_TYPE.K_DAY, begin_date=None, end_date=None, autype=AUTYPE.QFQ):
        super(C_YOUR_OWN_DATA_CLS, self).__init__(code, k_type, begin_date, end_date, autype)

    def get_kl_data(self) -> Iterable[CKLine_Unit]:
       ...
       yield CKLine_Unit(item_dict)
```

item_dict为一个字典：
- 包含时间：必须是框架实现的CTime类
- 开收高低：必须要有
- 换手率，成交额，成交量：这三个可以没有

```python
{
    DATA_FIELD.FIELD_TIME: time,  # 必须是CTime
    DATA_FIELD.FIELD_OPEN: float(_open),  # 必填
    DATA_FIELD.FIELD_CLOSE: float(_close),  # 必填
    DATA_FIELD.FIELD_LOW: float(_low),  # 必填
    DATA_FIELD.FIELD_HIGH: float(_high),  # 必填
    DATA_FIELD.FIELD_VOLUME: float(volume),  # 可选
    DATA_FIELD.FIELD_TURNOVER: float(amount),  # 可选
    DATA_FIELD.FIELD_TURNRATE: float(turn),  # 可选
}
```

### CTime
构造`CTime(year, month, day, hour, minute)`实例即可；


### 初始化和结束
如果数据来源于其他服务，需要有初始化和结束的操作，那么需要额外重载实现两个类函数：
```python
  @classmethod
  def do_init(cls):
      ...

  @classmethod
  def do_close(cls):
      ...
```

比如baostock即需要实现login,logout操作，futu数据源需要初始化和关闭ctx操作；


### 接入数据源
最简单的方法就是把实现的类放在`./DataAPI/`目录下，然后`CChan`的`data_src`参数配置为`custom:文件名.类名`即可；


## 线段
框架默认提供的线段画法是基于特征序列那一套的，如果不了解，请搜索引擎搜索：“缠论 线段 特征序列”；

首先需要说明的是，线段这部分为整个框架代码里面最复杂，最绕，最难以维护的部分（主要是本人的锅，开发能力不够），如果不是作为挑战，或者有重要特性需要实现，没啥事不要尝试去挑战阅读。。

关于划段算法，简单来说，就是上线线段里面的下降笔（或者下降线段里面的上升笔）当做K线（也叫特征序列），进行合并后找顶底分析，主要区分两种情况（以上升线段为例）：
- 特征序列形成的顶分型第一二元素之间有跳空，那么需要在后面找到反向**且合法**的特征序列底分型，这个上升线段才会被判断为确认（即框架里面CSeg的is_sure=True，或者说画图为实线）；
- 如果没有跳空，那么顶分型出现时即被判断为确认。

当然，里面还有更多的细节，这里不展开赘述。

当然，开源代码里面也提供了一些其他的线段的实现算法（参见 SegListDYH.py, SegListDef.py 等），大家也可以自行开发；

### 虚段
线段的确定时刻实际上是具有很强的滞后性的，所以框架在计算“当前帧”的缠论元素的时候，会产生一些推断的线段（即框架里面CSeg的is_sure=False，或者说画图为虚线），这些虚段在后面新增K线产生的过程中，可能随时有可能会变化。

虚段可能出现在线段的开头和结尾，主要是框架认为当下的K线信息不足以确定一些线段，或者说特征序列的顶底分型尚未完成；

开头的虚段参考意义不大，但是建议大家如果给出的K线算出来的所有线段都是虚的，那么不要进行任何回测或者在上面交易，至少在出现一条实段后在进行策略分析。

## 中枢

## 策略实现 & 回测
具体demo参见[strategy_demo.py](./Debug/strategy_demo.py)

原理就是：打开CChanConfig中的`trigger_step`开关，那么CChan初始化的时候就不会做任何计算；

而手动调用CChan.step_load()，才会启动计算；
- 多少根K线就返回多少次
- 这个函数就是一个生成器：每喂一根K线后，就会计算当前K线位置的静态元素，返回当前的CChan类，可以用上文描述的方法来获取需要的元素；
- 每一帧的计算不是完全重算的，只重新计算不确定的部分，故计算性能还行

回测啥的就自行组装了~


### 从外部喂K线
实盘的时候需要在获取到K线之后触发缠论计算，可以使用`CChan.trigger_load`来触发计算；

其中该函数的输入参数格式为：`Dict[KL_TYPE, List[CKLine_Unit]]`

具体使用case可以参考[strategy_demo.py](./Debug/strategy_demo2.py)


### 更新小级别触发大级别重算
这种场景一般是：
- 实盘中使用了1分钟，5分钟两个级别来构建策略
- 每过一分钟，当前5分钟的K线由于数据源并没提供，是由1分钟K线合成的
  - 或者也有可能券商接口提供了当前5分钟的K线，但是由于没有完成，下一分钟这5分钟的K线可能会有变化
- 把这两个级别的K线用CChan.trigger_load()喂进去

问题是当你把当前的5分钟K线喂进去后，下一分钟框架无法回退掉/更新这个5分钟K线，而这个5分钟K线可能相较于前一分钟时所得是有变化的；

解决方法：参考[strategy_demo.py](./Debug/strategy_demo3.py)
原理是：
- 当某一个时刻所有级别的K线都在将来不需要变化时（比如每5分钟结束时），把当前CChan保存下来（不管是用深度拷贝保存成一个临时的变量或者序列化到本地文件）成一个快照
- 之后每根最小级别K线产生时，均重新加载这个快照重新计算当前的所有级别


## 开源版本指标添加
以实现RSI指标为例，只需要三步：

首先你需要实现一个计算类（见Math/RSI.py）：
- 类可以接收指标计算的参数（如周期等）
- 类对外提供一个方法：
  - 接收需要的K线信息（不要直接接收CKLine_Unit，不然后续可能会有循环引用问题）
  - 返回指标值，或者包含所有指标结果的一个类（比如MACD类需要返回快线慢线，红绿柱等信息）
  - tips：
    - 出于性能考虑，指标的计算尽量优化成增量计算，而不是当前K线的指标需要用前面所有K线的数据来算
    - 也就是新的一根K线+部分之前K线计算的中间结果，就可以算出当前K线的指标
    - 本框架所有开源指标均遵循此原则
    - 当然你自己开发的不在意计算效率的话，倒无所谓。。


然后在`CChanConfig`的GetMetricModel方法修改res变量的注解（增加你的指标类），然后append一个上面实现的指标计算实例(可以参考rsi实现方法在)CChanConfig里面配置指标计算的参数；
```python
    def GetMetricModel(self):
        res: List[CMACD | CTrendModel | BollModel | CDemarkEngine | RSI] = []
        # 其他已有指标
        # balabala....
        res.append(RSI(self.rsi_cycle))
        return res

```

最后在`CKLine_Unit`的set_metric方法最后增加一行，调用你实现的指标类的计算方法：
```python
    def set_metric(self, metric_model_lst: list) -> None:
        for metric_model in metric_model_lst:
            # balabala...
            elif isinstance(metric_model, RSI):
                self.rsi = metric_model.add(self.close)
```

至此，你就可以通过CKLine_Unit.rsi取得你的指标，参与后续计算了；

### 指标画图
如果你想你的指标支持绘制，PlotDriver.py的DrawElement方法增加一行：
```python
def DrawElement(self, plot_config: Dict[str, bool], meta: CChanPlotMeta, ax: Axes, lv, plot_para, ax_macd: Optional[Axes], x_limits):
    # balabala...
    if plot_config.get("plot_rsi", False):
        self.draw_rsi(meta, ax.twinx(), **plot_para.get('rsi', {}))
```

然后实现draw_rsi方法即可：
```python
def draw_rsi(self, meta: CChanPlotMeta, ax, color='b'):
    data = [klu.rsi for klu in meta.klu_iter()]
    x_begin, x_end = int(ax.get_xlim()[0]), int(ax.get_xlim()[1])
    ax.plot(range(x_begin, x_end), data[x_begin: x_end], c=color)
```


## 机器学习接入
缠论有个好处在于，基础元素的定义大多非常精确，包括买卖点，很容易用程序化语言来实现；

带来的好处就是，策略可以接入机器学习，让机器学习来判断当下状态，框架也可以较方便的接入这些能力；

机器学习相关演示参见项目`machinelearning`分支[strategy_demo5.py](./Debug/strategy_demo5.py)，里面演示了包括：
- 如何在bsp各个地方增加特征计算
- 如何在bsp里面增加通用特征
- 策略如何与bsp特征联动
  - 如何在策略生效时新增策略特征
- 如何绘图分析label是否正确
- 如何训练 & 预测

### 机器学习分支和主分支区别
机器学习分支仅仅在主分支基础上，在 CChan 内部增加了一些特征计算演示的 demo，和机器学习特有的一些 demo策略。

主分支的所有特性都会合并进机器学习分支，只是额外的特征计算会消耗计算性能，考虑到不是所有人都需要机器学习特征计算，所以专门开了个分支；

不介意性能的话，无脑用机器学习分支亦可。


## 一致性
上面提到框架支持两种计算模式：
- 直接给定一批K线，计算出所有缠论元素
- 在已有（可以为空）K线基础上，逐根K线投喂更新得到“当下为止”的缠论元素

两种方法实现上略有区别，前者计算速度快于后者；

但是可以保证（或者说目标是要保证）：如果给定同样范围的K线，那么两种模式最终计算状态应该是完全一致的！（如果不一致，说明有bug，联系作者排查）

### 如何防止未来信息
如果你使用`CChan.trigger_load`来触发计算，那么每次触发后框架只拿到当前位置的 K 线数据来进行计算缠论元素，你只要在下一次trigger_load之前完成策略的判断，那么你的策略模型在没有 Bug 的情况下，是拿不到未来信息的。

## 二十九、多模式综合对比与选型指南

### 29.1 四大模式维度总览

`a_replay_trainer.py` 的运行时行为由 **4 个独立维度** 共同决定：

| 维度 | 参数名 | 可选值 | 默认值 | 归一化函数 |
|------|--------|--------|--------|-----------|
| 图表模式 | `chart_mode` | `single` / `dual` / `multi` | `single` | `normalize_replay_chart_mode()` |
| 数据形态 | `data_form_mode` | `traditional` / `quantity` / `tick_traditional` / `tick_quantity` | `traditional` | `normalize_data_form_mode()` |
| 数据喂入 | `data_feed_mode` | `step` / `unified` | `step` | `normalize_data_feed_mode()` |
| 买卖点判定 | `judge_mode` | `auto` / `manual` | `auto` | 前端 Z/S 键切换 |

### 29.2 各模式对前端 UI 的影响

| UI 元素 | single | dual | multi | unified 喂入 |
|----------|--------|------|-------|-------------|
| 图表数量 | 1 张 | 2 张（上下） | 1 张（叠加） | 同 chart_mode |
| 图切换按钮 (Tab) | 无 | 有 | 无 | 同 chart_mode |
| 步进按钮 (Space) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 连续步进 (Ctrl+Alt+N) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 回退按钮 (Shift+Space) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 买入按钮 (PageUp) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 卖出按钮 (PageDown) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 做空/平空按钮 | ✅ | ✅ | ✅ | ❌ 灰色 |
| 判定按钮 (J) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 自动/手动切换 (Z/S) | ✅ | ✅ | ✅ | ❌ 灰色 |
| 筹码分布面板 | ✅ | ✅（两图独立） | ✅（驱动周期） | ✅ |
| 节奏线显示 | ✅ | ✅（激活图） | ✅（驱动周期） | ✅ |
| 多周期图例 | 无 | 无 | 有 | 同 chart_mode |

### 29.3 各模式对后端行为的影响

| 后端行为 | single | dual | multi | unified |
|----------|--------|------|-------|---------|
| CChan 实例数 | 1 | 2 | 2~5 | 同 chart_mode |
| step_load() 调用 | ✅ | ✅（驱动图） | ✅（驱动周期） | ❌ |
| trigger_load() 调用 | ❌ | ❌ | ❌ | ✅ |
| 双/多周期同步 | 无 | `_sync_stepper_to_anchor()` | 同 dual × N | 跳过 |
| 防未来数据修正 | 无 | `_dual_rebuild_coarse_chan_anti_future()` | 同 dual × N | 跳过 |
| 回退缓存快照 | 基础 | + stepper2 | + multi_steppers[] | 不适用 |
| 买卖点判定 | ✅ | ✅（激活图） | ✅（驱动周期） | ❌ |
| 节奏系统 | ✅ | ✅（激活图） | ✅（驱动周期） | ✅ |
| 筹码计算 | ✅ | ✅（两图独立） | ✅（驱动周期） | ✅ |

### 29.4 各模式对会话缓存 (session_key) 的影响

会话缓存 key 由以下字段组成，变化即触发重新拉取数据：

```python
session_key = (code, begin_date, end_date, autype, chan_cfg_hash,
               k_type, data_form_mode, data_form_quantity)
```

| 参数变更 | 是否重建会话 | 说明 |
|----------|------------|------|
| 改 `chart_mode` | ✅ 是 | 不同模式需要不同 stepper 结构 |
| 改 `data_form_mode` | ✅ 是 | 影响 K 线生成方式 |
| 改 `data_feed_mode` | ❌ 否 | 仅影响喂入方式，不重建会话 |
| 改 `judge_mode` | ❌ 否 | 仅影响判定触发时机 |
| 改 `k_types_multi` | ✅ 是 | 周期列表变化 |
| 仅改 chan_config (reconfig) | ❌ 否 | 只重建 Chan 对象，不重拉数据 |

### 29.5 典型场景选型指南

| 使用场景 | 推荐 chart_mode | 推荐 data_form_mode | 推荐 data_feed_mode | 推荐 judge_mode |
|----------|----------------|--------------------|--------------------|-----------------|
| 标准复盘训练 | `single` | `traditional` | `step` | `auto` |
| 快速浏览缠论结构 | `single` | `traditional` | `unified` | 不适用 |
| 日线+30分钟联动分析 | `dual` | `traditional` | `step` | `auto` |
| 多周期共振分析 | `multi` | `traditional` | `step` | `auto` |
| 长期趋势压缩复盘 | `single` | `quantity`（Q=50） | `step` | `auto` |
| 高精度筹码复盘 | `single` | `tick_traditional` | `step` | `auto` |
| 精细手动判定 | `single` | `traditional` | `step` | `manual` |
| 指标+买卖点回测 | `single`/`dual` | `traditional` | `step` | 不适用（独立回测） |

### 29.6 模式组合的互斥与限制

| 限制规则 | 说明 |
|----------|------|
| unified ⊗ 模拟交易 | unified 模式下所有交易 API 返回 400 |
| unified ⊗ 买卖点判定 | unified 模式下无步进过程，无法触发判定 |
| unified ⊗ 回退操作 | unified 模式下 back_n / goto_step 不可用 |
| tick_* ⊗ 无离线数据 | tick_traditional / tick_quantity 必须有分笔文件 |
| multi ⊗ 周期数 < 2 | k_types_multi 至少 2 个周期 |
| multi ⊗ 周期数 > 5 | 超过 MULTI_CHART_MAX_LAYERS 报错 |
| quantity ⊗ Q > N | Q 不能超过原始 K 线总数 |
| dual/multi ⊗ unified | 双/多周期在 unified 下跳过同步和防泄漏（仅全量展示） |

---

## 尚未实现（完整版 vs 开源版差异）
> 以下内容来源于 README.md（完整版），当前开源版**尚未实现**，仅供参考完整版功能规划。
---
### 一、策略买卖点开发（CustomBuySellPoint/）
| 功能 | 说明 |
|------|------|
| 自定义动力学买卖点 (cbsp) | 用户编写策略，在每根新K线出现时判断当下是否是新的买卖点 |
| 背驰算法配置 | 支持配置不同的背驰判断算法 |
| 区间套买卖点计算 | 多级别联立，区间套精确定位买卖点 |
| 策略基类 Strategy.py | 通用抽象策略父类，供自定义策略继承 |
| Demo 策略 | CustomStrategy.py、SegBspStrategy.py 等示例策略 |
| 试题生成策略 ExamStrategy.py | 自动生成买卖点判断试题 |
### 二、机器学习框架（ModelStrategy/ + ChanModel/）
| 功能 | 说明 |
|------|------|
| 500+ 特征计算 | FeatureDesc.py 特征注册，Features.py 完整特征计算（当前仅有基础 demo） |
| XGBoost 模型 | XGBModel.py + XGBTrainModelGenerator.py |
| LightGBM 模型 | LGBMModelGenerator.py |
| MLP 深度学习模型 | MLPModelGenerator.py |
| 模型基类 CommModel.py | 通用模型抽象父类，定义训练/预测/读写接口 |
| 回测框架 | acktest.py + BacktestChanConfig.py，支持策略回测与评估 |
| AutoML 超参搜索 | para_automl.py，自动搜索模型最优超参数 |
| 特征离线/在线一致性校验 | FeatureReconciliation.py，确保线上线下特征计算一致 |
| 策略参数评估 | eval_strategy.py + multi_cycle_test.py，多周期策略收益评估 |
### 三、交易引擎（Trade/）
| 功能 | 说明 |
|------|------|
| Futu 交易引擎 | FutuTradeEngine.py，对接富途模拟盘 & 实盘 |
| 交易引擎核心 | TradeEngine.py，开仓/平仓/止损/止盈逻辑 |
| MySQL 数据库 | MysqlDB.py，缠论专用数据库 API |
| SQLite 数据库 | SqliteDB.py，轻量级本地数据库 |
| 仓位管理 | OpenQuotaGen.py，开仓交易手数策略 |
| 实时股价跟踪 | RealTimeTracker.py，实时监控止损/止盈点 |
| 信号计算调度 | SignalMonitor.py，定时计算交易信号 |
| 峰值股价更新 | UpdatePeakPrice.py，用于动态止损 |
| 开仓/平仓脚本 | MakeOpenTrade.py、ClosePreErrorOpen.py 等 |
### 四、实时数据接口（DataAPI/SnapshotAPI/）
| 功能 | 说明 |
|------|------|
| 实时股价快照 | StockSnapshotAPI.py 统一调用接口 |
| AKShare 实时 | AkShareSnapshot.py，支持A股/ETF/港股/美股 |
| Futu 实时 | FutuSnapshot.py，支持A股/港股/美股 |
| Pytdx 实时 | PytdxSnapshot.py，支持A股/ETF |
| 新浪财经实时 | SinaSnapshot.py，支持A股/ETF/港股/美股 |
### 五、离线数据管理（OfflineData/）
| 功能 | 说明 |
|------|------|
| A股全量下载 | ao_download.py，baostock 下载全量A股数据 |
| A股增量更新 | ao_update.py，增量更新离线数据 |
| 港股/美股/A股更新 | k_update.py，akshare 更新离线数据 |
| ETF 数据下载 | etf_download.py |
| Futu 港股更新 | utu_download.py |
| 股票市值分位数 | query_marketvalue.py，计算股票市值分布 |
| 股票指标分布 | CalTradeInfo.py，计算换手率/成交量等指标分位数 |
### 六、配置与工具
| 功能 | 说明 |
|------|------|
| YAML 配置文件 | Config/demo_config.yaml + EnvConfig.py，统一配置管理 |
| COS 文件上传 | Plot/CosApi/，支持 MinIO / 腾讯云 COS 上传 |
| 消息推送 | Common/send_msg_cmd.py，支持 Gotify 等消息通道 |
| 试题生成 API | ExamGenerator.py，自动生成买卖点判断试题及批改 |
| 性能分析 | Debug/cprofile_analysis/，cProfile 性能分析脚本 |
| Jupyter Notebook | Debug/Notebook/，各种分析 Notebook |
| 股票市值过滤 | DataAPI/MarketValueFilter.py，按市值过滤股票池 |
| ETF 数据接口 | DataAPI/ETFStockAPI.py |
| Futu 数据接口 | DataAPI/FutuAPI.py |
| 离线数据读取 | DataAPI/OfflineDataAPI.py |
---
> **说明**：以上功能均来自 README.md 描述的完整版（约 22000 行代码），当前开源版（约 5300 行）仅包含基础缠论元素计算 + 画图 + 数据接入 + replay_trainer 回放训练。如需上述功能，可自行基于基座开发或联系作者。
## 打赏
如果你觉得这个项目对你有帮助或有启发，可以请我喝一杯。。额。。咖啡和牛奶以外的东西，毕竟我喝这两种会拉肚子。。

<img src="./Image/coffee.jpeg" width="300"/>
