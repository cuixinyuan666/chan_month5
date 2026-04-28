from .a_frontend import HTML
from .a_rld_backend import *
from .a_rld_train_backend import *




APP_STATE = AppState()
APP_STOCK_NAME: Optional[str] = None
RLD_APP_STATE = RldAppState()
RLD_TRAIN_APP_STATE = RldTrainAppState()


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    CBaoStock.do_close()


app = FastAPI(title="chan.py replay trainer", lifespan=lifespan)


@app.get("/", response_class=HTMLResponse)
def index():
    return HTML


@app.post("/api/init")
def api_init(req: InitReq):
    try:
        autype_map = {"qfq": AUTYPE.QFQ, "hfq": AUTYPE.HFQ, "none": AUTYPE.NONE}
        autype = autype_map.get(req.autype.lower(), AUTYPE.QFQ)
        if req.initial_cash <= 0:
            raise ValueError("初始资金必须大于0")
        code_norm = normalize_code(req.code)

        APP_STATE.stepper.init(code_norm, req.begin_date, req.end_date, autype, chan_config=req.chan_config)
        global APP_STOCK_NAME
        APP_STOCK_NAME = APP_STATE.stepper.stock_name
        APP_STATE.account.reset(req.initial_cash)
        APP_STATE.ready = True
        APP_STATE.finished = False
        APP_STATE.session_params = {
            "code": code_norm,
            "begin_date": req.begin_date,
            "end_date": req.end_date,
            "autype": autype,
            "initial_cash": req.initial_cash,
            "chan_config": req.chan_config,
        }
        APP_STATE.trade_events = []
        APP_STATE.bsp_history = []
        APP_STATE._reset_rhythm_history()
        APP_STATE.bsp_judge_logs = []
        APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
        # init后先推进一根，确保前端有可视数据并可交互
        APP_STATE.rebuild_bsp_all_snapshot()
        APP_STATE.stepper.step()
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        APP_STATE._rhythm_notice_hits = []
        APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        source_label = data_source_label(APP_STATE.stepper.data_src_used)
        if source_label == "AKShare":
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，当前数据源 {source_label}。"
        else:
            payload["message"] = f"加载成功：{APP_STOCK_NAME or code_norm}，已自动切换到 {source_label}。"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/reconfig")
def api_reconfig(req: ReconfigReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    try:
        APP_STATE.reconfig(req.chan_config)
        APP_STATE._rhythm_notice_hits = []
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = "缠论配置更新成功，已按新逻辑重新计算并清除模拟持仓。"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/step")
def api_step(req: StepReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        ok = APP_STATE.stepper.step()
        APP_STATE.sync_bsp_history()
        APP_STATE.sync_rhythm_history()
        mode = (req.judge_mode or "auto").lower().strip()
        if mode != "manual":
            APP_STATE.after_step_update()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = "已到最后一根K线" if not ok else "步进成功"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/judge_bsp")
def api_judge_bsp(req: JudgeBspReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        APP_STATE._judge_bsp_against_all(reason=str(req.reason or "manual_check"))
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = "买卖点判定完成"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/buy")
def api_buy():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        price = APP_STATE.stepper.current_price()
        step_idx = APP_STATE.stepper.step_idx
        detail = APP_STATE.account.buy_with_all_cash(price, step_idx)
        APP_STATE.trade_events.append(
            {
                "side": "buy",
                "step_idx": step_idx,
                "x": APP_STATE._current_kline_x(),
                "price": float(price),
                "shares": int(detail.get("shares", 0)),
            }
        )
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = f"买入成功：{json.dumps(detail, ensure_ascii=False)}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/sell")
def api_sell():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        price = APP_STATE.stepper.current_price()
        step_idx = APP_STATE.stepper.step_idx
        detail = APP_STATE.account.sell_all(price, step_idx)
        APP_STATE.trade_events.append(
            {
                "side": "sell",
                "step_idx": step_idx,
                "x": APP_STATE._current_kline_x(),
                "price": float(price),
                "shares": int(detail.get("shares", 0)),
            }
        )
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = f"卖出结果：{json.dumps(detail, ensure_ascii=False)}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/back_n")
def api_back_n(req: BackNReq):
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    try:
        n = int(req.n)
        if n < 1:
            raise ValueError("N 必须>=1")
        cur = APP_STATE.stepper.step_idx
        target = max(0, cur - n)
        APP_STATE.rebuild_to_step(target)
        APP_STATE._rhythm_notice_hits = []
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = f"自动重建回放：已后退 {cur - target} 根（目标 step={target}）"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/state")
def api_state():
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


@app.get("/api/source-settings")
def api_source_settings():
    return get_data_source_settings()


@app.post("/api/source-settings")
def api_save_source_settings(req: DataSourceSettingsReq):
    try:
        return set_data_source_priority(req.priority)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/shared-settings")
def api_shared_settings():
    return get_shared_settings()


@app.post("/api/shared-settings")
def api_save_shared_settings(req: SharedSettingsReq):
    try:
        return set_shared_settings(req.model_dump())
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/init")
def api_rld_init(req: RldInitReq):
    try:
        RLD_APP_STATE.init(req)
        payload = RLD_APP_STATE.build_payload()
        payload["message"] = f"融立得工作台已加载：{payload.get('name') or payload.get('code')}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/rld/state")
def api_rld_state():
    return RLD_APP_STATE.build_payload()


@app.post("/api/rld/reconfig")
def api_rld_reconfig(req: RldReconfigReq):
    try:
        RLD_APP_STATE.reconfig(req)
        payload = RLD_APP_STATE.build_payload()
        payload["message"] = "融立得工作台配置已更新"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/matrix")
def api_rld_matrix(req: RldMatrixReq):
    try:
        result = RLD_APP_STATE.build_matrix(req)
        payload = RLD_APP_STATE.build_payload()
        payload["matrix"] = result
        payload["message"] = f"矩阵评估完成，共 {result['meta'].get('count', 0)} 个标的"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/backtest")
def api_rld_backtest(req: RldBacktestReq):
    try:
        result = RLD_APP_STATE.run_backtest(req)
        payload = RLD_APP_STATE.build_payload()
        payload["backtest"] = result
        payload["message"] = f"回归评测完成，共 {result['summary'].get('count', 0)} 个标的"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld/reset")
def api_rld_reset():
    RLD_APP_STATE.reset()
    payload = RLD_APP_STATE.build_payload()
    payload["message"] = "融立得工作台已重置"
    return payload


@app.post("/api/rld-train/init")
def api_rld_train_init(req: RldTrainInitReq):
    try:
        RLD_TRAIN_APP_STATE.init(req)
        payload = RLD_TRAIN_APP_STATE.build_payload()
        payload["message"] = f"缠论训练已加载：{payload.get('name') or payload.get('code')}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/rld-train/state")
def api_rld_train_state():
    try:
        return RLD_TRAIN_APP_STATE.build_payload()
    except Exception:
        return {"ready": False, "message": "请先加载融立得缠论训练"}


@app.post("/api/rld-train/reset")
def api_rld_train_reset():
    RLD_TRAIN_APP_STATE.reset()
    return {"ready": False, "message": "缠论训练已重置"}


@app.post("/api/rld-train/reconfig")
def api_rld_train_reconfig(req: RldTrainReconfigReq):
    try:
        RLD_TRAIN_APP_STATE.reconfig(req)
        payload = RLD_TRAIN_APP_STATE.build_payload()
        payload["message"] = "缠论训练配置已更新"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld-train/step")
def api_rld_train_step(req: RldTrainStepReq):
    try:
        RLD_TRAIN_APP_STATE.step(req, forward=True)
        payload = RLD_TRAIN_APP_STATE.build_payload()
        payload["message"] = "训练步进成功"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld-train/back")
def api_rld_train_back(req: RldTrainStepReq):
    try:
        RLD_TRAIN_APP_STATE.step(req, forward=False)
        payload = RLD_TRAIN_APP_STATE.build_payload()
        payload["message"] = "训练后退成功"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/rld-train/trade")
def api_rld_train_trade(req: RldTrainTradeReq):
    try:
        detail = RLD_TRAIN_APP_STATE.trade(req)
        payload = RLD_TRAIN_APP_STATE.build_payload()
        payload["trade_detail"] = detail
        payload["message"] = "训练交易已执行"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/finish")
def api_finish():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    APP_STATE.finished = True
    payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
    payload["message"] = "训练结束"
    return payload


@app.post("/api/reset")
def api_reset():
    global APP_STOCK_NAME
    APP_STOCK_NAME = None
    APP_STATE.stepper = ChanStepper()
    APP_STATE.account = PaperAccount(initial_cash=10_000, cash=10_000)
    APP_STATE.ready = False
    APP_STATE.finished = False
    APP_STATE.session_params = None
    APP_STATE.trade_events = []
    APP_STATE.bsp_history = []
    APP_STATE._reset_rhythm_history()
    APP_STATE.bsp_all_snapshot = []
    APP_STATE.bsp_judge_logs = []
    APP_STATE._last_level_dirs = {level: None for level in set(JUDGE_TRIGGER_LEVELS.values())}
    APP_STATE._reset_judge_state()
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


@app.post("/api/exit")
def api_exit():
    import os
    import signal
    os.kill(os.getpid(), signal.SIGTERM)
    return {"message": "Server is exiting..."}

def run_dev_server() -> None:
    import socket
    import subprocess

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", 8000)) == 0:
                print("?? 8000 ???????????...")
                cmd = "netstat -ano | findstr :8000"
                res = subprocess.check_output(cmd, shell=True).decode()
                pids = set()
                for line in res.strip().split("\n"):
                    parts = line.split()
                    if len(parts) >= 5:
                        pids.add(parts[-1])
                for pid in pids:
                    if pid != "0":
                        print(f"???? PID: {pid}")
                        subprocess.run(f"taskkill /F /PID {pid}", shell=True)
    except Exception as e:
        print(f"?????????: {e}")

    uvicorn.run(app, host="127.0.0.1", port=8000)
