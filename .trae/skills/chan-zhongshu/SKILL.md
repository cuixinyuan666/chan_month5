---
name: "chan-zhongshu"
description: "原生缠论中枢（ZS/ZhongShu）逻辑速查与修改指南。当修改中枢数据结构、cal_bi_zs 计算主流程、中枢合并 combine、update_zs_in_seg、build_level_zs、serialize_zs_collection、中枢配置项 zs_algo/one_bi_zs/zs_combine_mode、Rust 侧 zs.rs、前端 drawZsRects 渲染时，必须调用此 Skill 确保逻辑一致。"
---

# 原生缠论中枢（ZS/ZhongShu）逻辑速查与修改指南

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **修改 `CZS` 数据结构**（`ZS/ZS.py` 中字段、`update_zs_range`、`update_zs_end`、`combine`、`do_combine`、`try_add_to_end`、`in_range`、`is_divergence`、`end_bi_break` 等）
2. **修改 `CZSList` 计算主流程**（`ZS/ZSList.py` 中 `cal_bi_zs`、`try_construct_zs`、`add_to_free_lst`、`update`、`add_zs_from_bi_range`、`update_overseg_zs`、`try_combine`）
3. **修改 `CZSConfig` 配置项**（`ZS/ZSConfig.py`：`need_combine`、`zs_combine_mode`、`one_bi_zs`、`zs_algo`）
4. **修改 `update_zs_in_seg`**（`KLine/KLine_List.py` 中计算 seg 的 zs_lst、中枢 bi_in/bi_out/bi_lst 的绑定）
5. **修改 `build_level_zs` / `empty_zs_list` / `build_extra_zs_and_bsp`**（`a_replay_trainer.py` 中层级中枢构建包装）
6. **修改 `serialize_zs_collection`**（payload 序列化字段：`x1/x2/low/high/is_sure/is_one_bi_zs`）
7. **修改 Rust 侧 `a_rust_core/chan-core/src/zs.rs`**（`Zs`/`ZsList` 结构、`cal_bi_zs`、`try_construct`、`add_to_free`、`push_bi`）
8. **修改中枢配置项**（前端 `zs_algo`、`zs_combine`、`zs_combine_mode`、`one_bi_zs`、`zs_levels` 懒加载开关）
9. **修改中枢前端渲染**（`drawZsRects`、`drawMainChartChanDecor` 中枢框、`fractZs/biZs/segZs/segsegZs` 样式）
10. **修改中枢 payload 下发字段**（`fract_zs`/`bi_zs`/`seg_zs`/`segseg_zs`/`extra_zs`）

---

## 一、功能概述

中枢（ZS）是原生缠论中**方向相反的三段次级走势构成的价格重叠区间**，用于刻画"震荡整理"的载体，是判断趋势、背驰、买卖点的核心结构。

**核心定义**：
- 至少 3 个反向次级走势（笔/段）的价格区间存在重叠
- 中枢区间 `[low, high]`：`low = max(各笔低点)`、`high = min(各笔高点)`
- 中枢中点：`mid = (low + high) / 2`
- 峰值边界：`peak_low = min(各笔低点)`、`peak_high = max(各笔高点)`

**关键属性**：
| 属性 | 含义 |
|------|------|
| `begin` / `end` | 中枢起止 KLine_Unit（指向 klu） |
| `begin_bi` / `end_bi` | 中枢内部首/末笔 |
| `low` / `high` / `mid` | 中枢价格区间与中点 |
| `peak_low` / `peak_high` | 中枢涉及笔的极值（用于 peak 合并模式） |
| `bi_in` / `bi_out` | 进/出中枢那一笔（`update_zs_in_seg` 中绑定） |
| `bi_lst` | `begin_bi ~ end_bi` 之间的笔列表 |
| `sub_zs_lst` | 合并后的子中枢列表（combine 时填充） |
| `is_sure` | 是否由确认段产生 |
| `is_one_bi_zs()` | 是否为一笔中枢（`begin_bi.idx == end_bi.idx`） |

---

## 二、关键文件与职责

| 文件 | 职责 |
|------|------|
| `ZS/ZS.py` | **核心数据结构**：`CZS` 类，定义中枢字段、区间更新、合并、扩展、背驰判断 |
| `ZS/ZSList.py` | **计算主流程**：`CZSList` 类，`cal_bi_zs` 三种算法（normal/over_seg/auto）、`try_construct_zs`、`try_combine` |
| `ZS/ZSConfig.py` | **配置类**：`CZSConfig`（4 个配置项） |
| `KLine/KLine_List.py` | **入口**：`cal_seg_and_zs()` 串联段→中枢；`update_zs_in_seg()` 绑定 bi_in/bi_out/bi_lst |
| `a_replay_trainer.py` | **层级包装**：`build_level_zs` / `empty_zs_list` / `build_extra_zs_and_bsp`；**序列化**：`serialize_zs_collection`；**懒加载**：`chart_lazy_zs_enabled` |
| `a_rust_core/chan-core/src/zs.rs` | **Rust 加速**：`Zs`/`ZsList` 结构、`cal_bi_zs`（仅 normal 算法），与 Python 逻辑对应 |

---

## 三、核心数据结构

### 3.1 Python `CZS` 类（`ZS/ZS.py` L13-234）

```python
class CZS(Generic[LINE_TYPE]):
    # LINE_TYPE ∈ {CBi, CSeg}，分别用于笔中枢和段中枢
    __begin: CKLine_Unit         # 起始 K 线单元
    __end: CKLine_Unit           # 结束 K 线单元
    __begin_bi: LINE_TYPE        # 中枢首笔
    __end_bi: LINE_TYPE          # 中枢末笔
    __low: float                 # max(各笔低点)
    __high: float                # min(各笔高点)
    __mid: float                 # (low+high)/2
    __peak_low: float            # min(各笔低点)
    __peak_high: float           # max(各笔高点)
    __bi_in: Optional[LINE_TYPE] # 进中枢那一笔
    __bi_out: Optional[LINE_TYPE]# 出中枢那一笔
    __bi_lst: List[LINE_TYPE]    # begin_bi~end_bi 之间的笔
    __sub_zs_lst: List[CZS]      # 合并产生的子中枢
    __is_sure: bool              # 是否由确认段产生
```

**关键方法**：
| 方法 | 行号 | 作用 |
|------|------|------|
| `update_zs_range(lst)` | L89 | 重算 low/high/mid（max 低点 / min 高点） |
| `update_zs_end(item)` | L99 | 更新 end/end_bi/peak_low/peak_high |
| `is_one_bi_zs()` | L95 | 判断一笔中枢（begin_bi.idx == end_bi.idx） |
| `combine(zs2, combine_mode)` | L115 | 合并两个中枢（zs/peak 两种模式） |
| `do_combine(zs2)` | L134 | 实际执行合并：扩展 sub_zs_lst/边界/end_bi |
| `try_add_to_end(item)` | L148 | 尝试将笔加入现有中枢末尾 |
| `in_range(item)` | L156 | 判断笔与中枢区间是否有重叠 |
| `is_inside(seg)` | L159 | 判断中枢是否在某线段内 |
| `is_divergence(config, out_bi)` | L162 | 判断背驰（末笔必须突破中枢 + MACD 指标比较） |
| `end_bi_break(end_bi)` | L193 | 判断末笔是否突破中枢 |
| `out_bi_is_peak(end_bi_idx)` | L200 | 判断出中枢笔是否为峰值（用于 BSP 判定） |
| `make_copy()` | L188 | 深拷贝（合并时保留子中枢原始副本） |

### 3.2 Rust `Zs` / `ZsList`（`a_rust_core/chan-core/src/zs.rs`）

```rust
pub struct Zs {
    pub begin_bi: i32,
    pub end_bi: i32,
    pub is_sure: bool,
    pub low: f64,
    pub high: f64,
}

pub struct ZsList {
    pub zs_lst: Vec<Zs>,
    pub one_bi_zs: bool,
    pub last_sure_pos: i32,
    pub last_seg_idx: i32,
    free_item: Vec<i32>,
}
```

**Rust 实现限制**：
- 仅实现 `normal` 算法（不含 `over_seg`/`auto`）
- 不含 `combine`/`do_combine`（不做中枢合并）
- 不含 `peak_low`/`peak_high`/`sub_zs_lst`/`bi_in`/`bi_out` 等扩展字段
- 用于性能加速场景，与 Python 逻辑对应但**字段更精简**

---

## 四、计算主流程（`CZSList.cal_bi_zs`）

**位置**：`ZS/ZSList.py` L91-130

### 4.1 三种算法

| 算法 | 常量 | 行为 |
|------|------|------|
| **normal** | `zs_algo="normal"` | 按线段遍历，仅在段内构建中枢（最常用，原生缠论） |
| **over_seg** | `zs_algo="over_seg"` | 跨线段构建中枢（忽略段边界），要求 `one_bi_zs=False` |
| **auto** | `zs_algo="auto"` | 智能切换：确认段用 normal，未确认段用 over_seg |

### 4.2 normal 算法流程

```
1. 弹出 begin_bi.idx >= last_sure_pos 的旧中枢（防止重算冲突）
2. 遍历 last_seg_idx 之后的线段：
   - 对每个 seg，取 bi_lst[seg.start_bi.idx : seg.end_bi.idx+1]
   - 调用 add_zs_from_bi_range(seg_bi_lst, seg.dir, seg.is_sure)
     - 跳过与 seg 同向的笔
     - 第 1 笔调用 add_to_free_lst(..., "normal")
     - 后续笔调用 update()（先尝试 try_add_to_end 扩展，否则 add_to_free_lst）
3. 处理最后一个线段之后未成段的笔（is_sure=False，方向反向）
4. update_last_pos(seg_lst) 记录最后确认段位置
```

### 4.3 try_construct_zs 中枢构造判定（L73-89）

```python
def try_construct_zs(self, lst, is_sure, zs_algo):
    if zs_algo == "normal":
        if not self.config.one_bi_zs:
            if len(lst) == 1: return None   # 禁止一笔中枢
            else: lst = lst[-2:]             # 取最后 2 笔
    elif zs_algo == "over_seg":
        if len(lst) < 3: return None        # 至少 3 笔
        lst = lst[-3:]
        if lst[0].dir == lst[0].parent_seg.dir:  # 首笔与父段同向则跳过
            lst = lst[1:]
            return None
    min_high = min(item._high() for item in lst)
    max_low = max(item._low() for item in lst)
    return CZS(lst, is_sure=is_sure) if min_high > max_low else None  # 区间重叠才能成中枢
```

### 4.4 中枢合并 `try_combine`（L157-161）

```python
def try_combine(self):
    if not self.config.need_combine: return
    while len(self.zs_lst) >= 2 and \
          self.zs_lst[-2].combine(self.zs_lst[-1], combine_mode=self.config.zs_combine_mode):
        self.zs_lst = self.zs_lst[:-1]  # 合并成功则删除末尾中枢
```

**合并模式**（`CZS.combine`，ZS.py L115-132）：
| 模式 | 判定条件 |
|------|---------|
| `zs` | 两中枢 `[low, high]` 区间有重叠（`has_overlap(equal=True)`） |
| `peak` | 两中枢 `[peak_low, peak_high]` 区间有重叠 |

**合并限制**：
- 一笔中枢（`is_one_bi_zs()`）不可被合并
- `begin_bi.seg_idx` 必须相同（同一段内的中枢才能合并）

---

## 五、`update_zs_in_seg` 绑定逻辑

**位置**：`KLine/KLine_List.py` L177-204

**作用**：
1. 将中枢按归属绑定到对应线段（`seg.add_zs(zs)`，形成 `seg.zs_lst`）
2. 为每个中枢绑定 `bi_in`（`begin_bi.idx - 1` 那一笔）、`bi_out`（`end_bi.idx + 1` 那一笔）、`bi_lst`（`begin_bi ~ end_bi` 之间的笔列表）

**关键代码**：
```python
def update_zs_in_seg(bi_list, seg_list, zs_list):
    sure_seg_cnt = 0
    seg_idx = len(seg_list) - 1
    while seg_idx >= 0:
        seg = seg_list[seg_idx]
        if seg.ele_inside_is_sure: break
        if seg.is_sure: sure_seg_cnt += 1
        seg.clear_zs_lst()
        _zs_idx = len(zs_list) - 1
        while _zs_idx >= 0:
            zs = zs_list[_zs_idx]
            if zs.end.idx < seg.start_bi.get_begin_klu().idx: break
            if zs.is_inside(seg):
                seg.add_zs(zs)
            assert zs.begin_bi.idx > 0
            zs.set_bi_in(bi_list[zs.begin_bi.idx-1])
            if zs.end_bi.idx+1 < len(bi_list):
                zs.set_bi_out(bi_list[zs.end_bi.idx+1])
            zs.set_bi_lst(list(bi_list[zs.begin_bi.idx:zs.end_bi.idx+1]))
            _zs_idx -= 1
        if sure_seg_cnt > 2 and not seg.ele_inside_is_sure:
            seg.ele_inside_is_sure = True
        seg_idx -= 1
```

**修改时注意**：
- `zs.begin_bi.idx > 0` 断言：禁止第一笔就是中枢起点（与 `add_to_free_lst` 中 `res.begin_bi.idx > 0` 一致）
- `bi_out` 仅在 `end_bi.idx+1 < len(bi_list)` 时绑定（末笔为最后一笔时无 bi_out）
- `sure_seg_cnt > 2` 触发 `ele_inside_is_sure`（线段内部元素全部确认）

---

## 六、层级中枢构建（`a_replay_trainer.py`）

### 6.1 `build_level_zs`（L3667-3674）

```python
def build_level_zs(base_lines, upper_lines, zs_conf) -> CZSList:
    zs_list = CZSList(zs_config=zs_conf)
    try:
        zs_list.cal_bi_zs(base_lines, upper_lines)
        update_zs_in_seg(base_lines, upper_lines, zs_list)
    except Exception:
        return CZSList(zs_config=zs_conf)  # 失败兜底返回空列表
    return zs_list
```

**层级映射**：
| 层级 | base_lines | upper_lines | payload 字段 |
|------|-----------|-------------|-------------|
| 分型中枢 | fract_list | bi_list | `fract_zs` |
| 笔中枢 | bi_list | seg_list | `bi_zs` |
| 段中枢 | seg_list | segseg_list | `seg_zs` |
| 2 段中枢 | segseg_list | segsegseg_list | `segseg_zs` |
| 自定义高阶 | extra_lines[level-1] | extra_lines[level] | `extra_zs[level]` |

### 6.2 `build_extra_zs_and_bsp`（L3755-3769）

为自定义高阶线段（segsegseg、4 段、5 段…）构建对应中枢与买卖点。

### 6.3 懒加载 `chart_lazy_zs_enabled`（L336-338）

```python
def chart_lazy_zs_enabled(layers: Any, level: str) -> bool:
    cfg = layers or {}
    return bool((cfg.get("zs_levels") or {}).get(level, True))
```

- 默认开启（True）
- 关闭时调用 `empty_zs_list(conf.zs_conf)` 返回空 `CZSList`，跳过计算

---

## 七、序列化与 payload 下发

### 7.1 `serialize_zs_collection`（L4092-4105）

```python
def serialize_zs_collection(zs_list: Any) -> list[dict[str, Any]]:
    arr = []
    for zs in zs_list:
        arr.append({
            "x1": int(zs.begin.idx),
            "x2": int(zs.end.idx),
            "low": float(zs.low),
            "high": float(zs.high),
            "is_sure": bool(zs.is_sure),
            "is_one_bi_zs": bool(zs.is_one_bi_zs()),
        })
    return arr
```

### 7.2 payload 字段（L5936-5943）

```python
out["fract_zs"]  = [it for it in payload.get("fract_zs", [])  if int(it.get("x2", -1)) <= x_max]
out["bi_zs"]     = [it for it in payload.get("bi_zs", [])     if int(it.get("x2", -1)) <= x_max]
out["seg_zs"]    = [it for it in payload.get("seg_zs", [])    if int(it.get("x2", -1)) <= x_max]
out["segseg_zs"] = [it for it in payload.get("segseg_zs", []) if int(it.get("x2", -1)) <= x_max]
if isinstance(payload.get("extra_zs"), dict):
    out["extra_zs"] = {level: [...] for level, items in payload.get("extra_zs", {}).items()}
```

**修改时注意**：
- 下发时按 `x2 <= x_max` 截断（避免越界渲染）
- `extra_zs` 是 dict（key 为 level 字符串），其他四个是 list
- 字段名严格区分：`fract_zs` / `bi_zs` / `seg_zs` / `segseg_zs`（下划线 + zs 后缀）

---

## 八、配置项一览

### 8.1 后端配置（`CZSConfig`）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `need_combine` | bool | True | 是否启用中枢合并 |
| `zs_combine_mode` | str | "zs" | 合并模式：`zs`（区间重叠）/ `peak`（峰值重叠） |
| `one_bi_zs` | bool | False | 是否允许一笔中枢 |
| `zs_algo` | str | "normal" | 计算算法：`normal` / `over_seg` / `auto` |

### 8.2 前端默认配置（`DEFAULT_CHAN_CONFIG`，L11412-11415）

```javascript
zs_algo: "normal",
zs_combine: true,
zs_combine_mode: "zs",
one_bi_zs: false,
```

### 8.3 懒加载配置（`zs_levels`）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `zs_levels.fract` | bool | True | 分型中枢开关 |
| `zs_levels.bi` | bool | True | 笔中枢开关 |
| `zs_levels.seg` | bool | True | 段中枢开关 |
| `zs_levels.segseg` | bool | True | 2 段中枢开关 |
| `zs_levels.<custom>` | bool | True | 自定义高阶中枢开关 |

### 8.4 渲染样式配置（`activeDrawStyle()`）

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `fractZs.enabled` | true | 分型中枢框开关 |
| `fractZs.color` | "#b45309" | 分型中枢框颜色（琥珀深） |
| `fractZs.width` | 1.4 | 分型中枢框线宽 |
| `biZs.enabled` | true | 笔中枢框开关 |
| `biZs.color` | "#f59e0b" | 笔中枢框颜色（琥珀） |
| `biZs.width` | 1.8 | 笔中枢框线宽 |
| `segZs.enabled` | true | 段中枢框开关 |
| `segZs.color` | "#059669" | 段中枢框颜色（绿） |
| `segZs.width` | 2.4 | 段中枢框线宽 |
| `segsegZs.enabled` | true | 2 段中枢框开关 |
| `segsegZs.color` | "#2563eb" | 2 段中枢框颜色（蓝） |
| `segsegZs.width` | 2.8 | 2 段中枢框线宽 |

---

## 九、前端渲染

### 9.1 `drawZsRects`（L22241-22262）

```javascript
function drawZsRects(arr, s, color, width) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  for (const zs of arr || []) {
    const loX = Math.min(zs.x1, zs.x2);
    const hiX = Math.max(zs.x1, zs.x2);
    if (hiX < s.xMin || loX > s.xMax) continue;  // 视口剔除
    const x1 = s.x(loX), x2 = s.x(hiX);
    const yTop = s.y(zs.high), yBottom = s.y(zs.low);
    const rectX = Math.min(x1, x2);
    const rectY = Math.min(yTop, yBottom);
    const rectW = Math.max(1, Math.abs(x2 - x1));
    const rectH = Math.max(1, Math.abs(yBottom - yTop));
    if (!zs.is_sure) ctx.setLineDash([6, 4]);  // 未确认中枢用虚线
    else ctx.setLineDash([]);
    ctx.strokeRect(rectX, rectY, rectW, rectH);
  }
  ctx.restore();
}
```

### 9.2 `drawMainChartChanDecor`（L22265-22286）

按层级顺序绘制：分型→笔→段→2段→自定义高阶，每层独立开关与样式。

**修改时注意**：
- 视口剔除：`hiX < s.xMin || loX > s.xMax` 跳过不可见中枢
- 未确认中枢（`is_sure=false`）使用 `[6, 4]` 虚线
- `rectW` / `rectH` 至少为 1（避免 0 宽高渲染异常）
- 自定义高阶通过 `zsConfigKeyForLevel(level)` 映射到样式 key（如 `seg3segZs`）

---

## 十、数据流与生命周期

```
init() → zs_conf 从 cfg_dict 读取并构造 CZSConfig

逐K步进（trigger_step=True）:
  add_single_klu(klu)
    → cal_seg_and_zs()
      → cal_seg(bi_list, seg_list, ...)          # 先算段
      → zs_list.cal_bi_zs(bi_list, seg_list)     # 再算笔中枢
      → update_zs_in_seg(bi_list, seg_list, zs_list)  # 绑定 bi_in/bi_out/bi_lst
      → cal_seg(seg_list, segseg_list, ...)      # 算 2 段
      → segzs_list.cal_bi_zs(seg_list, segseg_list)   # 算段中枢
      → update_zs_in_seg(seg_list, segseg_list, segzs_list)

复盘层级构建（a_replay_trainer.py）:
  build_structure_bundle() / build_classic_bundle() / build_new_bundle()
    → build_level_zs(fract_list, bi_list, conf.zs_conf)        # 分型中枢
    → build_level_zs(bi_list, seg_list, conf.zs_conf)          # 笔中枢
    → build_level_zs(seg_list, segseg_list, conf.zs_conf)      # 段中枢
    → build_level_zs(segseg_list, segsegseg_list, conf.zs_conf)# 2 段中枢
    → build_extra_zs_and_bsp(extra_lines, conf, lazy)          # 自定义高阶

payload 下发:
  serialize_zs_collection(zs_list)  →  payload["bi_zs"]
  serialize_zs_collection(segzs_list)  →  payload["seg_zs"]
  ...
  视口截断 (x2 <= x_max)

前端渲染:
  drawMainChartChanDecor()
    → drawZsRects(chart.fract_zs, s, fractZs.color, fractZs.width)
    → drawZsRects(chart.bi_zs, s, biZs.color, biZs.width)
    → drawZsRects(chart.seg_zs, s, segZs.color, segZs.width)
    → drawZsRects(chart.segseg_zs, s, segsegZs.color, segsegZs.width)
    → drawZsRects(chart.extra_zs[level], s, cfg.color, cfg.width)
```

---

## 十一、Python 与 Rust 实现对照

| 项 | Python (`ZS/`) | Rust (`a_rust_core/chan-core/src/zs.rs`) |
|----|----------------|------------------------------------------|
| 数据结构 | `CZS`（完整字段） | `Zs`（仅 begin_bi/end_bi/is_sure/low/high） |
| 列表 | `CZSList` | `ZsList` |
| 算法 | normal / over_seg / auto | **仅 normal** |
| 合并 | `combine` + `do_combine`（zs/peak 两模式） | **无合并** |
| bi_in/bi_out | `update_zs_in_seg` 绑定 | **无绑定** |
| sub_zs_lst | 支持 | **不支持** |
| peak_low/peak_high | 支持 | **不支持** |
| 背驰判断 | `is_divergence` | **无** |
| 一笔中枢 | 由 `one_bi_zs` 配置控制 | 由 `one_bi_zs` 配置控制 |

**修改时注意**：
- 修改 Python `CZS` 字段时，若 Rust 已有对应字段需**同步修改**
- 修改 `cal_bi_zs` normal 算法时，**必须同步修改 Rust** `ZsList::cal_bi_zs`
- Rust 不支持 over_seg/auto/combine，相关改动**不需要同步 Rust**

---

## 十二、修改检查清单

修改中枢相关代码后，必须逐项确认：

### 数据结构层
- [ ] `CZS.update_zs_range` 的 `low = max(低点)`、`high = min(高点)` 是否正确
- [ ] `CZS.combine` 是否检查 `is_one_bi_zs()`（一笔中枢不可合并）
- [ ] `CZS.combine` 是否检查 `begin_bi.seg_idx` 相同（跨段不合并）
- [ ] `do_combine` 是否正确扩展 `sub_zs_lst`、`peak_low`/`peak_high`、`end_bi`、`bi_out`
- [ ] `try_add_to_end` 对一笔中枢扩展时是否调用 `update_zs_range` 重算区间

### 计算主流程层
- [ ] `cal_bi_zs` 开头是否弹出 `begin_bi.idx >= last_sure_pos` 的旧中枢
- [ ] `add_to_free_lst` 是否防止 `res.begin_bi.idx > 0`（禁止第一笔成中枢）
- [ ] `try_construct_zs` 中 normal 模式是否受 `one_bi_zs` 控制
- [ ] `try_construct_zs` 中 over_seg 模式是否要求 `len(lst) >= 3` 且首笔与父段反向
- [ ] `try_construct_zs` 的核心判定 `min_high > max_low` 是否正确（区间重叠）
- [ ] `try_combine` 是否受 `need_combine` 开关控制
- [ ] `auto` 算法是否在确认段用 normal、未确认段用 over_seg

### 绑定与上下文层
- [ ] `update_zs_in_seg` 是否正确绑定 `bi_in`（`begin_bi.idx-1`）、`bi_out`（`end_bi.idx+1`）
- [ ] `bi_out` 是否检查 `end_bi.idx+1 < len(bi_list)` 防越界
- [ ] `zs.is_inside(seg)` 判定是否正确（`seg.start_bi.idx <= begin_bi.idx <= seg.end_bi.idx`）
- [ ] `ele_inside_is_sure` 是否在 `sure_seg_cnt > 2` 时置位

### 层级包装层
- [ ] `build_level_zs` 异常时是否返回空 `CZSList`（不抛异常打断流程）
- [ ] `chart_lazy_zs_enabled` 关闭时是否调用 `empty_zs_list` 而非跳过赋值
- [ ] `build_extra_zs_and_bsp` 是否为每个自定义高阶层级构建中枢
- [ ] 懒加载关闭某层级时，对应 payload 字段是否为空数组（而非缺失）

### 序列化与下发层
- [ ] `serialize_zs_collection` 输出字段是否完整：`x1/x2/low/high/is_sure/is_one_bi_zs`
- [ ] payload 下发是否按 `x2 <= x_max` 截断
- [ ] `extra_zs` 是否为 dict（key 为 level），其他四个是否为 list
- [ ] 字段名是否严格匹配：`fract_zs` / `bi_zs` / `seg_zs` / `segseg_zs`

### 前端渲染层
- [ ] `drawZsRects` 是否做视口剔除（`hiX < s.xMin || loX > s.xMax`）
- [ ] 未确认中枢（`is_sure=false`）是否使用 `[6, 4]` 虚线
- [ ] `rectW` / `rectH` 是否有 `Math.max(1, ...)` 兜底
- [ ] 各层级样式开关（`fractZs.enabled` 等）是否生效
- [ ] 自定义高阶中枢是否能通过 `zsConfigKeyForLevel` 正确映射到样式

### Rust 同步层（若修改了 Python 计算逻辑）
- [ ] normal 算法改动是否同步到 `zs.rs` 的 `cal_bi_zs`
- [ ] `try_construct` 的 `min_high > max_low` 判定是否一致
- [ ] `one_bi_zs` 配置是否在 Rust 侧生效
- [ ] `last_sure_pos` / `last_seg_idx` 更新逻辑是否一致
- [ ] over_seg / auto / combine 改动**不需要**同步 Rust（Rust 不支持）

### 配置项适配层
- [ ] `zs_algo` 修改后是否影响 `a_replay_trainer.py` 默认配置（L5355）和前端默认（L11412）
- [ ] `one_bi_zs` 修改后是否同步前端默认（L11415）
- [ ] `zs_combine_mode` 取值是否在 `{"zs", "peak"}` 范围内
- [ ] 新增配置项是否需要持久化（`a_replay_trainer.py` 使用可持久化）
- [ ] 新增配置项是否需要弹窗说明操作逻辑（按 AGENTS.md 规则 7）
