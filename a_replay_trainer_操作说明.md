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

## 二、环境依赖

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

1. **顶部工具栏**：缠论配置、图表显示设置、系统配置、全屏按钮
2. **会话控制区**：加载会话、重新训练、结束训练、退出
3. **步进控制区**：下一根K线、步进N根、后退N根
4. **交易区**：买入（全仓）、卖出（全量）
5. **账户信息**：当前持仓、现金、盈亏等
6. **数据源状态**：当前使用的数据源标签与日志

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
| `Ctrl+Alt+N` | 连续步进N根 | 按"步进数量 N"设置值连续推进，**遇到买卖点自动停止** |
| `Ctrl+Alt+M` | 后退N根 | 按设置值回退，**自动重建缠论结构**到更早状态 |
| `C` / `center` | 居中到最新K线 | 视图快速定位到最新位置 |

#### 交易操作

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `PageUp` | 买入（全仓） | 以当前收盘价用全部可用现金买入（按手，每手100股） |
| `PageDown` | 卖出（全量） | 以当前价格全部卖出；T+1约束下当天买入的不可卖 |

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

## 十二、核心类说明

### 12.1 ChanStepper

步进器，负责K线迭代与缠论计算：

| 属性 | 说明 |
|------|------|
| `chan` | 当前缠论对象 `CChan` |
| `step_idx` | 当前步进索引 |
| `code` | 股票代码 |
| `k_type` | K线周期类型 |
| `kline_all` | 全历史K线列表 |
| `indicators` | 指标引擎（MACD/KDJ/RSI/BOLL/Demark） |

### 12.2 PaperAccount

模拟账户：

| 属性 | 说明 |
|------|------|
| `initial_cash` | 初始资金 |
| `cash` | 当前现金 |
| `position` | 持仓股数 |
| `avg_cost` | 平均成本 |

**交易规则：**
- 单持仓：同时只能持有一只股票
- T+1：当天买入的股票当天不能卖出
- 每步最多一笔：每个步进索引最多发生一次买卖成交

### 12.3 AppState

全局会话状态，管理双周期图表、交易事件、买卖点历史、节奏提示等。

---

## 十三、API 接口列表

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
| `data_form_mode` | string | 否 | 数据形态模式：`traditional` 或 `quantity` |
| `data_form_quantity` | int | 否 | 聚合数量 |

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

---

### 13.3 步进

**POST** `/api/step`

向前推进一根K线，更新缠论结构。

**请求体 (StepReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `judge_mode` | string | 否 | 判定模式：`auto`（默认）或 `manual` |
| `active_chart_id` | string | 否 | 激活图表 ID |

---

### 10.4 买卖点判定

**POST** `/api/judge_bsp`

对当前缠论结构执行买卖点判定。

**请求体 (JudgeBspReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `reason` | string | 否 | 判定原因描述，默认 `manual_check` |

---

### 13.5 买入

**POST** `/api/buy`

以当前价格全仓买入（按手买入，每手100股）。

---

### 13.6 卖出

**POST** `/api/sell`

以当前价格全部持仓卖出。

---

### 10.7 后退N步

**POST** `/api/back_n`

回退指定步数并重建缠论结构。

**请求体 (BackNReq)：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `n` | int | 是 | 步数，必须 >= 1 |

---

### 13.8 获取状态

**GET** `/api/state`

获取当前会话的完整状态 payload。

---

### 10.9 结束会话

**POST** `/api/finish`

标记训练结束，但保持数据可用。

---

### 13.10 设置数据源优先级

**POST** `/api/set_data_source_priority`

**请求体：**

```json
{
  "priority": ["AKShare", "BaoStock", "离线数据"]
}
```

---

### 13.11 检测数据源

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

### 13.12 重置会话

**POST** `/api/reset`

重置所有状态，清空账户、历史记录等。

---

### 10.13 退出服务

**POST** `/api/exit`

关闭服务器进程。

---

## 十四、周期类型 (KL_TYPE)

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

## 十五、数据形态模式

| 模式 | 说明 |
|------|------|
| `traditional` | 传统模式，按时间顺序 |
| `quantity` | 按数量Q聚合K线，前面等分，余数归入最后一组 |

---

## 十六、离线数据支持

本服务器支持从 `a_Data` 目录读取离线数据：

- **分笔数据优先**：优先使用 TickData 目录下的分笔数据
- **1分钟合成**：无分笔时使用 1 分钟K线数据合成高周期
- **自动探测**：init 时自动检测离线包是否存在

---

## 十七、使用流程示例

1. **启动服务**：`python replay_trainer.py`
2. **打开前端**：浏览器访问 `http://127.0.0.1:8000/`
3. **配置会话**：输入股票代码、日期范围、初始资金
4. **加载会话**：按 `Ctrl+I` 或点击【加载会话】
5. **步进回放**：按 `Space` 逐步回放K线
6. **调整配置**：按 `L` 打开缠论配置，按 `P` 打开图表设置
7. **买卖点判定**：
   - 自动模式：步进时自动判定（默认）
   - 手动模式：按 `S` 切换为手动，按 `J` 检查买卖点
8. **模拟交易**：按 `PageUp` 买入，`PageDown` 卖出
9. **连续步进**：按 `Ctrl+Alt+N` 连续步进N根
10. **后退回放**：按 `Ctrl+Alt+M` 回退N根
11. **结束训练**：点击【结束训练】
12. **重置会话**：按 `Ctrl+R` 开始新股票

---

## 十八、双周期模式

在【会话配置】中设置 `chart_mode` 为 `dual` 可开启双周期模式：

- 两个图表（chart1 / chart2）可显示不同周期的K线
- 快捷键 `Tab` 可切换激活的图表
- 步进时两个图表同步推进
- 可分别调整每个图表的显示配置

---

## 十九、ReplayChan 特殊说明

`ReplayChan` 是 `CChan` 的子类，专门用于回放场景：

- 构造函数接收 `replay_klus_master` 参数，传入内存缓存的K线单元列表
- `load()` 方法从内存快照 deepcopy 后喂给迭代器，避免重复请求行情
- 数据层与配置层解耦，笔/线段/中枢/买卖点随 ChanConfig 重新计算

## 二十、新缠论模式 (CHAN_ALGO_NEW) 买卖点显示说明

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

## 二十一、数量模式 (data_form_mode = "quantity") 逻辑说明

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

## 二十二、离线数据使用规则

### 22.1 概述

离线数据是内置的本地数据源，存储在 `a_Data/` 目录下（与 `replay_trainer.py` 同级）。当所有在线数据源均不可用时，系统可自动回退到离线数据。

**核心设计原则：分笔优先，1分钟兜底。**

### 22.2 目录结构

```
a_Data/
├── SH#600340/              # 上交所股票
│   ├── TickData/           # 分笔成交数据（优先级最高）
│   │   ├── 20240101_600340.txt   # 格式: YYYYMMDD_代码.txt
│   │   ├── 20240102_600340.txt
│   │   └── ...
│   └── KLine/
│       └── 1MINUTE/
│           └── SH#600340.txt      # 1分钟K线数据（分笔不存在时使用）
├── SZ#001312/              # 深交所股票
│   ├── TickData/
│   └── KLine/
│       └── 1MINUTE/
│           └── SZ#001312.txt
└── ...
```

**文件夹命名规则** ([offline_folder_from_code](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L368-L378))：

| 输入代码 | 文件夹名 | 规则 |
|---------|---------|------|
| `sh.600340` | `SH#600340` | 取前缀 `sh.` → `SH#` + 后6位 |
| `sz.001312` | `SZ#001312` | 取前缀 `sz.` → `SZ#` + 后6位 |
| `600340` | `SH#600340` | 纯数字6位，以6开头归上交所 |
| `001312` | `SZ#001312` | 纯数字6位，非6开头归深交所 |

### 22.3 数据源优先级中的位置

离线数据在默认优先级链中排第 **7 位**：

```
AKShare > AKShare-腾讯历史 > Ashare > AData > pytdx > BaoStock > **离线数据** > Tushare > 新浪 > 腾讯 > 雅虎 > 东方财富 > GitHub-CSV
```

用户可通过【系统配置】面板调整优先级，将"离线数据"提前或置后。

### 22.4 数据获取流程（COfflineInline 类）

位于 [replay_trainer.py 第1858行](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1858-L1920)：

```
用户请求任意周期K线（如日线）
    ↓
① 检查 TickData/ 目录下是否有日期范围内的分笔文件
    ↓ 有分笔文件？
   ├─ 是 → 加载分笔数据 → 合成1分钟K线 → 合成目标周期K线 ✅
   └─ 否 ↓
② 检查 KLine/1MINUTE/ 下是否有1分钟K线文件
    ↓ 存在且 > 80字节？
   ├─ 是 → 加载1分钟K线 → 合成目标周期K线 ✅
   └─ 否 → 抛出 ValueError（未找到离线基础数据）❌
```

**关键点**：无论用户请求什么周期（日线、周线、5分钟等），离线数据始终从 **分笔或1分钟** 基础数据出发向上合成。

### 22.5 周期合成规则

[_offline_rows_to_ktype()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1829-L1855) 实现了完整的周期合成链：

| 目标周期 | 合成路径 | 说明 |
|---------|---------|------|
| 1分钟 | 直接使用原始1分钟数据 | 无需合成 |
| 3分钟 | 1分钟按3根分组合并 | OHLCV 聚合 |
| 5分钟 | 1分钟按5根分组合并 | - |
| 15分钟 | 1分钟按15根分组合并 | - |
| 30分钟 | 1分钟按30根分组合并 | - |
| 60分钟 | 1分钟按60根分组合并 | - |
| 日线 | 1分钟按自然日聚合 | 取当日首根open、末根close、全日high/low |
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

**文件命名**：`TickData/YYYYMMDD_代码.txt`（如 `20240101_600340.txt`）

**文件内容**：每行一条成交记录，由 [_offline_load_ticks()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1671-L1695) 解析，包含时间、价格、成交量三列。

分笔数据会被先合成为1分钟K线（[_offline_ticks_to_1m](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1698-L1716)），再进入后续周期合成流程。

### 22.7 1分钟K线数据格式

**文件路径**：`KLine/1MINUTE/{文件夹名}.txt`

**文件内容**：每行一根1分钟K线，由 [_offline_load_1m_rows()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L1613-L1651) 解析，包含以下字段（空格/制表符分隔）：

| 列 | 字段 | 说明 |
|----|------|------|
| 1 | 时间 | 格式 `YYYY/MM/DD HH:MM`（如 `2024/01/01 09:31`） |
| 2 | 开盘价 | 浮点数 |
| 3 | 最高价 | 浮点数 |
| 4 | 最低价 | 浮点数 |
| 5 | 收盘价 | 浮点数 |
| 6 | 成交量 | 浮点数 |
| 7 | 成交额 | 浮点数 |

**文件大小要求**：必须 > 80 字节才被视为有效数据。

### 22.8 自动探测机制

在会话初始化（`/api/init`）之前，系统会调用 [offline_bundle_exists()](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L390-L407) 探测离线包是否可用：

```
探测逻辑：
1. 检查 a_Data/{文件夹}/ 是否存在目录
2. 检查 TickData/ 下是否有日期范围内（begin_date ~ end_date）的分笔文件
3. 若无分笔，检查 KLine/1MINUTE/ 下是否有1分钟K线文件且大小 > 80字节
4. 任一条件满足 → 返回 True（离线包可用）
```

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
3. 存在分笔文件 **或** 1分钟K线文件

**写入逻辑**：
- **有分笔数据**：按分笔的 (价格, 成交量) 直加汇总到对应K线的分桶中
- **仅有1分钟数据**：用每根1分钟的收盘价 × 成交量作为近似筹码
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

## 二十三、单品种双周期操作规则

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

## 二十四、筹码分布设计逻辑

### 24.1 概述

筹码分布（Chip Distribution）是 `replay_trainer.py` 中用于展示**历史成交量在价格维度上的累积分布**的可视化功能。它回答的核心问题是：**"从上市至今（或某个参考日期），每个价格区间累计成交了多少量？"**

### 24.2 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    筹码分布数据流                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  数据源层                                                    │
│  ├─ 离线分笔数据 (TickData/*.txt) ──┐                        │
│  │   格式: 时间 价格 成交量           │                        │
│  └─ 离线1分钟K线 (KLine/1MINUTE/) ──┤                        │
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

### 24.3 底层数据来源（两条路径）

#### 路径 A：离线分笔数据（最高精度）— 优先

**文件位置**：`a_Data/{股票代码}/TickData/{日期}_{代码}.txt`

**文件格式**（每行一条 Tick）：
```
时间          价格       成交量
09:25:00      12.35      1000
09:30:01      12.36      500
...
```

**处理流程** ([_enrich_kline_all_offline_chip_non_triangle](file:///c:\Users/Administrator/Desktop/my_file1/my_file/3/chan.py/replay_trainer.py#L516-L578))：

```
1. 扫描 a_Data/{code}/TickData/ 目录下所有匹配 {YYYYMMDD}_{code}.txt 的文件
2. 逐行读取 (时间, 价格, 成交量) 元组
3. 按 _offline_chip_bar_bucket_key() 将 tick 归入对应 K 线周期的桶
   例: 日线桶 = (年, 月, 日), 5分钟桶 = (年, 月, 日, 时, 分//5)
4. 对每个桶内的所有 tick:
   - 按 _fold_price_vols() 将价格四舍五入到 4 位小数后按价合并成交量
   - 结果: p=[10.01, 10.02, ...], w=[15000, 23000, ...]
5. 写入对应 kline_all 条目的 chip_tick_bins 字段
```

#### 路径 B：离线1分钟K线（兜底）

**条件**：无分笔数据时，使用 `a_Data/{代码}/KLine/1MINUTE/{代码}.txt`

**处理方式**：用1分钟K线的**收盘价 × 成交量**作为该分钟的"点质量化"筹码。

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

对应代码 ([第552-557行](file:///c:\Users/Administrator/Desktop\my_file1/my_file/3/chan.py/replay_trainer.py#L552-L557))：

```python
# 无分笔时走1分钟兜底 → 点质量化
for r in rows_1m:
    key_to_rows[bk].append(
        (float(r["c"]), float(r["v"]))   # 收盘价(点) × 成交量(质量)
    )
```

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
    "w": [5000, 12000, 35000, 28000, 8000]
  }
}
```

- `p`（prices）：该根 K 线期间内出现过的**去重价格列表**（升序）
- `w`（weights）：对应价格的**累计成交量**
- 两者长度必须一致；为空或不合法则前端回退到三角分摊

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
    arr[priceIdx] += tb.w[j];                          // 直接累加成交量
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

## 二十五、数据源一致性规则

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

## 二十六、使用逻辑总结

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
│     规则：单持仓 / T+1 / 每步最多一笔                        │
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
| 筹码区空白 | chipEnabled=false 或 kline_all 为空 | 检查设置面板中筹码开关 |
| 筹码峰偏移严重 | 在线数据三角分摊精度不足 | 使用离线分笔数据提升精度 |
| 双周期图2无数据 | kType2 设置的周期该数据源不支持 | 换数据源或换周期 |
| reconfig 后结构不变 | chan_config 字段名错误被忽略 | 检查字段是否匹配 §7 定义的名称 |
| 409 离线确认弹窗 | 检测到离线数据但未确认 | 勾选确认或取消勾选离线优先级 |
