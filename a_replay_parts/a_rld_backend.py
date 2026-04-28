from .a_trainer import *

class ReplayMultiLvChan(CChan):
    def __init__(self, *args: Any, replay_klus_map_master: Optional[dict[KL_TYPE, list]] = None, **kwargs: Any) -> None:
        self._replay_klus_map_master: Optional[dict[KL_TYPE, list]] = replay_klus_map_master
        super().__init__(*args, **kwargs)

    def load(self, step: bool = False):
        if self._replay_klus_map_master is None:
            yield from super().load(step)
            return
        frozen_map = {lv: copy.deepcopy(self._replay_klus_map_master.get(lv, [])) for lv in self.lv_list}
        self.klu_cache = [None for _ in self.lv_list]
        self.klu_last_t = [CTime(1980, 1, 1, 0, 0) for _ in self.lv_list]
        for lv_idx, lv in enumerate(self.lv_list):
            self.add_lv_iter(lv_idx, iter(frozen_map.get(lv, [])))
        yield from self.load_iterator(lv_idx=0, parent_klu=None, step=step)
        if not step:
            for lv in self.lv_list:
                self.kl_datas[lv].cal_seg_and_zs()
        if len(self[0]) == 0:
            raise CChanException("最高级别没有获得任何数据", ErrCode.NO_DATA)


class _SingleLevelChanView:
    def __init__(self, kl_list, conf: CChanConfig):
        self._kl_list = kl_list
        self.conf = conf

    def __getitem__(self, n):
        if n == 0:
            return self._kl_list
        raise IndexError(n)


def create_stock_api_instance_for_level(
    data_src: Any,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    k_type: KL_TYPE,
) -> CCommonStockApi:
    api_cls = get_stock_api_cls(data_src)
    api_cls.do_init()
    try:
        return api_cls(code=code, k_type=k_type, begin_date=begin_date, end_date=end_date, autype=autype)
    except Exception:
        api_cls.do_close()
        raise


def fetch_level_klus_from_source(
    data_src: Any,
    code: str,
    begin_date: Optional[str],
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[list[CKLine_Unit], Optional[str]]:
    selection = select_runtime_data_source_for_level(
        code=code,
        begin_date=begin_date,
        end_date=end_date,
        autype=autype,
        lv=lv,
    )
    return selection.items, selection.stock_name


def select_data_source_for_level(
    code: str,
    begin_date: str,
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[Any, str, list[CKLine_Unit], Optional[str], list[str]]:
    logs: list[str] = []
    errors: list[str] = []
    for label, data_src in get_data_source_chain():
        if not data_source_supports_level(data_src, lv):
            errors.append(f"{label}:不支持 {kl_type_to_label(lv)}")
            continue
        try:
            items, stock_name = fetch_level_klus_from_source(data_src, code, begin_date, end_date, autype, lv)
            if len(items) <= 0:
                raise RuntimeError("未获取到任何数据")
            logs.append(f"{kl_type_to_label(lv)} 使用 {label}，加载 {len(items)} 根 K 线")
            return data_src, label, items, stock_name, logs
        except Exception as exc:
            errors.append(f"{label}:{format_source_error(exc)}")
    raise RuntimeError(f"{kl_type_to_label(lv)} 数据源全部失败：{'；'.join(errors)}")


def select_runtime_data_source_for_level_safe(
    code: str,
    begin_date: str,
    end_date: Optional[str],
    autype: AUTYPE,
    lv: KL_TYPE,
) -> tuple[Any, str, list[CKLine_Unit], Optional[str], list[str]]:
    selection = select_runtime_data_source_for_level(
        code=code,
        begin_date=begin_date,
        end_date=end_date,
        autype=autype,
        lv=lv,
    )
    return selection.data_src, selection.label, selection.items, selection.stock_name, list(selection.logs)


def serialize_rld_klu_iter(klu_iter) -> list[dict[str, Any]]:
    arr: list[dict[str, Any]] = []
    for klu in klu_iter:
        arr.append(
            {
                "x": int(klu.idx),
                "t": klu.time.to_str(),
                "o": float(klu.open),
                "h": float(klu.high),
                "l": float(klu.low),
                "c": float(klu.close),
                "v": float(getattr(klu, "volume", getattr(klu, "vol", 0.0)) or 0.0),
                "sup_x": int(klu.sup_kl.idx) if getattr(klu, "sup_kl", None) is not None else None,
                "sub_count": len(getattr(klu, "sub_kl_list", []) or []),
            }
        )
    return arr


@dataclass
class RldDataSession:
    code: str
    begin_date: str
    end_date: Optional[str]
    autype: AUTYPE
    lv_list: list[KL_TYPE]
    replay_klus_map: dict[KL_TYPE, list]
    source_map: dict[str, str]
    logs: list[str] = field(default_factory=list)
    stock_name: Optional[str] = None

    @classmethod
    def load(
        cls,
        code: str,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        lv_list: list[KL_TYPE],
    ) -> "RldDataSession":
        replay_klus_map: dict[KL_TYPE, list] = {}
        source_map: dict[str, str] = {}
        logs: list[str] = []
        stock_name: Optional[str] = None
        valid_lv_list: list[KL_TYPE] = []
        for idx, lv in enumerate(lv_list):
            try:
                data_src, label, items, name, lv_logs = select_runtime_data_source_for_level_safe(code, begin_date, end_date, autype, lv)
                replay_klus_map[lv] = items
                source_map[kl_type_to_name(lv)] = label
                logs.extend(lv_logs)
                valid_lv_list.append(lv)
                if stock_name is None and name:
                    stock_name = name
            except Exception as exc:
                if idx == 0:
                    raise
                logs.append(f"{kl_type_to_label(lv)} 降级跳过：{format_source_error(exc)}")
                continue
        if not valid_lv_list:
            raise RuntimeError("未能构建任何有效周期")
        return cls(
            code=code,
            begin_date=begin_date,
            end_date=end_date,
            autype=autype,
            lv_list=valid_lv_list,
            replay_klus_map=replay_klus_map,
            source_map=source_map,
            logs=logs,
            stock_name=stock_name,
        )

    def build_chan(self, chan_config: Optional[dict[str, Any]] = None, *, trigger_step: bool = False) -> tuple[ReplayMultiLvChan, dict[str, Any]]:
        cfg_dict = build_chan_config_dict(chan_config, trigger_step=trigger_step)
        cfg = CChanConfig(strip_chan_algo(cfg_dict))
        chan = ReplayMultiLvChan(
            code=self.code,
            begin_time=self.begin_date,
            end_time=self.end_date,
            data_src=DATA_SRC.BAO_STOCK,
            lv_list=self.lv_list,
            config=cfg,
            autype=self.autype,
            replay_klus_map_master=self.replay_klus_map,
        )
        return chan, cfg_dict


def build_level_macd_history(klus: list[Any], macd_cfg: Optional[dict[str, Any]] = None) -> list[dict[str, Any]]:
    macd_cfg = macd_cfg or {}
    eng = CMACD(
        fastperiod=int(macd_cfg.get("fast", 12) or 12),
        slowperiod=int(macd_cfg.get("slow", 26) or 26),
        signalperiod=int(macd_cfg.get("signal", 9) or 9),
    )
    arr: list[dict[str, Any]] = []
    for klu in klus:
        item = eng.add(float(klu.close))
        arr.append({"x": int(klu.idx), "macd": {"dif": float(item.DIF), "dea": float(item.DEA), "macd": float(item.macd)}})
    return arr


def line_dir_sign(line: Any) -> int:
    try:
        y1 = float(line.get_begin_val())
        y2 = float(line.get_end_val())
    except Exception:
        return 0
    if y2 > y1:
        return 1
    if y2 < y1:
        return -1
    return 0


def describe_trend(sign: int) -> str:
    if sign > 0:
        return "上升"
    if sign < 0:
        return "下降"
    return "震荡"


def get_latest_nonempty_line(bundle: ChanStructureBundle):
    for lines in (bundle.segseg_list, bundle.seg_list, bundle.bi_list, bundle.fract_list):
        if lines and len(lines) > 0:
            return lines[-1]
    return None


def latest_bundle_bsp(bundle: ChanStructureBundle) -> Optional[dict[str, Any]]:
    arr = []
    arr.extend(serialize_bsp_collection("bi", bundle.bs_point_lst))
    arr.extend(serialize_bsp_collection("seg", bundle.seg_bs_point_lst))
    arr.extend(serialize_bsp_collection("segseg", bundle.segseg_bs_point_lst))
    if not arr:
        return None
    arr.sort(key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))))
    return arr[-1]


def latest_zs_state(bundle: ChanStructureBundle, current_price: float) -> dict[str, Any]:
    last_zs = None
    last_kind = "笔中枢"
    for kind, zs_list in [("段中枢", bundle.segzs_list), ("笔中枢", bundle.zs_list), ("分型中枢", bundle.fractzs_list)]:
        zs_items = list(zs_list)
        if zs_items:
            last_zs = zs_items[-1]
            last_kind = kind
            break
    if last_zs is None:
        return {"label": "无中枢", "kind": "无", "low": None, "high": None, "bias": 0}
    low = float(last_zs.low)
    high = float(last_zs.high)
    if current_price > high:
        return {"label": "上离开", "kind": last_kind, "low": low, "high": high, "bias": 1}
    if current_price < low:
        return {"label": "下离开", "kind": last_kind, "low": low, "high": high, "bias": -1}
    return {"label": "中枢内", "kind": last_kind, "low": low, "high": high, "bias": 0}


def calc_macd_area(macd_history: list[dict[str, Any]], start_x: Optional[int], end_x: Optional[int]) -> Optional[float]:
    if start_x is None or end_x is None or end_x < start_x:
        return None
    total = 0.0
    hit = False
    for item in macd_history:
        x = int(item["x"])
        if x < start_x or x > end_x:
            continue
        total += abs(float(item["macd"]["macd"]))
        hit = True
    return round(total, 4) if hit else None


def find_previous_same_dir_line(lines: Any, latest_line: Any):
    if not lines or len(lines) <= 1:
        return None
    latest_sign = line_dir_sign(latest_line)
    if latest_sign == 0:
        return None
    for line in reversed(lines[:-1]):
        if line_dir_sign(line) == latest_sign:
            return line
    return None


def calc_divergence_bias(lines: Any, latest_line: Any, macd_history: list[dict[str, Any]]) -> int:
    if latest_line is None:
        return 0
    prev_line = find_previous_same_dir_line(lines, latest_line)
    if prev_line is None:
        return 0
    latest_area = calc_macd_area(macd_history, int(latest_line.get_begin_klu().idx), int(latest_line.get_end_klu().idx))
    prev_area = calc_macd_area(macd_history, int(prev_line.get_begin_klu().idx), int(prev_line.get_end_klu().idx))
    if latest_area is None or prev_area is None or prev_area <= 1e-9:
        return 0
    latest_sign = line_dir_sign(latest_line)
    if latest_area <= prev_area * 0.85:
        return -latest_sign
    if latest_area >= prev_area * 1.05:
        return latest_sign
    return 0


def last_macd_bias(macd_history: list[dict[str, Any]]) -> float:
    if not macd_history:
        return 0.0
    value = float(macd_history[-1]["macd"]["macd"])
    return float(math.tanh(value * 4.0) * 100.0)


def bsp_bias(item: Optional[dict[str, Any]], latest_x: int) -> tuple[int, list[str]]:
    if not item:
        return 0, ["最近未出现明确买卖点"]
    label_weight = {"1": 22, "1p": 18, "2": 16, "2s": 12, "3a": 18, "3b": 16}
    sign = 1 if bool(item.get("is_buy")) else -1
    weight = label_weight.get(str(item.get("label")), 10)
    reasons = [f"最近买卖点：{item.get('display_label') or item.get('label')}"]
    if latest_x - int(item.get("x", latest_x)) > 12:
        weight = int(weight * 0.55)
        reasons.append("买卖点距离当前较远，影响衰减")
    return sign * weight, reasons


def build_level_chart_payload(kl_list, chan_algo: str, macd_cfg: Optional[dict[str, Any]] = None) -> tuple[dict[str, Any], dict[str, Any]]:
    klu_items = list(kl_list.klu_iter())
    chart = {"kline": [], "fract": [], "bi": [], "seg": [], "segseg": [], "fract_zs": [], "bi_zs": [], "seg_zs": [], "segseg_zs": [], "bsp": [], "trend_lines": [], "indicators": []}
    if not klu_items:
        return chart, {
            "trend_sign": 0,
            "trend_label": "震荡",
            "zs_state": {"label": "无数据", "kind": "无", "low": None, "high": None, "bias": 0},
            "latest_bsp": None,
            "macd_bi_area": None,
            "macd_seg_area": None,
            "macd_bias": 0.0,
            "chdl_score": 0.0,
            "divergence_bias": 0,
            "reasons": ["当前级别无数据"],
        }
    view = _SingleLevelChanView(kl_list, kl_list.config)
    bundle = build_structure_bundle(view, chan_algo)
    macd_history = build_level_macd_history(klu_items, macd_cfg)
    current_price = float(klu_items[-1].close)
    latest_x = int(klu_items[-1].idx)
    latest_line = get_latest_nonempty_line(bundle)
    trend_sign = line_dir_sign(latest_line) if latest_line is not None else 0
    trend_label = describe_trend(trend_sign)
    zs_state = latest_zs_state(bundle, current_price)
    latest_bsp = latest_bundle_bsp(bundle)
    bi_line = bundle.bi_list[-1] if bundle.bi_list and len(bundle.bi_list) > 0 else None
    seg_line = bundle.seg_list[-1] if bundle.seg_list and len(bundle.seg_list) > 0 else None
    macd_bi_area = calc_macd_area(macd_history, int(bi_line.get_begin_klu().idx), int(bi_line.get_end_klu().idx)) if bi_line is not None else None
    macd_seg_area = calc_macd_area(macd_history, int(seg_line.get_begin_klu().idx), int(seg_line.get_end_klu().idx)) if seg_line is not None else None
    divergence = calc_divergence_bias(bundle.bi_list if bundle.bi_list else bundle.seg_list, bi_line or seg_line, macd_history)
    macd_bias = last_macd_bias(macd_history)
    chdl = 0.0
    reasons: list[str] = [f"结构方向：{trend_label}"]
    chdl += trend_sign * 22.0
    chdl += float(zs_state["bias"]) * 14.0
    reasons.append(f"中枢状态：{zs_state['kind']}{zs_state['label']}")
    _bsp_bias, bsp_reasons = bsp_bias(latest_bsp, latest_x)
    chdl += float(_bsp_bias)
    reasons.extend(bsp_reasons)
    chdl += macd_bias * 0.18
    if abs(macd_bias) >= 8:
        reasons.append(f"MACD 动量：{macd_bias:+.1f}")
    chdl += divergence * 14.0
    if divergence > 0:
        reasons.append("最近结构出现正向背驰/动能改善")
    elif divergence < 0:
        reasons.append("最近结构出现反向背驰/动能衰减")
    chdl = round(max(-100.0, min(100.0, chdl)), 2)
    chart = {
        "kline": serialize_rld_klu_iter(klu_items),
        "fract": serialize_line_collection(bundle.fract_list),
        "bi": serialize_line_collection(bundle.bi_list),
        "seg": serialize_line_collection(bundle.seg_list),
        "segseg": serialize_line_collection(bundle.segseg_list),
        "fract_zs": serialize_zs_collection(bundle.fractzs_list),
        "bi_zs": serialize_zs_collection(bundle.zs_list),
        "seg_zs": serialize_zs_collection(bundle.segzs_list),
        "segseg_zs": serialize_zs_collection(bundle.segsegzs_list),
        "bsp": sorted(
            [
                *serialize_bsp_collection("bi", bundle.bs_point_lst),
                *serialize_bsp_collection("seg", bundle.seg_bs_point_lst),
                *serialize_bsp_collection("segseg", bundle.segseg_bs_point_lst),
            ],
            key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))),
        ),
        "trend_lines": bundle.trend_lines,
        "indicators": macd_history,
    }
    return chart, {
        "trend_sign": trend_sign,
        "trend_label": trend_label,
        "zs_state": zs_state,
        "latest_bsp": latest_bsp,
        "macd_bi_area": macd_bi_area,
        "macd_seg_area": macd_seg_area,
        "macd_bias": round(macd_bias, 2),
        "chdl_score": chdl,
        "divergence_bias": divergence,
        "reasons": reasons,
    }


def normalize_strategy_config(strategy_config: Optional[dict[str, Any]], lv_list: list[KL_TYPE]) -> dict[str, Any]:
    default_weights = [50.0, 30.0, 20.0]
    weights_raw = []
    if isinstance(strategy_config, dict):
        weights_raw = list(strategy_config.get("weights", []) or [])
    weights: list[float] = []
    for idx, lv in enumerate(lv_list):
        try:
            weights.append(float(weights_raw[idx]))
        except Exception:
            weights.append(default_weights[idx] if idx < len(default_weights) else max(5.0, 20.0 - idx * 3.0))
    total = sum(abs(weight) for weight in weights) or 1.0
    normalized = [round(weight / total * 100.0, 3) for weight in weights]
    return {"weights": normalized}


def build_rld_summary(level_snapshots: list[dict[str, Any]], strategy_config: dict[str, Any]) -> dict[str, Any]:
    if not level_snapshots:
        return {"weighted_chdl": 0.0, "three_macd": 0.0, "one_line": False, "stupid_buy_bi": False, "stupid_buy_seg": False, "rld_bs": {"side": "neutral", "score": 0.0, "reasons": ["暂无数据"]}, "weights": []}
    weights = strategy_config.get("weights", [])
    weighted_chdl = 0.0
    weighted_macd = 0.0
    trend_signs: list[int] = []
    reasons: list[str] = []
    for idx, item in enumerate(level_snapshots):
        weight = float(weights[idx] if idx < len(weights) else 0.0)
        weighted_chdl += float(item["summary"]["chdl_score"]) * weight / 100.0
        weighted_macd += float(item["summary"]["macd_bias"]) * weight / 100.0
        trend_signs.append(int(item["summary"]["trend_sign"]))
        reasons.append(f"{item['label']} CHDL={item['summary']['chdl_score']:+.1f}")
    nonzero_signs = [sign for sign in trend_signs if sign != 0]
    aligned = len(nonzero_signs) == len(level_snapshots) and len(set(nonzero_signs)) == 1
    no_recent_opposite = all(
        snapshot["summary"]["latest_bsp"] is None
        or (
            snapshot["summary"]["trend_sign"] == 0
            or (
                (snapshot["summary"]["trend_sign"] > 0 and bool(snapshot["summary"]["latest_bsp"].get("is_buy")))
                or (snapshot["summary"]["trend_sign"] < 0 and not bool(snapshot["summary"]["latest_bsp"].get("is_buy")))
            )
        )
        for snapshot in level_snapshots
    )
    one_line = bool(aligned and no_recent_opposite and abs(weighted_chdl) >= 12)
    stupid_buy_bi = bool(weighted_chdl >= 20 and aligned and all(item["summary"]["macd_bi_area"] is not None for item in level_snapshots[:2]))
    stupid_buy_seg = bool(weighted_chdl >= 38 and aligned and all(item["summary"]["zs_state"]["bias"] >= 0 for item in level_snapshots[:2]))
    rld_bs_score = round(max(-100.0, min(100.0, weighted_chdl * 0.7 + weighted_macd * 0.3 + (12.0 if one_line else 0.0))), 2)
    if rld_bs_score >= 25:
        side = "buy"
        reasons.append("多周期合成分偏多")
    elif rld_bs_score <= -25:
        side = "sell"
        reasons.append("多周期合成分偏空")
    else:
        side = "neutral"
        reasons.append("多周期分歧较大，维持中性")
    if one_line:
        reasons.append("三周期同向且最近未见明显逆向破坏")
    if stupid_buy_bi:
        reasons.append("满足无脑买入（笔）模板")
    if stupid_buy_seg:
        reasons.append("满足无脑买入（线段）模板")
    return {
        "weighted_chdl": round(weighted_chdl, 2),
        "three_macd": round(weighted_macd, 2),
        "one_line": one_line,
        "stupid_buy_bi": stupid_buy_bi,
        "stupid_buy_seg": stupid_buy_seg,
        "rld_bs": {"side": side, "score": rld_bs_score, "reasons": reasons},
        "weights": list(weights),
    }


def build_level_matrix(level_snapshots: list[dict[str, Any]], aggregate: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    metrics = [
        ("趋势", lambda item: item["summary"]["trend_label"]),
        ("BSP", lambda item: item["summary"]["latest_bsp"]["display_label"] if item["summary"]["latest_bsp"] else "无"),
        ("ZS状态", lambda item: f"{item['summary']['zs_state']['kind']}{item['summary']['zs_state']['label']}"),
        ("CHDL", lambda item: f"{item['summary']['chdl_score']:+.2f}"),
        ("MACD笔面积", lambda item: "-" if item["summary"]["macd_bi_area"] is None else f"{float(item['summary']['macd_bi_area']):.3f}"),
        ("MACD段面积", lambda item: "-" if item["summary"]["macd_seg_area"] is None else f"{float(item['summary']['macd_seg_area']):.3f}"),
        ("三级别MACD", lambda item: f"{item['summary']['macd_bias']:+.2f}"),
    ]
    for metric, getter in metrics:
        row = {"metric": metric}
        for item in level_snapshots:
            row[item["label"]] = getter(item)
        rows.append(row)
    rows.append({"metric": "一根筋", **{item["label"]: ("是" if aggregate["one_line"] else "否") for item in level_snapshots}})
    rows.append({"metric": "无脑买入(笔)", **{item["label"]: ("是" if aggregate["stupid_buy_bi"] else "否") for item in level_snapshots}})
    rows.append({"metric": "无脑买入(线段)", **{item["label"]: ("是" if aggregate["stupid_buy_seg"] else "否") for item in level_snapshots}})
    rows.append({"metric": "RLD_BS", **{item["label"]: f"{aggregate['rld_bs']['side']} {aggregate['rld_bs']['score']:+.2f}" for item in level_snapshots}})
    return rows


def analyze_rld_chan(chan: ReplayMultiLvChan, effective_cfg_dict: dict[str, Any], strategy_config: Optional[dict[str, Any]] = None, *, include_chart: bool = True) -> dict[str, Any]:
    level_snapshots: list[dict[str, Any]] = []
    normalized_strategy = normalize_strategy_config(strategy_config, list(chan.lv_list))
    macd_cfg = effective_cfg_dict.get("macd") if isinstance(effective_cfg_dict.get("macd"), dict) else {}
    for lv in chan.lv_list:
        kl_list = chan[lv]
        chart, summary = build_level_chart_payload(kl_list, effective_cfg_dict.get("chan_algo", CHAN_ALGO_CLASSIC), macd_cfg)
        level_snapshots.append(
            {
                "level": kl_type_to_name(lv),
                "label": kl_type_to_label(lv),
                "chart": chart if include_chart else None,
                "summary": summary,
                "last_time": chart["kline"][-1]["t"] if chart["kline"] else "-",
                "last_price": chart["kline"][-1]["c"] if chart["kline"] else None,
            }
        )
    aggregate = build_rld_summary(level_snapshots, normalized_strategy)
    return {
        "levels": level_snapshots,
        "aggregate": aggregate,
        "level_matrix": build_level_matrix(level_snapshots, aggregate),
        "strategy_config": normalized_strategy,
    }


def parse_watchlist_codes(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        candidates = raw
    else:
        candidates = re.findall(r"\d{6}", str(raw))
    normalized: list[str] = []
    seen: set[str] = set()
    for item in candidates:
        try:
            code = normalize_code(str(item)[-6:])
        except Exception:
            continue
        if code not in seen:
            normalized.append(code)
            seen.add(code)
    return normalized


def resolve_watchlist_or_sector(raw: Any, *, limit: int = 18) -> tuple[list[str], str]:
    codes = parse_watchlist_codes(raw)
    if codes:
        return codes[:limit], "manual"
    name = str(raw or "").strip()
    if not name:
        return [], "empty"
    loaders = [
        ("概念板块", getattr(ak, "stock_board_concept_cons_em", None)),
        ("行业板块", getattr(ak, "stock_board_industry_cons_em", None)),
    ]
    for label, loader in loaders:
        if loader is None:
            continue
        try:
            df = loader(symbol=name)
            if df is None or df.empty:
                continue
            code_col = next((col for col in ["代码", "code", "证券代码", "股票代码"] if col in df.columns), None)
            if code_col is None:
                continue
            resolved = parse_watchlist_codes(df[code_col].astype(str).tolist())
            if resolved:
                return resolved[:limit], label
        except Exception:
            continue
    return [], "unknown"


def compact_reasons(reasons: list[str], *, limit: int = 5) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for reason in reasons:
        text = str(reason or "").strip()
        if not text or text in seen:
            continue
        seen.add(text)
        result.append(text)
        if len(result) >= limit:
            break
    return result


def build_matrix_row(code: str, payload: dict[str, Any], *, stock_name: Optional[str] = None) -> dict[str, Any]:
    levels = payload["analysis"]["levels"]
    agg = payload["analysis"]["aggregate"]
    row = {
        "code": code,
        "name": stock_name,
        "rotation_score": round((agg["weighted_chdl"] * 0.55) + (agg["three_macd"] * 0.25) + (20.0 if agg["one_line"] else 0.0), 2),
        "chdl": agg["weighted_chdl"],
        "three_macd": agg["three_macd"],
        "one_line": agg["one_line"],
        "stupid_buy_bi": agg["stupid_buy_bi"],
        "stupid_buy_seg": agg["stupid_buy_seg"],
        "rld_bs_side": agg["rld_bs"]["side"],
        "rld_bs_score": agg["rld_bs"]["score"],
    }
    for idx, level in enumerate(levels):
        prefix = f"lv{idx + 1}"
        row[f"{prefix}_name"] = level["label"]
        row[f"{prefix}_trend"] = level["summary"]["trend_label"]
        row[f"{prefix}_bsp"] = level["summary"]["latest_bsp"]["display_label"] if level["summary"]["latest_bsp"] else "无"
        row[f"{prefix}_zs"] = f"{level['summary']['zs_state']['kind']}{level['summary']['zs_state']['label']}"
        row[f"{prefix}_chdl"] = level["summary"]["chdl_score"]
    row["reasons"] = compact_reasons(list(agg["rld_bs"]["reasons"]))
    return row


def evaluate_entry_rule(rule: str, analysis: dict[str, Any]) -> bool:
    agg = analysis["aggregate"]
    top = analysis["levels"][0]["summary"] if analysis["levels"] else {}
    rule = str(rule or "").strip().lower()
    if rule == "rld_bs_buy":
        return agg["rld_bs"]["side"] == "buy"
    if rule == "one_line":
        return bool(agg["one_line"])
    if rule == "stupid_buy_bi":
        return bool(agg["stupid_buy_bi"])
    if rule == "stupid_buy_seg":
        return bool(agg["stupid_buy_seg"])
    if rule == "bsp_buy":
        return bool(top.get("latest_bsp") and top["latest_bsp"].get("is_buy"))
    if rule == "zs_breakout_up":
        return int(top.get("zs_state", {}).get("bias", 0)) > 0
    if rule == "chdl_ge_20":
        return float(agg["weighted_chdl"]) >= 20.0
    if rule == "chdl_ge_40":
        return float(agg["weighted_chdl"]) >= 40.0
    return False


def evaluate_exit_rule(rule: str, analysis: dict[str, Any], *, pnl_pct: Optional[float] = None) -> bool:
    agg = analysis["aggregate"]
    top = analysis["levels"][0]["summary"] if analysis["levels"] else {}
    rule = str(rule or "").strip().lower()
    if rule == "rld_bs_sell":
        return agg["rld_bs"]["side"] == "sell"
    if rule == "trend_down":
        return int(top.get("trend_sign", 0)) < 0
    if rule == "bsp_sell":
        return bool(top.get("latest_bsp") and not top["latest_bsp"].get("is_buy"))
    if rule == "chdl_le_-20":
        return float(agg["weighted_chdl"]) <= -20.0
    if rule == "chdl_le_-40":
        return float(agg["weighted_chdl"]) <= -40.0
    if rule == "take_profit_8":
        return pnl_pct is not None and pnl_pct >= 0.08
    if rule == "stop_loss_5":
        return pnl_pct is not None and pnl_pct <= -0.05
    return False


def evaluate_rules(rule_ids: list[str], analysis: dict[str, Any], *, logic: str, pnl_pct: Optional[float] = None, exit_mode: bool = False) -> bool:
    if not rule_ids:
        return False
    results = []
    for rule in rule_ids:
        if exit_mode:
            results.append(evaluate_exit_rule(rule, analysis, pnl_pct=pnl_pct))
        else:
            results.append(evaluate_entry_rule(rule, analysis))
    mode = str(logic or "and").strip().lower()
    return all(results) if mode == "and" else any(results)


def compute_max_drawdown(points: list[dict[str, Any]]) -> float:
    if not points:
        return 0.0
    peak = float(points[0]["equity"])
    max_dd = 0.0
    for point in points:
        equity = float(point["equity"])
        if equity > peak:
            peak = equity
        if peak > 1e-9:
            max_dd = min(max_dd, (equity - peak) / peak)
    return round(max_dd, 4)


def run_backtest_for_code(
    session: RldDataSession,
    chan_config: dict[str, Any],
    strategy_config: dict[str, Any],
    entry_rules: list[str],
    exit_rules: list[str],
    *,
    logic: str,
    fee: float,
    slippage: float,
) -> dict[str, Any]:
    chan, effective_cfg_dict = session.build_chan(chan_config, trigger_step=True)
    iterator = chan.step_load()
    top_lv = session.lv_list[0]
    top_master = session.replay_klus_map[top_lv]
    cash = 100000.0
    position = 0
    avg_cost = 0.0
    buy_idx: Optional[int] = None
    pending_order: Optional[dict[str, Any]] = None
    trades: list[dict[str, Any]] = []
    equity_curve: list[dict[str, Any]] = []
    wins = 0
    losses = 0
    while True:
        try:
            next(iterator)
        except StopIteration:
            break
        current_klu = chan[top_lv].lst[-1].lst[-1]
        current_idx = int(current_klu.idx)
        if pending_order and int(pending_order["execute_idx"]) == current_idx:
            open_price = float(current_klu.open)
            if pending_order["side"] == "buy" and position <= 0:
                exec_price = open_price * (1.0 + slippage)
                hand_cost = exec_price * 100 * (1.0 + fee)
                hands = int(cash // hand_cost)
                if hands > 0:
                    shares = hands * 100
                    gross = exec_price * shares
                    commission = gross * fee
                    cash -= gross + commission
                    position = shares
                    avg_cost = exec_price
                    buy_idx = current_idx
                    trades.append({"side": "buy", "idx": current_idx, "time": current_klu.time.to_str(), "price": round(exec_price, 4), "shares": shares, "reason": list(pending_order.get("reasons", []))})
            elif pending_order["side"] == "sell" and position > 0:
                exec_price = open_price * (1.0 - slippage)
                gross = exec_price * position
                commission = gross * fee
                pnl = gross - commission - position * avg_cost
                pnl_pct = pnl / (position * avg_cost) if position * avg_cost > 1e-9 else 0.0
                cash += gross - commission
                trades.append({"side": "sell", "idx": current_idx, "time": current_klu.time.to_str(), "price": round(exec_price, 4), "shares": position, "pnl": round(pnl, 2), "pnl_pct": round(pnl_pct, 4), "reason": list(pending_order.get("reasons", []))})
                if pnl >= 0:
                    wins += 1
                else:
                    losses += 1
                position = 0
                avg_cost = 0.0
                buy_idx = None
            pending_order = None

        analysis = analyze_rld_chan(chan, effective_cfg_dict, strategy_config, include_chart=False)
        current_close = float(current_klu.close)
        equity_curve.append({"idx": current_idx, "time": current_klu.time.to_str(), "equity": round(cash + position * current_close, 2)})

        if current_idx >= len(top_master) - 1 or pending_order is not None:
            continue
        pnl_pct = None
        if position > 0 and avg_cost > 1e-9:
            pnl_pct = (current_close - avg_cost) / avg_cost
        if position > 0:
            can_sell = buy_idx is None or current_idx >= buy_idx + 1
            if can_sell and evaluate_rules(exit_rules, analysis, logic=logic, pnl_pct=pnl_pct, exit_mode=True):
                pending_order = {"side": "sell", "execute_idx": current_idx + 1, "reasons": compact_reasons(list(analysis["aggregate"]["rld_bs"]["reasons"]))}
        else:
            if evaluate_rules(entry_rules, analysis, logic=logic, exit_mode=False):
                pending_order = {"side": "buy", "execute_idx": current_idx + 1, "reasons": compact_reasons(list(analysis["aggregate"]["rld_bs"]["reasons"]))}

    if position > 0 and top_master:
        last_klu = top_master[-1]
        exit_price = float(last_klu.close) * (1.0 - slippage)
        gross = exit_price * position
        commission = gross * fee
        pnl = gross - commission - position * avg_cost
        pnl_pct = pnl / (position * avg_cost) if position * avg_cost > 1e-9 else 0.0
        cash += gross - commission
        trades.append({"side": "sell", "idx": int(last_klu.idx), "time": last_klu.time.to_str(), "price": round(exit_price, 4), "shares": position, "pnl": round(pnl, 2), "pnl_pct": round(pnl_pct, 4), "reason": ["回测结束强制平仓"]})
        if pnl >= 0:
            wins += 1
        else:
            losses += 1

    completed = sum(1 for item in trades if item["side"] == "sell")
    total_return = (cash - 100000.0) / 100000.0
    pnl_values = [float(item.get("pnl", 0.0)) for item in trades if item["side"] == "sell"]
    gross_profit = sum(value for value in pnl_values if value > 0)
    gross_loss = -sum(value for value in pnl_values if value < 0)
    profit_factor = gross_profit / gross_loss if gross_loss > 1e-9 else None
    return {
        "code": session.code,
        "name": session.stock_name,
        "trade_count": completed,
        "win_rate": round((wins / completed) if completed > 0 else 0.0, 4),
        "return": round(total_return, 4),
        "max_drawdown": compute_max_drawdown(equity_curve),
        "profit_factor": round(profit_factor, 4) if profit_factor is not None else None,
        "equity_curve": equity_curve,
        "trades": trades,
    }


class RldInitReq(BaseModel):
    code: str
    begin_date: str
    end_date: Optional[str] = None
    autype: str = "qfq"
    lv_list: Optional[list[str]] = None
    chan_config: Optional[dict[str, Any]] = None
    strategy_config: Optional[dict[str, Any]] = None
    watchlist_or_sector: Optional[str] = None


class RldMatrixReq(BaseModel):
    codes: Optional[list[str]] = None
    watchlist_or_sector: Optional[str] = None


class RldBacktestReq(BaseModel):
    codes: Optional[list[str]] = None
    watchlist_or_sector: Optional[str] = None
    entry_rules: list[str] = Field(default_factory=list)
    exit_rules: list[str] = Field(default_factory=list)
    logic: str = "and"
    execution_mode: str = "next_open"
    fee: float = 0.001
    slippage: float = 0.0005


class RldReconfigReq(BaseModel):
    chan_config: Optional[dict[str, Any]] = None
    strategy_config: Optional[dict[str, Any]] = None
    watchlist_or_sector: Optional[str] = None
    lv_list: Optional[list[str]] = None


class RldAppState:
    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.ready = False
        self.session: Optional[RldDataSession] = None
        self.chan: Optional[ReplayMultiLvChan] = None
        self.effective_cfg_dict: dict[str, Any] = {}
        self.analysis: Optional[dict[str, Any]] = None
        self.session_params: Optional[dict[str, Any]] = None
        self.matrix_rows: list[dict[str, Any]] = []
        self.matrix_meta: dict[str, Any] = {}
        self.backtest_result: Optional[dict[str, Any]] = None

    def init(self, req: RldInitReq) -> None:
        autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
        autype = autype_map.get(str(req.autype).lower(), AUTYPE.QFQ)
        code = normalize_code(req.code)
        lv_list = normalize_rld_lv_list(req.lv_list)
        self.session = RldDataSession.load(code, req.begin_date, req.end_date, autype, lv_list)
        self.chan, self.effective_cfg_dict = self.session.build_chan(req.chan_config, trigger_step=False)
        self.analysis = analyze_rld_chan(self.chan, self.effective_cfg_dict, req.strategy_config, include_chart=True)
        self.session_params = {
            "code": code,
            "begin_date": req.begin_date,
            "end_date": req.end_date,
            "autype": autype,
            "lv_list": lv_list,
            "chan_config": req.chan_config or {},
            "strategy_config": req.strategy_config or {},
            "watchlist_or_sector": req.watchlist_or_sector,
        }
        self.ready = True
        self.matrix_rows = []
        self.matrix_meta = {}
        self.backtest_result = None

    def reconfig(self, req: RldReconfigReq) -> None:
        if not self.ready or self.session is None or self.session_params is None:
            raise ValueError("请先初始化融立得工作台")
        lv_list = normalize_rld_lv_list(req.lv_list) if req.lv_list else list(self.session.lv_list)
        if lv_list != self.session.lv_list:
            self.session = RldDataSession.load(self.session.code, self.session.begin_date, self.session.end_date, self.session.autype, lv_list)
        chan_config = req.chan_config if req.chan_config is not None else self.session_params.get("chan_config", {})
        strategy_config = req.strategy_config if req.strategy_config is not None else self.session_params.get("strategy_config", {})
        watchlist_or_sector = req.watchlist_or_sector if req.watchlist_or_sector is not None else self.session_params.get("watchlist_or_sector")
        self.chan, self.effective_cfg_dict = self.session.build_chan(chan_config, trigger_step=False)
        self.analysis = analyze_rld_chan(self.chan, self.effective_cfg_dict, strategy_config, include_chart=True)
        self.session_params.update({"lv_list": lv_list, "chan_config": chan_config, "strategy_config": strategy_config, "watchlist_or_sector": watchlist_or_sector})
        self.matrix_rows = []
        self.matrix_meta = {}
        self.backtest_result = None

    def build_payload(self) -> dict[str, Any]:
        if not self.ready or self.session is None or self.analysis is None:
            return {"ready": False, "message": "请先加载融立得工作台"}
        levels = []
        for snapshot in self.analysis["levels"]:
            item = {"level": snapshot["level"], "label": snapshot["label"], "summary": snapshot["summary"]}
            if snapshot["chart"] is not None:
                item["chart"] = snapshot["chart"]
            levels.append(item)
        return {
            "ready": True,
            "code": self.session.code,
            "name": self.session.stock_name,
            "begin_date": self.session.begin_date,
            "end_date": self.session.end_date,
            "lv_list": [kl_type_to_name(lv) for lv in self.session.lv_list],
            "lv_labels": [kl_type_to_label(lv) for lv in self.session.lv_list],
            "data_source": {"levels": dict(self.session.source_map), "logs": list(self.session.logs)},
            "analysis": {"levels": levels, "aggregate": self.analysis["aggregate"], "level_matrix": self.analysis["level_matrix"], "strategy_config": self.analysis["strategy_config"]},
            "matrix": {"rows": self.matrix_rows, "meta": self.matrix_meta},
            "backtest": self.backtest_result,
        }

    def _require_ready(self) -> None:
        if not self.ready or self.session is None or self.analysis is None or self.session_params is None:
            raise ValueError("请先初始化融立得工作台")

    def build_matrix(self, req: Optional[RldMatrixReq] = None) -> dict[str, Any]:
        self._require_ready()
        assert self.session_params is not None
        codes = parse_watchlist_codes(req.codes) if req and req.codes else []
        source_kind = "manual"
        if not codes:
            source_value = req.watchlist_or_sector if req and req.watchlist_or_sector is not None else self.session_params.get("watchlist_or_sector")
            codes, source_kind = resolve_watchlist_or_sector(source_value)
        if not codes:
            codes = [self.session.code]
            source_kind = "current"
        rows: list[dict[str, Any]] = []
        failures: list[str] = []
        for code in codes:
            try:
                if self.session and code == self.session.code:
                    payload = self.build_payload()
                    rows.append(build_matrix_row(code, payload, stock_name=self.session.stock_name))
                    continue
                session = RldDataSession.load(
                    code,
                    self.session_params["begin_date"],
                    self.session_params["end_date"],
                    self.session_params["autype"],
                    list(self.session_params["lv_list"]),
                )
                chan, effective_cfg_dict = session.build_chan(self.session_params.get("chan_config"), trigger_step=False)
                analysis = analyze_rld_chan(chan, effective_cfg_dict, self.session_params.get("strategy_config"), include_chart=False)
                rows.append(
                    build_matrix_row(
                        code,
                        {
                            "analysis": analysis,
                        },
                        stock_name=session.stock_name,
                    )
                )
            except Exception as exc:
                failures.append(f"{code}:{format_source_error(exc)}")
        rows.sort(key=lambda item: float(item.get("rotation_score", 0.0)), reverse=True)
        avg_chdl = sum(float(item.get("chdl", 0.0)) for item in rows) / len(rows) if rows else 0.0
        buy_breadth = (sum(1 for item in rows if item.get("rld_bs_side") == "buy") / len(rows)) if rows else 0.0
        macd_breadth = (sum(1 for item in rows if float(item.get("three_macd", 0.0)) > 0.0) / len(rows)) if rows else 0.0
        self.matrix_rows = rows
        self.matrix_meta = {
            "source_kind": source_kind,
            "count": len(rows),
            "avg_chdl": round(avg_chdl, 2),
            "buy_breadth": round(buy_breadth, 4),
            "macd_breadth": round(macd_breadth, 4),
            "failures": failures,
        }
        return {"rows": self.matrix_rows, "meta": self.matrix_meta}

    def run_backtest(self, req: RldBacktestReq) -> dict[str, Any]:
        self._require_ready()
        assert self.session_params is not None
        codes = parse_watchlist_codes(req.codes) if req.codes else []
        if not codes:
            source_value = req.watchlist_or_sector if req.watchlist_or_sector is not None else self.session_params.get("watchlist_or_sector")
            codes, _ = resolve_watchlist_or_sector(source_value, limit=12)
        if not codes:
            codes = [self.session.code]
        entry_rules = req.entry_rules or list(RLD_ENTRY_RULES_DEFAULT)
        exit_rules = req.exit_rules or list(RLD_EXIT_RULES_DEFAULT)
        logic = str(req.logic or "and").strip().lower()
        if logic not in {"and", "or"}:
            logic = "and"
        fee = max(0.0, float(req.fee or 0.0))
        slippage = max(0.0, float(req.slippage or 0.0))
        rows: list[dict[str, Any]] = []
        curves: list[dict[str, Any]] = []
        trades: list[dict[str, Any]] = []
        failures: list[str] = []
        for code in codes:
            try:
                session = self.session if self.session and code == self.session.code else RldDataSession.load(
                    code,
                    self.session_params["begin_date"],
                    self.session_params["end_date"],
                    self.session_params["autype"],
                    list(self.session_params["lv_list"]),
                )
                result = run_backtest_for_code(
                    session,
                    self.session_params.get("chan_config", {}),
                    self.session_params.get("strategy_config", {}),
                    entry_rules,
                    exit_rules,
                    logic=logic,
                    fee=fee,
                    slippage=slippage,
                )
                rows.append(
                    {
                        "code": result["code"],
                        "name": result.get("name"),
                        "trade_count": result["trade_count"],
                        "return": result["return"],
                        "max_drawdown": result["max_drawdown"],
                        "win_rate": result["win_rate"],
                        "profit_factor": result["profit_factor"],
                    }
                )
                curves.append({"code": result["code"], "name": result.get("name"), "points": result["equity_curve"]})
                for item in result["trades"]:
                    trade_item = {"code": result["code"], "name": result.get("name"), **item}
                    trades.append(trade_item)
            except Exception as exc:
                failures.append(f"{code}:{format_source_error(exc)}")
        avg_return = sum(float(item.get("return", 0.0)) for item in rows) / len(rows) if rows else 0.0
        avg_mdd = sum(float(item.get("max_drawdown", 0.0)) for item in rows) / len(rows) if rows else 0.0
        self.backtest_result = {
            "params": {
                "entry_rules": entry_rules,
                "exit_rules": exit_rules,
                "logic": logic,
                "execution_mode": "next_open",
                "fee": fee,
                "slippage": slippage,
            },
            "summary": {
                "count": len(rows),
                "avg_return": round(avg_return, 4),
                "avg_max_drawdown": round(avg_mdd, 4),
                "failures": failures,
            },
            "rows": rows,
            "equity_curves": curves,
            "trades": trades[:200],
        }
        return self.backtest_result

