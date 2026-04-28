from .a_core import *

@dataclass
class PaperAccount:
    initial_cash: float
    cash: float
    position: int = 0
    avg_cost: float = 0.0
    last_buy_step: Optional[int] = None
    last_trade_step: Optional[int] = None

    def reset(self, initial_cash: float) -> None:
        self.initial_cash = initial_cash
        self.cash = initial_cash
        self.position = 0
        self.avg_cost = 0.0
        self.last_buy_step = None
        self.last_trade_step = None

    def buy_with_all_cash(self, price: float, step_idx: int) -> dict[str, Any]:
        if self.position > 0:
            raise ValueError("当前已有持仓，需先卖出全部再买入。")
        if self.last_trade_step == step_idx:
            raise ValueError("每一步最多允许一笔成交。")
        hand_cost = price * 100
        hands = int(self.cash // hand_cost)
        if hands <= 0:
            raise ValueError("余额不足一手。")
        cost = hands * hand_cost
        if cost > self.cash + 1e-8:
            raise ValueError("余额不足。")
        self.cash -= cost
        self.position = hands * 100
        self.avg_cost = price
        self.last_buy_step = step_idx
        self.last_trade_step = step_idx
        return {"hands": hands, "shares": self.position, "cost": round(cost, 2)}

    def can_sell(self, step_idx: int) -> bool:
        if self.position <= 0:
            return False
        if self.last_buy_step is None:
            return False
        return step_idx >= self.last_buy_step + 1

    def sell_all(self, price: float, step_idx: int) -> dict[str, Any]:
        if self.position <= 0:
            return {"noop": True, "message": "当前无持仓。"}
        if self.last_trade_step == step_idx:
            raise ValueError("每一步最多允许一笔成交。")
        if not self.can_sell(step_idx):
            raise ValueError("受T+1限制，下一根K线后才能卖出。")
        shares = self.position
        proceeds = shares * price
        pnl = (price - self.avg_cost) * shares
        self.cash += proceeds
        self.position = 0
        self.avg_cost = 0.0
        self.last_buy_step = None
        self.last_trade_step = step_idx
        return {
            "shares": shares,
            "proceeds": round(proceeds, 2),
            "pnl": round(pnl, 2),
        }

    def equity(self, price: float) -> float:
        return self.cash + self.position * price


class ChanStepper:
    def __init__(self) -> None:
        self.chan: Optional[CChan] = None
        self._iter = None
        self.step_idx = -1
        self.code = ""
        self.chan_algo = CHAN_ALGO_CLASSIC
        self.effective_cfg_dict: dict[str, Any] = {}
        # Full history K-lines (used by chip distribution).
        self.kline_all: list[dict[str, Any]] = []
        self.indicators = {
            "macd": CMACD(),
            "kdj": KDJ(),
            "rsi": RSI(),
            "boll": BollModel(),
            "demark": CDemarkEngine(),
        }
        self.indicator_history = []
        self.trend_lines = []
        # 会话级行情缓存：同一股票代码与日期区间下只拉取一次，缠论/BSP 配置变更时仅重算结构。
        self._data_session_key: Optional[tuple[Any, ...]] = None
        self._replay_klus_master: Optional[list] = None
        self.data_src_used: Any = None
        self.data_src_logs: list[str] = []
        self.stock_name: Optional[str] = None
        self.structure_bundle: Optional[ChanStructureBundle] = None
        self._bundle_cache_step_idx: Optional[int] = None

    def _cfg_without_chan_algo(self, cfg_dict: dict[str, Any]) -> dict[str, Any]:
        return {k: v for k, v in cfg_dict.items() if k != "chan_algo"}

    def _fetch_from_single_source(
        self,
        data_src: Any,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_cfg_dict: dict[str, Any],
    ) -> tuple[list, list[dict[str, Any]], Optional[str]]:
        selection = select_runtime_data_source_for_level(
            code=self.code,
            begin_date=begin_date,
            end_date=end_date,
            autype=autype,
            lv=KL_TYPE.K_DAY,
        )
        replay_klus_master = selection.items
        stock_name = selection.stock_name
        chip_begin_date = "1990-01-01"
        try:
            chip_selection = select_runtime_data_source_for_level(
                code=self.code,
                begin_date=chip_begin_date,
                end_date=end_date,
                autype=autype,
                lv=KL_TYPE.K_DAY,
            )
            kline_all = serialize_klu_iter(chip_selection.items)
        except Exception:
            kline_all = serialize_klu_iter(replay_klus_master)
        return replay_klus_master, kline_all, stock_name

    def _select_data_source_with_fallback(
        self,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_cfg_dict: dict[str, Any],
    ) -> DataSourceSelection:
        logs: list[str] = []
        errors: list[str] = []
        for idx, (label, data_src) in enumerate(get_data_source_chain()):
            print(f"[DataSource] try {label} for {self.code} {begin_date} -> {end_date or 'latest'}")
            try:
                replay_klus_master, kline_all, stock_name = self._fetch_from_single_source(data_src, begin_date, end_date, autype, chan_cfg_dict)
                if idx == 0:
                    logs.append(f"数据源已连接：{label}")
                else:
                    logs.append(f"数据源切换成功：{label}（前序源不可用，已自动降级）")
                print(f"[DataSource] selected {label}")
                return DataSourceSelection(
                    data_src=data_src,
                    label=label,
                    logs=logs + errors,
                    replay_klus_master=replay_klus_master,
                    kline_all=kline_all,
                    stock_name=stock_name,
                )
            except Exception as exc:
                detail = format_source_error(exc)
                errors.append(f"{label} 失败：{detail}")
                logs.append(f"数据源尝试失败：{label}")
                print(f"[DataSource] failed {label}: {detail}")
        raise RuntimeError("全部数据源均不可用：" + "；".join(errors))

    def _select_runtime_data_source_with_fallback(
        self,
        begin_date: str,
        end_date: Optional[str],
        autype: AUTYPE,
        chan_cfg_dict: dict[str, Any],
    ) -> DataSourceSelection:
        selection = select_runtime_data_source_for_level(
            code=self.code,
            begin_date=begin_date,
            end_date=end_date,
            autype=autype,
            lv=KL_TYPE.K_DAY,
        )
        replay_klus_master, kline_all, stock_name = self._fetch_from_single_source(
            selection.data_src,
            begin_date,
            end_date,
            autype,
            chan_cfg_dict,
        )
        return DataSourceSelection(
            data_src=selection.data_src,
            label=selection.label,
            logs=list(selection.logs),
            replay_klus_master=replay_klus_master,
            kline_all=kline_all,
            stock_name=stock_name,
        )

    def get_structure_bundle(self, *, force: bool = False, chan: Optional[CChan] = None) -> ChanStructureBundle:
        target_chan = chan or self.chan
        if target_chan is None:
            raise ValueError("会话未初始化")
        if chan is None and not force and self.structure_bundle is not None and self._bundle_cache_step_idx == self.step_idx:
            return self.structure_bundle
        bundle = build_structure_bundle(target_chan, self.chan_algo)
        if chan is None:
            self.structure_bundle = bundle
            self._bundle_cache_step_idx = self.step_idx
            self.trend_lines = list(bundle.trend_lines)
        return bundle

    def init(self, code: str, begin_date: str, end_date: Optional[str], autype: AUTYPE, chan_config: Optional[dict[str, Any]] = None) -> None:
        cfg_dict = {
            "chan_algo": CHAN_ALGO_CLASSIC,
            "bi_strict": True,
            "bi_algo": "normal",
            "bi_fx_check": "strict",
            "gap_as_kl": False,
            "bi_end_is_peak": True,
            "bi_allow_sub_peak": True,
            "seg_algo": "chan",
            "left_seg_method": "peak",
            "zs_combine": True,
            "zs_combine_mode": "zs",
            "one_bi_zs": False,
            "zs_algo": "normal",
            "trigger_step": True,
            "skip_step": 0,
            "kl_data_check": True,
            "print_warning": False,
            "print_err_time": False,
            # BSP defaults
            "divergence_rate": float("inf"),
            "min_zs_cnt": 1,
            "bsp1_only_multibi_zs": True,
            "max_bs2_rate": 0.9999,
            "macd_algo": "peak",
            "bs1_peak": True,
            "bs_type": "1,1p,2,2s,3a,3b",
            "bsp2_follow_1": True,
            "bsp3_follow_1": True,
            "bsp3_peak": False,
            "bsp2s_follow_2": False,
            "max_bsp2s_lv": None,
            "strict_bsp3": False,
            "bsp3a_max_zs_cnt": 1,
        }
        if chan_config:
            for k, v in chan_config.items():
                if v is not None and v != "":
                    if k in ["divergence_rate", "max_bs2_rate"]:
                        try:
                            cfg_dict[k] = float(v)
                        except (ValueError, TypeError):
                            if isinstance(v, str) and v.lower() == "inf":
                                cfg_dict[k] = float("inf")
                    elif k in ["min_zs_cnt", "bsp3a_max_zs_cnt", "boll_n", "rsi_cycle", "kdj_cycle", "skip_step"]:
                        try:
                            cfg_dict[k] = int(v)
                        except (ValueError, TypeError):
                            pass
                    elif k == "macd" and isinstance(v, dict):
                        macd_dict = cfg_dict.get("macd", {"fast": 12, "slow": 26, "signal": 9}).copy()
                        for mk, mv in v.items():
                            if mv is not None and mv != "":
                                try:
                                    macd_dict[mk] = int(mv)
                                except (ValueError, TypeError):
                                    pass
                        cfg_dict["macd"] = macd_dict
                    else:
                        cfg_dict[k] = v

        self.chan_algo = normalize_chan_algo(cfg_dict.get("chan_algo"))
        cfg_dict["chan_algo"] = self.chan_algo
        self.effective_cfg_dict = cfg_dict.copy()
        chan_cfg_dict = self._cfg_without_chan_algo(cfg_dict)
        cfg = CChanConfig(chan_cfg_dict)
        self.code = normalize_code(code)
        self.stock_name = None
        session_key = (self.code, begin_date, end_date, autype)
        cache_hit = session_key == self._data_session_key and self._replay_klus_master is not None

        if not cache_hit:
            selection = self._select_runtime_data_source_with_fallback(begin_date, end_date, autype, chan_cfg_dict)
            self._replay_klus_master = selection.replay_klus_master
            self.kline_all = selection.kline_all
            self.data_src_used = selection.data_src
            self.data_src_logs = list(selection.logs)
            self._data_session_key = session_key
            if selection.stock_name:
                self.stock_name = selection.stock_name
        else:
            if self.data_src_logs:
                self.data_src_logs = [f"沿用已缓存数据源：{data_source_label(self.data_src_used)}"]

        self.chan = ReplayChan(
            code=self.code,
            begin_time=begin_date,
            end_time=end_date,
            data_src=self.data_src_used or DATA_SRC.BAO_STOCK,
            lv_list=[KL_TYPE.K_DAY],
            config=cfg,
            autype=autype,
            replay_klus_master=self._replay_klus_master,
        )
        self._iter = self.chan.step_load()
        self.step_idx = -1
        self.indicators = {
            "macd": CMACD(),
            "kdj": KDJ(),
            "rsi": RSI(),
            "boll": BollModel(),
            "demark": CDemarkEngine(),
        }
        self.indicator_history = []
        self.trend_lines = []
        self.structure_bundle = None
        self._bundle_cache_step_idx = None

    def step(self) -> bool:
        if self._iter is None:
            raise ValueError("请先初始化会话。")
        try:
            next(self._iter)
            self.step_idx += 1
            self.structure_bundle = None
            self._bundle_cache_step_idx = None
            # Update indicators
            kl_list = self.chan[0]
            latest_klu = kl_list.lst[-1].lst[-1]
            h, l, c = float(latest_klu.high), float(latest_klu.low), float(latest_klu.close)
            
            macd_item = self.indicators["macd"].add(c)
            kdj_item = self.indicators["kdj"].add(h, l, c)
            rsi_val = self.indicators["rsi"].add(c)
            boll_item = self.indicators["boll"].add(c)
            demark_idx = self.indicators["demark"].update(latest_klu.idx, c, h, l)
            
            # Extract current demark points
            demark_pts = []
            for item in demark_idx.data:
                demark_pts.append({
                    "type": item["type"],
                    "dir": "UP" if item["dir"].name == "UP" else "DOWN",
                    "val": item["idx"],
                    "x": item["idx_in_kl"] if "idx_in_kl" in item else latest_klu.idx # Fallback to current
                })

            self.indicator_history.append({
                "x": latest_klu.idx,
                "macd": {"dif": macd_item.DIF, "dea": macd_item.DEA, "macd": macd_item.macd},
                "kdj": {"k": kdj_item.k, "d": kdj_item.d, "j": kdj_item.j},
                "rsi": rsi_val,
                "boll": {"mid": boll_item.MID, "up": boll_item.UP, "down": boll_item.DOWN},
                "demark": demark_pts
            })
            
            # 新缠论/原缠论统一从 bundle 获取趋势线，避免前端与当前笔级别脱节。
            self.get_structure_bundle(force=True)
            return True
        except StopIteration:
            return False

    def current_price(self) -> float:
        if self.chan is None:
            raise ValueError("会话未初始化")
        kl_list = self.chan[0]
        if len(kl_list.lst) == 0:
            raise ValueError("当前无K线数据")
        return kl_list.lst[-1].lst[-1].close

    def current_time(self) -> str:
        if self.chan is None:
            return "-"
        kl_list = self.chan[0]
        if len(kl_list.lst) == 0:
            return "-"
        return kl_list.lst[-1].lst[-1].time.to_str()


class InitReq(BaseModel):
    code: str
    begin_date: str
    end_date: Optional[str] = None
    initial_cash: float = 10_000
    autype: str = "qfq"
    chan_config: Optional[dict[str, Any]] = None


class ReconfigReq(BaseModel):
    chan_config: dict[str, Any]


class BackNReq(BaseModel):
    n: int = 1


class StepReq(BaseModel):
    judge_mode: Optional[str] = None  # "auto" | "manual"


class JudgeBspReq(BaseModel):
    reason: str = "manual_check"


class AppState:
    def __init__(self) -> None:
        self.stepper = ChanStepper()
        self.account = PaperAccount(initial_cash=10_000, cash=10_000)
        self.ready = False
        self.finished = False
        self.session_params: Optional[dict[str, Any]] = None
        self.trade_events: list[dict[str, Any]] = []
        self.bsp_history: list[dict[str, Any]] = []
        # trigger_step==False 全量预计算的买卖点（基于当前缠论配置）
        self.bsp_all_snapshot: list[dict[str, Any]] = []
        # 用于检测各级别变向（不区分确定/不确定）
        self._last_level_dirs: dict[str, Optional[str]] = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        # 判定步骤后台记录
        self.bsp_judge_logs: list[dict[str, Any]] = []
        # 1382 节奏命中历史与去重缓存
        self.rhythm_hit_history: list[dict[str, Any]] = []
        self.rhythm_hit_keys: set[str] = set()
        self._rhythm_notice_hits: list[dict[str, Any]] = []
        # 本次 payload 是否需要弹窗提醒
        self._judge_notice: bool = False
        # 最近一次判定统计（用于 payload 弹窗展示）
        self._last_judge_stats: Optional[dict[str, Any]] = None
        # 上次判定位置（用于弹窗展示区间）
        self._last_judge_x: Optional[int] = None
        self._last_judge_time: Optional[str] = None

    def _reset_judge_state(self) -> None:
        self._judge_notice = False
        self._last_judge_stats = None
        self._last_judge_x = None
        self._last_judge_time = None
        self._rhythm_notice_hits = []

    def _reset_rhythm_history(self) -> None:
        self.rhythm_hit_history = []
        self.rhythm_hit_keys = set()
        self._rhythm_notice_hits = []

    def _current_level_dir(self, level: str) -> Optional[str]:
        if self.stepper.chan is None:
            return None
        bundle = self.stepper.get_structure_bundle()
        lines = get_bundle_line_list(bundle, level)
        if not lines:
            return None
        line = lines[-1]
        try:
            y1 = float(line.get_begin_val())
            y2 = float(line.get_end_val())
        except Exception:
            return None
        if y2 > y1:
            return "UP"
        if y2 < y1:
            return "DOWN"
        return None

    def rebuild_bsp_all_snapshot(self) -> None:
        """使用 trigger_step==False 一次性计算全量买卖点快照。"""
        self.bsp_all_snapshot = []
        self._reset_judge_state()
        if self.session_params is None:
            return
        if self.stepper._replay_klus_master is None:
            return
        cfg_dict = (self.stepper.effective_cfg_dict or {}).copy()
        cfg_dict["trigger_step"] = False
        cfg = CChanConfig(self.stepper._cfg_without_chan_algo(cfg_dict))
        chan_all = ReplayChan(
            code=self.stepper.code,
            begin_time=self.session_params["begin_date"],
            end_time=self.session_params["end_date"],
            data_src=self.stepper.data_src_used or DATA_SRC.BAO_STOCK,
            lv_list=[KL_TYPE.K_DAY],
            config=cfg,
            autype=self.session_params["autype"],
            replay_klus_master=self.stepper._replay_klus_master,
        )
        # 强制全量加载一次，生成笔/线段/中枢/买卖点
        for _ in chan_all.load(step=False):
            pass
        bundle = build_structure_bundle(chan_all, self.stepper.chan_algo)
        snapshot: list[dict[str, Any]] = []
        for level in VISIBLE_BSP_LEVELS:
            bsp_list = get_bundle_bsp_list(bundle, level)
            for bsp in bsp_list.bsp_iter():
                item = make_bsp_item(level, bsp)
                item["key"] = self._bsp_key(item)
                snapshot.append(item)
        self.bsp_all_snapshot = sorted(
            snapshot,
            key=lambda item: (int(item.get("x", -1)), LEVEL_ORDER.get(str(item.get("level")), 999), int(not bool(item.get("is_buy")))),
        )

    def _judge_bsp_against_all(self, *, reason: str, levels: Optional[list[str]] = None) -> None:
        """在当前步进位置，对照（全量预计算）与（步进触发快照）进行 ×/✓ 判定。"""
        current_x = self._current_kline_x()
        if current_x is None:
            return
        if not self.bsp_all_snapshot:
            return
        active_levels = [level for level in (levels or list(VISIBLE_BSP_LEVELS)) if level in VISIBLE_BSP_LEVELS]
        if not active_levels:
            return
        all_keys_upto = {str(it.get("key")) for it in self.bsp_all_snapshot if int(it.get("x", -1)) <= current_x}
        details: list[dict[str, Any]] = []
        summary = {"appeared": 0, "judged": 0, "correct": 0, "wrong": 0}
        for level in active_levels:
            pending_items: list[dict[str, Any]] = []
            correct = 0
            wrong = 0
            for item in self.bsp_history:
                x = int(item.get("x", -1))
                if str(item.get("level")) != level or x < 0 or x > current_x:
                    continue
                if item.get("status") is not None:
                    continue
                pending_items.append(item)
            for item in pending_items:
                if str(item.get("key")) in all_keys_upto:
                    item["status"] = "correct"
                    correct += 1
                else:
                    item["status"] = "wrong"
                    wrong += 1
            judged = len(pending_items)
            summary["appeared"] += judged
            summary["judged"] += judged
            summary["correct"] += correct
            summary["wrong"] += wrong
            details.append(
                {
                    "level": level,
                    "level_label": level_label(level),
                    "appeared": judged,
                    "judged": judged,
                    "correct": correct,
                    "wrong": wrong,
                    "rate": (correct / judged) if judged > 0 else None,
                }
            )

        rate = (summary["correct"] / summary["judged"]) if summary["judged"] > 0 else None
        cur_time = self.stepper.current_time() if self.stepper.chan is not None else "-"
        interval = {
            "from_x": self._last_judge_x,
            "to_x": int(current_x),
            "from_time": self._last_judge_time or "-",
            "to_time": cur_time,
        }
        stats = {
            "step_idx": int(self.stepper.step_idx),
            "x": int(current_x),
            "time": cur_time,
            "reason": reason,
            "appeared": summary["appeared"],
            "judged": summary["judged"],
            "correct": summary["correct"],
            "wrong": summary["wrong"],
            "rate": rate,
            "interval": interval,
            "summary": {**summary, "rate": rate},
            "details": details,
        }
        # 自动模式（线段变向）仅在确实发生判定时提示；手动检查则始终提示
        reason_s = str(reason or "")
        is_manual = "manual" in reason_s.lower()
        should_notice = summary["judged"] > 0 or is_manual
        self._judge_notice = bool(should_notice)
        self._last_judge_stats = stats if should_notice else None
        self.bsp_judge_logs.append(stats)
        # 更新“上次判定”区间锚点（无论是否弹窗，均视为一次检查点）
        self._last_judge_x = int(current_x)
        self._last_judge_time = cur_time

    def after_step_update(self) -> None:
        """每次步进后调用：检测上一级结构变向并触发三层买卖点判定。"""
        self._judge_notice = False
        self._last_judge_stats = None
        triggered_levels: list[str] = []
        reason_parts: list[str] = []
        for level in VISIBLE_BSP_LEVELS:
            trigger_level = JUDGE_TRIGGER_LEVELS[level]
            cur_dir = self._current_level_dir(trigger_level)
            last_dir = self._last_level_dirs.get(trigger_level)
            if last_dir is None:
                self._last_level_dirs[trigger_level] = cur_dir
                continue
            if cur_dir is None:
                continue
            if cur_dir != last_dir:
                triggered_levels.append(level)
                reason_parts.append(f"{level_label(level)}:{trigger_level}:{last_dir}->{cur_dir}")
            self._last_level_dirs[trigger_level] = cur_dir
        if triggered_levels:
            self._judge_bsp_against_all(reason="; ".join(reason_parts), levels=triggered_levels)

    def _current_kline_x(self) -> Optional[int]:
        if self.stepper.chan is None:
            return None
        kl_list = self.stepper.chan[0]
        if len(kl_list.lst) == 0:
            return None
        return int(kl_list.lst[-1].lst[-1].idx)

    def _build_trade_state(self) -> dict[str, Any]:
        history: list[dict[str, Any]] = []
        active: Optional[dict[str, Any]] = None
        for event in self.trade_events:
            if event.get("side") == "buy":
                active = {
                    "buyX": event.get("x"),
                    "buyPrice": float(event.get("price", 0.0)),
                    "shares": int(event.get("shares", 0)),
                    "sellX": None,
                    "sellPrice": None,
                }
            elif event.get("side") == "sell" and active is not None:
                history.append(
                    {
                        "buyX": active.get("buyX"),
                        "buyPrice": active.get("buyPrice"),
                        "shares": active.get("shares"),
                        "sellX": event.get("x"),
                        "sellPrice": float(event.get("price", 0.0)),
                    }
                )
                active = None
        return {"history": history, "active": active}

    def _current_bsp_snapshot(self) -> list[dict[str, Any]]:
        if self.stepper.chan is None:
            return []
        bundle = self.stepper.get_structure_bundle()
        snapshot: list[dict[str, Any]] = []
        for level in VISIBLE_BSP_LEVELS:
            bsp_list = get_bundle_bsp_list(bundle, level)
            for bsp in bsp_list.bsp_iter():
                snapshot.append(make_bsp_item(level, bsp))
        return sorted(snapshot, key=lambda item: (int(item["x"]), LEVEL_ORDER.get(item["level"], 999), int(not bool(item["is_buy"]))))

    @staticmethod
    def _bsp_key(item: dict[str, Any]) -> str:
        return f'{item["level"]}|{int(item["x"])}|{item["label"]}|{1 if item["is_buy"] else 0}'

    def sync_bsp_history(self) -> None:
        """同步当前步进下的买卖点历史。

        注意：×/✓ 判定不在这里做，而是在“上一级结构变向”时对照全量快照进行。
        """
        current_x = self._current_kline_x()
        if current_x is None:
            self.bsp_history = []
            return

        snapshot = self._current_bsp_snapshot()

        existing_keys = {str(item.get("key")) for item in self.bsp_history}
        for item in snapshot:
            if int(item["x"]) != current_x:
                continue
            key = self._bsp_key(item)
            if key in existing_keys:
                continue
            self.bsp_history.append(
                {
                    "key": key,
                    "x": int(item["x"]),
                    "is_buy": bool(item["is_buy"]),
                    "label": item["label"],
                    "level": item["level"],
                    "level_label": item["level_label"],
                    "display_label": item["display_label"],
                    "status": None,
                }
            )
            existing_keys.add(key)

    def sync_rhythm_history(self) -> None:
        current_x = self._current_kline_x()
        self._rhythm_notice_hits = []
        if current_x is None or self.stepper.chan is None:
            return
        bundle = self.stepper.get_structure_bundle()
        for item in bundle.rhythm_hits:
            if int(item.get("x", -1)) != current_x:
                continue
            key = str(item.get("key") or "")
            if not key or key in self.rhythm_hit_keys:
                continue
            history_item = {
                "key": key,
                "x": int(item["x"]),
                "y": float(item["y"]),
                "level": str(item["level"]),
                "parent_level": str(item.get("parent_level", "")),
                "parent_key": str(item.get("parent_key", "")),
                "display_label": str(item.get("display_label", "")),
                "round_ref": int(item.get("round_ref", 0)),
                "detail": str(item.get("detail", "")),
                "time": str(item.get("time", self.stepper.current_time())),
            }
            self.rhythm_hit_history.append(history_item)
            self.rhythm_hit_keys.add(key)
            self._rhythm_notice_hits.append(
                {
                    "key": key,
                    "display_label": history_item["display_label"],
                    "detail": history_item["detail"],
                    "x": history_item["x"],
                    "time": history_item["time"],
                }
            )

    def rebuild_to_step(self, target_step: int) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重建会话")
        params = self.session_params
        self.stepper.init(
            params["code"],
            params["begin_date"],
            params["end_date"],
            params["autype"],
            chan_config=params.get("chan_config"),
        )
        # Account reset is handled by the caller if needed (e.g. in reconfig)
        # but for back_n it should stay consistent with history.
        # However, rebuild_to_step is also used by back_n which needs to replay trades.
        self.ready = True
        self.finished = False
        self.bsp_history = []
        self._reset_rhythm_history()
        self._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        self._reset_judge_state()
        self.rebuild_bsp_all_snapshot()

        if not self.stepper.step():
            return
        self.sync_bsp_history()
        self.sync_rhythm_history()
        self.after_step_update()
        for _ in range(target_step):
            if not self.stepper.step():
                break
            self.sync_bsp_history()
            self.sync_rhythm_history()
            self.after_step_update()

        effective_step = max(0, self.stepper.step_idx)
        self.trade_events = [e for e in self.trade_events if int(e.get("step_idx", -1)) <= effective_step]
        self.account.reset(params["initial_cash"])
        for event in self.trade_events:
            side = event.get("side")
            price = float(event.get("price", 0.0))
            step_idx = int(event.get("step_idx", -1))
            try:
                if side == "buy":
                    self.account.buy_with_all_cash(price, step_idx)
                elif side == "sell":
                    self.account.sell_all(price, step_idx)
            except Exception:
                # Replay might fail if parameters changed drastically, but we try our best
                pass

    def reconfig(self, chan_config: dict[str, Any]) -> None:
        if self.session_params is None:
            raise ValueError("当前无可重配会话")
        
        # 1. Update session params
        self.session_params["chan_config"] = chan_config
        
        # 2. Clear simulation data (trades and account)
        self.trade_events = []
        self.account.reset(self.session_params["initial_cash"])
        
        # 3. Rebuild to current step
        target_step = self.stepper.step_idx
        self.rebuild_to_step(target_step)

    def build_payload(self, stock_name: Optional[str] = None) -> dict[str, Any]:
        if not self.ready or self.stepper.chan is None:
            return {
                "ready": False,
                "finished": self.finished,
                "message": "请先加载会话",
            }
        rhythm_notice_hits = list(self._rhythm_notice_hits)
        self._rhythm_notice_hits = []
        bundle = self.stepper.get_structure_bundle()
        chart = serialize_chan(
            self.stepper.chan,
            self.stepper.indicator_history,
            self.stepper.trend_lines,
            chan_algo=self.stepper.chan_algo,
            bundle=bundle,
            kline_all=self.stepper.kline_all,
        )
        price: Optional[float] = None
        if len(chart.get("kline", [])) > 0:
            price = self.stepper.current_price()
        return {
            "ready": True,
            "finished": self.finished,
            "code": self.stepper.code,
            "name": stock_name,
            "data_source": {
                "label": data_source_label(self.stepper.data_src_used),
                "logs": list(self.stepper.data_src_logs),
            },
            "chan_algo": self.stepper.chan_algo,
            "step_idx": self.stepper.step_idx,
            "time": self.stepper.current_time(),
            "price": price,
            "chart": chart,
            "bsp_history": self.bsp_history,
            "rhythm_notice_hits": rhythm_notice_hits,
            "judge_notice": bool(self._judge_notice),
            "judge_stats": self._last_judge_stats,
            "account": {
                "initial_cash": round(self.account.initial_cash, 2),
                "cash": round(self.account.cash, 2),
                "position": self.account.position,
                "avg_cost": round(self.account.avg_cost, 4),
                "equity": round(self.account.equity(price or 0.0), 2),
                "can_sell": bool(price is not None and self.account.can_sell(self.stepper.step_idx)),
            },
            "trades": self._build_trade_state(),
        }


def serialize_klu_iter(klu_iter) -> list[dict[str, Any]]:
    arr: list[dict[str, Any]] = []
    for klu in klu_iter:
        arr.append(
            {
                "x": klu.idx,
                "t": klu.time.to_str(),
                "o": float(klu.open),
                "h": float(klu.high),
                "l": float(klu.low),
                "c": float(klu.close),
                "v": float(getattr(klu, "volume", getattr(klu, "vol", 0.0)) or 0.0),
            }
        )
    return arr


def serialize_chan(
    chan: CChan,
    indicator_history: list,
    trend_lines: list,
    *,
    chan_algo: str = CHAN_ALGO_CLASSIC,
    bundle: Optional[ChanStructureBundle] = None,
    kline_all: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
    kl_list = chan[0]
    klu_arr = serialize_klu_iter(kl_list.klu_iter())
    active_bundle = bundle or build_structure_bundle(chan, chan_algo)
    fract_arr = serialize_line_collection(active_bundle.fract_list)
    bi_arr = serialize_line_collection(active_bundle.bi_list)
    seg_arr = serialize_line_collection(active_bundle.seg_list)
    segseg_arr = serialize_line_collection(active_bundle.segseg_list)
    fract_zs_arr = serialize_zs_collection(active_bundle.fractzs_list)
    bi_zs_arr = serialize_zs_collection(active_bundle.zs_list)
    seg_zs_arr = serialize_zs_collection(active_bundle.segzs_list)
    segseg_zs_arr = serialize_zs_collection(active_bundle.segsegzs_list)
    bsp_bi_arr = serialize_bsp_collection("bi", active_bundle.bs_point_lst)
    bsp_seg_arr = serialize_bsp_collection("seg", active_bundle.seg_bs_point_lst)
    bsp_segseg_arr = serialize_bsp_collection("segseg", active_bundle.segseg_bs_point_lst)
    bsp_arr = sorted(
        [*bsp_bi_arr, *bsp_seg_arr, *bsp_segseg_arr],
        key=lambda item: (int(item["x"]), LEVEL_ORDER.get(str(item["level"]), 999), int(not bool(item["is_buy"]))),
    )

    return {
        "kline": klu_arr,
        "kline_all": kline_all or [],
        "fract": fract_arr,
        "bi": bi_arr,
        "seg": seg_arr,
        "segseg": segseg_arr,
        "fract_zs": fract_zs_arr,
        "bi_zs": bi_zs_arr,
        "seg_zs": seg_zs_arr,
        "segseg_zs": segseg_zs_arr,
        "bsp": bsp_arr,
        "bsp_bi": bsp_bi_arr,
        "bsp_seg": bsp_seg_arr,
        "bsp_segseg": bsp_segseg_arr,
        "rhythm_lines": active_bundle.rhythm_lines,
        "rhythm_hits": active_bundle.rhythm_hits,
        "fx_lines": active_bundle.fx_lines,
        "indicators": indicator_history,
        "trend_lines": active_bundle.trend_lines if active_bundle.trend_lines else trend_lines,
    }


RLD_DEFAULT_LV_LIST = [KL_TYPE.K_DAY, KL_TYPE.K_60M, KL_TYPE.K_15M]
RLD_LEVEL_LABELS = {
    KL_TYPE.K_YEAR: "年线",
    KL_TYPE.K_QUARTER: "季线",
    KL_TYPE.K_MON: "月线",
    KL_TYPE.K_WEEK: "周线",
    KL_TYPE.K_DAY: "日线",
    KL_TYPE.K_60M: "60分钟",
    KL_TYPE.K_30M: "30分钟",
    KL_TYPE.K_15M: "15分钟",
    KL_TYPE.K_5M: "5分钟",
    KL_TYPE.K_3M: "3分钟",
    KL_TYPE.K_1M: "1分钟",
}
RLD_LEVEL_NAMES = {
    KL_TYPE.K_YEAR: "year",
    KL_TYPE.K_QUARTER: "quarter",
    KL_TYPE.K_MON: "month",
    KL_TYPE.K_WEEK: "week",
    KL_TYPE.K_DAY: "day",
    KL_TYPE.K_60M: "60m",
    KL_TYPE.K_30M: "30m",
    KL_TYPE.K_15M: "15m",
    KL_TYPE.K_5M: "5m",
    KL_TYPE.K_3M: "3m",
    KL_TYPE.K_1M: "1m",
}
RLD_LEVEL_RANK = {
    KL_TYPE.K_YEAR: 0,
    KL_TYPE.K_QUARTER: 1,
    KL_TYPE.K_MON: 2,
    KL_TYPE.K_WEEK: 3,
    KL_TYPE.K_DAY: 4,
    KL_TYPE.K_60M: 5,
    KL_TYPE.K_30M: 6,
    KL_TYPE.K_15M: 7,
    KL_TYPE.K_5M: 8,
    KL_TYPE.K_3M: 9,
    KL_TYPE.K_1M: 10,
}
RLD_INTRADAY_TYPES = {KL_TYPE.K_60M, KL_TYPE.K_30M, KL_TYPE.K_15M, KL_TYPE.K_5M, KL_TYPE.K_3M, KL_TYPE.K_1M}
RLD_ENTRY_RULES_DEFAULT = ["rld_bs_buy", "one_line"]
RLD_EXIT_RULES_DEFAULT = ["rld_bs_sell", "trend_down"]


def kl_type_to_name(lv: KL_TYPE) -> str:
    return RLD_LEVEL_NAMES.get(lv, str(lv.name).lower())


def kl_type_to_label(lv: KL_TYPE) -> str:
    return RLD_LEVEL_LABELS.get(lv, str(lv.name))


def is_intraday_kl_type(lv: KL_TYPE) -> bool:
    return lv in RLD_INTRADAY_TYPES


def parse_kl_type(raw: Any) -> KL_TYPE:
    if isinstance(raw, KL_TYPE):
        return raw
    text = str(raw or "").strip().lower()
    mapping = {
        "year": KL_TYPE.K_YEAR,
        "y": KL_TYPE.K_YEAR,
        "quarter": KL_TYPE.K_QUARTER,
        "q": KL_TYPE.K_QUARTER,
        "mon": KL_TYPE.K_MON,
        "month": KL_TYPE.K_MON,
        "m": KL_TYPE.K_MON,
        "week": KL_TYPE.K_WEEK,
        "w": KL_TYPE.K_WEEK,
        "day": KL_TYPE.K_DAY,
        "d": KL_TYPE.K_DAY,
        "60m": KL_TYPE.K_60M,
        "1h": KL_TYPE.K_60M,
        "30m": KL_TYPE.K_30M,
        "15m": KL_TYPE.K_15M,
        "5m": KL_TYPE.K_5M,
        "3m": KL_TYPE.K_3M,
        "1m": KL_TYPE.K_1M,
        "k_year": KL_TYPE.K_YEAR,
        "k_quarter": KL_TYPE.K_QUARTER,
        "k_mon": KL_TYPE.K_MON,
        "k_week": KL_TYPE.K_WEEK,
        "k_day": KL_TYPE.K_DAY,
        "k_60m": KL_TYPE.K_60M,
        "k_30m": KL_TYPE.K_30M,
        "k_15m": KL_TYPE.K_15M,
        "k_5m": KL_TYPE.K_5M,
        "k_3m": KL_TYPE.K_3M,
        "k_1m": KL_TYPE.K_1M,
    }
    if text in mapping:
        return mapping[text]
    raise ValueError(f"不支持的周期：{raw}")


def normalize_rld_lv_list(raw: Any) -> list[KL_TYPE]:
    if raw is None:
        return list(RLD_DEFAULT_LV_LIST)
    if isinstance(raw, str):
        parts = [part for part in re.split(r"[\s,，;；|/]+", raw) if part]
    elif isinstance(raw, Iterable):
        parts = list(raw)
    else:
        parts = [raw]
    levels: list[KL_TYPE] = []
    seen: set[KL_TYPE] = set()
    for part in parts:
        try:
            lv = parse_kl_type(part)
        except Exception:
            continue
        if lv not in seen:
            levels.append(lv)
            seen.add(lv)
    if len(levels) <= 0:
        levels = list(RLD_DEFAULT_LV_LIST)
    levels.sort(key=lambda lv: RLD_LEVEL_RANK.get(lv, 999))
    check_kltype_order(levels)
    return levels


def build_chan_config_dict(chan_config: Optional[dict[str, Any]] = None, *, trigger_step: bool) -> dict[str, Any]:
    cfg_dict = {
        "chan_algo": CHAN_ALGO_CLASSIC,
        "bi_strict": True,
        "bi_algo": "normal",
        "bi_fx_check": "strict",
        "gap_as_kl": False,
        "bi_end_is_peak": True,
        "bi_allow_sub_peak": True,
        "seg_algo": "chan",
        "left_seg_method": "peak",
        "zs_combine": True,
        "zs_combine_mode": "zs",
        "one_bi_zs": False,
        "zs_algo": "normal",
        "trigger_step": trigger_step,
        "skip_step": 0,
        "kl_data_check": True,
        "print_warning": False,
        "print_err_time": False,
        "divergence_rate": float("inf"),
        "min_zs_cnt": 1,
        "bsp1_only_multibi_zs": True,
        "max_bs2_rate": 0.9999,
        "macd_algo": "peak",
        "bs1_peak": True,
        "bs_type": "1,1p,2,2s,3a,3b",
        "bsp2_follow_1": True,
        "bsp3_follow_1": True,
        "bsp3_peak": False,
        "bsp2s_follow_2": False,
        "max_bsp2s_lv": None,
        "strict_bsp3": False,
        "bsp3a_max_zs_cnt": 1,
        "macd": {"fast": 12, "slow": 26, "signal": 9},
    }
    if chan_config:
        for k, v in chan_config.items():
            if v is None or v == "":
                continue
            if k in ["divergence_rate", "max_bs2_rate"]:
                try:
                    cfg_dict[k] = float(v)
                except (TypeError, ValueError):
                    if isinstance(v, str) and v.lower() == "inf":
                        cfg_dict[k] = float("inf")
            elif k in ["min_zs_cnt", "bsp3a_max_zs_cnt", "boll_n", "rsi_cycle", "kdj_cycle", "skip_step"]:
                try:
                    cfg_dict[k] = int(v)
                except (TypeError, ValueError):
                    continue
            elif k == "macd" and isinstance(v, dict):
                macd_dict = cfg_dict["macd"].copy()
                for mk, mv in v.items():
                    if mv is None or mv == "":
                        continue
                    try:
                        macd_dict[mk] = int(mv)
                    except (TypeError, ValueError):
                        continue
                cfg_dict["macd"] = macd_dict
            else:
                cfg_dict[k] = v
    cfg_dict["chan_algo"] = normalize_chan_algo(cfg_dict.get("chan_algo"))
    cfg_dict["trigger_step"] = trigger_step
    return cfg_dict


def strip_chan_algo(cfg_dict: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in cfg_dict.items() if k != "chan_algo"}


