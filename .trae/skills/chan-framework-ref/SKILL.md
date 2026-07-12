---
name: "chan-framework-ref"
description: "缠论工程框架与既有功能速查。当新增数据源、修改缠论计算逻辑、或检查数据格式兼容性时必须调用，确保不自造缠论、数据格式正确、不重复造车轮。"
---

# 缠论工程框架与既有功能速查

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **新增数据源**（如接入新的行情 API、文件格式等）
2. **修改数据源逻辑**（如调整字段映射、时间格式解析等）
3. **新增或修改缠论计算逻辑**（Bi/笔、Seg/线段、ZS/中枢、BuySellPoint/买卖点）
4. **检查数据格式兼容性**（如用户问"能否接入 XX 数据源"）
5. **用户问"当前工程有哪些功能"** 或 "缠论框架是什么样的"

---

## 一、工程总览

本工程是一个**缠论量化复盘系统**，基于 Python，核心计算引擎与 UI/渲染解耦（便于未来移植 Android）。

### 工程目录结构

```
chan.py/
├── Chan.py                  # 缠论主引擎 CChan（数据加载、多级联动、步进驱动）
├── ChanConfig.py            # 全局配置（笔/线段/中枢/买卖点/指标参数）
├── a_replay_trainer.py      # 复盘训练器 UI（FastAPI + 前端，含全部 inline 数据源）
├── Bi/                      # 笔模块（Bi.py, BiConfig.py, BiList.py）
├── Seg/                     # 线段模块（Seg.py, Eigen.py, EigenFX.py, SegListChan.py 等）
├── ZS/                      # 中枢模块（ZS.py, ZSConfig.py, ZSList.py）
├── BuySellPoint/            # 买卖点模块（BS_Point.py, BSPointList.py, BSPointConfig.py）
├── KLine/                   # K线模块（KLine_Unit.py, KLine.py, KLine_List.py）
├── Combiner/                # K线合并模块（KLine_Combiner.py, Combine_Item.py）
├── Math/                    # 技术指标（MACD, BOLL, KDJ, RSI, Demark, TrendLine, TrendModel）
├── Common/                  # 公共模块（CEnum.py, CTime.py, ChanException.py, func_util.py, cache.py）
├── DataAPI/                 # 核心数据源接口（StockAPI 抽象 + akshare/baostock/ccxt/csv）
├── Plot/                    # 绘图模块（PlotDriver, PlotMeta, AnimatePlotDriver）
├── App/                     # 独立应用（ashare_bsp_scanner_gui.py）
├── ChanModel/               # 特征模型（Features.py）
└── a_Data/                  # 离线分笔数据目录（YYYYMMDD_六位代码.txt）
```

---

## 二、数据流总览

```
┌──────────────┐     ┌──────────────┐     ┌─────────────────────────────────────┐
│  数据源 API   │ ──→ │  CKLine_Unit │ ──→ │  CKLine_List (多级联动)              │
│ (CommonStockAPI)│    │  (单根K线)    │     │  ├─ CKLine (合并后K线)               │
│  get_kl_data() │     │              │     │  ├─ CBiList    → CBi (笔)           │
└──────────────┘     └──────────────┘     │  ├─ CSegList   → CSeg (线段)         │
                                           │  ├─ CZSList    → CZS (中枢)          │
                                           │  └─ CBSPointList → CBS_Point (买卖点) │
                                           └─────────────────────────────────────┘
```

**数据入口**：任何数据源**必须**实现 `CCommonStockApi` 抽象类，`get_kl_data()` 方法返回 `Iterator[CKLine_Unit]`。

---

## 三、数据源体系

### 3.1 抽象基类：`CCommonStockApi`

路径：[DataAPI/CommonStockAPI.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/DataAPI/CommonStockAPI.py)

```python
class CCommonStockApi:
    def __init__(self, code, k_type, begin_date, end_date, autype):
        self.code = code          # 股票代码
        self.k_type = k_type      # 周期（KL_TYPE枚举）
        self.begin_date = begin_date  # 开始日期
        self.end_date = end_date      # 结束日期
        self.autype = autype      # 复权类型（AUTYPE枚举）
        self.SetBasciInfo()       # 设置 is_stock, name 等

    @abc.abstractmethod
    def get_kl_data(self) -> Iterable[CKLine_Unit]:
        """返回 K 线迭代器，每根 K 线为 CKLine_Unit 对象"""
        pass
```

### 3.2 新增数据源的标准做法

**Step 1**：创建 `XXX_API` 类，继承 `CCommonStockApi`

**Step 2**：实现 `get_kl_data()`，每根 K 线构造为 `CKLine_Unit`，传入字典必须包含以下 5 个**必填字段**：

| 字段常量 | 含义 | 格式 |
|---------|------|------|
| `DATA_FIELD.FIELD_TIME` | 时间 | `CTime(year, month, day, hour, minute)` |
| `DATA_FIELD.FIELD_OPEN` | 开盘价 | `float` |
| `DATA_FIELD.FIELD_HIGH` | 最高价 | `float` |
| `DATA_FIELD.FIELD_LOW` | 最低价 | `float` |
| `DATA_FIELD.FIELD_CLOSE` | 收盘价 | `float` |

**可选字段**（`TRADE_INFO_LST`）：

| 字段常量 | 含义 |
|---------|------|
| `DATA_FIELD.FIELD_VOLUME` | 成交量 |
| `DATA_FIELD.FIELD_TURNOVER` | 成交额 |
| `DATA_FIELD.FIELD_TURNRATE` | 换手率 |

**示例**（最小可用数据源）：

```python
from DataAPI.CommonStockAPI import CCommonStockApi
from KLine.KLine_Unit import CKLine_Unit
from Common.CEnum import DATA_FIELD
from Common.CTime import CTime

class CMyAPI(CCommonStockApi):
    def SetBasciInfo(self):
        self.is_stock = True
        self.name = self.code

    def get_kl_data(self):
        # 假设从某处获取数据
        for row in my_data:
            item = {
                DATA_FIELD.FIELD_TIME: CTime(2024, 1, 2, 0, 0),
                DATA_FIELD.FIELD_OPEN: 10.0,
                DATA_FIELD.FIELD_HIGH: 10.5,
                DATA_FIELD.FIELD_LOW: 9.8,
                DATA_FIELD.FIELD_CLOSE: 10.2,
                DATA_FIELD.FIELD_VOLUME: 123456,
                DATA_FIELD.FIELD_TURNOVER: 12345678,
                DATA_FIELD.FIELD_TURNRATE: 1.5,
            }
            yield CKLine_Unit(item)

    @classmethod
    def do_init(cls): pass

    @classmethod
    def do_close(cls): pass
```

**Step 3（复盘 UI 接入）**：在 [a_replay_trainer.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/a_replay_trainer.py) 中：
1. 定义 `inline` 数据源常量（如 `MY_INLINE_SRC = "inline:myapi"`）
2. 将 API 类注册到 `_DATA_SOURCE_NAME_TO_PAIR` 字典
3. 在 `get_stock_api_cls()` 函数中添加分支
4. 在 `DATA_SOURCE_LABELS` 中添加显示名

### 3.3 既有数据源清单

#### 核心 DataAPI 层（可直接被 `CChan` 使用）

| 数据源 | 文件 | 来源 |
|--------|------|------|
| `CBaoStock` | [DataAPI/BaoStockAPI.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/DataAPI/BaoStockAPI.py) | BaoStock 免费行情 |
| `CAkshare` | [DataAPI/AkshareAPI.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/DataAPI/AkshareAPI.py) | AKShare 开源数据 |
| `CCXT` | [DataAPI/ccxt.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/DataAPI/ccxt.py) | 加密货币（Binance） |
| `CSV_API` | [DataAPI/csvAPI.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/DataAPI/csvAPI.py) | 本地 CSV 文件 |

#### 复盘 UI 内联数据源（`a_replay_trainer.py` 内）

| 数据源 | 类名 | 常量 |
|--------|------|------|
| AKShare | `CAkshareInline` | `AKSHARE_INLINE_SRC` |
| AKShare-腾讯历史 | `CAkTxInline` | `AKTX_INLINE_SRC` |
| GitHub-CSV | `CGitHubCsvInline` | `GITHUB_CSV_INLINE_SRC` |
| Ashare | `CAshareInline` | `"inline:ashare"` |
| AData | `CADataInline` | `"inline:adata"` |
| pytdx | `CPytdxInline` | `PYTDX_INLINE_SRC` |
| Tushare | `CTushareInline` | `TUSHARE_INLINE_SRC` |
| 新浪财经 | `CSinaInline` | `SINA_INLINE_SRC` |
| 腾讯财经 | `CTencentInline` | `TENCENT_INLINE_SRC` |
| 雅虎财经 | `CYahooInline` | `YAHOO_INLINE_SRC` |
| 东方财富 | `CEastmoneyInline` | `EASTMONEY_INLINE_SRC` |
| 离线数据 | `COfflineInline` | `OFFLINE_INLINE_SRC` |

**数据源优先级链**：`DATA_SOURCE_CHAIN_KLINE` 和 `DATA_SOURCE_CHAIN_CHIP` 分别控制 K 线和筹码全历史的数据源回退链。筹码分布的详细设计参见 `chan-chip-distribution` Skill。

---

## 四、核心计算模块

### 4.1 计算层级

```
CKLine_Unit (单根K线)
  └─→ CKLine (合并K线，含包含处理)  →  Combiner/KLine_Combiner.py
       └─→ CBi (笔)  →  Bi/Bi.py
            └─→ CSeg (线段)  →  Seg/Seg.py
                 └─→ CZS (中枢)  →  ZS/ZS.py
                      └─→ CBS_Point (买卖点)  →  BuySellPoint/BS_Point.py
```

### 4.2 各模块职责

| 模块 | 核心类 | 文件 | 职责 |
|------|--------|------|------|
| KLine | `CKLine_Unit` | [KLine/KLine_Unit.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/KLine/KLine_Unit.py) | 单根原始 K 线，含 OHLCV + 时间 + 指标 |
| KLine | `CKLine` | [KLine/KLine.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/KLine/KLine.py) | 合并后的 K 线（包含处理），含分型判定 |
| KLine | `CKLine_List` | [KLine/KLine_List.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/KLine/KLine_List.py) | 某周期的 K 线列表，聚合笔/线段/中枢/买卖点列表 |
| Combiner | `CKLine_Combiner` | [Combiner/KLine_Combiner.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Combiner/KLine_Combiner.py) | K 线合并逻辑（高低点包含处理） |
| Bi | `CBi` | [Bi/Bi.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Bi/Bi.py) | 单根笔，含方向、分型、买卖点关联 |
| Bi | `CBiList` | [Bi/BiList.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Bi/BiList.py) | 笔列表，含笔的生成与更新 |
| Seg | `CSeg` | [Seg/Seg.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Seg/Seg.py) | 单根线段，含方向、中枢列表、特征序列 |
| Seg | `CSegListChan` | [Seg/SegListChan.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Seg/SegListChan.py) | 缠论标准线段算法 |
| Seg | `CEigenFX` | [Seg/EigenFX.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Seg/EigenFX.py) | 特征序列分型 |
| ZS | `CZS` | [ZS/ZS.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/ZS/ZS.py) | 单根中枢，含区间、进出中枢笔、子中枢 |
| ZS | `CZSList` | [ZS/ZSList.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/ZS/ZSList.py) | 中枢列表 |
| BSP | `CBS_Point` | [BuySellPoint/BS_Point.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/BuySellPoint/BS_Point.py) | 买卖点（1/2/3类），含特征向量 |
| BSP | `CBSPointList` | [BuySellPoint/BSPointList.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/BuySellPoint/BSPointList.py) | 买卖点列表，含判定逻辑 |

### 4.3 技术指标

| 指标 | 文件 | 说明 |
|------|------|------|
| MACD | [Math/MACD.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/MACD.py) | 含面积、峰值、斜率等多种算法 |
| BOLL | [Math/BOLL.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/BOLL.py) | 布林带 |
| KDJ | [Math/KDJ.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/KDJ.py) | 随机指标 |
| RSI | [Math/RSI.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/RSI.py) | 相对强弱指标 |
| Demark | [Math/Demark.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/Demark.py) | 德马克序列 |
| TrendLine | [Math/TrendLine.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/TrendLine.py) | 趋势线 |
| TrendModel | [Math/TrendModel.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Math/TrendModel.py) | 均线/最值趋势模型 |

---

## 五、关键枚举定义

路径：[Common/CEnum.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/Common/CEnum.py)

| 枚举 | 说明 |
|------|------|
| `DATA_SRC` | 数据源：`BAO_STOCK`, `CCXT`, `CSV`, `AKSHARE` |
| `KL_TYPE` | K 线周期：`K_1M`, `K_3M`, `K_5M`, `K_15M`, `K_30M`, `K_60M`, `K_DAY`, `K_WEEK`, `K_MON`, `K_QUARTER`, `K_YEAR` |
| `AUTYPE` | 复权：`QFQ`, `HFQ`, `NONE` |
| `BI_DIR` | 笔方向：`UP`, `DOWN` |
| `BI_TYPE` | 笔类型：`STRICT`, `SUB_VALUE`, `TIAOKONG_THRED`, `DAHENG`, `TUIBI`, `UNSTRICT`, `TIAOKONG_VALUE` |
| `BSP_TYPE` | 买卖点类型：`T1`(1买), `T1P`(1卖), `T2`(2买), `T2S`(2卖), `T3A`(3买), `T3B`(3卖) |
| `FX_TYPE` | 分型：`BOTTOM`, `TOP` |
| `FX_CHECK_METHOD` | 分型检测：`STRICT`, `LOSS`, `HALF`, `TOTALLY` |
| `SEG_TYPE` | 线段类型：`BI`, `SEG` |
| `MACD_ALGO` | MACD 算法：`AREA`, `PEAK`, `FULL_AREA`, `DIFF`, `SLOPE`, `AMP`, `VOLUMN`, `AMOUNT`, `VOLUMN_AVG`, `AMOUNT_AVG`, `TURNRATE_AVG`, `RSI` |
| `DATA_FIELD` | 数据字段常量：`FIELD_TIME`, `FIELD_OPEN`, `FIELD_HIGH`, `FIELD_LOW`, `FIELD_CLOSE`, `FIELD_VOLUME`, `FIELD_TURNOVER`, `FIELD_TURNRATE` |
| `TREND_TYPE` | 趋势类型：`MEAN`, `MAX`, `MIN` |

---

## 六、关键配置项

路径：[ChanConfig.py](file:///c:/Users/Administrator/Desktop/my_file1/my_file/3/chan.py/ChanConfig.py)

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `bi_algo` | `"normal"` | 笔算法 |
| `bi_strict` | `True` | 是否严格笔 |
| `bi_fx_check` | `"strict"` | 分型检测方法 |
| `gap_as_kl` | `False` | 跳空是否视为独立K线 |
| `bi_end_is_peak` | `True` | 笔端点是否为极值 |
| `seg_algo` | `"chan"` | 线段算法（chan/1+1/break） |
| `zs_combine` | `True` | 中枢是否合并 |
| `zs_combine_mode` | `"zs"` | 中枢合并模式 |
| `one_bi_zs` | `False` | 一笔是否构成中枢 |
| `zs_algo` | `"normal"` | 中枢算法 |
| `trigger_step` | `False` | 是否逐K步进 |
| `macd` | `{"fast":12,"slow":26,"signal":9}` | MACD参数 |
| `cal_demark` | `False` | 是否计算德马克 |
| `cal_rsi` | `False` | 是否计算RSI |
| `cal_kdj` | `False` | 是否计算KDJ |

---

## 七、禁止事项（防重复造车轮）

### 7.1 不自造缠论

- **笔的生成**：必须使用 `Bi/BiList.py` 中的 `CBiList`，它已实现包含处理 → 分型检测 → 笔生成 → 笔修正的完整流程。
- **线段的生成**：必须使用 `Seg/SegListChan.py`（或 `SegListDYH.py`、`SegListDef.py`），它已实现特征序列 → 线段划分。
- **中枢的生成**：必须使用 `ZS/ZSList.py` 中的 `CZSList`，它已实现中枢识别、合并、扩展。
- **买卖点的判定**：必须使用 `BuySellPoint/BSPointList.py`，它已实现 1/2/3 类买卖点判定逻辑。

### 7.2 不重复造数据源

- 接入新数据源时，**必须继承 `CCommonStockApi`**，不要绕过抽象基类。
- 已有 12+ 个 inline 数据源，**优先检查是否已有类似实现可复用**。
- 数据源只负责**产出 `CKLine_Unit`**，不要自行处理笔/线段/中枢等缠论逻辑。

### 7.3 数据格式正确

- 时间字段**必须使用 `CTime` 对象**，不要用 `datetime` 或字符串。
- 数值字段**必须为 `float`**，空值用 `0.0` 替代（`str2float` 函数）。
- 必填字段 5 个（`FIELD_TIME`, `FIELD_OPEN`, `FIELD_HIGH`, `FIELD_LOW`, `FIELD_CLOSE`），一个不能少。
- `CKLine_Unit` 构造函数会自动检查 OHLC 的合法性（`autofix` 参数）。

---

## 八、常见错误与排查

| 错误现象 | 可能原因 | 排查方向 |
|---------|---------|---------|
| `SRC_DATA_NOT_FOUND` | 数据源未安装或数据不存在 | 检查数据源 API 是否已安装，或离线数据路径是否正确 |
| `SRC_DATA_FORMAT_ERROR` | CSV 列数不匹配 | 检查 `self.columns` 与文件列数一致 |
| `KL_DATA_ERR` | OHLC 数据非法（如 high < low） | 设置 `autofix=True` 或检查数据源 |
| `SEG_END_VALUE_ERR` | 线段方向与端点值矛盾 | 检查笔的方向和端点值 |
| `SEG_LEN_ERR` | 线段长度不足 | 线段至少需要 2 根笔 |
| 买卖点不出现 | 配置项不符合条件 | 检查 `bsp_type` 配置、`min_zs_cnt`、`divergence_rate` 等 |

---

## 注意事项

1. **持久化兼容**：`a_replay_trainer.py` 使用了持久化，新增配置项时注意 `AppRollbackSnapshot` 的兼容性。
2. **多模式兼容**：新增功能需考虑 chart_mode(single/dual/multi)、data_form_mode、data_feed_mode、kline_presentation_mode 四种维度的正交组合。
3. **逐K当下性**：`逐K喂数据` 模式下，BSP 历史只记录当前已喂入数据能判断出的买卖点，写入后冻结，不得回写。
4. **模块解耦**：核心计算模块与 UI/渲染解耦，新增核心逻辑不要引入 Plot 或 FastAPI 依赖。