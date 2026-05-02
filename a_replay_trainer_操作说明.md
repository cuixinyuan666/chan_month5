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

### 全局快捷键

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `Ctrl+I` | 加载会话 | 根据当前代码、日期和资金初始化 |
| `Ctrl+R` | 重新训练 | 清空当前会话并重置 |
| `Space` | 步进到下一根K线 | 若当前K线命中买卖点会弹窗提示 |
| `Ctrl+Alt+N` | 连续步进N根 | 遇到买卖点自动停止 |
| `Ctrl+Alt+M` | 后退N根 | 自动重建到更早状态 |
| `PageUp` | 买入（全仓） | 以当前价格全仓买入 |
| `PageDown` | 卖出（全量） | 以当前价格全部卖出 |
| `C` | 居中到最新K线 | 视图快速定位 |
| `Ctrl+Enter` | 生成水平射线 | 在十字光标价位生成射线 |
| `Ctrl+Alt+↑/↓` | 纵向缩放 | 放大/缩小图表纵轴 |
| `Ctrl+Alt+←/→` | 横向缩放 | 放大/缩小图表横轴 |
| `Ctrl+↑/↓` | 十字光标微调 | 上下微调光标价格 |
| `L` | 打开缠论配置面板 | 调整笔/段/中枢等算法参数 |
| `P` | 打开图表显示设置 | 调整样式、指标、显示项 |
| `Shift+P` | 打开系统配置 | 维护快捷键配置 |
| `F11` | 全屏切换 | 图表区域全屏显示 |
| `Z` | 切换为自动判定模式 | 买卖点自动判定 |
| `S` | 切换为手动判定模式 | 买卖点需手动检查 |
| `J` | 手动检查买卖点 | 仅手动模式下可用 |

### 快捷键自定义

在【系统配置】面板中可修改每个快捷键，按 `S` 保存后生效。

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
