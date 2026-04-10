import json
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any, Optional

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from Chan import CChan
from ChanConfig import CChanConfig
from Common.CEnum import AUTYPE, DATA_SRC, FX_TYPE, KL_TYPE
from DataAPI.BaoStockAPI import CBaoStock
from Math.BOLL import BollModel
from Math.KDJ import KDJ
from Math.MACD import CMACD
from Math.RSI import RSI
from Math.Demark import CDemarkEngine
from Math.TrendLine import CTrendLine
from Common.CEnum import TREND_LINE_SIDE


def normalize_code(raw: str) -> str:
    raw = raw.strip()
    if len(raw) == 0:
        raise ValueError("代码不能为空")
    if raw.startswith("sh.") or raw.startswith("sz."):
        return raw
    if len(raw) != 6 or not raw.isdigit():
        raise ValueError("代码必须为6位数字，例如 000001")
    return ("sh." if raw.startswith("6") else "sz.") + raw


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
        self.indicators = {
            "macd": CMACD(),
            "kdj": KDJ(),
            "rsi": RSI(),
            "boll": BollModel(),
            "demark": CDemarkEngine(),
        }
        self.indicator_history = []
        self.trend_lines = []

    def init(self, code: str, begin_date: str, end_date: Optional[str], autype: AUTYPE) -> None:
        cfg = CChanConfig(
            {
                "bi_strict": True,
                "trigger_step": True,
                "skip_step": 0,
                "print_warning": False,
                "kl_data_check": True,
            }
        )
        self.code = normalize_code(code)
        self.chan = CChan(
            code=self.code,
            begin_time=begin_date,
            end_time=end_date,
            data_src=DATA_SRC.BAO_STOCK,
            lv_list=[KL_TYPE.K_DAY],
            config=cfg,
            autype=autype,
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

    def step(self) -> bool:
        if self._iter is None:
            raise ValueError("请先初始化会话。")
        try:
            next(self._iter)
            self.step_idx += 1
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
            
            # Update TrendLines if we have enough Bi
            self.trend_lines = []
            if len(kl_list.bi_list) >= 3:
                try:
                    tl_outside = CTrendLine(kl_list.bi_list, side=TREND_LINE_SIDE.OUTSIDE)
                    if tl_outside.line:
                        self.trend_lines.append({
                            "type": "OUTSIDE",
                            "x0": tl_outside.line.p.x,
                            "y0": tl_outside.line.p.y,
                            "slope": tl_outside.line.slope
                        })
                    tl_inside = CTrendLine(kl_list.bi_list, side=TREND_LINE_SIDE.INSIDE)
                    if tl_inside.line:
                        self.trend_lines.append({
                            "type": "INSIDE",
                            "x0": tl_inside.line.p.x,
                            "y0": tl_inside.line.p.y,
                            "slope": tl_inside.line.slope
                        })
                except Exception:
                    pass
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
    initial_cash: float = 1_000_000
    autype: str = "qfq"


class AppState:
    def __init__(self) -> None:
        self.stepper = ChanStepper()
        self.account = PaperAccount(initial_cash=1_000_000, cash=1_000_000)
        self.ready = False
        self.finished = False

    def build_payload(self, stock_name: Optional[str] = None) -> dict[str, Any]:
        if not self.ready or self.stepper.chan is None:
            return {
                "ready": False,
                "finished": self.finished,
                "message": "请先加载会话",
            }
        chart = serialize_chan(self.stepper.chan, self.stepper.indicator_history, self.stepper.trend_lines)
        price: Optional[float] = None
        if len(chart.get("kline", [])) > 0:
            price = self.stepper.current_price()
        return {
            "ready": True,
            "finished": self.finished,
            "code": self.stepper.code,
            "name": stock_name,
            "step_idx": self.stepper.step_idx,
            "time": self.stepper.current_time(),
            "price": price,
            "chart": chart,
            "account": {
                "initial_cash": round(self.account.initial_cash, 2),
                "cash": round(self.account.cash, 2),
                "position": self.account.position,
                "avg_cost": round(self.account.avg_cost, 4),
                "equity": round(self.account.equity(price or 0.0), 2),
                "can_sell": bool(price is not None and self.account.can_sell(self.stepper.step_idx)),
            },
        }


def serialize_chan(chan: CChan, indicator_history: list, trend_lines: list) -> dict[str, Any]:
    kl_list = chan[0]
    klu_arr = []
    for klu in kl_list.klu_iter():
        klu_arr.append(
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
    
    # BOLL, MACD, KDJ, RSI data from indicator_history
    # We only need to return the indicators for the current visible k-lines (or all of them for now)
    
    bi_arr = []
    for bi in kl_list.bi_list:
        bi_arr.append(
            {
                "x1": bi.get_begin_klu().idx,
                "y1": float(bi.get_begin_val()),
                "x2": bi.get_end_klu().idx,
                "y2": float(bi.get_end_val()),
                "is_sure": bool(bi.is_sure),
            }
        )

    seg_arr = []
    for seg in kl_list.seg_list:
        seg_arr.append(
            {
                "x1": seg.start_bi.get_begin_klu().idx,
                "y1": float(seg.start_bi.get_begin_val()),
                "x2": seg.end_bi.get_end_klu().idx,
                "y2": float(seg.end_bi.get_end_val()),
                "is_sure": bool(seg.is_sure),
            }
        )

    bsp_arr = []
    for bsp in kl_list.bs_point_lst.bsp_iter():
        bsp_arr.append(
            {
                "x": bsp.klu.idx,
                "y": float(bsp.klu.low if bsp.is_buy else bsp.klu.high),
                "is_buy": bool(bsp.is_buy),
                "label": bsp.type2str(),
            }
        )

    fx_points = []
    for klc in kl_list.lst:
        if klc.fx == FX_TYPE.TOP:
            peak = max(klc.lst, key=lambda item: item.high)
            fx_points.append({"type": "TOP", "x": peak.idx, "y": float(peak.high)})
        elif klc.fx == FX_TYPE.BOTTOM:
            trough = min(klc.lst, key=lambda item: item.low)
            fx_points.append({"type": "BOTTOM", "x": trough.idx, "y": float(trough.low)})

    fx_lines = []
    last = None
    for pt in fx_points:
        if last is not None and pt["type"] != last["type"]:
            fx_lines.append({"x1": last["x"], "y1": last["y"], "x2": pt["x"], "y2": pt["y"]})
        last = pt

    return {
        "kline": klu_arr,
        "bi": bi_arr,
        "seg": seg_arr,
        "bsp": bsp_arr,
        "fx_lines": fx_lines,
        "indicators": indicator_history,
        "trend_lines": trend_lines,
    }


HTML = """
<!DOCTYPE html>
<html lang="zh-CN" data-theme="light">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>chan.py 复盘训练器</title>
  <style>
    :root, [data-theme="light"]{
      --bg: #f7f7f8;
      --panel: #ffffff;
      --text: #0f172a;
      --muted: #475569;
      --border: #cbd5e1;
      --btn: #f1f5f9;
      --btnText: #0f172a;
      --chartBg: #ffffff;
      --grid: #e2e8f0;
      --candleUp: #ef4444;
      --candleDown: #22c55e;
      --candleUpFill: rgba(239,68,68,0.12);
      --candleDownFill: rgba(34,197,94,0.75);
      --lineFx: #06b6d4;
      --lineBi: #f59e0b;
      --lineBiWeak: #94a3b8;
      --lineSeg: #059669;
      --lineSegWeak: #34d399;
      --holdFill: rgba(59,130,246,0.14);
      --holdFillPast: rgba(99,102,241,0.12);
      --markBuy: #dc2626;
      --markSell: #16a34a;
      --rayBuy: #f97316;
      --raySell: #14b8a6;
      --bspBuy: #dc2626;
      --bspSell: #16a34a;
      --legendBg: rgba(255,255,255,0.92);
      --legendText: #0f172a;
      --legendBorder: rgba(148,163,184,0.6);
      --chipFill: rgba(59,130,246,0.45);
      --chipBg: rgba(148,163,184,0.12);
      --chipEdge: rgba(59,130,246,0.75);
    }
    [data-theme="dark"]{
      --bg: #0b0f14;
      --panel: #0b0f14;
      --text: #e6edf3;
      --muted: #9ca3af;
      --border: #334155;
      --btn: #1e293b;
      --btnText: #e6edf3;
      --chartBg: #0b0f14;
      --grid: #334155;
      --candleUp: #f87171;
      --candleDown: #4ade80;
      --candleUpFill: rgba(248,113,113,0.15);
      --candleDownFill: rgba(74,222,128,0.45);
      --lineFx: #22d3ee;
      --lineBi: #fbbf24;
      --lineBiWeak: #94a3b8;
      --lineSeg: #34d399;
      --lineSegWeak: #6ee7b7;
      --holdFill: rgba(59,130,246,0.18);
      --holdFillPast: rgba(129,140,248,0.16);
      --markBuy: #f87171;
      --markSell: #4ade80;
      --rayBuy: #fb923c;
      --raySell: #2dd4bf;
      --bspBuy: #fca5a5;
      --bspSell: #86efac;
      --legendBg: rgba(15,23,42,0.88);
      --legendText: #e2e8f0;
      --legendBorder: rgba(71,85,105,0.8);
      --chipFill: rgba(96,165,250,0.5);
      --chipBg: rgba(148,163,184,0.16);
      --chipEdge: rgba(147,197,253,0.8);
    }
    [data-theme="eye-care"]{
      --bg: #e8f0e8;
      --panel: #f4faf4;
      --text: #1a2e1a;
      --muted: #3d5a3d;
      --border: #a3c4a3;
      --btn: #dcefdc;
      --btnText: #1a2e1a;
      --chartBg: #fafdf8;
      --grid: #c5dcc5;
      --candleUp: #c0392b;
      --candleDown: #27ae60;
      --candleUpFill: rgba(192,57,43,0.12);
      --candleDownFill: rgba(39,174,96,0.55);
      --lineFx: #1a8a9e;
      --lineBi: #b45309;
      --lineBiWeak: #78716c;
      --lineSeg: #047857;
      --lineSegWeak: #6ee7b7;
      --holdFill: rgba(37,99,235,0.12);
      --holdFillPast: rgba(79,70,229,0.1);
      --markBuy: #b91c1c;
      --markSell: #15803d;
      --rayBuy: #c2410c;
      --raySell: #0f766e;
      --bspBuy: #b91c1c;
      --bspSell: #15803d;
      --legendBg: rgba(250,253,248,0.94);
      --legendText: #1a2e1a;
      --legendBorder: rgba(163,196,163,0.9);
      --chipFill: rgba(37,99,235,0.42);
      --chipBg: rgba(163,196,163,0.18);
      --chipEdge: rgba(37,99,235,0.72);
    }
    body { margin: 0; font-family: Arial, sans-serif; background: var(--bg); color: var(--text); }
    .wrap { display: flex; height: 100vh; flex-direction: row-reverse; }
    .left { width: 360px; padding: 12px; border-right: none; border-left: 1px solid var(--border); box-sizing: border-box; overflow-y: auto; background: var(--panel); }
    .right { flex: 1; padding: 8px; box-sizing: border-box; }
    .row { margin-bottom: 8px; }
    .row input[type="checkbox"] { width: auto; transform: scale(1.1); }
    label { display: inline-block; width: 110px; }
    input, select { width: 210px; padding: 4px; background: var(--panel); color: var(--text); border: 1px solid var(--border); }
    button { margin-right: 8px; margin-top: 6px; padding: 6px 10px; border: 1px solid var(--border); background: var(--btn); color: var(--btnText); cursor: pointer; }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
    .title { font-size: 16px; margin: 4px 0 10px; color: #2563eb; }
    .card { border: 1px solid var(--border); padding: 10px; margin-bottom: 12px; background: var(--panel); }
    #chart { width: 100%; height: calc(100vh - 40px); background: var(--chartBg); border: 1px solid var(--border); }
    .muted { color: var(--muted); font-size: 12px; }
    .mono { font-family: Consolas, monospace; }
    .stateScroll { max-height: 220px; overflow-y: auto; border: 1px solid var(--border); border-radius: 6px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { padding: 6px 6px; border-bottom: 1px solid var(--grid); font-size: 14px; }
    th { text-align: left; color: #2563eb; position: sticky; top: 0; background: var(--panel); z-index: 1; }
    #msgList { max-height: 220px; overflow-y: auto; border: 1px solid var(--border); padding: 6px; }
    .msgItem { font-family: Consolas, monospace; font-size: 13px; border-bottom: 1px dashed var(--grid); padding: 4px 0; white-space: pre-wrap;}
    .card.collapsed { opacity: 0.82; }
    .card.collapsed .cfg-editable { display: none; }
    .btnRow { display: flex; flex-wrap: wrap; gap: 6px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="left">
      <div class="title">chan.py 复盘训练器（单文件 A1）</div>
      <div class="card" id="configCard">
        <div class="row"><label>主题</label>
          <select id="theme">
            <option value="light">白色</option>
            <option value="dark">黑色</option>
            <option value="eye-care">护眼</option>
          </select>
        </div>
        <div class="row cfg-editable"><label>代码</label><input id="code" value="600340" /></div>
        <div class="row cfg-editable"><label>开始日期</label><input id="begin" type="date" value="2018-01-01" /></div>
        <div class="row cfg-editable"><label>结束日期</label><input id="end" type="date" value="" placeholder="可空" /></div>
        <div class="row cfg-editable"><label>初始资金</label><input id="cash" value="1000000" /></div>
        <div class="row cfg-editable">
          <label>复权</label>
          <select id="autype">
            <option value="qfq">前复权</option>
            <option value="hfq">后复权</option>
            <option value="none">不复权</option>
          </select>
        </div>
        <div class="btnRow">
          <button id="btnInit">加载会话</button>
          <button id="btnReset">重新训练</button>
          <button id="btnExit">退出</button>
        </div>
        <div class="btnRow">
          <button id="btnStep" disabled>下一根K线</button>
          <button id="btnFinish" disabled>结束训练</button>
        </div>
      </div>

      <div class="card" id="tradeCard">
        <button id="btnBuy" disabled>买入（全仓）</button>
        <button id="btnSell" disabled>卖出（全量）</button>
        <div class="muted">规则：单持仓、T+1、每步最多一笔</div>
        <div class="row" style="margin-top:8px;"><label>显示筹码</label><input id="chipEnabled" type="checkbox" checked /></div>
        <div class="row"><label>技术指标</label>
          <select id="indicatorType">
            <option value="none">无</option>
            <option value="boll">BOLL (主图)</option>
            <option value="demark">Demark (主图)</option>
            <option value="trendline">TrendLine (主图)</option>
            <option value="macd">MACD (副图)</option>
            <option value="kdj">KDJ (副图)</option>
            <option value="rsi">RSI (副图)</option>
          </select>
        </div>
        <div class="muted">全历史累计；三角分布峰值=Close；价格步长=0.001</div>
      </div>

      <div class="card">
        <div class="title" style="margin:0 0 8px 0;">状态</div>
        <div class="stateScroll">
          <table>
            <thead>
              <tr>
                <th>项目</th>
                <th>数值</th>
              </tr>
            </thead>
            <tbody>
              <tr><td>现金</td><td id="st_cash">-</td></tr>
              <tr><td>持仓(股)</td><td id="st_pos">-</td></tr>
              <tr><td>平均成本</td><td id="st_cost">-</td></tr>
              <tr><td>当前价</td><td id="st_price">-</td></tr>
              <tr><td>总资产</td><td id="st_equity">-</td></tr>
              <tr><td>总盈亏</td><td id="st_total_pnl">-</td></tr>
            </tbody>
          </table>
        </div>
      </div>
      <div class="card">
        <div class="title" style="margin:0 0 8px 0;">消息</div>
        <div id="msgList"></div>
      </div>
    </div>
    <div class="right">
      <canvas id="chart"></canvas>
    </div>
  </div>
<script>
const $ = (id) => document.getElementById(id);
const msgList = $("msgList");
const canvas = $("chart");
const ctx = canvas.getContext("2d");
let lastPayload = null;
let allXMin = 0;
let allXMax = 0;
let viewXMin = 0;
let viewXMax = 0;
let viewReady = false;
let userAdjustedView = false;

const PAD_L = 55;
const PAD_R = 10;
const PAD_T = 10;
const PAD_B = 90;

let isPanning = false;
let panStartX = 0;
let panStartViewMin = 0;
let panStartViewMax = 0;

let activeTrade = null;
let tradeHistory = [];
let lastSeenBspKey = new Set();
let bspHistory = [];
let bspHistoryKey = new Set();
let sessionFinished = false;
let crosshairEnabled = false;
let crosshairX = null;
let crosshairY = null;

function cssVar(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

function applyThemeFromSelect() {
  const t = $("theme").value || "light";
  document.documentElement.setAttribute("data-theme", t);
  if (lastPayload && lastPayload.ready && lastPayload.chart) draw(lastPayload.chart);
}

$("indicatorType").addEventListener("change", () => {
  if (lastPayload && lastPayload.ready && lastPayload.chart) draw(lastPayload.chart);
});

function zoomViewAt(factor, anchorCanvasX) {
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (!lastPayload.chart || !lastPayload.chart.kline || lastPayload.chart.kline.length === 0) return;
  const span = viewXMax - viewXMin;
  if (span <= 1) return;
  let newSpan = span / factor;
  newSpan = Math.max(5, newSpan);
  const w = canvas.clientWidth;
  const usableW = Math.max(1, w - PAD_L - PAD_R);
  const rel = Math.min(1, Math.max(0, (anchorCanvasX - PAD_L) / usableW));
  const xAtMouse = viewXMin + rel * span;
  let newXMin = xAtMouse - rel * newSpan;
  let newXMax = newXMin + newSpan;
  if (newXMin < allXMin) {
    newXMin = allXMin;
    newXMax = newXMin + newSpan;
  }
  const rightMax = allXMax + Math.round(newSpan * 2);
  if (newXMax > rightMax) {
    newXMax = rightMax;
    newXMin = newXMax - newSpan;
  }
  viewXMin = Math.round(newXMin);
  viewXMax = Math.round(newXMax);
  if (viewXMin < allXMin) viewXMin = allXMin;
  if (viewXMin >= viewXMax) {
    viewXMin = allXMin;
    viewXMax = allXMax;
  }
  userAdjustedView = true;
  draw(lastPayload.chart);
}

function ensureLatestKVisible() {
  if (!lastPayload || !lastPayload.chart || !lastPayload.chart.kline.length) return;
  const lastX = lastPayload.chart.kline[lastPayload.chart.kline.length - 1].x;
  if (lastX >= viewXMin && lastX <= viewXMax) return;
  const span = viewXMax - viewXMin;
  if (span <= 1) return;
  const pos = 0.85;
  let newMin = lastX - span * pos;
  let newMax = newMin + span;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  const rightMax = allXMax + Math.round(span * 2);
  if (newMax > rightMax) {
    newMax = rightMax;
    newMin = newMax - span;
  }
  viewXMin = Math.round(newMin);
  viewXMax = Math.round(newMax);
}

function centerLatestK() {
  if (!lastPayload || !lastPayload.chart || !lastPayload.chart.kline.length || !viewReady) return;
  const lastX = lastPayload.chart.kline[lastPayload.chart.kline.length - 1].x;
  const span = viewXMax - viewXMin;
  if (span <= 1) return;
  let newMin = lastX - span * 0.5;
  let newMax = newMin + span;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  viewXMin = Math.round(newMin);
  viewXMax = Math.round(newMax);
  userAdjustedView = true;
  draw(lastPayload.chart);
}

function setText(id, value) {
  const el = $(id);
  if (!el) return;
  el.textContent = value;
}

function resizeCanvas() {
  const rect = canvas.getBoundingClientRect();
  canvas.width = rect.width * devicePixelRatio;
  canvas.height = rect.height * devicePixelRatio;
  ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
}
window.addEventListener("resize", resizeCanvas);
setTimeout(resizeCanvas, 0);

canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const factor = e.deltaY > 0 ? 1 / 1.15 : 1.15;
    zoomViewAt(factor, mouseX);
  },
  { passive: false }
);

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  isPanning = true;
  panStartX = e.clientX;
  panStartViewMin = viewXMin;
  panStartViewMax = viewXMax;
});
window.addEventListener("mouseup", () => {
  isPanning = false;
});
window.addEventListener("mousemove", (e) => {
  if (!isPanning) return;
  const rect = canvas.getBoundingClientRect();
  if (e.clientY < rect.top || e.clientY > rect.bottom) return;
  const dx = e.clientX - panStartX;
  const span = panStartViewMax - panStartViewMin;
  const usableW = Math.max(1, canvas.clientWidth - PAD_L - PAD_R);
  const dxBars = Math.round((-dx / usableW) * span);
  let newMin = panStartViewMin + dxBars;
  let newMax = panStartViewMax + dxBars;
  if (newMin < allXMin) {
    newMin = allXMin;
    newMax = newMin + span;
  }
  viewXMin = newMin;
  viewXMax = newMax;
  userAdjustedView = true;
  draw(lastPayload.chart);
});

canvas.addEventListener("mousemove", (e) => {
  if (!crosshairEnabled || !lastPayload || !lastPayload.ready) return;
  const rect = canvas.getBoundingClientRect();
  crosshairX = e.clientX - rect.left;
  crosshairY = e.clientY - rect.top;
  draw(lastPayload.chart);
});

canvas.addEventListener("mouseleave", () => {
  if (!crosshairEnabled) return;
  crosshairX = null;
  crosshairY = null;
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
});

canvas.addEventListener("dblclick", () => {
  crosshairEnabled = !crosshairEnabled;
  canvas.style.cursor = crosshairEnabled ? "crosshair" : "default";
  if (!crosshairEnabled) {
    crosshairX = null;
    crosshairY = null;
  }
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
});

window.addEventListener("keydown", (e) => {
  const tag = (document.activeElement && document.activeElement.tagName) ? document.activeElement.tagName.toLowerCase() : "";
  if (tag === "input" || tag === "select" || tag === "textarea") return;
  if (e.code === "Space") {
    e.preventDefault();
    if (!$("btnStep").disabled) $("btnStep").click();
    return;
  }
  if (e.code === "PageUp") {
    e.preventDefault();
    if (!$("btnBuy").disabled) $("btnBuy").click();
    return;
  }
  if (e.code === "PageDown") {
    e.preventDefault();
    if (!$("btnSell").disabled) $("btnSell").click();
    return;
  }
  if (e.code === "KeyC") {
    e.preventDefault();
    centerLatestK();
    return;
  }
  if (!viewReady || !lastPayload || !lastPayload.ready) return;
  const span = viewXMax - viewXMin;
  const shift = Math.max(2, Math.round(span * 0.1));
  const plotMidX = PAD_L + (canvas.clientWidth - PAD_L - PAD_R) / 2;
  if (e.code === "ArrowUp") {
    e.preventDefault();
    zoomViewAt(1.15, plotMidX);
    return;
  }
  if (e.code === "ArrowDown") {
    e.preventDefault();
    zoomViewAt(1 / 1.15, plotMidX);
    return;
  }
  if (e.code === "ArrowLeft") {
    viewXMin = Math.max(allXMin, viewXMin - shift);
    viewXMax = viewXMin + span;
    userAdjustedView = true;
    draw(lastPayload.chart);
  } else if (e.code === "ArrowRight") {
    viewXMin = viewXMin + shift;
    viewXMax = viewXMax + shift;
    userAdjustedView = true;
    draw(lastPayload.chart);
  }
});

function setMsg(text) {
  const t = new Date().toLocaleTimeString();
  const div = document.createElement("div");
  div.className = "msgItem";
  div.textContent = `[${t}] ${text}`;
  msgList.prepend(div);
}

function setState(p) {
  if (!p.ready) {
    setText("st_cash", "-");
    setText("st_pos", "-");
    setText("st_cost", "-");
    setText("st_price", "-");
    setText("st_equity", "-");
    setText("st_total_pnl", "-");
    return;
  }
  const a = p.account;
  const price = (p.price === null || p.price === undefined) ? null : Number(p.price);
  const totalPnl = a.equity - a.initial_cash;

  setText("st_cash", a.cash.toFixed(2));
  setText("st_pos", String(a.position));
  setText("st_cost", a.avg_cost.toFixed(4));
  setText("st_price", price === null ? "-" : price.toFixed(4));
  setText("st_equity", a.equity.toFixed(2));
  setText("st_total_pnl", totalPnl.toFixed(2));
}

function toScaler(chart, xMin, xMax) {
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;

  const xToTime = {};
  for (const k of chart.kline) {
    xToTime[k.x] = k.t;
  }

  let visibleK = chart.kline.filter((k) => k.x >= xMin && k.x <= xMax);
  if (visibleK.length === 0) visibleK = chart.kline;

  let yMin = Infinity;
  let yMax = -Infinity;
  for (const k of visibleK) {
    if (k.l < yMin) yMin = k.l;
    if (k.h > yMax) yMax = k.h;
  }
  
  // If BOLL is selected, expand y range to include BOLL
    const indType = $("indicatorType").value;
    if (indType === "boll" && chart.indicators) {
      const visibleInd = chart.indicators.filter(i => i.x >= xMin && i.x <= xMax);
      for (const i of visibleInd) {
        if (i.boll.up > yMax) yMax = i.boll.up;
        if (i.boll.down < yMin) yMin = i.boll.down;
      }
    }
    
    // Expand for TrendLines
    if (indType === "trendline" && chart.trend_lines) {
      for (const tl of chart.trend_lines) {
        const y_at_min = tl.y0 + tl.slope * (xMin - tl.x0);
        const y_at_max = tl.y0 + tl.slope * (xMax - tl.x0);
        if (isFinite(y_at_min)) {
          if (y_at_min > yMax) yMax = y_at_min;
          if (y_at_min < yMin) yMin = y_at_min;
        }
        if (isFinite(y_at_max)) {
          if (y_at_max > yMax) yMax = y_at_max;
          if (y_at_max < yMin) yMin = y_at_max;
        }
      }
    }

  if (!isFinite(yMin) || !isFinite(yMax)) {
    yMin = 0;
    yMax = 1;
  }

  const xSpan = Math.max(1, xMax - xMin);
  const ySpan = Math.max(1e-6, yMax - yMin);
  
  const showSubChart = ["macd", "kdj", "rsi"].includes(indType);
  const subChartH = showSubChart ? (h - PAD_T - PAD_B) * 0.25 : 0;
  
  const plotBottomY = h - PAD_B - subChartH;
  const plotH = h - PAD_T - PAD_B - subChartH;
  const plotW = w - PAD_L - PAD_R;

  return {
    visibleK,
    xToTime,
    w,
    h,
    xMin,
    xMax,
    yMin,
    yMax,
    plotBottomY,
    plotH,
    plotW,
    subChartH,
    indType,
    x: (x) => PAD_L + ((x - xMin) / xSpan) * plotW,
    y: (y) => PAD_T + ((yMax - y) / ySpan) * plotH,
  };
}

function drawAxes(s) {
  const yBase = s.plotBottomY;
  const xLeft = PAD_L;
  const xRight = s.w - PAD_R;

  // main axes
  ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(xLeft, PAD_T);
  ctx.lineTo(xLeft, yBase);
  ctx.lineTo(xRight, yBase);
  ctx.stroke();

  // main y labels
  ctx.fillStyle = cssVar("--muted", "#475569");
  ctx.font = "12px Consolas";
  ctx.fillText(s.yMax.toFixed(2), 4, PAD_T + 10);
  ctx.fillText(s.yMin.toFixed(2), 4, yBase);
  
  // sub chart axes
  if (s.subChartH > 0) {
    const subT = s.plotBottomY + 20;
    const subB = s.h - PAD_B;
    ctx.beginPath();
    ctx.moveTo(xLeft, subT);
    ctx.lineTo(xLeft, subB);
    ctx.lineTo(xRight, subB);
    ctx.stroke();
    
    // x ticks are on the sub chart bottom if it exists
    drawXTicks(s, subB);
  } else {
    drawXTicks(s, yBase);
  }
}

function drawXTicks(s, yPos) {
  const span = s.xMax - s.xMin;
  if (span <= 0) return;
  const tickCount = 10;
  const tickXs = [];
  for (let i = 0; i <= tickCount; i++) {
    const x = Math.round(s.xMin + (span * i) / tickCount);
    if (x < s.xMin || x > s.xMax) continue;
    tickXs.push(x);
  }
  const uniq = [...new Set(tickXs)];

  ctx.save();
  for (const x of uniq) {
    const xp = s.x(x);
    ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
    ctx.beginPath();
    ctx.moveTo(xp, yPos);
    ctx.lineTo(xp, yPos + 4);
    ctx.stroke();

    const t = s.xToTime[x];
    if (!t) continue;
    ctx.save();
    ctx.translate(xp, yPos + 20);
    ctx.rotate(-Math.PI / 4);
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.fillText(t, 0, 0);
    ctx.restore();
  }
  ctx.restore();
}

function drawCrosshair(s) {
  if (!crosshairEnabled || crosshairX === null || crosshairY === null) return;
  const x = Math.max(PAD_L, Math.min(s.w - PAD_R, crosshairX));
  const y = Math.max(PAD_T, Math.min(s.plotBottomY, crosshairY));
  const xBar = s.xMin + ((x - PAD_L) / Math.max(1, s.plotW)) * (s.xMax - s.xMin);
  const idx = Math.round(xBar);
  const nearest = s.xToTime[idx] ? idx : Object.keys(s.xToTime).map(Number).reduce((best, cur) => {
    return Math.abs(cur - idx) < Math.abs(best - idx) ? cur : best;
  }, s.xMin);
  const t = s.xToTime[nearest] || "-";
  const price = s.yMax - ((y - PAD_T) / Math.max(1, s.plotH)) * (s.yMax - s.yMin);

  ctx.save();
  ctx.strokeStyle = cssVar("--grid", "#64748b");
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 4]);
  ctx.beginPath();
  ctx.moveTo(x, PAD_T);
  ctx.lineTo(x, s.plotBottomY);
  ctx.moveTo(PAD_L, y);
  ctx.lineTo(s.w - PAD_R, y);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.92)");
  ctx.strokeStyle = cssVar("--legendBorder", "rgba(148,163,184,0.6)");
  ctx.beginPath();
  ctx.rect(x + 8, y - 30, 152, 26);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = cssVar("--legendText", "#0f172a");
  ctx.font = "12px Consolas";
  ctx.fillText(`${t}  ${price.toFixed(3)}`, x + 14, y - 12);
  ctx.restore();
}

function drawGridLines(s) {
  const grid = cssVar("--grid", "#e2e8f0");
  ctx.save();
  ctx.strokeStyle = grid;
  ctx.globalAlpha = 0.45;
  ctx.lineWidth = 1;
  const yBase = s.plotBottomY;
  const xLeft = PAD_L;
  const xRight = s.w - PAD_R;
  const steps = 5;
  for (let i = 1; i < steps; i++) {
    const t = i / steps;
    const y = PAD_T + t * (yBase - PAD_T);
    ctx.beginPath();
    ctx.moveTo(xLeft, y);
    ctx.lineTo(xRight, y);
    ctx.stroke();
  }
  ctx.restore();
}

function drawChips(chart, s) {
  if (!$("chipEnabled").checked) return;
  const ks = chart.kline || [];
  if (ks.length === 0) return;
  const priceStep = 0.001;
  const stepMul = 1000;
  const xAtCursor = s.xMin + ((Math.max(PAD_L, Math.min(s.w - PAD_R, crosshairX ?? (s.w - PAD_R))) - PAD_L) / Math.max(1, s.plotW)) * (s.xMax - s.xMin);
  const refIdx = (!crosshairEnabled || crosshairX === null)
    ? ks.length - 1
    : Math.max(
        0,
        ks.findIndex((k) => k.x >= xAtCursor) >= 0 ? ks.findIndex((k) => k.x >= xAtCursor) : ks.length - 1
      );
  const useKs = ks.slice(0, refIdx + 1);

  let allMin = Infinity;
  let allMax = -Infinity;
  for (const k of ks) {
    if (k.l < allMin) allMin = k.l;
    if (k.h > allMax) allMax = k.h;
  }
  if (!isFinite(allMin) || !isFinite(allMax)) return;
  const minTick = Math.floor(allMin * stepMul);
  const maxTick = Math.ceil(allMax * stepMul);
  const tickCount = Math.max(1, maxTick - minTick + 1);
  const arr = new Array(tickCount).fill(0);

  for (const k of useKs) {
    const low = Math.min(k.l, k.h);
    const high = Math.max(k.l, k.h);
    const mode = Math.min(high, Math.max(low, k.c)); // close作为筹码峰值
    let vol = Number(k.v);
    if (!Number.isFinite(vol) || vol <= 0) vol = 1;

    const i0 = Math.max(minTick, Math.floor(low * stepMul));
    const i1 = Math.min(maxTick, Math.ceil(high * stepMul));
    if (i1 < i0) continue;
    if (Math.abs(high - low) < 1e-12) {
      arr[i0 - minTick] += vol;
      continue;
    }

    let sumW = 0;
    const ws = [];
    for (let t = i0; t <= i1; t++) {
      const p = t / stepMul;
      let w = 0;
      if (Math.abs(mode - low) < 1e-12) {
        w = (high - p) / Math.max(1e-12, high - low);
      } else if (Math.abs(high - mode) < 1e-12) {
        w = (p - low) / Math.max(1e-12, high - low);
      } else if (p <= mode) {
        w = (p - low) / Math.max(1e-12, mode - low);
      } else {
        w = (high - p) / Math.max(1e-12, high - mode);
      }
      w = Math.max(0, w);
      ws.push(w);
      sumW += w;
    }
    if (sumW <= 1e-12) continue;
    for (let t = i0; t <= i1; t++) {
      const w = ws[t - i0];
      if (w <= 0) continue;
      arr[t - minTick] += (w / sumW) * vol;
    }
  }

  const maxV = Math.max(...arr);
  if (maxV <= 0) return;
  const chipW = Math.max(96, Math.min(220, s.plotW * 0.2));
  const xR = s.w - PAD_R - 2;
  const xL = xR - chipW;
  const fill = cssVar("--chipFill", "rgba(59,130,246,0.45)");
  const bg = cssVar("--chipBg", "rgba(148,163,184,0.12)");
  const edge = cssVar("--chipEdge", "rgba(59,130,246,0.75)");

  ctx.save();
  ctx.fillStyle = bg;
  ctx.fillRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  for (let i = 0; i < tickCount; i++) {
    const v = arr[i];
    if (v <= 0) continue;
    const len = (v / maxV) * chipW;
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    const yTop = s.y(p + priceStep);
    const yBot = s.y(p);
    const h = Math.max(1, yBot - yTop);
    ctx.fillStyle = fill;
    ctx.fillRect(xR - len, yTop, len, h);
  }
  ctx.strokeStyle = edge;
  ctx.lineWidth = 1;
  ctx.strokeRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  ctx.fillStyle = cssVar("--legendText", "#0f172a");
  ctx.font = "12px Consolas";
  const refText = (!crosshairEnabled || crosshairX === null) ? "最新" : `历史@${useKs[useKs.length - 1]?.t || "-"}`;
  ctx.fillText(`筹码(${refText})`, xL + 6, PAD_T + 14);
  ctx.restore();
}

function drawCandles(chart, s) {
  const ks = s.visibleK;
  const bodyW = Math.max(3, (s.plotW) / Math.max(42, ks.length * 1.28));
  const upS = cssVar("--candleUp", "#ef4444");
  const dnS = cssVar("--candleDown", "#22c55e");
  const upF = cssVar("--candleUpFill", "rgba(239,68,68,0.12)");
  const dnF = cssVar("--candleDownFill", "rgba(34,197,94,0.75)");
  for (const k of ks) {
    const x = s.x(k.x);
    const yo = s.y(k.o),
      yc = s.y(k.c),
      yh = s.y(k.h),
      yl = s.y(k.l);
    const up = k.c >= k.o;
    ctx.strokeStyle = up ? upS : dnS;
    ctx.fillStyle = up ? upF : dnF;
    ctx.lineWidth = 1.4;

    ctx.beginPath();
    ctx.moveTo(x, yh);
    ctx.lineTo(x, yl);
    ctx.stroke();

    const top = Math.min(yo, yc),
      bh = Math.max(1, Math.abs(yc - yo));
    if (up) {
      ctx.strokeRect(x - bodyW / 2, top, bodyW, bh);
    } else {
      ctx.fillRect(x - bodyW / 2, top, bodyW, bh);
    }
  }
}

function intersects(l, xMin, xMax) {
  const a = Math.min(l.x1, l.x2);
  const b = Math.max(l.x1, l.x2);
  return b >= xMin && a <= xMax;
}

function drawLines(arr, s, color, width, dashed = false) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  if (dashed) ctx.setLineDash([5, 4]);
  else ctx.setLineDash([]);
  for (const l of arr) {
    if (!intersects(l, s.xMin, s.xMax)) continue;
    ctx.beginPath();
    ctx.moveTo(s.x(l.x1), s.y(l.y1));
    ctx.lineTo(s.x(l.x2), s.y(l.y2));
    ctx.stroke();
  }
  ctx.restore();
}

function drawLegend() {
  const pad = 8;
  const lines = [
    { label: "分型连线", color: cssVar("--lineFx", "#06b6d4"), dashed: true, w: 1.1 },
    { label: "笔(确定)", color: cssVar("--lineBi", "#f59e0b"), dashed: false, w: 3.1 },
    { label: "笔(未完成)", color: cssVar("--lineBi", "#f59e0b"), dashed: true, w: 2.2 },
    { label: "线段(确定)", color: cssVar("--lineSeg", "#059669"), dashed: false, w: 4.8 },
    { label: "线段(未完成)", color: cssVar("--lineSeg", "#059669"), dashed: true, w: 3.5 },
  ];
  ctx.save();
  ctx.font = "12px Consolas";
  ctx.textBaseline = "middle";
  let maxW = 0;
  for (const L of lines) {
    const tw = ctx.measureText(L.label).width + 52;
    if (tw > maxW) maxW = tw;
  }
  const lh = 18;
  const boxH = pad * 2 + lines.length * lh;
  const boxW = maxW;
  const x0 = PAD_L + 4;
  const y0 = PAD_T + 4;
  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.92)");
  ctx.strokeStyle = cssVar("--legendBorder", "rgba(148,163,184,0.6)");
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.rect(x0, y0, boxW, boxH);
  ctx.fill();
  ctx.stroke();
  let y = y0 + pad + lh / 2;
  for (const L of lines) {
    const xLine = x0 + pad;
    ctx.strokeStyle = L.color;
    ctx.lineWidth = L.w;
    if (L.dashed) ctx.setLineDash([5, 4]);
    else ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(xLine, y);
    ctx.lineTo(xLine + 24, y);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = cssVar("--legendText", "#0f172a");
    ctx.fillText(L.label, xLine + 32, y);
    y += lh;
  }
  ctx.restore();
}

function drawTradeBands(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const lastX = chart.kline[chart.kline.length - 1].x;
  const holdFillActive = cssVar("--holdFill", "rgba(59,130,246,0.14)");
  const holdFillPast = cssVar("--holdFillPast", "rgba(99,102,241,0.12)");

  const fillBand = (x1, x2, alphaMul, color) => {
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    const top = PAD_T;
    const bot = s.plotBottomY;
    ctx.save();
    ctx.fillStyle = color;
    ctx.globalAlpha = alphaMul;
    ctx.fillRect(Math.min(xa, xb), top, Math.abs(xb - xa), bot - top);
    ctx.restore();
  };

  for (const tr of tradeHistory) {
    if (tr.buyX != null && tr.sellX != null) {
      fillBand(tr.buyX, tr.sellX, 0.75, holdFillPast);
    }
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    fillBand(activeTrade.buyX, lastX, 0.85, holdFillActive);
  }
}

function drawTradeMarkers(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const buyC = cssVar("--markBuy", "#dc2626");
  const sellC = cssVar("--markSell", "#16a34a");

  const mark = (xBar, color, tag) => {
    if (xBar < s.xMin || xBar > s.xMax) return;
    const xp = s.x(xBar);
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash([5, 4]);
    ctx.beginPath();
    ctx.moveTo(xp, PAD_T);
    ctx.lineTo(xp, s.plotBottomY);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = color;
    ctx.font = "bold 14px Consolas";
    ctx.textAlign = "center";
    ctx.fillText(tag, xp, s.plotBottomY + 18);
    ctx.restore();
  };

  for (const tr of tradeHistory) {
    if (tr.buyX != null) mark(tr.buyX, buyC, "买");
    if (tr.sellX != null) mark(tr.sellX, sellC, "卖");
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    mark(activeTrade.buyX, buyC, "买");
  }
}

function drawTradeRays(s) {
  const drawRay = (x1, y1, x2, color, dashed) => {
    if (x1 == null || x2 == null || y1 == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2.0;
    if (dashed) ctx.setLineDash([7, 5]);
    else ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(s.x(x1), s.y(y1));
    ctx.lineTo(s.x(x2), s.y(y1));
    ctx.stroke();
    ctx.restore();
  };

  const rayBuy = cssVar("--rayBuy", "#f97316");
  const raySell = cssVar("--raySell", "#14b8a6");
  for (const tr of tradeHistory) {
    drawRay(tr.buyX, tr.buyPrice, tr.sellX, rayBuy, false);
    drawRay(tr.sellX, tr.sellPrice, tr.buyX, raySell, true);
  }
  if (activeTrade && activeTrade.buyX != null && activeTrade.buyPrice != null) {
    const rightTo = Math.max(s.xMax, activeTrade.buyX + 1);
    drawRay(activeTrade.buyX, activeTrade.buyPrice, rightTo, rayBuy, false);
  }
}

function drawIndicators(chart, s) {
  if (!chart.indicators || chart.indicators.length === 0) return;
  const ind = chart.indicators;
  const visibleInd = ind.filter(i => i.x >= s.xMin && i.x <= s.xMax);
  
  if (s.indType === "boll") {
    // Draw on main chart
    ctx.save();
    ctx.lineWidth = 1;
    const drawBollLine = (key, color) => {
      ctx.strokeStyle = color;
      ctx.beginPath();
      let first = true;
      for (const i of visibleInd) {
        const xp = s.x(i.x);
        const yp = s.y(i.boll[key]);
        if (first) ctx.moveTo(xp, yp);
        else ctx.lineTo(xp, yp);
        first = false;
      }
      ctx.stroke();
    };
    drawBollLine("mid", "#94a3b8");
    drawBollLine("up", "#f59e0b");
    drawBollLine("down", "#f59e0b");
    ctx.restore();
  } else if (s.indType === "demark") {
    ctx.save();
    ctx.font = "bold 12px Consolas";
    ctx.textAlign = "center";
    for (const i of visibleInd) {
      if (!i.demark) continue;
      for (const pt of i.demark) {
        const xp = s.x(pt.x);
        const up = pt.dir === "UP";
        const yp = up ? s.y(s.visibleK.find(k => k.x === pt.x)?.h || 0) - 15 : s.y(s.visibleK.find(k => k.x === pt.x)?.l || 0) + 20;
        ctx.fillStyle = up ? cssVar("--candleUp", "#ef4444") : cssVar("--candleDown", "#22c55e");
        ctx.fillText(pt.val, xp, yp);
      }
    }
    ctx.restore();
  } else if (s.indType === "trendline") {
    if (chart.trend_lines) {
      ctx.save();
      ctx.lineWidth = 2;
      for (const tl of chart.trend_lines) {
        const y_start = tl.y0 + tl.slope * (s.xMin - tl.x0);
        const y_end = tl.y0 + tl.slope * (s.xMax - tl.x0);
        ctx.strokeStyle = tl.type === "OUTSIDE" ? "#a855f7" : "#ec4899"; // Purple/Pink
        ctx.setLineDash([5, 5]);
        ctx.beginPath();
        ctx.moveTo(s.x(s.xMin), s.y(y_start));
        ctx.lineTo(s.x(s.xMax), s.y(y_end));
        ctx.stroke();
      }
      ctx.restore();
    }
  } else if (["macd", "kdj", "rsi"].includes(s.indType)) {
    // Draw on sub chart
    const subT = s.plotBottomY + 20;
    const subB = s.h - PAD_B;
    const subH = subB - subT;
    
    let subYMin = Infinity, subYMax = -Infinity;
    if (s.indType === "macd") {
      for (const i of visibleInd) {
        subYMin = Math.min(subYMin, i.macd.dif, i.macd.dea, i.macd.macd);
        subYMax = Math.max(subYMax, i.macd.dif, i.macd.dea, i.macd.macd);
      }
    } else if (s.indType === "kdj") {
      subYMin = 0; subYMax = 100;
      for (const i of visibleInd) {
        subYMin = Math.min(subYMin, i.kdj.k, i.kdj.d, i.kdj.j);
        subYMax = Math.max(subYMax, i.kdj.k, i.kdj.d, i.kdj.j);
      }
    } else if (s.indType === "rsi") {
      subYMin = 0; subYMax = 100;
    }
    
    if (subYMin === subYMax) { subYMin -= 1; subYMax += 1; }
    const subYSpan = subYMax - subYMin;
    const subY = (val) => subB - ((val - subYMin) / subYSpan) * subH;
    
    ctx.save();
    // Sub chart axes labels
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.font = "10px Consolas";
    ctx.fillText(subYMax.toFixed(2), 4, subT + 10);
    ctx.fillText(subYMin.toFixed(2), 4, subB);
    
    const theme = document.documentElement.getAttribute("data-theme") || "light";
    const lineMain = theme === "light" ? "#1e293b" : "#f8fafc";
    
    if (s.indType === "macd") {
      // Draw MACD histogram
      for (const i of visibleInd) {
        const xp = s.x(i.x);
        const yp = subY(i.macd.macd);
        const y0 = subY(0);
        ctx.fillStyle = i.macd.macd >= 0 ? cssVar("--candleUp", "#ef4444") : cssVar("--candleDown", "#22c55e");
        ctx.fillRect(xp - 1, Math.min(yp, y0), 2, Math.abs(yp - y0));
      }
      // Draw DIF, DEA lines
      const drawLine = (key, color) => {
        ctx.strokeStyle = color;
        ctx.beginPath();
        let first = true;
        for (const i of visibleInd) {
          const xp = s.x(i.x);
          const yp = subY(i.macd[key]);
          if (first) ctx.moveTo(xp, yp);
          else ctx.lineTo(xp, yp);
          first = false;
        }
        ctx.stroke();
      };
      drawLine("dif", lineMain);
      drawLine("dea", "#fbbf24");
    } else if (s.indType === "kdj") {
      const drawLine = (key, color) => {
        ctx.strokeStyle = color;
        ctx.beginPath();
        let first = true;
        for (const i of visibleInd) {
          const xp = s.x(i.x);
          const yp = subY(i.kdj[key]);
          if (first) ctx.moveTo(xp, yp);
          else ctx.lineTo(xp, yp);
          first = false;
        }
        ctx.stroke();
      };
      drawLine("k", lineMain);
      drawLine("d", "#fbbf24");
      drawLine("j", "#f472b6");
    } else if (s.indType === "rsi") {
      ctx.strokeStyle = lineMain;
      ctx.beginPath();
      let first = true;
      for (const i of visibleInd) {
        const xp = s.x(i.x);
        const yp = subY(i.rsi);
        if (first) ctx.moveTo(xp, yp);
        else ctx.lineTo(xp, yp);
        first = false;
      }
      ctx.stroke();
    }
    ctx.restore();
  }
}

function drawBsp(arr, s) {
  // draw bsp types below candles
  const groups = {};
  for (const p of arr || []) {
    if (p.x < s.xMin || p.x > s.xMax) continue;
    if (!groups[p.x]) groups[p.x] = [];
    groups[p.x].push(p);
  }
  const xs = Object.keys(groups)
    .map((x) => Number(x))
    .sort((a, b) => a - b);

  const bspBaseY = s.h - 10;
  const lineH = 22;
  ctx.font = "bold 22px Consolas";
  const colBuy = cssVar("--bspBuy", "#dc2626");
  const colSell = cssVar("--bspSell", "#16a34a");

  for (const x of xs) {
    const xp = s.x(x);
    const ps = groups[x];
    // stack labels (并列换行 -> vertical stacking)
    const maxLines = 8;
    for (let i = 0; i < Math.min(ps.length, maxLines); i++) {
      const p = ps[i];
      const c = p.is_buy ? colBuy : colSell;
      ctx.fillStyle = c;
      const txt = (p.is_buy ? "b" : "s") + p.label;
      ctx.fillText(txt, xp - 10, bspBaseY - i * lineH);
    }
  }
}

function draw(chart) {
  const cw = canvas.clientWidth;
  const ch = canvas.clientHeight;
  ctx.clearRect(0, 0, cw, ch);
  ctx.fillStyle = cssVar("--chartBg", "#ffffff");
  ctx.fillRect(0, 0, cw, ch);
  if (!chart || !chart.kline || chart.kline.length === 0) return;

  const xMin = Math.max(allXMin, viewXMin);
  const xMax = viewXMax; // 允许右侧空白
  const s = toScaler(chart, xMin, xMax);

  drawGridLines(s);
  drawChips(chart, s);
  drawTradeBands(s, chart);
  drawTradeRays(s);
  drawAxes(s);
  drawIndicators(chart, s);
  drawCandles(chart, s);
  // 分型最细虚线 → 笔中等实线 → 线段最粗实线
  drawLines(chart.fx_lines || [], s, cssVar("--lineFx", "#06b6d4"), 1.1, true);
  drawLines((chart.bi || []).filter((x) => x.is_sure), s, cssVar("--lineBi", "#f59e0b"), 3.1, false);
  drawLines((chart.bi || []).filter((x) => !x.is_sure), s, cssVar("--lineBi", "#f59e0b"), 2.2, true);
  drawLines((chart.seg || []).filter((x) => x.is_sure), s, cssVar("--lineSeg", "#059669"), 4.8, false);
  drawLines((chart.seg || []).filter((x) => !x.is_sure), s, cssVar("--lineSeg", "#059669"), 3.5, true);
  drawBsp(bspHistory || [], s);
  drawTradeMarkers(s, chart);
  drawCrosshair(s);
  drawLegend();
}

async function api(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(body || {})
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.detail || JSON.stringify(data));
  return data;
}

function refreshUI(payload, options) {
  const afterStep = options && options.afterStep;
  lastPayload = payload;
  sessionFinished = !!payload.finished;
  if (payload.ready && payload.chart && payload.chart.bsp) {
    for (const p of payload.chart.bsp) {
      const k = `${p.x}|${p.label}|${p.is_buy ? 1 : 0}`;
      if (bspHistoryKey.has(k)) continue;
      bspHistoryKey.add(k);
      bspHistory.push(p);
    }
  }
  setState(payload);
  if (payload.ready) {
    const ks = payload.chart && payload.chart.kline ? payload.chart.kline : [];
    if (ks.length > 0) {
      allXMin = ks[0].x;
      allXMax = ks[ks.length - 1].x;
      if (!viewReady) {
        viewXMin = allXMin;
        viewXMax = allXMax;
        viewReady = true;
      } else {
        if (!userAdjustedView) {
          // 未手动操作视窗前，始终自动展示全量
          viewXMin = allXMin;
          viewXMax = allXMax;
        } else {
          // 手动操作后仅做边界修正
          if (viewXMin < allXMin) viewXMin = allXMin;
          if (viewXMin >= viewXMax) {
            viewXMin = allXMin;
            viewXMax = allXMax;
            userAdjustedView = false;
          }
        }
      }
      if (afterStep) ensureLatestKVisible();
      draw(payload.chart);
    }
  }
  $("btnStep").disabled = !payload.ready || sessionFinished;
  $("btnFinish").disabled = !payload.ready || sessionFinished;
  $("btnBuy").disabled = !payload.ready || sessionFinished || payload.price === null || payload.account.position > 0;
  $("btnSell").disabled = !payload.ready || sessionFinished || !payload.account.can_sell;
  $("configCard").classList.toggle("collapsed", payload.ready);
}

$("btnInit").onclick = async () => {
  try {
    const payload = await api("/api/init", {
      code: $("code").value,
      begin_date: $("begin").value,
      end_date: $("end").value || null,
      initial_cash: Number($("cash").value),
      autype: $("autype").value
    });
    document.title = `chan.py 复盘训练器 - ${(payload.name ? payload.name : payload.code)}`;
    setMsg(`加载成功：${payload.name ? payload.name : payload.code}，请点击“下一根K线”。`);
    $("btnInit").disabled = true;
    $("code").disabled = true;
    $("begin").disabled = true;
    $("end").disabled = true;
    $("cash").disabled = true;
    $("autype").disabled = true;
    userAdjustedView = false;
    viewReady = false;
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    sessionFinished = false;
    refreshUI(payload);
  } catch (e) {
    setMsg("加载失败：" + e.message);
  }
};

$("btnStep").onclick = async () => {
  try {
    const payload = await api("/api/step");
    setMsg(payload.message || "步进成功");
    refreshUI(payload, { afterStep: true });
    // 先渲染最新K线，再提示“本根新增K线”上出现的买卖点
    if (payload && payload.ready && payload.chart && payload.chart.kline && payload.chart.kline.length > 0) {
      const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
      const hits = (payload.chart.bsp || []).filter(p => p.x === lastX);
      if (hits.length > 0) {
        const lines = hits.map(p => (p.is_buy ? "买点" : "卖点") + ":" + p.label).join("\\n");
        const key = lastX + "|" + lines;
        if (!lastSeenBspKey.has(key)) {
          lastSeenBspKey.add(key);
          setTimeout(() => {
            alert(`出现买卖点\\n${lines}`);
            setMsg(`出现买卖点 @${payload.time}\\n${lines}`);
          }, 0);
        }
      }
    }
  } catch (e) {
    setMsg("步进失败：" + e.message);
  }
};

$("btnBuy").onclick = async () => {
  try {
    const payload = await api("/api/buy");
    setMsg(payload.message || "买入成功");
    if (payload && payload.ready && payload.chart && payload.chart.kline && payload.chart.kline.length > 0 && payload.price !== null) {
      const buyX = payload.chart.kline[payload.chart.kline.length - 1].x;
      activeTrade = {
        buyX: buyX,
        buyPrice: Number(payload.price),
        shares: Number(payload.account.position || 0),
        sellX: null,
        sellPrice: null,
      };
    }
    refreshUI(payload);
  } catch (e) {
    setMsg("买入失败：" + e.message);
  }
};

$("btnSell").onclick = async () => {
  try {
    const payload = await api("/api/sell");
    setMsg(payload.message || "卖出成功");
    if (payload && payload.ready && payload.chart && payload.chart.kline.length > 0 && payload.price !== null) {
      const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
      if (activeTrade && activeTrade.buyX !== null) {
        tradeHistory.push({
          buyX: activeTrade.buyX,
          buyPrice: activeTrade.buyPrice,
          shares: activeTrade.shares || 0,
          sellX: lastX,
          sellPrice: Number(payload.price),
        });
      }
    }
    activeTrade = null;
    refreshUI(payload);
  } catch (e) {
    setMsg("卖出失败：" + e.message);
  }
};

$("btnFinish").onclick = async () => {
  try {
    const payload = await api("/api/finish");
    refreshUI(payload);
    setMsg("训练已结束。");
    if (confirm("训练结束，是否下载训练结果？")) {
      let wins = 0;
      let loss = 0;
      let sumPnl = 0;
      let peak = 0;
      let curve = 0;
      let maxDd = 0;
      const rows = [];
      rows.push("idx,buy_x,buy_price,sell_x,sell_price,shares,pnl,pnl_pct,hold_bars");
      for (let i = 0; i < tradeHistory.length; i++) {
        const tr = tradeHistory[i];
        const shares = tr.shares || 0;
        const pnl = (tr.sellPrice - tr.buyPrice) * shares;
        const pnlPct = tr.buyPrice === 0 ? 0 : ((tr.sellPrice - tr.buyPrice) / tr.buyPrice) * 100;
        const hold = Math.max(0, tr.sellX - tr.buyX);
        if (pnl >= 0) wins += 1;
        else loss += 1;
        sumPnl += pnl;
        curve += pnl;
        if (curve > peak) peak = curve;
        const dd = peak - curve;
        if (dd > maxDd) maxDd = dd;
        rows.push(`${i + 1},${tr.buyX},${tr.buyPrice.toFixed(4)},${tr.sellX},${tr.sellPrice.toFixed(4)},${shares},${pnl.toFixed(2)},${pnlPct.toFixed(2)},${hold}`);
      }
      const n = tradeHistory.length;
      const winRate = n === 0 ? 0 : (wins / n) * 100;
      const avgPnl = n === 0 ? 0 : sumPnl / n;
      rows.unshift(`# 胜率,${winRate.toFixed(2)}%`);
      rows.unshift(`# 平均每笔盈亏,${avgPnl.toFixed(2)}`);
      rows.unshift(`# 最大回撤近似(按已平仓序列),${maxDd.toFixed(2)}`);
      rows.unshift(`# 交易笔数,${n}`);
      rows.unshift(`# 标的,${payload.name || payload.code || "-"}`);
      rows.unshift(`# 导出时间,${new Date().toISOString()}`);
      const blob = new Blob([rows.join("\\n")], { type: "text/csv;charset=utf-8" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = `chan_trades_${payload.code || "session"}_${Date.now()}.csv`;
      a.click();
      URL.revokeObjectURL(a.href);
    }
  } catch (e) {
    setMsg("结束失败：" + e.message);
  }
};

$("btnReset").onclick = async () => {
  try {
    const payload = await api("/api/reset");
    $("btnInit").disabled = false;
    $("code").disabled = false;
    $("begin").disabled = false;
    $("end").disabled = false;
    $("cash").disabled = false;
    $("autype").disabled = false;
    $("configCard").classList.remove("collapsed");
    document.title = "chan.py 复盘训练器";
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    lastPayload = null;
    sessionFinished = false;
    setState(payload);
    ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
    setMsg("已重置，可重新配置并加载会话。");
  } catch (e) {
    setMsg("重置失败：" + e.message);
  }
};

$("btnExit").onclick = () => {
  setMsg("正在尝试关闭页面...");
  window.close();
  setTimeout(() => {
    setMsg("浏览器可能拦截了关闭。请手动关闭此页面。");
  }, 400);
};

$("theme").onchange = () => applyThemeFromSelect();
for (const id of ["chipEnabled"]) {
  $(id).onchange = () => {
    if (!lastPayload || !lastPayload.ready) return;
    draw(lastPayload.chart);
  };
}
applyThemeFromSelect();
</script>
</body>
</html>
"""


APP_STATE = AppState()
APP_STOCK_NAME: Optional[str] = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    CBaoStock.do_init()
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
        # 获取股票名称（BaoStock basic info）
        try:
            api = CBaoStock(code=code_norm, k_type=KL_TYPE.K_DAY, begin_date=req.begin_date, end_date=req.end_date, autype=autype)
            stock_name = api.name
        except Exception:
            stock_name = None
        global APP_STOCK_NAME
        APP_STOCK_NAME = stock_name

        APP_STATE.stepper.init(code_norm, req.begin_date, req.end_date, autype)
        APP_STATE.account.reset(req.initial_cash)
        APP_STATE.ready = True
        APP_STATE.finished = False
        # init后先推进一根，确保前端有可视数据并可交互
        APP_STATE.stepper.step()
        return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.post("/api/step")
def api_step():
    if not APP_STATE.ready:
        raise HTTPException(status_code=400, detail="请先初始化会话")
    if APP_STATE.finished:
        raise HTTPException(status_code=400, detail="当前会话已结束，请重新训练")
    try:
        ok = APP_STATE.stepper.step()
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = "已到最后一根K线" if not ok else "步进成功"
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
        detail = APP_STATE.account.buy_with_all_cash(price, APP_STATE.stepper.step_idx)
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
        detail = APP_STATE.account.sell_all(price, APP_STATE.stepper.step_idx)
        payload = APP_STATE.build_payload(stock_name=APP_STOCK_NAME)
        payload["message"] = f"卖出结果：{json.dumps(detail, ensure_ascii=False)}"
        return payload
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e)) from e


@app.get("/api/state")
def api_state():
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


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
    APP_STATE.account = PaperAccount(initial_cash=1_000_000, cash=1_000_000)
    APP_STATE.ready = False
    APP_STATE.finished = False
    return APP_STATE.build_payload(stock_name=APP_STOCK_NAME)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000)

