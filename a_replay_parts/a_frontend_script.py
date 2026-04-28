FRONTEND_SCRIPT = """\

const $ = (id) => document.getElementById(id);
function markUiBound(id) {
  const el = $(id);
  if (el) el.dataset.bound = "1";
}
const canvas = $("chart");
const ctx = canvas.getContext("2d");
function safeJsonParse(raw, fallback) {
  try {
    if (raw === null || raw === undefined || raw === "") return fallback;
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function storageGet(key, fallback = null) {
  try {
    return localStorage.getItem(key);
  } catch (_) {
    return fallback;
  }
}

function storageSet(key, value) {
  try {
    localStorage.setItem(key, value);
    return true;
  } catch (_) {
    return false;
  }
}

function storageRemove(key) {
  try {
    localStorage.removeItem(key);
    return true;
  } catch (_) {
    return false;
  }
}

function ensureObject(v, fallback = {}) {
  return v && typeof v === "object" && !Array.isArray(v) ? v : fallback;
}

function ensureArray(v, fallback = []) {
  return Array.isArray(v) ? v : fallback;
}
let lastPayload = null;
let allXMin = 0;
let allXMax = 0;
let viewXMin = 0;
let viewXMax = 0;
let viewReady = false;
let userAdjustedView = false;
let userRays = ensureArray(safeJsonParse(storageGet("chan_user_rays"), []), []);
let userBiRays = ensureArray(safeJsonParse(storageGet("chan_user_bi_rays"), []), []);
let userBiRaysDirty = false;
let pendingBiRayPts = [];
let activeTool = storageGet("chan_active_tool") || "none"; // none | horizontalRay | biRay
let selectedDrawing = null; // { type: "ray"|"biRay", index: number }
let chartClickMoved = false;
let chartMouseDownPos = null;

const PAD_L = 64;
const PAD_R = 64;
const PAD_T = 10;
const PAD_B = 90;
const PRICE_AXIS_STEP = 0.5;
const WEEKDAY_NAMES = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

let isPanning = false;
let panStartX = 0;
let panStartY = 0;
let panStartViewMin = 0;
let panStartViewMax = 0;
let panStartYShiftRatio = 0;
let viewYShiftRatio = 0;
let viewYZoomRatio = 1.0;

let activeTrade = null;
let tradeHistory = [];
let lastSeenBspKey = new Set();
let bspHistory = [];
let bspHistoryKey = new Set();
let sessionFinished = false;
let stepInFlight = false;
let pendingBspPrompt = null;
let crosshairEnabled = false;
let crosshairX = null;
let crosshairY = null;
let canvasHovered = false;
let signalHoverBoxes = [];
let selectedMainIndicatorSlot = Number(storageGet("chan_selected_main_indicator_slot") || "0");
let selectedSubIndicatorSlot = Number(storageGet("chan_selected_sub_indicator_slot") || "0");
let indicatorMainSlots = ensureObject(safeJsonParse(storageGet("chan_indicator_main_slots"), null), null);
let indicatorSubSlots = ensureObject(safeJsonParse(storageGet("chan_indicator_sub_slots"), null), null);

const defaultMainSlots = { "0": [], "1": [], "2": [], "3": [], "4": [], "5": [] };
const defaultSubSlots = { "0": [], "1": [], "2": [], "3": [], "4": [], "5": [] };

if (!indicatorMainSlots || !indicatorSubSlots) {
  indicatorMainSlots = { ...defaultMainSlots };
  indicatorSubSlots = { ...defaultSubSlots };
}
if (!Number.isFinite(selectedMainIndicatorSlot) || selectedMainIndicatorSlot < 0 || selectedMainIndicatorSlot > 5) {
  selectedMainIndicatorSlot = 0;
}
if (!Number.isFinite(selectedSubIndicatorSlot) || selectedSubIndicatorSlot < 0 || selectedSubIndicatorSlot > 5) {
  selectedSubIndicatorSlot = 0;
}
storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));

// Migration from legacy string-based slots to arrays
for (let i = 0; i <= 5; i++) {
  const mainVal = indicatorMainSlots[String(i)];
  if (typeof mainVal === "string") indicatorMainSlots[String(i)] = (mainVal === "none" || mainVal === "enabled" ? [] : [mainVal]);
  else if (!Array.isArray(mainVal)) indicatorMainSlots[String(i)] = [];

  let v = indicatorSubSlots[String(i)];
  if (typeof v === "string") indicatorSubSlots[String(i)] = (v === "none" ? [] : [v]);
  else if (!Array.isArray(v)) indicatorSubSlots[String(i)] = [];
}

storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
const MAIN_INDICATORS = new Set(["boll", "demark", "trendline"]);
const SUB_INDICATORS = new Set(["macd", "kdj", "rsi"]);

const DEFAULT_CHAN_CONFIG = {
  chan_algo: "classic",
  bi_strict: true,
  bi_algo: "normal",
  bi_fx_check: "strict",
  gap_as_kl: false,
  bi_end_is_peak: true,
  bi_allow_sub_peak: true,
  seg_algo: "chan",
  left_seg_method: "peak",
  zs_algo: "normal",
  zs_combine: true,
  zs_combine_mode: "zs",
  one_bi_zs: false,
  trigger_step: true,
  skip_step: 0,
  kl_data_check: true,
  print_warning: false,
  print_err_time: false,
  mean_metrics: "",
  trend_metrics: "",
  macd: { fast: 12, slow: 26, signal: 9 },
  cal_demark: false,
  cal_rsi: false,
  cal_kdj: false,
  rsi_cycle: 14,
  kdj_cycle: 9,
  boll_n: 20,
  // BSP General
  divergence_rate: "inf",
  min_zs_cnt: 1,
  bsp1_only_multibi_zs: true,
  max_bs2_rate: 0.9999,
  macd_algo: "peak",
  bs1_peak: true,
  bs_type: "1,1p,2,2s,3a,3b",
  bsp2_follow_1: true,
  bsp3_follow_1: true,
  bsp3_peak: false,
  bsp2s_follow_2: false,
  max_bsp2s_lv: "",
  strict_bsp3: false,
  bsp3a_max_zs_cnt: 1
};

const DEFAULT_CHART_CONFIG = {
  theme: "light",
  crosshair: { width: 5, color: "#000000", fontSize: 16 },
  fx: { width: 1.1, color: "#06b6d4", dashed: true },
  fract: { widthSure: 2.2, widthUnsure: 1.6, color: "#d97706" },
  bi: { widthSure: 3.1, widthUnsure: 2.2, color: "#f59e0b" },
  seg: { widthSure: 4.8, widthUnsure: 3.5, color: "#059669" },
  segseg: { widthSure: 6.0, widthUnsure: 4.6, color: "#2563eb" },
  fractZs: { width: 1.4, color: "#b45309", enabled: true },
  biZs: { width: 1.8, color: "#f59e0b", enabled: true },
  segZs: { width: 2.4, color: "#059669", enabled: true },
  segsegZs: { width: 2.8, color: "#2563eb", enabled: true },
  candle: { width: 1.4, upColor: "#ef4444", downColor: "#22c55e" },
  bspBi: { fontSize: 14, lineColor: "#94a3b8", lineWidth: 1, lineStyle: "dashed", lineDash: [5, 4] },
  bspSeg: { fontSize: 14, lineColor: "#64748b", lineWidth: 1.1, lineStyle: "dashed", lineDash: [5, 4] },
  bspSegseg: { fontSize: 14, lineColor: "#475569", lineWidth: 1.2, lineStyle: "dashed", lineDash: [5, 4] },
  rhythmLine: {
    enabled: true,
    fractToBiEnabled: true,
    biToSegEnabled: true,
    segToSegsegEnabled: true,
    group1LineColor: "#9333ea",
    group1LineWidth: 1.2,
    group1LineStyle: "dashed",
    group1TextColor: "#9333ea",
    group1TextFontSize: 12,
    group1TextFontWeight: "bold",
    group2LineColor: "#0f766e",
    group2LineWidth: 1.6,
    group2LineStyle: "solid",
    group2TextColor: "#0f766e",
    group2TextFontSize: 13,
    group2TextFontWeight: "bold",
    group3LineColor: "#2563eb",
    group3LineWidth: 2.0,
    group3LineStyle: "dashed",
    group3TextColor: "#2563eb",
    group3TextFontSize: 14,
    group3TextFontWeight: "bold",
    group4LineColor: "#ea580c",
    group4LineWidth: 2.4,
    group4LineStyle: "solid",
    group4TextColor: "#ea580c",
    group4TextFontSize: 15,
    group4TextFontWeight: "bold",
    group5LineColor: "#be123c",
    group5LineWidth: 2.8,
    group5LineStyle: "dotted",
    group5TextColor: "#be123c",
    group5TextFontSize: 16,
    group5TextFontWeight: "bold"
  },
  rhythmHit: {
    fontSize: 14,
    color: "#7c3aed",
    lineColor: "#8b5cf6",
    lineWidth: 1,
    lineStyle: "dashed",
    overflowLimit: 4,
    overflowColor: "#7c3aed"
  },
  trade: {
    buyColor: "#dc2626",
    sellColor: "#16a34a",
    rangeFillBuy: "#dc2626",
    rangeFillSell: "#16a34a",
    profitBandColor: "#f97316",
    lossBandColor: "#0ea5e9",
    profitColor: "#ef4444",
    lossColor: "#22c55e",
    popupFontSize: 16,
    markerFontSize: 14,
    markerFontWeight: "bold",
    markerLineWidth: 2,
    markerLineStyle: "dashed",
    closeLineWidth: 2,
    buyCloseLineStyle: "solid",
    sellCloseLineStyle: "dashed"
  },
  tradeStatus: {
    titleFontSize: 14,
    titleFontWeight: "bold",
    titleColor: "#0f172a",
    labelFontSize: 12,
    labelFontWeight: "normal",
    labelColor: "#64748b",
    valueFontSize: 13,
    valueFontWeight: "bold",
    valueColor: "#0f172a"
  },
  chip: {
    enabled: true,
    stretchLevel: 5,
    bucketStep: 0.1,
    color: "rgba(59,130,246,0.45)",
    peakLineEnabled: true,
    peakRefMode: "latest_visible",
    peakLineColor: "#2563eb",
    peakLineWidth: 1.2,
    peakLineStyle: "dashed"
  },
  xAxis: { fontSize: 12, rotation: -45, fontWeight: "normal", interval: 10 },
  yAxis: { fontSize: 12, fontWeight: "normal", interval: 0.5 },
  toast: { fontSize: 16, fontWeight: "bold", speed: 3000 },
  legend: { fontSize: 12, fontWeight: "normal", color: "#0f172a" },
  userRay: { color: "#f97316", width: 1.5, dash: [8, 4], fontSize: 12 }
};

function deepMerge(target, source) {
  if (!source || typeof source !== "object" || Array.isArray(source)) return target;
  for (const key in source) {
    if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key])) {
      if (!target[key]) target[key] = {};
      deepMerge(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

let chanConfig = deepMerge(
  JSON.parse(JSON.stringify(DEFAULT_CHAN_CONFIG)),
  ensureObject(safeJsonParse(storageGet("chan_logic_config"), null), {})
);

function migrateChartConfig(cfg) {
  const next = ensureObject(cfg, {});
  if (next.bsp && !next.bspBi) next.bspBi = JSON.parse(JSON.stringify(next.bsp));
  if (!next.fract) next.fract = {};
  if (!next.segseg) next.segseg = {};
  if (!next.fractZs) next.fractZs = {};
  if (!next.segsegZs) next.segsegZs = {};
  if (!next.bspBi) next.bspBi = {};
  if (!next.bspSeg) next.bspSeg = {};
  if (!next.bspSegseg) next.bspSegseg = {};
  if (!next.rhythmLine) next.rhythmLine = {};
  if (!next.rhythmHit) next.rhythmHit = {};
  return next;
}

let savedChartConfig = ensureObject(safeJsonParse(storageGet("chan_chart_config"), {}), {});
let chartConfig = deepMerge(JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG)), migrateChartConfig(savedChartConfig));

const DEFAULT_SESSION_CONFIG = {
  code: "600340",
  begin: "2018-01-01",
  end: "",
  cash: "10000",
  autype: "qfq",
  theme: "light",
  chipEnabled: true,
  chipStretchLevel: "5",
  chipBucketStep: "0.1",
  fractZsEnabled: true,
  biZsEnabled: true,
  segZsEnabled: true,
  segsegZsEnabled: true,
  stepN: "5"
};
let sessionConfig = ensureObject(
  safeJsonParse(storageGet("chan_session_config"), JSON.parse(JSON.stringify(DEFAULT_SESSION_CONFIG))),
  JSON.parse(JSON.stringify(DEFAULT_SESSION_CONFIG))
);

const SHORTCUT_ACTIONS = [
  { id: "openChanSettings", label: "打开缠论配置", description: "打开缠论逻辑配置面板。", defaults: ["l"], contexts: ["global"], buttonId: "btnChanSettingsOpen" },
  { id: "openChartSettings", label: "打开图表显示设置", description: "打开图表显示设置面板。", defaults: ["p"], contexts: ["global"], buttonId: "btnSettingsOpen" },
  { id: "openSystemSettings", label: "打开系统配置", description: "打开系统配置面板。", defaults: ["shift+p"], contexts: ["global"], buttonId: "btnSystemSettingsOpen" },
  { id: "toggleFullscreen", label: "切换全屏显示", description: "切换右侧图表区域全屏显示。", defaults: ["f11"], contexts: ["global"], buttonId: "btnFullscreen" },
  { id: "initSession", label: "加载会话", description: "根据当前代码、日期区间和初始资金加载复盘会话。", defaults: ["ctrl+i"], contexts: ["global"], buttonId: "btnInit" },
  { id: "resetSession", label: "重新训练", description: "清空当前会话并恢复到可重新配置的初始状态。", defaults: ["ctrl+r"], contexts: ["global"], buttonId: "btnReset" },
  { id: "nextBar", label: "步进到下一根K线", description: "步进到下一根 K 线；若当前 K 线命中买卖点或 1382，会合并为一个弹窗提示。", defaults: ["space"], contexts: ["global"], buttonId: "btnStep" },
  { id: "stepForwardN", label: "步进 N 根", description: "按步进数量 N 连续推进，遇到买卖点自动停止，并合并当根提示。", defaults: ["ctrl+alt+n"], contexts: ["global"], buttonId: "btnStepN" },
  { id: "stepBackwardN", label: "后退 N 根", description: "按步进数量 N 回退，会自动重建到更早状态。", defaults: ["ctrl+alt+m"], contexts: ["global"], buttonId: "btnBackN" },
  { id: "buyAll", label: "买入（全仓）", description: "按当前收盘价使用全部可用现金买入。", defaults: ["pageup"], contexts: ["global"], buttonId: "btnBuy" },
  { id: "sellAll", label: "卖出（全量）", description: "按当前收盘价全部卖出。", defaults: ["pagedown"], contexts: ["global"], buttonId: "btnSell" },
  { id: "centerLatest", label: "居中到最新K线", description: "将视图快速居中到最新一根 K 线。", defaults: ["c", "center"], contexts: ["global"] },
  { id: "drawHorizontalRay", label: "生成水平射线", description: "在当前十字光标价位生成一条水平射线。", defaults: ["ctrl+enter"], contexts: ["global"] },
  { id: "zoomYIn", label: "纵向放大", description: "放大图表纵轴缩放比例。", defaults: ["ctrl+alt+arrowup"], contexts: ["global"] },
  { id: "zoomYOut", label: "纵向缩小", description: "缩小图表纵轴缩放比例。", defaults: ["ctrl+alt+arrowdown"], contexts: ["global"] },
  { id: "zoomXIn", label: "横向放大", description: "放大图表横轴缩放比例。", defaults: ["ctrl+alt+arrowleft"], contexts: ["global"] },
  { id: "zoomXOut", label: "横向缩小", description: "缩小图表横轴缩放比例。", defaults: ["ctrl+alt+arrowright"], contexts: ["global"] },
  { id: "adjustCrosshairUp", label: "十字光标价格上移", description: "将十字光标对应价格向上微调。", defaults: ["ctrl+arrowup"], contexts: ["global"] },
  { id: "adjustCrosshairDown", label: "十字光标价格下移", description: "将十字光标对应价格向下微调。", defaults: ["ctrl+arrowdown"], contexts: ["global"] },
  { id: "saveChanSettings", label: "保存缠论配置", description: "在缠论配置面板中保存并立即应用配置。", defaults: ["s"], contexts: ["chanSettings"], buttonId: "btnChanSettingsSave" },
  { id: "saveChartSettings", label: "保存图表显示设置", description: "在图表显示设置面板中保存并立即应用配置。", defaults: ["s"], contexts: ["chartSettings"], buttonId: "btnSettingsSave" },
  { id: "saveSystemSettings", label: "保存系统配置", description: "在系统配置面板中保存并立即应用快捷键设置。", defaults: ["s"], contexts: ["systemSettings"], buttonId: "btnSystemSettingsSave" },
  { id: "confirmBspPrompt", label: "确认买卖点提示", description: "确认当前买卖点提示并允许继续步进。", defaults: ["enter"], contexts: ["bspPrompt"], buttonId: "bspPromptConfirm" },
  { id: "closeSettlement", label: "关闭交易结算", description: "关闭当前交易结算弹窗。", defaults: ["enter"], contexts: ["settlement"], buttonId: "btnSettlementClose" },
  { id: "setBspJudgeAuto", label: "买卖点判定：自动", description: "将笔/段/2段买卖点 ×/✓ 判定方式切换为自动（按上一级结构变向自动判定）。", defaults: ["z"], contexts: ["global"] },
  { id: "setBspJudgeManual", label: "买卖点判定：手动", description: "将笔/段/2段买卖点 ×/✓ 判定方式切换为手动（需点击按钮/快捷键手动检查）。", defaults: ["s"], contexts: ["global"] },
  { id: "checkBspJudge", label: "检查买卖点（手动）", description: "在手动模式下触发一次笔/段/2段买卖点 ×/✓ 判定检查。", defaults: ["j"], contexts: ["global"], buttonId: "btnJudgeBsp" },
];

const SHORTCUT_ACTION_MAP = SHORTCUT_ACTIONS.reduce((acc, action) => {
  acc[action.id] = action;
  return acc;
}, {});

const DEFAULT_SYSTEM_CONFIG = {
  bspJudgeMode: "auto",
  shortcuts: SHORTCUT_ACTIONS.reduce((acc, action) => {
    acc[action.id] = action.defaults.slice();
    return acc;
  }, {})
};

let systemConfig = ensureObject(
  safeJsonParse(storageGet("chan_system_config"), JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG))),
  JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG))
);

let compiledShortcuts = [];
let shortcutSequenceBuffer = [];
let shortcutSequenceLastAt = 0;
const SHORTCUT_SEQUENCE_TIMEOUT = 1500;

function escapeHtmlAttr(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function normalizeShortcutKeyToken(raw) {
  if (raw === undefined || raw === null) return null;
  const rawStr = String(raw);
  const aliasMap = {
    " ": "space",
    spacebar: "space",
    esc: "escape",
    return: "enter",
    del: "delete",
    plus: "+",
    minus: "-",
    left: "arrowleft",
    right: "arrowright",
    up: "arrowup",
    down: "arrowdown",
    pgup: "pageup",
    pgdn: "pagedown",
    cmd: "meta",
    command: "meta",
    win: "meta",
    windows: "meta",
    option: "alt",
    control: "ctrl",
  };
  const lowerRaw = rawStr.toLowerCase();
  if (aliasMap[lowerRaw]) return aliasMap[lowerRaw];
  const text = rawStr.trim().toLowerCase();
  if (!text) return null;
  if (aliasMap[text]) return aliasMap[text];
  if (/^key[a-z]$/.test(text)) return text.slice(3);
  if (/^digit[0-9]$/.test(text)) return text.slice(5);
  return text;
}

function eventToShortcutKeyToken(e) {
  const code = String(e.code || "");
  if (/^Key[A-Z]$/.test(code)) return code.slice(3).toLowerCase();
  if (/^Digit[0-9]$/.test(code)) return code.slice(5);
  if (/^Numpad[0-9]$/.test(code)) return code.slice(6);
  if (/^F[0-9]{1,2}$/.test(code)) return code.toLowerCase();
  const key = normalizeShortcutKeyToken(e.key);
  if (!key || ["shift", "ctrl", "alt", "meta"].includes(key)) return null;
  return key;
}

function parseShortcutToken(text) {
  const raw = String(text || "").trim();
  if (!raw) return null;
  
  // 处理规范化后的序列格式 seq:a>b>c
  if (raw.startsWith("seq:")) {
    const keys = raw.slice(4).split(">").map(normalizeShortcutKeyToken).filter(Boolean);
    if (keys.length > 0) return { type: "sequence", keys };
    return null;
  }

  const normalized = raw.toLowerCase().replace(/\s+/g, "");
  if (normalized.includes("+")) {
    const parts = normalized.split("+").filter(Boolean);
    if (parts.length === 0) return null;
    const combo = { type: "combo", ctrl: false, alt: false, shift: false, meta: false, key: null };
    for (let i = 0; i < parts.length; i += 1) {
      const part = normalizeShortcutKeyToken(parts[i]);
      if (!part) return null;
      if (part === "ctrl") combo.ctrl = true;
      else if (part === "alt") combo.alt = true;
      else if (part === "shift") combo.shift = true;
      else if (part === "meta") combo.meta = true;
      else if (i === parts.length - 1 && !combo.key) combo.key = part;
      else return null;
    }
    return combo.key ? combo : null;
  }
  const lower = raw.trim().toLowerCase();
  const single = normalizeShortcutKeyToken(lower);
  const specialSingles = new Set(["space", "enter", "escape", "tab", "backspace", "delete", "pageup", "pagedown", "home", "end", "insert", "arrowup", "arrowdown", "arrowleft", "arrowright", "meta"]);
  if (single && (single.length === 1 || specialSingles.has(single) || /^f[0-9]{1,2}$/.test(single))) {
    return { type: "combo", ctrl: false, alt: false, shift: false, meta: false, key: single };
  }
  const compact = lower.replace(/\s+/g, "");
  if (/^[a-z0-9]+$/.test(compact)) {
    return { type: "sequence", keys: compact.split("") };
  }
  const seqParts = lower.split(/\s+/).map(normalizeShortcutKeyToken).filter(Boolean);
  if (seqParts.length > 1) return { type: "sequence", keys: seqParts };
  return null;
}

function canonicalizeShortcut(def) {
  if (!def) return "";
  if (def.type === "sequence") return `seq:${def.keys.join(">")}`;
  const parts = [];
  if (def.ctrl) parts.push("ctrl");
  if (def.alt) parts.push("alt");
  if (def.shift) parts.push("shift");
  if (def.meta) parts.push("meta");
  parts.push(def.key);
  return parts.join("+");
}

function parseShortcutList(raw) {
  const parts = String(raw || "")
    .split(/[\\n,，;；]+/)
    .map(item => item.trim())
    .filter(Boolean);
  const parsed = [];
  const invalid = [];
  const seen = new Set();
  parts.forEach(item => {
    const def = parseShortcutToken(item);
    if (!def) {
      invalid.push(item);
      return;
    }
    const canonical = canonicalizeShortcut(def);
    if (canonical && !seen.has(canonical)) {
      parsed.push(def);
      seen.add(canonical);
    }
  });
  return { parsed, invalid };
}

function formatShortcut(def) {
  if (!def) return "";
  if (typeof def === "string") {
    const parsed = parseShortcutToken(def);
    return parsed ? formatShortcut(parsed) : def;
  }
  if (def.type === "sequence") {
    const joined = def.keys.join("");
    if (/^[a-z0-9]+$/.test(joined)) return joined;
    return def.keys.map(key => formatShortcut({ type: "combo", ctrl: false, alt: false, shift: false, meta: false, key })).join(" > ");
  }
  const labels = [];
  if (def.ctrl) labels.push("Ctrl");
  if (def.alt) labels.push("Alt");
  if (def.shift) labels.push("Shift");
  if (def.meta) labels.push("Meta");
  const keyMap = {
    space: "Space",
    enter: "Enter",
    pageup: "PageUp",
    pagedown: "PageDown",
    arrowup: "ArrowUp",
    arrowdown: "ArrowDown",
    arrowleft: "ArrowLeft",
    arrowright: "ArrowRight",
    escape: "Esc",
  };
  let keyLabel = keyMap[def.key] || def.key;
  if (/^[a-z]$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();
  else if (/^f[0-9]{1,2}$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();
  labels.push(keyLabel);
  return labels.join("+");
}

function getActionShortcuts(actionId) {
  if (systemConfig.shortcuts && Object.prototype.hasOwnProperty.call(systemConfig.shortcuts, actionId)) {
    return ensureArray(systemConfig.shortcuts[actionId], []).slice();
  }
  const meta = SHORTCUT_ACTION_MAP[actionId];
  return meta ? meta.defaults.slice() : [];
}

function getActionShortcutDisplay(actionId) {
  return getActionShortcuts(actionId)
    .map(item => formatShortcut(item))
    .filter(Boolean)
    .join(" / ");
}

function setActionShortcuts(actionId, parsedShortcuts) {
  if (!systemConfig.shortcuts) systemConfig.shortcuts = {};
  systemConfig.shortcuts[actionId] = parsedShortcuts.map(canonicalizeShortcut);
}

function normalizeSystemConfig() {
  const normalized = { shortcuts: {}, bspJudgeMode: "auto" };
  const rawMode = systemConfig && typeof systemConfig.bspJudgeMode === "string" ? systemConfig.bspJudgeMode : "auto";
  normalized.bspJudgeMode = rawMode === "manual" ? "manual" : "auto";
  SHORTCUT_ACTIONS.forEach(action => {
    const hasOwn = systemConfig.shortcuts && Object.prototype.hasOwnProperty.call(systemConfig.shortcuts, action.id);
    const source = ensureArray(hasOwn ? systemConfig.shortcuts[action.id] : action.defaults, []);
    const parsed = [];
    const seen = new Set();
    source.forEach(item => {
      const def = typeof item === "string" ? parseShortcutToken(item) : item;
      const canonical = canonicalizeShortcut(def);
      if (canonical && !seen.has(canonical)) {
        parsed.push(canonical);
        seen.add(canonical);
      }
    });
    normalized.shortcuts[action.id] = parsed;
  });
  systemConfig = normalized;
}

function saveSystemConfig() {
  normalizeSystemConfig();
  storageSet("chan_system_config", JSON.stringify(systemConfig));
  rebuildShortcutRegistry();
  updateShortcutUI();
}

function rebuildShortcutRegistry() {
  compiledShortcuts = SHORTCUT_ACTIONS.map((action, index) => {
    const parsedShortcuts = getActionShortcuts(action.id)
      .map(item => parseShortcutToken(item))
      .filter(Boolean);
    return { actionId: action.id, index, contexts: action.contexts || ["global"], shortcuts: parsedShortcuts };
  });
}

function getShortcutConflicts(actionId) {
  const own = new Set(getActionShortcuts(actionId));
  const conflicts = [];
  SHORTCUT_ACTIONS.forEach(action => {
    if (action.id === actionId) return;
    const overlap = getActionShortcuts(action.id).filter(item => own.has(item));
    if (overlap.length > 0) conflicts.push(`${action.label} (${overlap.map(item => formatShortcut(item)).join(" / ")})`);
  });
  return conflicts;
}

function setButtonShortcutLabel(button, baseLabel, actionId) {
  if (!button) return;
  const display = getActionShortcutDisplay(actionId);
  button.innerHTML = display ? `${baseLabel} <small>(${escapeHtmlAttr(display)})</small>` : baseLabel;
}

function updateShortcutUI() {
  setButtonShortcutLabel($("btnChanSettingsOpen"), "缠论配置...", "openChanSettings");
  setButtonShortcutLabel($("btnSettingsOpen"), "图表显示设置...", "openChartSettings");
  setButtonShortcutLabel($("btnSystemSettingsOpen"), "系统配置...", "openSystemSettings");
  if ($("btnInit").disabled && $("btnInit").textContent.includes("已加载")) {
    $("btnInit").innerHTML = "已加载";
  } else {
    setButtonShortcutLabel($("btnInit"), "加载会话", "initSession");
  }
  setButtonShortcutLabel($("btnReset"), "重新训练", "resetSession");
  setButtonShortcutLabel($("btnStep"), "下一根K线", "nextBar");
  setButtonShortcutLabel($("btnStepN"), "步进 N 根", "stepForwardN");
  setButtonShortcutLabel($("btnBackN"), "后退 N 根", "stepBackwardN");
  setButtonShortcutLabel($("btnBuy"), "买入（全仓）", "buyAll");
  setButtonShortcutLabel($("btnSell"), "卖出（全量）", "sellAll");
  $("btnChanSettingsSave").textContent = `保存并应用${getActionShortcutDisplay("saveChanSettings") ? ` (${getActionShortcutDisplay("saveChanSettings")})` : ""}`;
  $("btnSettingsSave").textContent = `保存并应用${getActionShortcutDisplay("saveChartSettings") ? ` (${getActionShortcutDisplay("saveChartSettings")})` : ""}`;
  $("btnSystemSettingsSave").textContent = `保存并应用${getActionShortcutDisplay("saveSystemSettings") ? ` (${getActionShortcutDisplay("saveSystemSettings")})` : ""}`;
  $("bspPromptConfirm").textContent = `确认（${getActionShortcutDisplay("confirmBspPrompt") || "Enter"} / 左键）`;
  $("btnSettlementClose").textContent = `确认${getActionShortcutDisplay("closeSettlement") ? `（${getActionShortcutDisplay("closeSettlement")}）` : ""}`;
  $("btnFullscreen").innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg> 全屏显示${getActionShortcutDisplay("toggleFullscreen") ? ` (${escapeHtmlAttr(getActionShortcutDisplay("toggleFullscreen"))})` : ""}`;
  $("btnFullscreen").setAttribute("data-tip", `切换图表区域全屏显示。快捷键：${getActionShortcutDisplay("toggleFullscreen") || "未设置"}。`);
  $("btnChanSettingsOpen").setAttribute("data-tip", `打开缠论逻辑配置面板，可调整笔、线段、中枢等算法。快捷键：${getActionShortcutDisplay("openChanSettings") || "未设置"}。`);
  $("btnSettingsOpen").setAttribute("data-tip", `打开图表显示设置面板，可调整主题、指标与绘制项。快捷键：${getActionShortcutDisplay("openChartSettings") || "未设置"}。`);
  $("btnSystemSettingsOpen").setAttribute("data-tip", `打开系统配置面板，可统一维护快捷键。快捷键：${getActionShortcutDisplay("openSystemSettings") || "未设置"}。`);
  $("btnInit").setAttribute("data-tip", `根据当前代码、日期区间、初始资金加载复盘会话。首次加载历史数据可能较慢。快捷键：${getActionShortcutDisplay("initSession") || "未设置"}。`);
  $("btnReset").setAttribute("data-tip", `清空当前会话并恢复到可重新配置的初始状态。快捷键：${getActionShortcutDisplay("resetSession") || "未设置"}。`);
  $("btnStep").setAttribute("data-tip", `步进到下一根K线。若当前K线命中买卖点或 1382 提示，会合并为一个弹窗提示。快捷键：${getActionShortcutDisplay("nextBar") || "未设置"}。`);
  $("btnStepN").setAttribute("data-tip", `按步进数量 N 连续推进，若中途遇到买卖点则自动停止。快捷键：${getActionShortcutDisplay("stepForwardN") || "未设置"}。`);
  $("btnBackN").setAttribute("data-tip", `按步进数量 N 回退，会自动重建到更早的状态。快捷键：${getActionShortcutDisplay("stepBackwardN") || "未设置"}。`);
  $("btnBuy").setAttribute("data-tip", `按当前收盘价使用全部可用现金买入，遵循单持仓和每步最多一笔规则。快捷键：${getActionShortcutDisplay("buyAll") || "未设置"}。`);
  $("btnSell").setAttribute("data-tip", `按当前收盘价全部卖出，若受 T+1 约束则按钮不可用。快捷键：${getActionShortcutDisplay("sellAll") || "未设置"}。`);
  $("tipStepN").setAttribute("data-tip", `设置连续步进或回退时使用的根数。步进快捷键：${getActionShortcutDisplay("stepForwardN") || "未设置"}；回退快捷键：${getActionShortcutDisplay("stepBackwardN") || "未设置"}。`);
  if ($("btnJudgeBsp")) {
    setButtonShortcutLabel($("btnJudgeBsp"), "检查买卖点", "checkBspJudge");
    $("btnJudgeBsp").setAttribute("data-tip", `手动检查笔/段/2段买卖点（仅手动判定模式下可用）。快捷键：${getActionShortcutDisplay("checkBspJudge") || "未设置"}。`);
  }
  initTooltips();
}

function isBspJudgeManual() {
  return systemConfig && systemConfig.bspJudgeMode === "manual";
}

function updateBspJudgeUI() {
  const btn = $("btnJudgeBsp");
  if (!btn) return;
  const manual = isBspJudgeManual();
  btn.style.display = manual ? "inline-flex" : "none";
  btn.disabled = !manual || !lastPayload || !lastPayload.ready;
}

function getActiveShortcutContexts() {
  if ($("settlementModal").classList.contains("show")) return ["settlement"];
  if (isSystemSettingsOpen()) return ["systemSettings"];
  if (isChanSettingsOpen()) return ["chanSettings"];
  if (isSettingsOpen()) return ["chartSettings"];
  return ["global"];
}

function shortcutMatchesEvent(def, e) {
  if (!def || def.type !== "combo") return false;
  const key = eventToShortcutKeyToken(e);
  if (!key) return false;
  return def.key === key &&
    !!def.ctrl === !!e.ctrlKey &&
    !!def.alt === !!e.altKey &&
    !!def.shift === !!e.shiftKey &&
    !!def.meta === !!e.metaKey;
}

function cleanupShortcutSequenceBuffer(now) {
  if (!shortcutSequenceLastAt || now - shortcutSequenceLastAt > SHORTCUT_SEQUENCE_TIMEOUT) {
    shortcutSequenceBuffer = [];
  }
  while (shortcutSequenceBuffer.length > 12) shortcutSequenceBuffer.shift();
}

function shortcutSequenceMatches(def) {
  if (!def || def.type !== "sequence" || def.keys.length === 0) return false;
  if (shortcutSequenceBuffer.length < def.keys.length) return false;
  const tail = shortcutSequenceBuffer.slice(-def.keys.length);
  return def.keys.every((key, idx) => tail[idx] === key);
}

function saveSessionConfig() {
  sessionConfig = {
    code: $("code").value,
    begin: $("begin").value,
    end: $("end").value,
    cash: $("cash").value,
    autype: $("autype").value,
    theme: chartConfig.theme,
    chipEnabled: chartConfig.chip.enabled,
    chipStretchLevel: String(chartConfig.chip.stretchLevel),
    chipBucketStep: String(chartConfig.chip.bucketStep),
    fractZsEnabled: chartConfig.fractZs.enabled,
    biZsEnabled: chartConfig.biZs.enabled,
    segZsEnabled: chartConfig.segZs.enabled,
    segsegZsEnabled: chartConfig.segsegZs.enabled,
    stepN: $("stepN").value
  };
  storageSet("chan_session_config", JSON.stringify(sessionConfig));
}

function loadSessionConfig() {
  if (sessionConfig.code !== undefined) $("code").value = sessionConfig.code;
  if (sessionConfig.begin !== undefined) $("begin").value = sessionConfig.begin;
  if (sessionConfig.end !== undefined) $("end").value = sessionConfig.end;
  if (sessionConfig.cash !== undefined) $("cash").value = sessionConfig.cash;
  if (sessionConfig.autype !== undefined) $("autype").value = sessionConfig.autype;
  if (sessionConfig.theme !== undefined) {
    chartConfig.theme = sessionConfig.theme;
    applyThemeFromSelect();
  }
  // No longer setting DOM for chip/biZs/segZs here as they are in chartConfig
  if (sessionConfig.stepN !== undefined) $("stepN").value = sessionConfig.stepN;
}

function getCfgColor(c) {
  if (c && c.startsWith("--")) return cssVar(c, "#000");
  return c;
}

const BSP_LEVEL_CONFIG_KEY = { bi: "bspBi", seg: "bspSeg", segseg: "bspSegseg" };
const RHYTHM_LEVEL_ENABLED_KEY = {
  fract: "fractToBiEnabled",
  bi: "biToSegEnabled",
  seg: "segToSegsegEnabled",
};

function getBspConfig(level) {
  const key = BSP_LEVEL_CONFIG_KEY[level] || "bspBi";
  return chartConfig[key] || chartConfig.bspBi || DEFAULT_CHART_CONFIG.bspBi;
}

function getBspDisplayLabel(p) {
  if (!p) return "";
  if (p.display_label) return String(p.display_label);
  if (p.level_label && p.label) return `${p.level_label}${p.label}`;
  return String(p.label || "");
}

function isRhythmLevelEnabled(level) {
  const cfg = chartConfig.rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  const subKey = RHYTHM_LEVEL_ENABLED_KEY[level];
  if (!subKey) return true;
  return !!cfg[subKey];
}

function getRhythmGroupIndex(group) {
  const raw = String(group || "rhythm1").replace(/[^0-9]/g, "");
  const idx = Number(raw || "1");
  return Number.isFinite(idx) && idx >= 1 ? idx : 1;
}

function getRhythmVisualConfig(group) {
  const cfg = chartConfig.rhythmLine || DEFAULT_CHART_CONFIG.rhythmLine;
  const rawIdx = getRhythmGroupIndex(group);
  const cycleIdx = ((rawIdx - 1) % 5) + 1;
  const growth = Math.max(0, rawIdx - 5);
  const lineColor = getCfgColor(cfg[`group${cycleIdx}LineColor`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}LineColor`]);
  const lineStyle = String(cfg[`group${cycleIdx}LineStyle`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}LineStyle`] || "dashed");
  const baseLineWidth = Number(cfg[`group${cycleIdx}LineWidth`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}LineWidth`] || 1.2);
  const baseTextSize = Number(cfg[`group${cycleIdx}TextFontSize`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}TextFontSize`] || 12);
  const textColor = getCfgColor(cfg[`group${cycleIdx}TextColor`] || lineColor);
  const configuredWeight = String(cfg[`group${cycleIdx}TextFontWeight`] || DEFAULT_CHART_CONFIG.rhythmLine[`group${cycleIdx}TextFontWeight`] || "bold");
  return {
    rawIdx,
    cycleIdx,
    lineColor,
    lineStyle,
    lineWidth: baseLineWidth + growth * 0.4,
    textColor,
    textFontSize: baseTextSize + growth,
    textFontWeight: growth > 0 ? "bold" : configuredWeight,
  };
}

function getRhythmLineColor(group) {
  return getRhythmVisualConfig(group).lineColor;
}

function openChanSettings() {
  if (isSettingsOpen()) closeSettings();
  if (isSystemSettingsOpen()) closeSystemSettings();
  renderChanSettingsForm();
  $("chanSettingsModal").classList.add("show");
}

function closeChanSettings() {
  $("chanSettingsModal").classList.remove("show");
}

function isChanSettingsOpen() {
  return $("chanSettingsModal").classList.contains("show");
}

function renderChanSettingsForm() {
  const container = $("chanSettingsContent");
  container.innerHTML = "";

  const sections = [
    {
      title: "主逻辑 (Algo)",
      key: "algo",
      color: "#2563eb",
      bgColor: "rgba(37, 99, 235, 0.08)",
      items: [
        { label: "缠论主逻辑", subKey: "chan_algo", type: "select", options: [
          { value: "classic", label: "原缠论" },
          { value: "new", label: "新缠论" }
        ], tip: "原缠论使用工程原有笔/段/2段逻辑；新缠论使用“新K线 -> 分型 -> 笔 -> 段 -> 2段”的递推逻辑，前端展示名称固定为分型/笔/段/2段。" }
      ]
    },
    {
      title: "笔配置 (Bi)",
      key: "bi",
      color: "#d97706",
      bgColor: "rgba(217, 119, 6, 0.08)",
      items: [
        { label: "笔是否严格", subKey: "bi_strict", type: "checkbox", tip: "是否使用严格笔定义。开启后分型间必须至少有一根独立K线。" },
        { label: "笔算法", subKey: "bi_algo", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "fx", label: "分型" }
        ], tip: "选择笔的生成算法。常规算法更符合标准缠论。" },
        { label: "分型检查", subKey: "bi_fx_check", type: "select", options: [
          { value: "strict", label: "严格" },
          { value: "normal", label: "常规" }
        ], tip: "分型成立的检查强度。严格模式要求更高。" },
        { label: "缺口当K线", subKey: "gap_as_kl", type: "checkbox", tip: "是否将缺口视为一根K线。在某些品种中很有用。" },
        { label: "笔终点是极值", subKey: "bi_end_is_peak", type: "checkbox", tip: "笔的结束点是否必须是区间内的最高/最低点。" },
        { label: "允许次极值", subKey: "bi_allow_sub_peak", type: "checkbox", tip: "是否允许笔在次极值处结束。" }
      ]
    },
    {
      title: "线段配置 (Seg)",
      key: "seg",
      color: "#059669",
      bgColor: "rgba(5, 150, 105, 0.1)",
      items: [
        { label: "线段算法", subKey: "seg_algo", type: "select", options: [
          { value: "chan", label: "标准缠论" },
          { value: "simple", label: "简单线段" }
        ], tip: "选择线段的生成算法。" },
        { label: "左端点方法", subKey: "left_seg_method", type: "select", options: [
          { value: "peak", label: "极值" },
          { value: "all", label: "所有" }
        ], tip: "线段左端点确定的逻辑。" }
      ]
    },
    {
      title: "中枢配置 (ZS)",
      key: "zs",
      color: "#ea580c",
      bgColor: "rgba(234, 88, 12, 0.08)",
      items: [
        { label: "中枢算法", subKey: "zs_algo", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "mac", label: "MAC算法" }
        ], tip: "选择中枢的生成算法。" },
        { label: "中枢合并", subKey: "zs_combine", type: "checkbox", tip: "是否自动合并重叠的中枢。" },
        { label: "合并模式", subKey: "zs_combine_mode", type: "select", options: [
          { value: "zs", label: "按中枢" },
          { value: "peak", label: "按极值" }
        ], tip: "中枢合并时的逻辑依据。" },
        { label: "一笔中枢", subKey: "one_bi_zs", type: "checkbox", tip: "是否允许由单笔构成的中枢。" }
      ]
    },
    {
      title: "均线与指标配置 (Ind)",
      key: "ind",
      color: "#6366f1",
      bgColor: "rgba(99, 102, 241, 0.08)",
      items: [
        { label: "均线周期", subKey: "mean_metrics", type: "text", placeholder: "如: 5, 10, 20", tip: "均线计算周期，逗号分隔。" },
        { label: "趋势线周期", subKey: "trend_metrics", type: "text", placeholder: "如: 20, 60", tip: "趋势线计算周期，逗号分隔。" },
        { label: "MACD 快线", subKey: "macd_fast", type: "number", tip: "MACD 快线周期（默认12）。" },
        { label: "MACD 慢线", subKey: "macd_slow", type: "number", tip: "MACD 慢线周期（默认26）。" },
        { label: "MACD 信号", subKey: "macd_signal", type: "number", tip: "MACD 信号周期（默认9）。" },
        { label: "BOLL 周期", subKey: "boll_n", type: "number", tip: "布林带计算周期。" },
        { label: "计算 Demark", subKey: "cal_demark", type: "checkbox", tip: "是否计算 Demark 指标。" },
        { label: "计算 RSI", subKey: "cal_rsi", type: "checkbox", tip: "是否计算 RSI 指标。" },
        { label: "RSI 周期", subKey: "rsi_cycle", type: "number", tip: "RSI 计算周期。" },
        { label: "计算 KDJ", subKey: "cal_kdj", type: "checkbox", tip: "是否计算 KDJ 指标。" },
        { label: "KDJ 周期", subKey: "kdj_cycle", type: "number", tip: "KDJ 计算周期。" }
      ]
    },
    {
      title: "买卖点配置 (BSP)",
      key: "bsp",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "背驰比率阈值", subKey: "divergence_rate", type: "text", tip: "判定背驰的阈值，默认 inf (不限制)。" },
        { label: "最小中枢数量", subKey: "min_zs_cnt", type: "number", tip: "产生1类买卖点所需的最小中枢数量。" },
        { label: "1类点需多笔中枢", subKey: "bsp1_only_multibi_zs", type: "checkbox", tip: "1类买卖点是否仅在由多笔构成的中枢后产生。" },
        { label: "2类点最大回撤率", subKey: "max_bs2_rate", type: "number", tip: "2类买卖点允许的最大回撤比例 (0-1)。" },
        { label: "MACD 比较算法", subKey: "macd_algo", type: "select", options: [
          { value: "peak", label: "峰值 (Peak)" },
          { value: "area", label: "面积 (Area)" },
          { value: "full_area", label: "全面积" },
          { value: "diff", label: "DIFF值" },
          { value: "slope", label: "斜率 (Slope)" },
          { value: "amp", label: "振幅 (Amp)" }
        ], tip: "用于背驰比较的 MACD 数据提取算法。" },
        { label: "1类点需顶底分型", subKey: "bs1_peak", type: "checkbox", tip: "1类点是否必须对应分型极值。" },
        { label: "目标买卖点类型", subKey: "bs_type", type: "text", tip: "需要计算的买卖点类型，逗号分隔 (如 1, 2, 3a, 2s)。" },
        { label: "2类点跟随1类", subKey: "bsp2_follow_1", type: "checkbox", tip: "2类买卖点是否必须紧跟在1类点之后。" },
        { label: "3类点跟随1类", subKey: "bsp3_follow_1", type: "checkbox", tip: "3类买卖点是否必须跟在1类点之后。" },
        { label: "3类点需顶底分型", subKey: "bsp3_peak", type: "checkbox", tip: "3类点是否必须对应分型极值。" },
        { label: "类2s点跟随2类", subKey: "bsp2s_follow_2", type: "checkbox", tip: "类2s点是否必须紧跟在2类点之后。" },
        { label: "类2s点最大级别", subKey: "max_bsp2s_lv", type: "text", tip: "允许产生类2s点的最大中枢级别。" },
        { label: "严格3类点", subKey: "strict_bsp3", type: "checkbox", tip: "是否使用更严格的3类买卖点判定逻辑。" },
        { label: "3a类点最大中枢数", subKey: "bsp3a_max_zs_cnt", type: "number", tip: "3a类点允许的最大中枢数量。" }
      ]
    },
    {
      title: "系统运行 (Sys)",
      key: "sys",
      color: "#334155",
      bgColor: "rgba(51, 65, 85, 0.08)",
      items: [
        { label: "数据检查", subKey: "kl_data_check", type: "checkbox", tip: "是否在加载时检查K线数据的完整性。" },
        { label: "打印警告", subKey: "print_warning", type: "checkbox", tip: "是否在控制台打印逻辑警告。" },
        { label: "打印错误时间", subKey: "print_err_time", type: "checkbox", tip: "警告中是否包含时间信息。" },
        { label: "步进触发", subKey: "trigger_step", type: "checkbox", tip: "回放模式的核心开关，必须保持开启。" }
      ]
    }
  ];

  const buildLabelHtml = (item) => {
    const tipText = escapeHtmlAttr(item.tip || `${item.label}：用于调整缠论逻辑参数。`);
    const tipIcon = `<svg class="tip-icon" data-tip="${tipText}" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="display:inline-block; vertical-align:middle; cursor:help; color:#3b82f6; margin-left:4px;"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>`;
    return `${item.label}${tipIcon}`;
  };

  sections.forEach(sec => {
    const section = document.createElement("div");
    section.className = "settingsSection";
    section.style.background = sec.bgColor;
    section.innerHTML = `<div class="settingsSectionTitle" style="color:${sec.color}">${sec.title}</div>`;
    
    const grid = document.createElement("div");
    grid.className = "settingsGrid";
    
    sec.items.forEach(item => {
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      const label = document.createElement("label");
      label.innerHTML = buildLabelHtml(item);
      
      let input;
      let val;
      if (item.subKey === "macd_fast") val = (chanConfig.macd && chanConfig.macd.fast) || 12;
      else if (item.subKey === "macd_slow") val = (chanConfig.macd && chanConfig.macd.slow) || 26;
      else if (item.subKey === "macd_signal") val = (chanConfig.macd && chanConfig.macd.signal) || 9;
      else val = chanConfig[item.subKey];

      if (item.type === "select") {
        input = document.createElement("select");
        item.options.forEach(opt => {
          const o = document.createElement("option");
          o.value = opt.value;
          o.textContent = opt.label;
          if (String(opt.value) === String(val)) o.selected = true;
          input.appendChild(o);
        });
      } else if (item.type === "checkbox") {
        input = document.createElement("input");
        input.type = "checkbox";
        input.checked = !!val;
        input.style.width = "auto";
        itemDiv.style.flexDirection = "row";
        itemDiv.style.alignItems = "center";
        itemDiv.style.justifyContent = "space-between";
      } else {
        input = document.createElement("input");
        input.type = item.type;
        input.value = val !== undefined ? val : "";
        if (item.type === "number") input.step = "any";
        if (item.placeholder) input.placeholder = item.placeholder;
      }
      input.dataset.key = item.subKey;
      itemDiv.appendChild(label);
      itemDiv.appendChild(input);
      grid.appendChild(itemDiv);
    });
    section.appendChild(grid);
    container.appendChild(section);
  });
  initTooltips();
}

function saveChanSettings() {
  const inputs = $("chanSettingsContent").querySelectorAll("input, select");
  if (!chanConfig.macd) chanConfig.macd = { fast: 12, slow: 26, signal: 9 };
  
  inputs.forEach(input => {
    const key = input.dataset.key;
    if (input.type === "checkbox") {
      chanConfig[key] = input.checked;
    } else if (input.tagName === "SELECT") {
      const val = input.value;
      chanConfig[key] = (val === "true" ? true : (val === "false" ? false : val));
    } else if (input.type === "number") {
      const numVal = parseFloat(input.value);
      if (key === "macd_fast") chanConfig.macd.fast = numVal;
      else if (key === "macd_slow") chanConfig.macd.slow = numVal;
      else if (key === "macd_signal") chanConfig.macd.signal = numVal;
      else chanConfig[key] = numVal;
    } else if (key === "mean_metrics" || key === "trend_metrics" || key === "bs_type") {
      chanConfig[key] = input.value; // Store as string for easy editing
    } else {
      chanConfig[key] = input.value;
    }
  });
  
  // Create a deep copy for the final config to be sent to backend
  const finalConfig = JSON.parse(JSON.stringify(chanConfig));
  
  // Post-process list fields
  ["mean_metrics", "trend_metrics"].forEach(k => {
    if (typeof finalConfig[k] === "string") {
      finalConfig[k] = finalConfig[k].split(/[,，\s]+/).map(v => parseInt(v.trim())).filter(v => !isNaN(v));
    }
  });

  storageSet("chan_logic_config", JSON.stringify(chanConfig));

  // If session is already loaded, prompt for reconfig
  if (lastPayload && lastPayload.ready) {
    if (confirmAndLog("更改缠论配置将导致从第1根K线重新计算到当前位置，且之前的模拟持仓数据（若有）将被清除。是否继续并应用配置？")) {
      setGlobalLoading(true, "正在重新计算缠论逻辑...");
      api("/api/reconfig", { chan_config: finalConfig })
        .then(payload => {
          refreshUI(payload);
          if (payload.bsp_history && payload.bsp_history.length > 0) {
            payload.bsp_history.forEach(h => {
              setMsg(`[重算] 发现 ${h.display_label || h.label} @K线:${h.x}`, true);
            });
          }
          showToast(payload.message || "配置已更新，逻辑已重算。");
          closeChanSettings();
        })
        .catch(e => {
          showToast("配置应用失败：" + e.message);
        })
        .finally(() => {
          hideGlobalLoading();
        });
    }
  } else {
    showToast("缠论配置已保存，将在加载会话时生效。");
    closeChanSettings();
  }
}

function resetChanSettings() {
  if (confirmAndLog("确定要恢复默认缠论配置吗？")) {
    chanConfig = JSON.parse(JSON.stringify(DEFAULT_CHAN_CONFIG));
    renderChanSettingsForm();
  }
}

function openSettings() {
  if (isSystemSettingsOpen()) closeSystemSettings();
  renderSettingsForm();
  $("settingsModal").classList.add("show");
}

function closeSettings() {
  $("settingsModal").classList.remove("show");
}

function isSettingsOpen() {
  return $("settingsModal").classList.contains("show");
}

function openSystemSettings() {
  if (isSettingsOpen()) closeSettings();
  renderSystemSettingsForm();
  $("systemSettingsModal").classList.add("show");
}

function closeSystemSettings() {
  $("systemSettingsModal").classList.remove("show");
}

function isSystemSettingsOpen() {
  return $("systemSettingsModal").classList.contains("show");
}

function renderSettingsForm() {
  const container = $("settingsContent");
  container.innerHTML = "";

  const slotTip = [
    "槽位规则：",
    "1) 主图槽位(0-5)：0 表示主图不显示指标，1-5 为主图指标方案槽位。",
    "2) 副图槽位(0-5)：0 表示不显示任何副图，1-5 为副图指标方案槽位。",
    "3) 主图与副图槽位独立选择、独立保存。",
    "4) 更改配置后点击保存即可生效。"
  ].join("\\n");
  const mainSlotOptions = [
    { value: "0", label: "主图(0) 不显示指标" },
    { value: "1", label: "主图(1)" },
    { value: "2", label: "主图(2)" },
    { value: "3", label: "主图(3)" },
    { value: "4", label: "主图(4)" },
    { value: "5", label: "主图(5)" },
  ];
  const subSlotOptions = [
    { value: "0", label: "副图(0) 不显示副图" },
    { value: "1", label: "副图(1)" },
    { value: "2", label: "副图(2)" },
    { value: "3", label: "副图(3)" },
    { value: "4", label: "副图(4)" },
    { value: "5", label: "副图(5)" },
  ];

  const buildLabelHtml = (item) => {
    const tipText = String(item.tip || `${item.label}：用于调整该项在图表或浮窗中的显示效果。`).replace(/"/g, "&quot;");
    return `${item.label} <span class="tip-icon" data-tip="${tipText}">!</span>`;
  };

  const sections = [
    {
      title: "系统主题",
      key: "theme_section",
      color: "#3b82f6",
      bgColor: "rgba(59, 130, 246, 0.08)",
      items: [
        { label: "主题", subKey: "theme", type: "select", options: [
          { value: "light", label: "白色" },
          { value: "dark", label: "黑色" },
          { value: "eye-care", label: "护眼" }
        ]}
      ]
    },
    {
      title: "十字辅助线",
      key: "crosshair",
      color: "#0f766e",
      bgColor: "rgba(15, 118, 110, 0.08)",
      items: [
        { label: "粗细", subKey: "width", type: "number", min: 1, max: 10, step: 0.5 },
        { label: "颜色", subKey: "color", type: "color" },
        { label: "文字大小", subKey: "fontSize", type: "number", min: 10, max: 24 }
      ]
    },
    {
      title: "技术指标设置",
      key: "indicators",
      color: "#7c3aed",
      bgColor: "rgba(124, 58, 237, 0.08)",
      items: [
        { label: "主图配置槽位", subKey: "mainSlot", type: "select", options: mainSlotOptions, tip: slotTip },
        { label: "主图指标选择", subKey: "mainType", type: "indicator_multi_main" },
        { label: "副图配置槽位", subKey: "subSlot", type: "select", options: subSlotOptions, tip: slotTip },
        { label: "副图指标选择", subKey: "subType", type: "indicator_multi_sub" }
      ]
    },
    {
      title: "K线显示",
      key: "candle",
      color: "#dc2626",
      bgColor: "rgba(220, 38, 38, 0.08)",
      items: [
        { label: "描边粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "上涨颜色", subKey: "upColor", type: "color" },
        { label: "下跌颜色", subKey: "downColor", type: "color" }
      ]
    },
    {
      title: "分型辅助线",
      key: "fx",
      color: "#0891b2",
      bgColor: "rgba(8, 145, 178, 0.08)",
      items: [
        { label: "辅助线颜色", subKey: "color", type: "color" },
        { label: "辅助线粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "筹码分布 (Chip)",
      key: "chip",
      color: "#0891b2",
      bgColor: "rgba(8, 145, 178, 0.08)",
      items: [
        { label: "启用筹码", subKey: "enabled", type: "checkbox" },
        { label: "筹码峰延长线", subKey: "peakLineEnabled", type: "checkbox", tip: "控制筹码峰水平延长线的显示开关。" },
        { label: "拉伸强度", subKey: "stretchLevel", type: "number", min: 1, max: 20 },
        { label: "价格桶(元)", subKey: "bucketStep", type: "number", min: 0.001, max: 1, step: 0.001 },
        { label: "填充颜色", subKey: "color", type: "color" },
        { label: "筹码峰延长线参考", subKey: "peakRefMode", type: "select", options: [
          { value: "latest_visible", label: "最新可见K线" },
          { value: "seg_turn", label: "线段转折点" },
          { value: "bi_turn", label: "笔转折点" }
        ]},
        { label: "筹码峰延长线颜色", subKey: "peakLineColor", type: "color" },
        { label: "筹码峰延长线粗细", subKey: "peakLineWidth", type: "number", min: 0.1, max: 6, step: 0.1 },
        { label: "筹码峰延长线线型", subKey: "peakLineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "分型",
      key: "fract",
      color: "#b45309",
      bgColor: "rgba(180, 83, 9, 0.08)",
      items: [
        { label: "分型颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 8, step: 0.1 }
      ]
    },
    {
      title: "笔",
      key: "bi",
      color: "#d97706",
      bgColor: "rgba(217, 119, 6, 0.08)",
      items: [
        { label: "笔颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 8, step: 0.1 }
      ]
    },
    {
      title: "段",
      key: "seg",
      color: "#059669",
      bgColor: "rgba(5, 150, 105, 0.1)",
      items: [
        { label: "段颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 10, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 10, step: 0.1 }
      ]
    },
    {
      title: "2段",
      key: "segseg",
      color: "#2563eb",
      bgColor: "rgba(37, 99, 235, 0.1)",
      items: [
        { label: "2段颜色", subKey: "color", type: "color" },
        { label: "粗细(确定)", subKey: "widthSure", type: "number", min: 0.1, max: 12, step: 0.1 },
        { label: "粗细(未完成)", subKey: "widthUnsure", type: "number", min: 0.1, max: 12, step: 0.1 }
      ]
    },
    {
      title: "节奏线",
      key: "rhythmLine",
      color: "#7c3aed",
      bgColor: "rgba(124, 58, 237, 0.08)",
      items: [
        { label: "启用节奏线", subKey: "enabled", type: "checkbox", tip: "总开关，关闭后不绘制任何节奏线。" },
        { label: "分型→笔", subKey: "fractToBiEnabled", type: "checkbox", tip: "是否绘制分型→笔层级的节奏线。" },
        { label: "笔→段", subKey: "biToSegEnabled", type: "checkbox", tip: "是否绘制笔→段层级的节奏线。" },
        { label: "段→2段", subKey: "segToSegsegEnabled", type: "checkbox", tip: "是否绘制段→2段层级的节奏线。" },
        { label: "节奏线1颜色", subKey: "group1LineColor", type: "color" },
        { label: "节奏线1粗细", subKey: "group1LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线1线型", subKey: "group1LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线1数字颜色", subKey: "group1TextColor", type: "color" },
        { label: "节奏线1数字大小", subKey: "group1TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线1数字粗细", subKey: "group1TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线2颜色", subKey: "group2LineColor", type: "color" },
        { label: "节奏线2粗细", subKey: "group2LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线2线型", subKey: "group2LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线2数字颜色", subKey: "group2TextColor", type: "color" },
        { label: "节奏线2数字大小", subKey: "group2TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线2数字粗细", subKey: "group2TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线3颜色", subKey: "group3LineColor", type: "color" },
        { label: "节奏线3粗细", subKey: "group3LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线3线型", subKey: "group3LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线3数字颜色", subKey: "group3TextColor", type: "color" },
        { label: "节奏线3数字大小", subKey: "group3TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线3数字粗细", subKey: "group3TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线4颜色", subKey: "group4LineColor", type: "color" },
        { label: "节奏线4粗细", subKey: "group4LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线4线型", subKey: "group4LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线4数字颜色", subKey: "group4TextColor", type: "color" },
        { label: "节奏线4数字大小", subKey: "group4TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线4数字粗细", subKey: "group4TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "节奏线5颜色", subKey: "group5LineColor", type: "color" },
        { label: "节奏线5粗细", subKey: "group5LineWidth", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "节奏线5线型", subKey: "group5LineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "节奏线5数字颜色", subKey: "group5TextColor", type: "color" },
        { label: "节奏线5数字大小", subKey: "group5TextFontSize", type: "number", min: 8, max: 32, step: 1 },
        { label: "节奏线5数字粗细", subKey: "group5TextFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]}
      ]
    },
    {
      title: "分型中枢",
      key: "fractZs",
      color: "#c2410c",
      bgColor: "rgba(194, 65, 12, 0.08)",
      items: [
        { label: "启用分型中枢", subKey: "enabled", type: "checkbox" },
        { label: "分型中枢颜色", subKey: "color", type: "color" },
        { label: "分型中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "笔中枢",
      key: "biZs",
      color: "#ea580c",
      bgColor: "rgba(234, 88, 12, 0.08)",
      items: [
        { label: "启用笔中枢", subKey: "enabled", type: "checkbox" },
        { label: "笔中枢颜色", subKey: "color", type: "color" },
        { label: "笔中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "段中枢",
      key: "segZs",
      color: "#0d9488",
      bgColor: "rgba(13, 148, 136, 0.08)",
      items: [
        { label: "启用段中枢", subKey: "enabled", type: "checkbox" },
        { label: "段中枢颜色", subKey: "color", type: "color" },
        { label: "段中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "2段中枢",
      key: "segsegZs",
      color: "#1d4ed8",
      bgColor: "rgba(29, 78, 216, 0.08)",
      items: [
        { label: "启用2段中枢", subKey: "enabled", type: "checkbox" },
        { label: "2段中枢颜色", subKey: "color", type: "color" },
        { label: "2段中枢粗细", subKey: "width", type: "number", min: 0.1, max: 5, step: 0.1 }
      ]
    },
    {
      title: "笔买卖点",
      key: "bspBi",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "段买卖点",
      key: "bspSeg",
      color: "#9f1239",
      bgColor: "rgba(159, 18, 57, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "2段买卖点",
      key: "bspSegseg",
      color: "#881337",
      bgColor: "rgba(136, 19, 55, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "1382提示",
      key: "rhythmHit",
      color: "#6d28d9",
      bgColor: "rgba(109, 40, 217, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 30 },
        { label: "文字颜色", subKey: "color", type: "color" },
        { label: "连线颜色", subKey: "lineColor", type: "color" },
        { label: "连线粗细", subKey: "lineWidth", type: "number", min: 0.1, max: 5, step: 0.1 },
        { label: "连线线型", subKey: "lineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "同列显示上限", subKey: "overflowLimit", type: "number", min: 1, max: 10, step: 1 },
        { label: "溢出提示颜色", subKey: "overflowColor", type: "color" }
      ]
    },
    {
      title: "自定义支撑压力线 (User Rays)",
      key: "userRay",
      color: "#f97316",
      bgColor: "rgba(249, 115, 22, 0.1)",
      items: [
        { label: "射线颜色", subKey: "color", type: "color" },
        { label: "粗细", subKey: "width", type: "number", min: 0.1, max: 8, step: 0.1 },
        { label: "线型(虚线间隔)", subKey: "dash", type: "text", placeholder: "如 8, 4" },
        { label: "价格字体大小", subKey: "fontSize", type: "number", min: 8, max: 24 }
      ]
    },
    {
      title: "X 轴设置",
      key: "xAxis",
      color: "#475569",
      bgColor: "rgba(71, 85, 105, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 24 },
        { label: "文字方向(度)", subKey: "rotation", type: "number", min: -180, max: 180 },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "刻度间隔(K线)", subKey: "interval", type: "number", min: 1, max: 100 }
      ]
    },
    {
      title: "Y 轴设置",
      key: "yAxis",
      color: "#334155",
      bgColor: "rgba(51, 65, 85, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 24 },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "刻度间隔(价格)", subKey: "interval", type: "number", min: 0.001, max: 100, step: 0.001 }
      ]
    },
    {
      title: "买卖文字标记",
      key: "trade",
      color: "#be123c",
      bgColor: "rgba(190, 18, 60, 0.08)",
      items: [
        { label: "买入颜色", subKey: "buyColor", type: "color" },
        { label: "卖出颜色", subKey: "sellColor", type: "color" },
        { label: "文字大小", subKey: "markerFontSize", type: "number", min: 10, max: 32 },
        { label: "文字粗细", subKey: "markerFontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "买卖竖线粗细", subKey: "markerLineWidth", type: "number", min: 0.5, max: 8, step: 0.1 },
        { label: "买卖竖线线型", subKey: "markerLineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "买卖收盘价指示线",
      key: "trade",
      color: "#0f766e",
      bgColor: "rgba(15, 118, 110, 0.08)",
      items: [
        { label: "指示线粗细", subKey: "closeLineWidth", type: "number", min: 0.5, max: 8, step: 0.1 },
        { label: "买入价线型", subKey: "buyCloseLineStyle", type: "select", options: [
          { value: "solid", label: "实线" },
          { value: "dashed", label: "虚线" },
          { value: "dotted", label: "点线" }
        ]},
        { label: "卖出价线型", subKey: "sellCloseLineStyle", type: "select", options: [
          { value: "dashed", label: "虚线" },
          { value: "solid", label: "实线" },
          { value: "dotted", label: "点线" }
        ]}
      ]
    },
    {
      title: "持仓区间与盈亏区间",
      key: "trade",
      color: "#7c3aed",
      bgColor: "rgba(124, 58, 237, 0.08)",
      items: [
        { label: "持仓区间(买)背景", subKey: "rangeFillBuy", type: "color", tip: "用于买入后到卖出前整段背景色。" },
        { label: "持仓区间(卖)背景", subKey: "rangeFillSell", type: "color", tip: "用于已卖出历史交易区间整段背景色。" },
        { label: "盈利区间颜色", subKey: "profitBandColor", type: "color", tip: "用于买卖价之间的盈利区间填充色。" },
        { label: "亏损区间颜色", subKey: "lossBandColor", type: "color", tip: "用于买卖价之间的亏损区间填充色。" }
      ]
    },
    {
      title: "持仓浮窗字体",
      key: "tradeStatus",
      color: "#1d4ed8",
      bgColor: "rgba(29, 78, 216, 0.08)",
      items: [
        { label: "标题大小", subKey: "titleFontSize", type: "number", min: 10, max: 28, tip: "控制持仓状态窗口标题栏文字大小。" },
        { label: "标题粗细", subKey: "titleFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制持仓状态窗口标题栏文字粗细。" },
        { label: "标题颜色", subKey: "titleColor", type: "color", tip: "控制持仓状态窗口标题栏文字颜色。" },
        { label: "名称大小", subKey: "labelFontSize", type: "number", min: 10, max: 24, tip: "控制持仓状态窗口左侧名称文字大小。" },
        { label: "名称粗细", subKey: "labelFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制持仓状态窗口左侧名称文字粗细。" },
        { label: "名称颜色", subKey: "labelColor", type: "color", tip: "控制持仓状态窗口左侧名称文字颜色。" },
        { label: "数值大小", subKey: "valueFontSize", type: "number", min: 10, max: 28, tip: "控制持仓状态窗口右侧数值文字大小。" },
        { label: "数值粗细", subKey: "valueFontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制持仓状态窗口右侧数值文字粗细。" },
        { label: "数值颜色", subKey: "valueColor", type: "color", tip: "控制持仓状态窗口右侧数值默认颜色。" }
      ]
    },
    {
      title: "图例说明",
      key: "legend",
      color: "#7c2d12",
      bgColor: "rgba(124, 45, 18, 0.08)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 8, max: 24, tip: "控制左上角图例说明文字大小。" },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [{ value: "normal", label: "常规" }, { value: "bold", label: "加粗" }], tip: "控制左上角图例说明文字粗细。" },
        { label: "文字颜色", subKey: "color", type: "color", tip: "控制左上角图例说明文字颜色。" }
      ]
    },
    {
      title: "消息与通知",
      key: "toast",
      color: "#1e293b",
      bgColor: "rgba(30, 41, 59, 0.12)",
      items: [
        { label: "文字大小", subKey: "fontSize", type: "number", min: 10, max: 30 },
        { label: "文字粗细", subKey: "fontWeight", type: "select", options: [
          { value: "normal", label: "常规" },
          { value: "bold", label: "加粗" }
        ]},
        { label: "消失速度(ms)", subKey: "speed", type: "number", min: 500, max: 10000, step: 100 }
      ]
    }
  ];

  sections.forEach(sec => {
    const div = document.createElement("div");
    div.className = "settingsSection";
    div.style.background = sec.bgColor;
    div.innerHTML = `<div class="settingsSectionTitle" style="color:${sec.color}">${sec.title}</div>`;
    const grid = document.createElement("div");
    grid.className = "settingsGrid";
    sec.items.forEach(item => {
      let val;
      if (sec.key === "theme_section") {
        val = chartConfig.theme;
      } else if (sec.key === "indicators") {
        if (item.subKey === "mainSlot") val = selectedMainIndicatorSlot;
        else if (item.subKey === "subSlot") val = selectedSubIndicatorSlot;
        else if (item.subKey === "mainType") val = indicatorMainSlots[String(selectedMainIndicatorSlot)] || [];
        else if (item.subKey === "subType") val = indicatorSubSlots[String(selectedSubIndicatorSlot)] || [];
      } else {
        val = chartConfig[sec.key][item.subKey];
      }
      
      const itemDiv = document.createElement("div");
      itemDiv.className = "settingsItem";
      
      // Add a line preview for sections with color/width
       if (sec.key !== "theme_section" && sec.key !== "indicators" && sec.key !== "toast" && sec.key !== "xAxis" && sec.key !== "yAxis") {
          const previewLine = document.createElement("div");
          previewLine.style.height = "2px";
          previewLine.style.width = "100%";
          previewLine.style.marginBottom = "4px";
          const color = chartConfig[sec.key].color || chartConfig[sec.key].lineColor || chartConfig[sec.key].upColor || "#ccc";
          previewLine.style.background = getCfgColor(color);
          itemDiv.appendChild(previewLine);
       }
       
       if (item.type === "select") {
          let optionsHtml = item.options.map(o => `<option value="${o.value}" ${String(val) === String(o.value) ? "selected" : ""}>${o.label}</option>`).join("");
          itemDiv.innerHTML += `
            <label>${buildLabelHtml(item)}</label>
            <select data-key="${sec.key}" data-subkey="${item.subKey}">${optionsHtml}</select>
          `;
        if (sec.key === "indicators" && item.subKey === "mainSlot") {
           const select = itemDiv.querySelector("select");
           select.onchange = (e) => {
              selectedMainIndicatorSlot = Number(e.target.value);
              storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
              renderSettingsForm();
           };
        } else if (sec.key === "indicators" && item.subKey === "subSlot") {
           const select = itemDiv.querySelector("select");
           select.onchange = (e) => {
              selectedSubIndicatorSlot = Number(e.target.value);
              storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
              renderSettingsForm();
           };
        }
      } else if (item.type === "indicator_multi_main") {
          let html = `<label>${buildLabelHtml(item)}</label>`;
          if (selectedMainIndicatorSlot === 0) {
            html += `
              <div class="muted" style="margin-top:8px;">当前主图槽位为 0，不显示主图指标。</div>
            `;
          } else {
            const currentList = Array.isArray(val) ? val : [];
            const options = [{v:"boll",l:"BOLL"}, {v:"demark",l:"Demark"}, {v:"trendline",l:"TrendLine"}];
            html += `<div style="display:flex; flex-direction:column; gap:4px; margin-top:8px;">`;
            options.forEach(opt => {
              const checked = currentList.includes(opt.v);
              html += `
                <label style="flex-direction:row; align-items:center; display:flex;">
                  <input type="checkbox" class="indicator-check-main" value="${opt.v}" ${checked ? "checked" : ""} 
                         data-key="indicators" data-subkey="mainType"
                         style="width:auto; margin-right:8px;">
                  ${opt.l}
                </label>
              `;
            });
            html += `</div>`;
          }
          itemDiv.innerHTML += html;
      } else if (item.type === "indicator_multi_sub") {
          let html = `<label>${buildLabelHtml(item)}</label>`;
          if (selectedSubIndicatorSlot === 0) {
            html += `
              <div class="muted" style="margin-top:8px;">当前副图槽位为 0，不显示任何副图指标。</div>
            `;
          } else {
            const currentList = Array.isArray(val) ? val : [];
            const options = [{v:"macd",l:"MACD"}, {v:"kdj",l:"KDJ"}, {v:"rsi",l:"RSI"}];
            html += `<div style="display:flex; flex-direction:column; gap:4px; margin-top:8px;">`;
            options.forEach(opt => {
              const checked = currentList.includes(opt.v);
              html += `
                <label style="flex-direction:row; align-items:center; display:flex;">
                  <input type="checkbox" class="indicator-check-sub" value="${opt.v}" ${checked ? "checked" : ""} 
                         data-key="indicators" data-subkey="subType"
                         style="width:auto; margin-right:8px;">
                  ${opt.l}
                </label>
              `;
            });
            html += `</div>`;
          }
          itemDiv.innerHTML += html;
      } else if (item.type === "checkbox") {
        itemDiv.innerHTML += `
          <label style="flex-direction:row; align-items:center; display:flex;">
            <input type="checkbox" ${val ? "checked" : ""} 
                   data-key="${sec.key}" data-subkey="${item.subKey}" 
                   style="width:auto; margin-right:8px;">
            ${item.label}
          </label>
        `;
      } else if (item.type === "color") {
        // Use a better color indicator for colors
        const safeVal = typeof val === "string" ? val : "#000000";
        itemDiv.innerHTML += `
          <label>${buildLabelHtml(item)}</label>
          <div style="display:flex; align-items:center; gap:8px;">
            <input type="color" value="${safeVal.startsWith('#') ? safeVal : '#000000'}" data-key="${sec.key}" data-subkey="${item.subKey}" style="width:40px; height:24px; padding:0; border:none; background:none; cursor:pointer;">
            <input type="text" value="${safeVal}" data-key="${sec.key}" data-subkey="${item.subKey}-text" style="flex:1; height:24px; padding:2px 4px; font-size:12px; font-family:monospace;">
          </div>
        `;
        const colorInput = itemDiv.querySelector('input[type="color"]');
        const textInput = itemDiv.querySelector('input[type="text"]');
        colorInput.oninput = (e) => { textInput.value = e.target.value; };
        textInput.oninput = (e) => { 
          if (/^#[0-9a-fA-F]{6}$/.test(e.target.value)) {
            colorInput.value = e.target.value;
          }
        };
      } else {
        let displayVal = val;
        if (item.subKey === "dash" && Array.isArray(val)) displayVal = val.join(", ");
        itemDiv.innerHTML += `
          <label>${buildLabelHtml(item)}</label>
          <input type="${item.type}" 
                 value="${displayVal}" 
                 step="${item.step || 1}" 
                 placeholder="${item.placeholder || ""}"
                 data-key="${sec.key}" 
                 data-subkey="${item.subKey}">
        `;
      }
      grid.appendChild(itemDiv);
    });
    div.appendChild(grid);
    container.appendChild(div);
  });
  initTooltips();
}

function renderSystemSettingsForm() {
  const container = $("systemSettingsContent");
  container.innerHTML = "";

  const bspSec = document.createElement("div");
  bspSec.className = "settingsSection";
  bspSec.style.background = "rgba(34, 197, 94, 0.08)";
  bspSec.innerHTML = `<div class="settingsSectionTitle" style="color:#16a34a">买卖点判定</div>`;

  const bspGrid = document.createElement("div");
  bspGrid.className = "settingsGrid";

  const bspItem = document.createElement("div");
  bspItem.className = "settingsItem";
  bspItem.style.gridColumn = "1 / -1";
  bspItem.innerHTML = `<label>判定方式 <span class="tip-icon" data-tip="${escapeHtmlAttr("自动：段/2段/隐藏更高层变向时，会分别对笔/段/2段买卖点自动判定 ×/✓。手动：不自动判定，需要点击“检查买卖点”或按快捷键。由手动切回自动时，会自动补判当前尚未判定的三层买卖点，并记录。")}">!</span></label>`;

  const bspSel = document.createElement("select");
  bspSel.dataset.sysKey = "bspJudgeMode";
  bspSel.innerHTML = `<option value="auto">自动</option><option value="manual">手动</option>`;
  bspSel.value = isBspJudgeManual() ? "manual" : "auto";
  bspItem.appendChild(bspSel);

  const bspNote = document.createElement("div");
  bspNote.className = "muted";
  bspNote.style.fontSize = "12px";
  bspNote.textContent = `默认快捷键：自动(${getActionShortcutDisplay("setBspJudgeAuto") || "未设置"})；手动(${getActionShortcutDisplay("setBspJudgeManual") || "未设置"})；检查三层买卖点(${getActionShortcutDisplay("checkBspJudge") || "未设置"})。`;
  bspItem.appendChild(bspNote);

  bspGrid.appendChild(bspItem);
  bspSec.appendChild(bspGrid);
  container.appendChild(bspSec);

  const section = document.createElement("div");
  section.className = "settingsSection";
  section.style.background = "rgba(14, 165, 233, 0.08)";
  section.innerHTML = `<div class="settingsSectionTitle" style="color:#0ea5e9">快捷键配置</div>`;

  const intro = document.createElement("div");
  intro.className = "muted";
  intro.style.marginBottom = "12px";
  intro.textContent = "同一功能支持配置多个快捷键，可用英文逗号或换行分隔；支持单键（如 e）、组合键（如 Ctrl+A）和连续字母序列（如 center）。若同一快捷键命中多个操作，则按当前列表顺序优先，越靠前优先级越高。";
  section.appendChild(intro);

  const grid = document.createElement("div");
  grid.className = "settingsGrid";

  SHORTCUT_ACTIONS.forEach(action => {
    const itemDiv = document.createElement("div");
    itemDiv.className = "settingsItem";
    itemDiv.style.gridColumn = "1 / -1";

    const conflicts = getShortcutConflicts(action.id);
    const current = getActionShortcutDisplay(action.id) || "未设置";
    const tipText = [
      `操作：${action.label}`,
      action.description,
      `当前快捷键：${current}`,
      "支持格式：e、Ctrl+A、Ctrl+Alt+N、center。",
      "提示：Backspace 用于删除，不录为快捷键。",
      conflicts.length > 0 ? `冲突提示：${conflicts.join("；")}` : "冲突提示：当前无重复快捷键。"
    ].join("\\n");

    const label = document.createElement("label");
    label.innerHTML = `${action.label} <span class="tip-icon" data-tip="${escapeHtmlAttr(tipText)}">!</span>`;
    itemDiv.appendChild(label);

    const input = document.createElement("input");
    input.type = "text";
    input.dataset.actionId = action.id;
    input.placeholder = "点击录入... Backspace删除";
    input.value = getActionShortcuts(action.id).map(item => formatShortcut(item)).join(", ");
    itemDiv.appendChild(input);

    // 快捷键自动录入逻辑
    input.onkeydown = (e) => {
      // 允许的功能键
      if (["Tab", "CapsLock", "NumLock", "ScrollLock", "Pause"].includes(e.key)) return;
      
      // 处理清除逻辑 (Backspace 只用于删除，不录入)
      if (e.key === "Backspace") {
        e.preventDefault();
        const currentValues = input.value.split(/[,，]/).map(v => v.trim()).filter(Boolean);
        if (currentValues.length > 0) {
          const lastValue = currentValues[currentValues.length - 1];
          // 如果是序列（纯字母），删掉最后一个字母；否则删掉整个 token
          if (/^[a-z0-9]+$/i.test(lastValue) && lastValue.length > 1) {
            currentValues[currentValues.length - 1] = lastValue.slice(0, -1);
          } else {
            currentValues.pop();
          }
          input.value = currentValues.join(", ");
        }
        return;
      }
      if (e.key === "Escape") {
        input.blur();
        return;
      }

      e.preventDefault();
      e.stopPropagation();

      // 获取当前按键对应的 token
      const token = eventToShortcutKeyToken(e);
      if (!token) return;

      // 判断是否有修饰键
      const modifiers = [];
      if (e.ctrlKey) modifiers.push("Ctrl");
      if (e.altKey) modifiers.push("Alt");
      if (e.shiftKey) modifiers.push("Shift");
      if (e.metaKey) modifiers.push("Meta");

      let keyLabel = token;
      const keyMap = {
        space: "Space",
        enter: "Enter",
        pageup: "PageUp",
        pagedown: "PageDown",
        arrowup: "ArrowUp",
        arrowdown: "ArrowDown",
        arrowleft: "ArrowLeft",
        arrowright: "ArrowRight",
        escape: "Esc",
      };
      keyLabel = keyMap[token] || token;
      if (/^[a-z]$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();
      else if (/^f[0-9]{1,2}$/.test(keyLabel)) keyLabel = keyLabel.toUpperCase();

      const comboStr = modifiers.length > 0 ? `${modifiers.join("+")}+${keyLabel}` : keyLabel;

      // 如果是连续按键（如 gg），处理逻辑
      // 简单逻辑：如果是普通字母且没有修饰键，支持追加成序列
      const isPlainLetter = /^[a-z0-9]$/i.test(e.key) && !e.ctrlKey && !e.altKey && !e.metaKey;
      
      const currentValues = input.value.split(/[,，]/).map(v => v.trim()).filter(Boolean);
      if (currentValues.length > 0) {
        const lastValue = currentValues[currentValues.length - 1];
        // 如果最后是一个纯字母序列，且当前也是纯字母，则尝试追加
        if (isPlainLetter && /^[a-z0-9]+$/i.test(lastValue) && lastValue.length < 10) {
          currentValues[currentValues.length - 1] = lastValue + e.key.toLowerCase();
        } else {
          // 否则作为新的快捷键追加（以逗号分隔）
          if (!currentValues.includes(comboStr)) {
            currentValues.push(comboStr);
          }
        }
      } else {
        currentValues.push(comboStr);
      }
      
      input.value = currentValues.join(", ");
    };

    const note = document.createElement("div");
    note.className = "muted";
    note.style.fontSize = "12px";
    note.textContent = `默认：${action.defaults.map(item => formatShortcut(item)).join(" / ") || "未设置"}。`;
    itemDiv.appendChild(note);

    if (conflicts.length > 0) {
      const conflictNote = document.createElement("div");
      conflictNote.className = "muted";
      conflictNote.style.fontSize = "12px";
      conflictNote.style.color = "#dc2626";
      conflictNote.textContent = `冲突：${conflicts.join("；")}`;
      itemDiv.appendChild(conflictNote);
    }

    grid.appendChild(itemDiv);
  });

  section.appendChild(grid);
  container.appendChild(section);
  initTooltips();
}

function saveSettings() {
  const inputs = $("settingsContent").querySelectorAll("input, select");
  inputs.forEach(input => {
    const key = input.dataset.key;
    const subkey = input.dataset.subkey;
    if (!key || !subkey || subkey.endsWith("-text")) return;
    
    let val;
    if (input.type === "checkbox") {
      val = input.checked;
    } else if (input.type === "number") {
      val = parseFloat(input.value);
    } else {
      val = input.value;
    }
    
    if (key === "theme_section") {
      chartConfig.theme = val;
      applyThemeFromSelect();
    } else if (key === "indicators") {
      if (subkey === "mainSlot") {
        selectedMainIndicatorSlot = Number(val);
        storageSet("chan_selected_main_indicator_slot", String(selectedMainIndicatorSlot));
      } else if (subkey === "subSlot") {
        selectedSubIndicatorSlot = Number(val);
        storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
      } else if (subkey === "mainType") {
        const checks = $("settingsContent").querySelectorAll(".indicator-check-main");
        const selected = [];
        checks.forEach(c => { if (c.checked) selected.push(c.value); });
        indicatorMainSlots[String(selectedMainIndicatorSlot)] = selected;
      } else if (subkey === "subType") {
        const checks = $("settingsContent").querySelectorAll(".indicator-check-sub");
        const selected = [];
        checks.forEach(c => { if (c.checked) selected.push(c.value); });
        indicatorSubSlots[String(selectedSubIndicatorSlot)] = selected;
      }
      if (subkey === "mainType" || subkey === "subType" || subkey === "mainSlot" || subkey === "subSlot") {
        storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
        storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
      } 
    } else if (key && subkey) {
      if (subkey === "dash" && typeof val === "string") {
        const arr = val.split(",").map(n => parseFloat(n.trim())).filter(n => !isNaN(n));
        val = arr.length > 0 ? arr : null;
      }
      if (!chartConfig[key]) chartConfig[key] = {};
      chartConfig[key][subkey] = val;
    }
  });
  storageSet("chan_chart_config", JSON.stringify(chartConfig));
  closeSettings();
  if (lastPayload && lastPayload.ready && lastPayload.chart) draw(lastPayload.chart);
}

function saveSystemSettingsFromForm() {
  const modeSelect = $("systemSettingsContent").querySelector('select[data-sys-key="bspJudgeMode"]');
  if (modeSelect) {
    const prev = systemConfig.bspJudgeMode;
    const next = String(modeSelect.value || "auto") === "manual" ? "manual" : "auto";
    systemConfig.bspJudgeMode = next;
    if (prev === "manual" && next === "auto" && lastPayload && lastPayload.ready) {
      saveSystemConfig();
      updateBspJudgeUI();
      showAlertAndLog("买卖点判定方式切换：手动 → 自动。\\n将自动补判当前尚未判定的笔/段/2段买卖点，并记录到后台。");
      checkBspJudge("switch_manual_to_auto");
    } else if (prev === "auto" && next === "manual") {
      saveSystemConfig();
      updateBspJudgeUI();
      showAlertAndLog("买卖点判定方式切换：自动 → 手动。\\n上一级结构变向时将不再自动判定，需手动点击“检查买卖点”。");
    }
  }
  const inputs = $("systemSettingsContent").querySelectorAll("input[data-action-id]");
  const nextShortcuts = {};
  const errors = [];

  inputs.forEach(input => {
    const actionId = input.dataset.actionId;
    const action = SHORTCUT_ACTION_MAP[actionId];
    if (!action) return;
    const { parsed, invalid } = parseShortcutList(input.value);
    if (invalid.length > 0) {
      errors.push(`${action.label}: ${invalid.join("、")}`);
      return;
    }
    nextShortcuts[actionId] = parsed.map(canonicalizeShortcut);
  });

  if (errors.length > 0) {
    showAlertAndLog(`以下快捷键格式无法识别，请修改后再保存：
${errors.join("\\n")}`);
    return;
  }

  systemConfig.shortcuts = {};
  SHORTCUT_ACTIONS.forEach(action => {
    systemConfig.shortcuts[action.id] = nextShortcuts[action.id] || [];
  });
  saveSystemConfig();
  closeSystemSettings();
  renderSystemSettingsForm();
  updateBspJudgeUI();
}

function showFloatingTip(text, clientX, clientY, avoidRect = null) {
  const tipContent = $("tipContent");
  if (!tipContent || !text) return;
  tipContent.textContent = text;
  tipContent.style.display = "block";
  const tipRect = tipContent.getBoundingClientRect();
  let top = clientY - tipRect.height / 2;
  let left = clientX + 12;
  if (avoidRect) {
    const gap = 14;
    const rightCandidate = avoidRect.right + gap;
    const leftCandidate = avoidRect.left - tipRect.width - gap;
    if (rightCandidate + tipRect.width <= window.innerWidth - 8) {
      left = rightCandidate;
    } else if (leftCandidate >= 8) {
      left = leftCandidate;
    }
    const centeredTop = avoidRect.top + (avoidRect.height - tipRect.height) / 2;
    top = Math.max(8, centeredTop);
  } else if (left + tipRect.width > window.innerWidth) {
    left = clientX - tipRect.width - 12;
  }
  if (left + tipRect.width > window.innerWidth) left = window.innerWidth - tipRect.width - 8;
  if (top + tipRect.height > window.innerHeight) top = window.innerHeight - tipRect.height - 8;
  if (top < 0) top = 8;
  if (left < 0) left = 8;
  tipContent.style.top = `${top}px`;
  tipContent.style.left = `${left}px`;
}

function hideFloatingTip() {
  const tipContent = $("tipContent");
  if (tipContent) tipContent.style.display = "none";
}

let activeTipTarget = null;
let tipBubbleHovered = false;

function initTooltips() {
  const tipContent = $("tipContent");
  if (tipContent && tipContent.dataset.bound !== "1") {
    tipContent.dataset.bound = "1";
    tipContent.addEventListener("mouseenter", () => {
      tipBubbleHovered = true;
    });
    tipContent.addEventListener("mouseleave", () => {
      tipBubbleHovered = false;
      if (!activeTipTarget) hideFloatingTip();
    });
  }
  const showTooltip = (target) => {
    const text = target.getAttribute("data-tip");
    if (!text) return;
    activeTipTarget = target;
    const rect = target.getBoundingClientRect();
    showFloatingTip(text, rect.left + rect.width, rect.top + rect.height / 2, rect);
  };
  const hideTooltip = (target) => {
    if (activeTipTarget === target) activeTipTarget = null;
    if (tipBubbleHovered) return;
    hideFloatingTip();
  };
  document.querySelectorAll("[data-tip]").forEach(target => {
    target.onmouseenter = () => showTooltip(target);
    target.onmouseleave = () => hideTooltip(target);
  });
}
initTooltips();
normalizeSystemConfig();
rebuildShortcutRegistry();
updateShortcutUI();
updateBspJudgeUI();

function resetSettings() {
  if (confirmAndLog("确定要恢复默认设置吗？")) {
    chartConfig = JSON.parse(JSON.stringify(DEFAULT_CHART_CONFIG));
    indicatorMainSlots = { ...defaultMainSlots };
    indicatorSubSlots = { ...defaultSubSlots };
    selectedMainIndicatorSlot = 0;
    selectedSubIndicatorSlot = 0;
    storageSet("chan_indicator_main_slots", JSON.stringify(indicatorMainSlots));
    storageSet("chan_indicator_sub_slots", JSON.stringify(indicatorSubSlots));
    storageSet("chan_selected_main_indicator_slot", "0");
    storageSet("chan_selected_sub_indicator_slot", "0");
    renderSettingsForm();
  }
}

function resetSystemSettings() {
  if (confirmAndLog("确定要恢复默认快捷键配置吗？")) {
    systemConfig = JSON.parse(JSON.stringify(DEFAULT_SYSTEM_CONFIG));
    saveSystemConfig();
    renderSystemSettingsForm();
  }
}

$("btnChanSettingsOpen").addEventListener("click", openChanSettings);
markUiBound("btnChanSettingsOpen");
$("btnChanSettingsClose").addEventListener("click", closeChanSettings);
$("btnChanSettingsSave").addEventListener("click", saveChanSettings);
$("btnChanSettingsReset").addEventListener("click", resetChanSettings);
$("btnSettingsOpen").addEventListener("click", openSettings);
markUiBound("btnSettingsOpen");
$("btnSettingsClose").addEventListener("click", closeSettings);
$("btnSettingsSave").addEventListener("click", saveSettings);
$("btnSettingsReset").addEventListener("click", resetSettings);
$("btnSystemSettingsOpen").addEventListener("click", openSystemSettings);
$("btnSystemSettingsClose").addEventListener("click", closeSystemSettings);
$("btnSystemSettingsSave").addEventListener("click", saveSystemSettingsFromForm);
$("btnSystemSettingsReset").addEventListener("click", resetSystemSettings);
$("btnJudgeBsp").addEventListener("click", () => {
  if (!isBspJudgeManual()) return;
  checkBspJudge("manual_button");
});
markUiBound("btnJudgeBsp");

// Close on outside click
$("chanSettingsModal").addEventListener("click", (e) => {
  if (e.target === $("chanSettingsModal")) closeChanSettings();
});

$("settingsModal").addEventListener("click", (e) => {
  if (e.target === $("settingsModal")) closeSettings();
});

$("systemSettingsModal").addEventListener("click", (e) => {
  if (e.target === $("systemSettingsModal")) closeSystemSettings();
});

function cssVar(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

function isMainIndicator(type) {
  return MAIN_INDICATORS.has(type);
}

function isSubIndicator(type) {
  return SUB_INDICATORS.has(type);
}

function getTradeLineDash(style) {
  if (style === "solid") return [];
  if (style === "dotted") return [2, 4];
  return [7, 5];
}

function getIndicatorConfig() {
  const mainTypes = [];
  const mainSlot = Number(selectedMainIndicatorSlot);
  if (indicatorMainSlots && Number.isFinite(mainSlot) && mainSlot >= 1 && mainSlot <= 5) {
    const list = indicatorMainSlots[String(mainSlot)] || [];
    for (const type of list) {
      if (type && type !== "none" && isMainIndicator(type)) {
        mainTypes.push({ slot: mainSlot, type });
      }
    }
  }
  
  const subCharts = [];
  const subSlot = Number(selectedSubIndicatorSlot);
  if (indicatorSubSlots && Number.isFinite(subSlot) && subSlot >= 1 && subSlot <= 5) {
    const list = indicatorSubSlots[String(subSlot)] || [];
    for (const type of list) {
      if (type && type !== "none" && isSubIndicator(type)) {
        subCharts.push({ slot: subSlot, type });
      }
    }
  }
  return { mainTypes, subCharts };
}

function getChipBucketStep() {
  const v = Number(chartConfig.chip.bucketStep);
  return Number.isFinite(v) && v > 0 ? v : 0.1;
}

function setGlobalLoading(visible, text) {
  const overlay = $("globalLoading");
  if (!overlay) return;
  const txt = $("globalLoadingText");
  if (txt && text) txt.textContent = text;
  overlay.classList.toggle("show", !!visible);
}

function hideGlobalLoading() {
  setGlobalLoading(false);
}

function syncStepButtonState() {
  const disabled = !lastPayload || !lastPayload.ready || sessionFinished || stepInFlight;
  $("btnStep").disabled = disabled;
  $("btnStepN").disabled = disabled;
  $("btnBackN").disabled = !lastPayload || !lastPayload.ready || stepInFlight;
}

function getStepNValue() {
  const el = $("stepN");
  const v = Number(el ? el.value : 1);
  const n = Number.isFinite(v) ? Math.floor(v) : 1;
  const safeN = Math.max(1, n);
  if (el && String(safeN) !== String(el.value)) el.value = String(safeN);
  return safeN;
}

function syncTradesFromPayload(payload) {
  if (!payload || !payload.trades) return;
  tradeHistory = Array.isArray(payload.trades.history) ? payload.trades.history : [];
  activeTrade = payload.trades.active || null;
}

function showBspPrompt(payload, lines, key, hits) {
  const t = payload && payload.time ? payload.time : "-";
  const text = `检测到当前K线出现买卖点\n时间：${t}\n${lines || ""}`.trim();
  showToast(text, { record: false });
  setMsg(text, true);
}

function clearBspPrompt() {
  pendingBspPrompt = null;
  const box = $("bspPrompt");
  if (box) box.classList.remove("show");
  syncStepButtonState();
}

function formatDateWithWeekday(raw) {
  const text = String(raw || "").trim();
  if (!text) return "-";
  const datePart = text.slice(0, 10);
  const d = new Date(`${datePart}T00:00:00`);
  if (!Number.isNaN(d.getTime())) return `${text} ${WEEKDAY_NAMES[d.getDay()]}`;
  return text;
}

function formatPriceText(v, digits = 3) {
  const n = Number(v);
  if (!Number.isFinite(n)) return "-";
  const clean = Math.abs(n) < 1e-9 ? 0 : n;
  return clean.toFixed(digits);
}

function getBspAtX(chart, xVal) {
  const tags = [];
  const seen = new Set();
  for (const p of (bspHistory || [])) {
    if (!p || p.x !== xVal) continue;
    const prefix = p.status === "correct" ? "✓" : (p.status === "wrong" ? "×" : "…");
    const txt = `${prefix} ${getBspDisplayLabel(p)}`;
    if (seen.has(txt)) continue;
    seen.add(txt);
    tags.push(txt);
  }
  for (const hit of (chart && chart.rhythm_hits) || []) {
    if (!hit || hit.x !== xVal) continue;
    const txt = String(hit.display_label || "1382");
    if (seen.has(txt)) continue;
    seen.add(txt);
    tags.push(txt);
  }
  return tags;
}

function getChipStretchExponent() {
  const level = Number(chartConfig.chip.stretchLevel || 5);
  // level 1 -> 1.0(线性), level 10 -> 0.2(最强), keep extending smoothly.
  const exp = 1.0 - 0.08 * (level - 1);
  return Math.max(0.08, Math.min(1.0, exp));
}

function syncIndicatorControls() {
  // Main indicator panel controls were moved to the settings modal.
  // This function now primarily ensures indicators are refreshed if needed.
}

function applyThemeFromSelect() {
  const t = chartConfig.theme || "light";
  document.documentElement.setAttribute("data-theme", t);
  if (lastPayload && lastPayload.ready && lastPayload.chart) draw(lastPayload.chart);
}

// Indicator controls moved to modal.

const IDS_SESSION_PARAMS = ["code", "begin", "end", "cash", "autype", "stepN"];
IDS_SESSION_PARAMS.forEach(id => {
  const el = $(id);
  if (!el) return;
  el.addEventListener("change", () => {
    saveSessionConfig();
  });
});

syncIndicatorControls();

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
window.addEventListener("resize", () => {
  resizeCanvas();
  const overlay = $("tradeStatusOverlay");
  if (overlay) applyTradeOverlayPosition(parseFloat(overlay.style.left) || 16, parseFloat(overlay.style.top) || 16);
});
setTimeout(resizeCanvas, 0);

canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const factor = e.deltaY > 0 ? 1 / 1.15 : 1.15;
    if (e.ctrlKey) {
      if (e.deltaY > 0) {
        viewYZoomRatio /= 1.15;
      } else {
        viewYZoomRatio *= 1.15;
      }
      draw(lastPayload.chart);
      return;
    }
    zoomViewAt(factor, mouseX);
  },
  { passive: false }
);

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  isPanning = true;
  panStartX = e.clientX;
  panStartY = e.clientY;
  panStartViewMin = viewXMin;
  panStartViewMax = viewXMax;
  panStartYShiftRatio = viewYShiftRatio;
});
window.addEventListener("mouseup", () => {
  isPanning = false;
  chartMouseDownPos = null;
});
window.addEventListener("mousemove", (e) => {
  if (!isPanning) return;
  if (chartMouseDownPos) {
    const moved = Math.abs(e.clientX - chartMouseDownPos.x) + Math.abs(e.clientY - chartMouseDownPos.y);
    if (moved >= 6) chartClickMoved = true;
  }
  const rect = canvas.getBoundingClientRect();
  if (e.clientY < rect.top || e.clientY > rect.bottom) return;
  const dx = e.clientX - panStartX;
  const dy = e.clientY - panStartY;
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
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const plotH = Math.max(1, s.plotH);
  viewYShiftRatio = panStartYShiftRatio + (dy / plotH);
  viewYShiftRatio = Math.max(-3, Math.min(3, viewYShiftRatio));
  userAdjustedView = true;
  draw(lastPayload.chart);
});

canvas.addEventListener("mousemove", (e) => {
  canvasHovered = true;
  if (isPanning) {
    hideFloatingTip();
    return;
  }
  if (!lastPayload || !lastPayload.ready) {
    hideFloatingTip();
    return;
  }
  const rect = canvas.getBoundingClientRect();
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const visibleKs = getVisibleKs(lastPayload.chart, s.xMin, s.xMax);
  const rawX = e.clientX - rect.left;
  const rawY = e.clientY - rect.top;
  const clampedX = Math.max(PAD_L, Math.min(s.w - PAD_R, rawX));
  
  // Lock X if Ctrl is held
   if (!e.ctrlKey) {
     const targetX = s.xMin + ((clampedX - PAD_L) / Math.max(1, s.plotW)) * (s.xMax - s.xMin);
     const refK = nearestKByX(visibleKs, targetX);
     crosshairX = refK ? s.x(refK.x) : clampedX;
   }
  
   crosshairY = Math.max(PAD_T, Math.min(s.contentBottom, rawY));
   const hoveredSignal = (signalHoverBoxes || []).find((box) => rawX >= box.x1 && rawX <= box.x2 && rawY >= box.y1 && rawY <= box.y2);
   if (hoveredSignal && hoveredSignal.text) {
     showFloatingTip(hoveredSignal.text, e.clientX, e.clientY);
   } else {
     hideFloatingTip();
   }
   draw(lastPayload.chart);
});

canvas.addEventListener("mouseleave", () => {
  canvasHovered = false;
  crosshairX = null;
  crosshairY = null;
  hideFloatingTip();
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
});

canvas.addEventListener("dblclick", (e) => {
  if (crosshairX !== null && crosshairY !== null) {
    const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
    const rect = canvas.getBoundingClientRect();
    const xp = (e && typeof e.clientX === "number") ? (e.clientX - rect.left) : crosshairX;
    const yp = (e && typeof e.clientY === "number") ? (e.clientY - rect.top) : crosshairY;
    
    // Check if we are deleting a ray
    let removed = false;
    userRays = userRays.filter(ray => {
      const rayYp = s.y(ray.y);
      if (Math.abs(rayYp - yp) < 8) {
        removed = true;
        return false;
      }
      return true;
    });
    
    if (removed) {
      storageSet("chan_user_rays", JSON.stringify(userRays));
      draw(lastPayload.chart);
      return;
    }

    // Check if we are deleting a Bi ray
    let removedBi = false;
    const xVal = xFromPx(s, xp);
    userBiRays = userBiRays.filter(r => {
      const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
      const dx = (x2 - x1);
      if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(dx) || dx === 0) return true;
      if (xVal < x1) return true;
      const slope = (y2 - y1) / dx;
      const yOn = y1 + slope * (xVal - x1);
      const yPx = s.y(yOn);
      if (Math.abs(yPx - yp) < 8) {
        removedBi = true;
        return false;
      }
      return true;
    });
    if (removedBi) {
      userBiRaysDirty = true;
      if (selectedDrawing && selectedDrawing.type === "biRay") selectedDrawing = null;
      draw(lastPayload.chart);
      return;
    }
  }

  crosshairEnabled = !crosshairEnabled;
  canvas.style.cursor = crosshairEnabled ? "crosshair" : "default";
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
});

 // Fullscreen logic
const btnFullscreen = $("btnFullscreen");
btnFullscreen.onclick = () => {
  const rightPanel = document.querySelector(".right");
  if (!document.fullscreenElement) {
    rightPanel.requestFullscreen().catch(err => {
      setMsg(`全屏失败: ${err.message}`);
    });
  } else {
    document.exitFullscreen();
  }
};
markUiBound("btnFullscreen");

document.addEventListener("fullscreenchange", () => {
  resizeCanvas();
  const overlay = $("tradeStatusOverlay");
  if (overlay) applyTradeOverlayPosition(parseFloat(overlay.style.left) || 16, parseFloat(overlay.style.top) || 16);
});

function updateToolboxUI() {
  const ids = ["toolNone", "toolHorizontalRay", "toolBiRay"];
  ids.forEach((id) => {
    const el = $(id);
    if (!el) return;
    el.classList.remove("active");
  });
  if (activeTool === "horizontalRay" && $("toolHorizontalRay")) $("toolHorizontalRay").classList.add("active");
  else if (activeTool === "biRay" && $("toolBiRay")) $("toolBiRay").classList.add("active");
  else if ($("toolNone")) $("toolNone").classList.add("active");
}

function setActiveTool(next) {
  const v = next === "horizontalRay" || next === "biRay" ? next : "none";
  activeTool = v;
  storageSet("chan_active_tool", v);
  if (v !== "biRay") pendingBiRayPts = [];
  if (v !== "none") selectedDrawing = null;
  updateToolboxUI();
  if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
}

if ($("toolNone")) {
  $("toolNone").addEventListener("click", () => setActiveTool("none"));
  markUiBound("toolNone");
}
if ($("toolHorizontalRay")) {
  $("toolHorizontalRay").addEventListener("click", () => setActiveTool(activeTool === "horizontalRay" ? "none" : "horizontalRay"));
  markUiBound("toolHorizontalRay");
}
if ($("toolBiRay")) {
  $("toolBiRay").addEventListener("click", () => setActiveTool(activeTool === "biRay" ? "none" : "biRay"));
  markUiBound("toolBiRay");
}
updateToolboxUI();

function getRayLineStyle(ray) {
  return String(ray && ray.lineStyle ? ray.lineStyle : "dashed");
}

function getRayLineWidth(ray) {
  const v = Number(ray && ray.lineWidth);
  return Number.isFinite(v) && v > 0 ? v : chartConfig.userRay.width;
}

function getRayLineColor(ray) {
  return getCfgColor(ray && ray.lineColor ? ray.lineColor : chartConfig.userRay.color);
}

function applyLinePropsToDrawing(target, props) {
  if (!target) return false;
  const list = target.type === "biRay" ? userBiRays : userRays;
  if (!Array.isArray(list) || !Number.isInteger(target.index) || target.index < 0 || target.index >= list.length) return false;
  const item = list[target.index];
  item.lineColor = props.lineColor;
  item.lineWidth = props.lineWidth;
  item.lineStyle = props.lineStyle;
  if (target.type === "biRay") {
    userBiRaysDirty = true;
  } else {
    storageSet("chan_user_rays", JSON.stringify(userRays));
  }
  return true;
}

function pickDrawingAt(s, px, py) {
  const threshold = 8;
  for (let i = userRays.length - 1; i >= 0; i -= 1) {
    const ray = userRays[i];
    const yp = s.y(ray.y);
    const xp = s.x(ray.x);
    if (px >= xp - 10 && px <= s.w - PAD_R + 10 && Math.abs(py - yp) <= threshold) {
      return { type: "ray", index: i };
    }
  }
  const xVal = xFromPx(s, px);
  for (let i = userBiRays.length - 1; i >= 0; i -= 1) {
    const r = userBiRays[i];
    const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
    const dx = x2 - x1;
    if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(dx) || dx === 0) continue;
    if (xVal < x1) continue;
    const slope = (y2 - y1) / dx;
    const yOn = y1 + slope * (xVal - x1);
    const yPx = s.y(yOn);
    if (Math.abs(yPx - py) <= threshold) return { type: "biRay", index: i };
  }
  return null;
}

function editSelectedLineProps() {
  if (!selectedDrawing) {
    setMsg("请先点击“选择”，并在图表上选中一条画线。");
    return;
  }
  const list = selectedDrawing.type === "biRay" ? userBiRays : userRays;
  const cur = list[selectedDrawing.index];
  if (!cur) {
    setMsg("当前选中画线不存在，请重新选择。");
    selectedDrawing = null;
    return;
  }
  const defaultColor = String(cur.lineColor || chartConfig.userRay.color || "#f97316");
  const defaultWidth = String(getRayLineWidth(cur));
  const defaultStyle = String(getRayLineStyle(cur));
  const lineColor = prompt("请输入画线颜色（如 #ff0000 或 rgba(...)）", defaultColor);
  if (lineColor === null) return;
  const widthText = prompt("请输入画线粗细（正数）", defaultWidth);
  if (widthText === null) return;
  const lineWidth = Number(widthText);
  if (!Number.isFinite(lineWidth) || lineWidth <= 0) {
    setMsg("画线粗细无效，已取消。");
    return;
  }
  const styleText = prompt("请输入线型：solid / dashed / dotted", defaultStyle);
  if (styleText === null) return;
  const style = ["solid", "dashed", "dotted"].includes(String(styleText).trim()) ? String(styleText).trim() : "dashed";
  if (applyLinePropsToDrawing(selectedDrawing, { lineColor: String(lineColor).trim() || defaultColor, lineWidth, lineStyle: style })) {
    setMsg("画线属性已更新。");
    if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
  }
}

if ($("toolLineProps")) $("toolLineProps").addEventListener("click", editSelectedLineProps);

function persistUserBiRaysNow() {
  storageSet("chan_user_bi_rays", JSON.stringify(userBiRays));
  userBiRaysDirty = false;
}

function maybeSaveUserBiRaysOnExit() {
  if (!userBiRaysDirty || !Array.isArray(userBiRays) || userBiRays.length <= 0) return;
  const shouldSave = confirmAndLog("是否保存画线？");
  if (shouldSave) persistUserBiRaysNow();
}

window.addEventListener("beforeunload", () => {
  maybeSaveUserBiRaysOnExit();
});

(() => {
  const panel = $("chartToolsPanel");
  if (!panel) return;
  const handle = panel.querySelector(".drag-handle");
  if (!handle) return;
  let dragging = false;
  let startX = 0;
  let startY = 0;
  let baseLeft = 0;
  let baseTop = 0;
  handle.addEventListener("mousedown", (e) => {
    if (!panel.classList.contains("floating")) return;
    dragging = true;
    startX = e.clientX;
    startY = e.clientY;
    const rect = panel.getBoundingClientRect();
    baseLeft = rect.left;
    baseTop = rect.top;
    e.preventDefault();
  });
  window.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    panel.style.left = `${Math.max(8, baseLeft + (e.clientX - startX))}px`;
    panel.style.top = `${Math.max(8, baseTop + (e.clientY - startY))}px`;
    panel.style.right = "auto";
  });
  window.addEventListener("mouseup", () => {
    dragging = false;
  });
})();

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  chartClickMoved = false;
  chartMouseDownPos = { x: e.clientX, y: e.clientY };
});

canvas.addEventListener("click", (e) => {
  if (!lastPayload || !lastPayload.ready || !viewReady) return;
  if (chartClickMoved) return;
  const rect = canvas.getBoundingClientRect();
  const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
  const y = e.clientY - rect.top;
  const x = e.clientX - rect.left;

  const wantHorizontalRay = !!e.ctrlKey || activeTool === "horizontalRay";
  const wantBiRay = !!e.shiftKey || activeTool === "biRay";

  // Ctrl + Left Click (or toolbox): Horizontal Ray
  if (wantHorizontalRay) {
    const refK = getReferenceK(lastPayload.chart, s);
    if (refK) {
      const yVal = s.yFromPx(y);
      userRays.push({ x: refK.x, y: yVal });
      storageSet("chan_user_rays", JSON.stringify(userRays));
      setMsg(`已生成射线: ${yVal.toFixed(2)}`);
      draw(lastPayload.chart);
    }
    return;
  }

  // Shift + Left Click (or toolbox): pick 2 Bi endpoints then draw a right ray
  if (wantBiRay) {
    const pt = getNearestBiEndpoint(lastPayload.chart, s, x, y, 12);
    if (!pt) {
      return;
    }
    pendingBiRayPts.push(pt);
    if (pendingBiRayPts.length === 1) {
      setMsg("已选择端点1，请再选择端点2。");
      draw(lastPayload.chart);
      return;
    }
    const p1 = pendingBiRayPts[0];
    const p2 = pendingBiRayPts[1];
    pendingBiRayPts = [];
    if (Number(p2.x) === Number(p1.x)) {
      setMsg("两个端点 x 相同，无法生成射线。");
      return;
    }
    userBiRays.push({ x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y });
    userBiRaysDirty = true;
    setMsg("已生成笔射线 →");
    draw(lastPayload.chart);
    return;
  }

  if (activeTool === "none") {
    const picked = pickDrawingAt(s, x, y);
    if (picked) {
      selectedDrawing = picked;
      setMsg(picked.type === "biRay" ? "已选中笔端点射线，可点击“画线属性”编辑。" : "已选中水平射线，可点击“画线属性”编辑。");
      draw(lastPayload.chart);
      return;
    }
  }

  const panel = getPanelByY(s, y);
  if (!panel) return;
  selectedSubIndicatorSlot = Number(panel.slot);
  storageSet("chan_selected_sub_indicator_slot", String(selectedSubIndicatorSlot));
  syncIndicatorControls();
});

function executeShortcutAction(actionId) {
  switch (actionId) {
    case "openChartSettings":
      openSettings();
      return true;
    case "openSystemSettings":
      openSystemSettings();
      return true;
    case "toggleFullscreen":
      $("btnFullscreen").click();
      return true;
    case "initSession":
      if ($("btnInit").disabled) return false;
      $("btnInit").click();
      return true;
    case "resetSession":
      if ($("btnReset").disabled) return false;
      $("btnReset").click();
      return true;
    case "nextBar":
      if ($("btnStep").disabled || stepInFlight) return false;
      $("btnStep").click();
      return true;
    case "stepForwardN":
      if ($("btnStepN").disabled) return false;
      $("btnStepN").click();
      return true;
    case "stepBackwardN":
      if ($("btnBackN").disabled) return false;
      $("btnBackN").click();
      return true;
    case "buyAll":
      if ($("btnBuy").disabled) return false;
      $("btnBuy").click();
      return true;
    case "sellAll":
      if ($("btnSell").disabled) return false;
      $("btnSell").click();
      return true;
    case "centerLatest":
      centerLatestK();
      return true;
    case "drawHorizontalRay": {
      if (!crosshairEnabled || crosshairX === null || crosshairY === null || !lastPayload || !lastPayload.ready) return false;
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (!refK) return false;
      const yVal = s.yFromPx(crosshairY);
      userRays.push({ x: refK.x, y: yVal });
      storageSet("chan_user_rays", JSON.stringify(userRays));
      setMsg(`已生成射线: ${yVal.toFixed(2)}`);
      draw(lastPayload.chart);
      return true;
    }
    case "zoomYIn":
      if (!lastPayload || !lastPayload.ready) return false;
      viewYZoomRatio *= 1.15;
      draw(lastPayload.chart);
      return true;
    case "zoomYOut":
      if (!lastPayload || !lastPayload.ready) return false;
      viewYZoomRatio /= 1.15;
      draw(lastPayload.chart);
      return true;
    case "zoomXIn":
      if (!lastPayload || !lastPayload.ready) return false;
      zoomViewAt(1.15, canvas.clientWidth / 2);
      return true;
    case "zoomXOut":
      if (!lastPayload || !lastPayload.ready) return false;
      zoomViewAt(1 / 1.15, canvas.clientWidth / 2);
      return true;
    case "adjustCrosshairUp":
    case "adjustCrosshairDown": {
      if (!crosshairEnabled || crosshairY === null || !lastPayload || !lastPayload.ready) return false;
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const delta = actionId === "adjustCrosshairUp" ? -0.01 : 0.01;
      const curPrice = s.yFromPx(crosshairY);
      const newPrice = curPrice - delta;
      crosshairY = s.y(newPrice);
      draw(lastPayload.chart);
      return true;
    }
    case "saveChartSettings":
      if (!isSettingsOpen()) return false;
      saveSettings();
      return true;
    case "saveSystemSettings":
      if (!isSystemSettingsOpen()) return false;
      saveSystemSettingsFromForm();
      return true;
    case "confirmBspPrompt":
      // 兼容旧逻辑：买卖点提示不再阻断步进，无需确认
      clearBspPrompt();
      return true;
    case "closeSettlement":
      if (!$("settlementModal").classList.contains("show")) return false;
      $("btnSettlementClose").click();
      return true;
    case "setBspJudgeAuto": {
      const prev = systemConfig.bspJudgeMode;
      systemConfig.bspJudgeMode = "auto";
      saveSystemConfig();
      updateBspJudgeUI();
      showAlertAndLog("买卖点判定方式切换：手动 → 自动。\\n将自动补判当前尚未判定的笔/段/2段买卖点，并记录到后台。");
      if (prev === "manual") checkBspJudge("switch_manual_to_auto");
      return true;
    }
    case "setBspJudgeManual":
      systemConfig.bspJudgeMode = "manual";
      saveSystemConfig();
      updateBspJudgeUI();
      showAlertAndLog("买卖点判定方式切换：自动 → 手动。\\n上一级结构变向时将不再自动判定，需手动点击“检查买卖点”。");
      return true;
    case "checkBspJudge":
      if (!isBspJudgeManual()) return false;
      checkBspJudge("manual_shortcut");
      return true;
    default:
      return false;
  }
}

window.addEventListener("keydown", (e) => {
  const contexts = getActiveShortcutContexts();
  const activeTag = (document.activeElement && document.activeElement.tagName) ? document.activeElement.tagName.toLowerCase() : "";
  const allowWhenEditing = contexts.some(ctx => ctx === "bspPrompt" || ctx === "settlement");

  if (!allowWhenEditing && (activeTag === "input" || activeTag === "select" || activeTag === "textarea")) return;

  const now = Date.now();
  if (!shortcutSequenceLastAt || now - shortcutSequenceLastAt > SHORTCUT_SEQUENCE_TIMEOUT) {
    shortcutSequenceBuffer = [];
  }

  const currentEntries = compiledShortcuts.filter(entry => entry.contexts.some(ctx => contexts.includes(ctx)));
  const keyToken = eventToShortcutKeyToken(e);

  if (keyToken && !e.ctrlKey && !e.altKey && !e.metaKey) {
    shortcutSequenceBuffer.push(keyToken);
    shortcutSequenceLastAt = now;
    while (shortcutSequenceBuffer.length > 12) shortcutSequenceBuffer.shift();

    for (const entry of currentEntries) {
      const matched = entry.shortcuts.find(def => def.type === "sequence" && shortcutSequenceMatches(def));
      if (matched && executeShortcutAction(entry.actionId)) {
        e.preventDefault();
        shortcutSequenceBuffer = [];
        return;
      }
    }
  }

  for (const entry of currentEntries) {
    const matched = entry.shortcuts.find(def => shortcutMatchesEvent(def, e));
    if (matched && executeShortcutAction(entry.actionId)) {
      e.preventDefault();
      shortcutSequenceBuffer = [];
      return;
    }
  }

  if (!viewReady || !lastPayload || !lastPayload.ready || contexts[0] !== "global") return;
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
    if (crosshairEnabled && crosshairX !== null) {
      e.preventDefault();
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (refK) {
        const prev = nearestKByX(lastPayload.chart.kline.filter((k) => k.x < refK.x), refK.x - 1);
        if (prev) {
          crosshairX = s.x(prev.x);
          crosshairY = s.y(prev.c);
          draw(lastPayload.chart);
        }
      }
      return;
    }
    viewXMin = Math.max(allXMin, viewXMin - shift);
    viewXMax = viewXMin + span;
    userAdjustedView = true;
    draw(lastPayload.chart);
  } else if (e.code === "ArrowRight") {
    if (crosshairEnabled && crosshairX !== null) {
      e.preventDefault();
      const s = toScaler(lastPayload.chart, Math.max(allXMin, viewXMin), viewXMax);
      const refK = getReferenceK(lastPayload.chart, s);
      if (refK) {
        const next = nearestKByX(lastPayload.chart.kline.filter((k) => k.x > refK.x), refK.x + 1);
        if (next) {
          crosshairX = s.x(next.x);
          crosshairY = s.y(next.c);
          draw(lastPayload.chart);
        }
      }
      return;
    }
    viewXMin = viewXMin + shift;
    viewXMax = viewXMax + shift;
    userAdjustedView = true;
    draw(lastPayload.chart);
  }
});

let msgHistory = ensureArray(safeJsonParse(storageGet("chan_msg_history"), []), []);
let lastToastText = "";
let lastToastAt = 0;

function appendMsgHistory(text) {
  const content = String(text || "").trim();
  if (!content) return;
  if (!Array.isArray(msgHistory)) msgHistory = [];
  const last = msgHistory.length > 0 ? msgHistory[msgHistory.length - 1] : null;
  if (last && String(last.text || "").trim() === content) return;
  const t = new Date().toLocaleTimeString();
  const entry = { time: t, text: content };
  msgHistory.push(entry);
  if (msgHistory.length > 500) msgHistory.shift();
  storageSet("chan_msg_history", JSON.stringify(msgHistory));
}

function setMsg(text, quiet = false) {
  appendMsgHistory(text);
  if (!quiet) showToast(text, { record: false });
}

function showToast(text, options = {}) {
  const content = String(text || "").trim();
  if (!content) return;
  const record = options && Object.prototype.hasOwnProperty.call(options, "record") ? !!options.record : true;
  if (record) appendMsgHistory(content);
  const now = Date.now();
  if (content === lastToastText && now - lastToastAt < 1600) return;
  lastToastText = content;
  lastToastAt = now;
  const container = $("toastContainer");
  if (!container) return;
  
  const toast = document.createElement("div");
  toast.className = "toast";
  toast.textContent = content;
  
  // Apply settings
  toast.style.fontSize = `${chartConfig.toast.fontSize}px`;
  toast.style.fontWeight = chartConfig.toast.fontWeight;
  
  container.appendChild(toast);
  
  const speed = chartConfig.toast.speed || 3000;
  setTimeout(() => {
    toast.style.opacity = "0";
    setTimeout(() => toast.remove(), 300);
  }, speed);
}

function showAlertAndLog(text) {
  setMsg(text, true);
  alert(text);
}

function confirmAndLog(text) {
  setMsg(text, true);
  return confirm(text);
}

function judgeStatsText(stats) {
  if (!stats || typeof stats !== "object") return null;
  const reason = stats.reason ? String(stats.reason) : "-";
  const time = stats.time ? String(stats.time) : "-";
  const interval = stats.interval && typeof stats.interval === "object" ? stats.interval : null;
  const fromTime = interval && interval.from_time ? String(interval.from_time) : "-";
  const toTime = interval && interval.to_time ? String(interval.to_time) : time;
  const summary = stats.summary && typeof stats.summary === "object" ? stats.summary : stats;
  const details = Array.isArray(stats.details) ? stats.details : [];
  const appeared = Number.isFinite(summary.appeared) ? summary.appeared : null;
  const correct = Number.isFinite(summary.correct) ? summary.correct : null;
  const rate = typeof summary.rate === "number" ? (summary.rate * 100) : null;
  if (appeared === null || correct === null) return null;
  const lines = [
    "买卖点判定结果（自上次判定以来）",
    `区间：${fromTime} ~ ${toTime}`,
    `本次时间：${time}`,
    `总出现：${appeared}`,
    `总正确：${correct}`,
    `总正确率：${rate === null ? "-" : `${rate.toFixed(2)}%`}`,
    `原因：${reason}`,
  ];
  details.forEach((item) => {
    const itemRate = typeof item.rate === "number" ? `${(item.rate * 100).toFixed(2)}%` : "-";
    lines.push(`${item.level_label || item.level || "-"}：出现${item.appeared || 0}，正确${item.correct || 0}，正确率${itemRate}`);
  });
  return lines.join("\\n");
}

function getRhythmNoticeTexts(payload) {
  const hits = payload && Array.isArray(payload.rhythm_notice_hits) ? payload.rhythm_notice_hits : [];
  return Array.from(new Set(hits
    .map((hit) => String(hit && (hit.detail || hit.display_label || "1382")).trim())
    .filter(Boolean)));
}

function getLatestBspNotice(payload) {
  if (!payload || !payload.ready || !payload.chart || !Array.isArray(payload.chart.kline) || payload.chart.kline.length === 0) return null;
  const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
  const hits = (payload.chart.bsp || []).filter((p) => p && p.x === lastX);
  if (hits.length <= 0) return null;
  const key = lastX + "|" + hits.map((p) => `${p.level || "-"}:${getBspDisplayLabel(p)}`).join("|");
  if (lastSeenBspKey.has(key)) return null;
  lastSeenBspKey.add(key);
  return {
    key,
    x: lastX,
    lines: hits.map((p) => getBspDisplayLabel(p)),
    hits,
  };
}

function formatCombinedNoticeSection(title, blocks) {
  const cleanBlocks = Array.from(new Set((blocks || []).map((block) => String(block || "").trim()).filter(Boolean)));
  if (cleanBlocks.length <= 0) return "";
  if (cleanBlocks.length === 1) return `${title}
${cleanBlocks[0]}`;
  return `${title}
${cleanBlocks.map((block, idx) => `${idx + 1}. ${block.replace(/\\n/g, "\\n   ")}`).join("\\n\\n")}`;
}

function buildStepNoticeText(payload, bspNotice) {
  const sections = [];
  if (bspNotice && Array.isArray(bspNotice.lines) && bspNotice.lines.length > 0) {
    sections.push(formatCombinedNoticeSection("买卖点提示", bspNotice.lines));
  }
  const rhythmTexts = getRhythmNoticeTexts(payload);
  if (rhythmTexts.length > 0) {
    sections.push(formatCombinedNoticeSection("1382提示", rhythmTexts));
  }
  if (payload && payload.judge_notice) {
    const judgeText = judgeStatsText(payload && payload.judge_stats ? payload.judge_stats : null) || "买卖点判定";
    sections.push(formatCombinedNoticeSection("买卖点判定", [judgeText]));
  }
  const cleanSections = sections.filter(Boolean);
  if (cleanSections.length <= 0) return null;
  if (cleanSections.length === 1) {
    const only = cleanSections[0];
  return only.includes("\\n1.") ? only : only.replace(/^[^\\n]+\\n/, "");
  }
  return cleanSections.join("\\n\\n");
}

function showCombinedNotice(text) {
  const clean = String(text || "").trim();
  if (!clean) return false;
  showToast(clean, { record: false });
  setMsg(clean, true);
  return true;
}

function showJudgeNotice(payload) {
  const text = judgeStatsText(payload && payload.judge_stats ? payload.judge_stats : null) || "买卖点判定";
  showToast(text, { record: false });
  setMsg(text, true);
}

function showRhythmHitNotices(payload) {
  const hits = payload && Array.isArray(payload.rhythm_notice_hits) ? payload.rhythm_notice_hits : [];
  hits.forEach((hit) => {
    const text = String(hit.detail || hit.display_label || "1382").trim();
    if (!text) return;
    showToast(text, { record: false });
    setMsg(text, true);
  });
}

function showMsgHistory() {
  const list = $("msgHistoryList");
  list.innerHTML = "";
  msgHistory.slice().reverse().forEach(m => {
    const item = document.createElement("div");
    item.className = "msgHistoryItem";
    item.innerHTML = `<span class="time">[${m.time}]</span><span class="text">${m.text}</span>`;
    list.appendChild(item);
  });
  $("msgHistoryModal").classList.add("show");
}

$("btnMsgHistory").onclick = showMsgHistory;
$("btnMsgHistoryClose").onclick = () => $("msgHistoryModal").classList.remove("show");
$("btnMsgHistoryOk").onclick = () => $("msgHistoryModal").classList.remove("show");
$("btnMsgHistoryClear").onclick = () => {
  if (confirmAndLog("确定要清空所有消息历史记录吗？")) {
    msgHistory = [];
    storageRemove("chan_msg_history");
    $("msgHistoryList").innerHTML = "";
  }
};

window.addEventListener("resize", () => {
  updateCompactLayout();
  hideFloatingTip();
});

// Sidebar Resizer
const resizer = $("resizer");
const leftPanel = document.querySelector(".left");
let isResizing = false;

resizer.addEventListener("mousedown", (e) => {
  isResizing = true;
  document.body.style.cursor = "col-resize";
});

window.addEventListener("mousemove", (e) => {
  if (!isResizing) return;
  const newWidth = window.innerWidth - e.clientX;
  if (newWidth > 200 && newWidth < 800) {
    leftPanel.style.width = `${newWidth}px`;
    resizeCanvas();
  }
});

window.addEventListener("mouseup", () => {
  if (isResizing) {
    isResizing = false;
    document.body.style.cursor = "default";
    storageSet("chan_sidebar_width", leftPanel.style.width);
  }
});

// Restore sidebar width
const savedWidth = storageGet("chan_sidebar_width");
if (savedWidth) leftPanel.style.width = savedWidth;

const tradeOverlayState = { dragging: false, offsetX: 0, offsetY: 0, resizing: false, startW: 0, startH: 0, startX: 0, startY: 0, minimized: false, maximized: false, prevRect: null };
function clampOverlayPosition(overlay, left, top) {
  const margin = 8;
  const maxLeft = Math.max(margin, window.innerWidth - overlay.offsetWidth - margin);
  const maxTop = Math.max(margin, window.innerHeight - overlay.offsetHeight - margin);
  return {
    left: Math.max(margin, Math.min(maxLeft, left)),
    top: Math.max(margin, Math.min(maxTop, top)),
  };
}

function applyTradeOverlayPosition(left, top) {
  const overlay = $("tradeStatusOverlay");
  if (!overlay) return;
  const pos = clampOverlayPosition(overlay, left, top);
  overlay.style.left = `${pos.left}px`;
  overlay.style.top = `${pos.top}px`;
  overlay.style.right = "auto";
}

function saveTradeOverlayState() {
  const overlay = $("tradeStatusOverlay");
  if (!overlay) return;
  storageSet("chan_trade_overlay_pos", JSON.stringify({
    left: parseFloat(overlay.style.left) || 16,
    top: parseFloat(overlay.style.top) || 16,
    width: parseFloat(overlay.style.width) || overlay.offsetWidth || 280,
    height: parseFloat(overlay.style.height) || overlay.offsetHeight || 0,
    minimized: !!tradeOverlayState.minimized,
    maximized: !!tradeOverlayState.maximized,
  }));
}

function initTradeStatusDrag() {
  const overlay = $("tradeStatusOverlay");
  const titleBar = overlay ? overlay.querySelector(".tradeStatusTitleBar") : null;
  const resizeHandle = overlay ? overlay.querySelector(".tradeStatusResizeHandle") : null;
  if (!overlay || !titleBar || !resizeHandle) return;
  const saved = safeJsonParse(storageGet("chan_trade_overlay_pos"), null);
  if (saved && Number.isFinite(saved.left) && Number.isFinite(saved.top)) {
    applyTradeOverlayPosition(saved.left, saved.top);
    if (Number.isFinite(saved.width)) {
      const safeWidth = Math.max(220, Math.min(window.innerWidth - 16, saved.width));
      overlay.style.width = `${safeWidth}px`;
    }
    if (Number.isFinite(saved.height) && saved.height > 0) {
      const safeHeight = Math.max(64, Math.min(window.innerHeight - 16, saved.height));
      overlay.style.height = `${safeHeight}px`;
    }
    tradeOverlayState.minimized = !!saved.minimized;
    // Do not auto-enter maximized mode on load, avoid covering the full page and blocking controls.
    tradeOverlayState.maximized = false;
    overlay.classList.toggle("minimized", tradeOverlayState.minimized);
  } else {
    applyTradeOverlayPosition(16, 16);
  }
  titleBar.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    if (e.target.closest("button")) return;
    tradeOverlayState.dragging = true;
    overlay.classList.add("dragging");
    const rect = overlay.getBoundingClientRect();
    tradeOverlayState.offsetX = e.clientX - rect.left;
    tradeOverlayState.offsetY = e.clientY - rect.top;
    e.preventDefault();
  });
  window.addEventListener("mousemove", (e) => {
    if (tradeOverlayState.dragging) {
      const left = e.clientX - tradeOverlayState.offsetX;
      const top = e.clientY - tradeOverlayState.offsetY;
      applyTradeOverlayPosition(left, top);
      return;
    }
    if (tradeOverlayState.resizing) {
      const nextW = Math.max(220, tradeOverlayState.startW + (e.clientX - tradeOverlayState.startX));
      const nextH = Math.max(64, tradeOverlayState.startH + (e.clientY - tradeOverlayState.startY));
      overlay.style.width = `${nextW}px`;
      overlay.style.height = `${nextH}px`;
    }
  });
  window.addEventListener("mouseup", () => {
    if (tradeOverlayState.dragging) {
      tradeOverlayState.dragging = false;
      overlay.classList.remove("dragging");
      saveTradeOverlayState();
    }
    if (tradeOverlayState.resizing) {
      tradeOverlayState.resizing = false;
      saveTradeOverlayState();
    }
  });
  resizeHandle.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    tradeOverlayState.resizing = true;
    tradeOverlayState.startW = overlay.offsetWidth;
    tradeOverlayState.startH = overlay.offsetHeight;
    tradeOverlayState.startX = e.clientX;
    tradeOverlayState.startY = e.clientY;
    e.preventDefault();
    e.stopPropagation();
  });
  $("btnTradeStatusMin").onclick = () => {
    tradeOverlayState.minimized = !tradeOverlayState.minimized;
    overlay.classList.toggle("minimized", tradeOverlayState.minimized);
    saveTradeOverlayState();
  };
  $("btnTradeStatusMax").onclick = () => {
    if (!tradeOverlayState.maximized) {
      tradeOverlayState.prevRect = {
        left: parseFloat(overlay.style.left) || 16,
        top: parseFloat(overlay.style.top) || 16,
        width: overlay.offsetWidth,
        height: overlay.offsetHeight,
      };
      overlay.style.left = "8px";
      overlay.style.top = "8px";
      overlay.style.width = `${Math.max(320, window.innerWidth - 16)}px`;
      overlay.style.height = `${Math.max(90, window.innerHeight - 16)}px`;
      tradeOverlayState.maximized = true;
    } else {
      const prev = tradeOverlayState.prevRect || { left: 16, top: 16, width: 280, height: overlay.offsetHeight };
      overlay.style.left = `${prev.left}px`;
      overlay.style.top = `${prev.top}px`;
      overlay.style.width = `${prev.width}px`;
      overlay.style.height = `${prev.height}px`;
      tradeOverlayState.maximized = false;
    }
    saveTradeOverlayState();
  };
}
initTradeStatusDrag();

function setState(p) {
  if (!p.ready) {
    setText("st_cash", "-");
    setText("st_pos", "-");
    setText("st_cost", "-");
    setText("st_price", "-");
    setText("st_pos_pnl", "-");
    setText("st_equity", "-");
    setText("st_total_pnl", "-");
    return;
  }
  const a = p.account;
  const price = (p.price === null || p.price === undefined) ? null : Number(p.price);
  
  // Fix precision: very small P/L should be 0
  const totalPnl = Math.abs(a.equity - a.initial_cash) < 0.005 ? 0 : (a.equity - a.initial_cash);
  const posPnlRaw = a.position > 0 && price !== null ? (price - a.avg_cost) * a.position : 0;
  const posPnl = Math.abs(posPnlRaw) < 0.005 ? 0 : posPnlRaw;

  setText("st_cash", a.cash.toFixed(2) + " 元");
  setText("st_pos", String(a.position) + " 股");
  setText("st_cost", a.avg_cost === 0 ? "-" : a.avg_cost.toFixed(4) + " 元");
  setText("st_price", price === null ? "-" : price.toFixed(4) + " 元");
  
  const posPnlEl = $("st_pos_pnl");
  if (posPnlEl) {
    posPnlEl.textContent = (posPnl >= 0 ? "+" : "") + posPnl.toFixed(2) + " 元";
    posPnlEl.style.color = posPnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (posPnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");
  }

  setText("st_equity", a.equity.toFixed(2) + " 元");
  
  const totalPnlEl = $("st_total_pnl");
  if (totalPnlEl) {
    totalPnlEl.textContent = (totalPnl >= 0 ? "+" : "") + totalPnl.toFixed(2) + " 元";
    totalPnlEl.style.color = totalPnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (totalPnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");
  }
}

function updateTradeStatusOverlay(payload) {
  const overlay = $("tradeStatusOverlay");
  if (!payload || !payload.ready || !payload.account || payload.account.position <= 0) {
    overlay.style.display = "none";
    return;
  }

  const a = payload.account;
  const price = payload.price;
  const buyX = activeTrade ? activeTrade.buyX : null;
  const lastX = payload.chart.kline[payload.chart.kline.length - 1].x;
  const holdBars = buyX !== null ? (lastX - buyX) : 0;
  const pnlRaw = (price - a.avg_cost) * a.position;
  const pnl = Math.abs(pnlRaw) < 0.005 ? 0 : pnlRaw;
  const pnlPct = (a.avg_cost > 0 && a.position > 0) ? (pnl / (a.avg_cost * a.position)) * 100 : 0;
  const totalPnlRaw = a.equity - a.initial_cash;
  const totalPnl = Math.abs(totalPnlRaw) < 0.005 ? 0 : totalPnlRaw;

  overlay.style.display = "block";
  overlay.style.borderColor = pnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (pnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "#e2e8f0");
  const titleEl = overlay.querySelector(".tradeStatusTitle");
  if (titleEl) {
    titleEl.style.fontSize = `${chartConfig.tradeStatus.titleFontSize}px`;
    titleEl.style.fontWeight = chartConfig.tradeStatus.titleFontWeight;
    titleEl.style.color = getCfgColor(chartConfig.tradeStatus.titleColor);
  }
  overlay.querySelectorAll(".tsItem label").forEach((el) => {
    el.style.fontSize = `${chartConfig.tradeStatus.labelFontSize}px`;
    el.style.fontWeight = chartConfig.tradeStatus.labelFontWeight;
    el.style.color = getCfgColor(chartConfig.tradeStatus.labelColor);
  });
  overlay.querySelectorAll(".tsItem span").forEach((el) => {
    el.style.fontSize = `${chartConfig.tradeStatus.valueFontSize}px`;
    el.style.fontWeight = chartConfig.tradeStatus.valueFontWeight;
    el.style.color = getCfgColor(chartConfig.tradeStatus.valueColor);
  });

  setText("ts_hold_bars", `${holdBars} 根`);
  setText("ts_pos", `${a.position} 股`);
  setText("ts_buy_price", a.avg_cost.toFixed(4));
  setText("ts_curr_price", price.toFixed(4));
  
  const pnlEl = $("ts_pnl");
  pnlEl.textContent = (pnl >= 0 ? "+" : "") + pnl.toFixed(2);
  pnlEl.style.color = pnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (pnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");

  const pnlPctEl = $("ts_pnl_pct");
  pnlPctEl.textContent = `${(pnlPct >= 0 ? "+" : "") + pnlPct.toFixed(2)}%`;
  pnlPctEl.style.color = pnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (pnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");

  setText("ts_cash", `${a.cash.toFixed(2)} 元`);
  setText("ts_equity", `${a.equity.toFixed(2)} 元`);
  const totalPnlEl = $("ts_total_pnl");
  totalPnlEl.textContent = `${totalPnl >= 0 ? "+" : ""}${totalPnl.toFixed(2)} 元`;
  totalPnlEl.style.color = totalPnl > 0 ? getCfgColor(chartConfig.trade.profitColor) : (totalPnl < 0 ? getCfgColor(chartConfig.trade.lossColor) : "inherit");
}

function showSettlement(tr, stockName) {
  const pnl = (tr.sellPrice - tr.buyPrice) * tr.shares;
  const pnlPct = ((tr.sellPrice - tr.buyPrice) / tr.buyPrice) * 100;
  const holdBars = tr.sellX - tr.buyX;
  
  // Estimate max favorable excursion and max adverse excursion if we have the data
  // For now we just show basic info
  
  const modal = $("settlementModal");
  const body = $("settlementBody");
  const title = $("settlementTitle");
  
  title.textContent = pnl >= 0 ? "交易结算 - 盈利" : "交易结算 - 亏损";
  title.style.color = pnl >= 0 ? "#ef4444" : "#22c55e";
  
  body.innerHTML = `
    <div style="display:grid; grid-template-columns: 1fr 1fr; gap: 12px;">
      <div>标的: <b>${stockName || '-'}</b></div>
      <div>持仓周期: <b>${holdBars} 根</b></div>
      <div>买入价格: <b>${tr.buyPrice.toFixed(4)}</b></div>
      <div>卖出价格: <b>${tr.sellPrice.toFixed(4)}</b></div>
      <div>成交股数: <b>${tr.shares}</b></div>
      <div style="grid-column: span 2; border-top: 1px dashed #ccc; padding-top: 8px; margin-top: 4px;"></div>
      <div>盈亏金额: <b class="${pnl >= 0 ? 'pnl-plus' : 'pnl-minus'}">${pnl.toFixed(2)}</b></div>
      <div>盈亏比例: <b class="${pnl >= 0 ? 'pnl-plus' : 'pnl-minus'}">${pnlPct.toFixed(2)}%</b></div>
    </div>
    <div style="margin-top: 16px; font-size: 12px; color: #64748b;">
      * 最大上涨和回撤指标将在后续版本支持更精确的日内数据统计。
    </div>
  `;
  
  setMsg(
    `交易结算\n标的：${stockName || '-'}\n持仓周期：${holdBars} 根\n买入价格：${tr.buyPrice.toFixed(4)}\n卖出价格：${tr.sellPrice.toFixed(4)}\n成交股数：${tr.shares}\n盈亏金额：${pnl.toFixed(2)}\n盈亏比例：${pnlPct.toFixed(2)}%`,
    true
  );
  modal.classList.add("show");
}

function buildTradeExportSummary(payload) {
  let wins = 0;
  let loss = 0;
  let sumPnl = 0;
  let peak = 0;
  let curve = 0;
  let maxDd = 0;
  let bestTrade = null;
  let worstTrade = null;
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
    maxDd = Math.max(maxDd, peak - curve);
    if (!bestTrade || pnl > bestTrade.pnl) bestTrade = { idx: i + 1, pnl };
    if (!worstTrade || pnl < worstTrade.pnl) worstTrade = { idx: i + 1, pnl };
    rows.push(`${i + 1},${tr.buyX},${tr.buyPrice.toFixed(4)},${tr.sellX},${tr.sellPrice.toFixed(4)},${shares},${pnl.toFixed(2)},${pnlPct.toFixed(2)},${hold}`);
  }
  const n = tradeHistory.length;
  const winRate = n === 0 ? 0 : (wins / n) * 100;
  const avgPnl = n === 0 ? 0 : sumPnl / n;
  rows.unshift(`# 最差单笔,${worstTrade ? `${worstTrade.idx}:${worstTrade.pnl.toFixed(2)}` : "-"}`);
  rows.unshift(`# 最佳单笔,${bestTrade ? `${bestTrade.idx}:${bestTrade.pnl.toFixed(2)}` : "-"}`);
  rows.unshift(`# 最大回撤近似(按已平仓序列),${maxDd.toFixed(2)}`);
  rows.unshift(`# 胜率,${winRate.toFixed(2)}%`);
  rows.unshift(`# 平均每笔盈亏,${avgPnl.toFixed(2)}`);
  rows.unshift(`# 总盈亏,${sumPnl.toFixed(2)}`);
  rows.unshift(`# 亏损笔数,${loss}`);
  rows.unshift(`# 盈利笔数,${wins}`);
  rows.unshift(`# 交易笔数,${n}`);
  rows.unshift(`# 标的,${payload.name || payload.code || "-"}`);
  rows.unshift(`# 导出时间,${new Date().toISOString()}`);
  return rows.join("\\n");
}

function downloadTradeExport(payload) {
  const blob = new Blob([buildTradeExportSummary(payload)], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `chan_trades_${payload.code || "session"}_${Date.now()}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

$("btnSettlementClose").onclick = () => {
  $("settlementModal").classList.remove("show");
};

function getVisibleKs(chart, xMin, xMax) {
  let visibleK = chart.kline.filter((k) => k.x >= xMin && k.x <= xMax);
  if (visibleK.length === 0) visibleK = chart.kline;
  return visibleK;
}

function nearestKByX(ks, targetX) {
  if (!ks || ks.length === 0) return null;
  return ks.reduce((best, cur) => {
    return Math.abs(cur.x - targetX) < Math.abs(best.x - targetX) ? cur : best;
  }, ks[0]);
}

function getChipBaseKs(chart) {
  // Use full history K-lines for chip distribution.
  // Accumulation cutoff is controlled by reference K (crosshair/latest), not by replay step.
  return (chart.kline_all && chart.kline_all.length > 0) ? chart.kline_all : (chart.kline || []);
}

function getReferenceKByBounds(chart, xMin, xMax, w) {
  const ksAll = getChipBaseKs(chart);
  if (ksAll.length === 0) return null;
  if (!crosshairEnabled || crosshairX === null) return ksAll[ksAll.length - 1];
  const plotW = Math.max(1, w - PAD_L - PAD_R);
  const clampedX = Math.max(PAD_L, Math.min(w - PAD_R, crosshairX));
  const targetX = xMin + ((clampedX - PAD_L) / plotW) * (xMax - xMin);
  const visibleKs = getVisibleKs(chart, xMin, xMax).filter((k) => k.x <= ksAll[ksAll.length - 1].x);
  return nearestKByX(visibleKs.length > 0 ? visibleKs : ksAll, targetX) || ksAll[ksAll.length - 1];
}

function getReferenceK(chart, s) {
  return getReferenceKByBounds(chart, s.xMin, s.xMax, s.w);
}

function getPanelByY(s, y) {
  if (!s.subPanels || s.subPanels.length === 0) return null;
  return s.subPanels.find((panel) => y >= panel.top && y <= panel.bottom) || null;
}

function toScaler(chart, xMin, xMax) {
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;

  const xToTime = {};
  for (const k of chart.kline) {
    xToTime[k.x] = k.t;
  }

  let visibleK = getVisibleKs(chart, xMin, xMax);

  let yMin = Infinity;
  let yMax = -Infinity;
  for (const k of visibleK) {
    if (k.l < yMin) yMin = k.l;
    if (k.h > yMax) yMax = k.h;
  }
  
  const indicatorCfg = getIndicatorConfig();
  const mainTypes = indicatorCfg.mainTypes || [];
  const mainTypeSet = new Set(mainTypes.map((m) => m.type));
  const visibleInd = (chart.indicators || []).filter(i => i.x >= xMin && i.x <= xMax);
  if (mainTypeSet.has("boll")) {
    for (const i of visibleInd) {
      if (i.boll.up > yMax) yMax = i.boll.up;
      if (i.boll.down < yMin) yMin = i.boll.down;
    }
  }
  if (mainTypeSet.has("trendline") && chart.trend_lines) {
    for (const tl of chart.trend_lines) {
      const yAtMin = tl.y0 + tl.slope * (xMin - tl.x0);
      const yAtMax = tl.y0 + tl.slope * (xMax - tl.x0);
      if (isFinite(yAtMin)) {
        if (yAtMin > yMax) yMax = yAtMin;
        if (yAtMin < yMin) yMin = yAtMin;
      }
      if (isFinite(yAtMax)) {
        if (yAtMax > yMax) yMax = yAtMax;
        if (yAtMax < yMin) yMin = yAtMax;
      }
    }
  }
  if (chartConfig.rhythmLine && chartConfig.rhythmLine.enabled && chart.rhythm_lines) {
    for (const rl of chart.rhythm_lines) {
      if (!isRhythmLevelEnabled(rl.level)) continue;
      if (!intersects(rl, xMin, xMax)) continue;
      const yVal = Number(rl.y1);
      if (!Number.isFinite(yVal)) continue;
      if (yVal > yMax) yMax = yVal;
      if (yVal < yMin) yMin = yVal;
    }
  }
  if (!isFinite(yMin) || !isFinite(yMax)) {
    yMin = 0;
    yMax = 1;
  }
  const baseYSpan = Math.max(1e-6, yMax - yMin);
  const midY = (yMax + yMin) / 2;
  const zoomedSpan = baseYSpan / viewYZoomRatio;
  yMin = midY - zoomedSpan / 2;
  yMax = midY + zoomedSpan / 2;

  if (viewYShiftRatio !== 0) {
    const yOffset = baseYSpan * viewYShiftRatio;
    yMin += yOffset;
    yMax += yOffset;
  }

  const xSpan = Math.max(1, xMax - xMin);
  const ySpan = Math.max(1e-6, yMax - yMin);

  const totalChartH = h - PAD_T - PAD_B;
  const subCharts = indicatorCfg.subCharts;
  let subPanelGap = 18;
  let subPanelH = 90;
  const maxSubAreaH = totalChartH * 0.55;
  const totalNeed = subCharts.length * (subPanelH + subPanelGap);
  if (subCharts.length > 0 && totalNeed > maxSubAreaH) {
    const scale = maxSubAreaH / totalNeed;
    subPanelGap *= scale;
    subPanelH *= scale;
  }
  const totalSubH = subCharts.length > 0 ? subCharts.length * (subPanelH + subPanelGap) : 0;
  const plotBottomY = h - PAD_B - totalSubH;
  const plotH = plotBottomY - PAD_T;
  const plotW = w - PAD_L - PAD_R;
  const subPanels = [];
  let panelTop = plotBottomY;
  for (const subCfg of subCharts) {
    panelTop += subPanelGap;
    const top = panelTop;
    const bottom = top + subPanelH;
    subPanels.push({
      slot: subCfg.slot,
      type: subCfg.type,
      top,
      bottom,
      height: subPanelH,
    });
    panelTop = bottom;
  }
  const contentBottom = subPanels.length > 0 ? subPanels[subPanels.length - 1].bottom : plotBottomY;

  return {
    visibleK,
    visibleInd,
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
    subPanels,
    contentBottom,
    mainTypes,
    x: (x) => PAD_L + ((x - xMin) / xSpan) * plotW,
    y: (y) => PAD_T + ((yMax - y) / ySpan) * plotH,
    yFromPx: (py) => yMax - ((py - PAD_T) / Math.max(1, plotH)) * ySpan,
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

  // main y labels/ticks on both sides
  const tickStep = chartConfig.yAxis.interval || 0.5;
  const startTick = Math.ceil(s.yMin / tickStep);
  const endTick = Math.floor(s.yMax / tickStep);
  ctx.save();
  ctx.strokeStyle = cssVar("--grid", "#e2e8f0");
  ctx.fillStyle = cssVar("--muted", "#475569");
  ctx.font = `${chartConfig.yAxis.fontWeight || "normal"} ${chartConfig.yAxis.fontSize || 12}px Consolas`;
  ctx.lineWidth = 1;
  for (let t = startTick; t <= endTick; t++) {
    const p = t * tickStep;
    const y = s.y(p);
    if (y < PAD_T || y > yBase) continue;
    ctx.globalAlpha = 0.2;
    ctx.beginPath();
    ctx.moveTo(xLeft, y);
    ctx.lineTo(xRight, y);
    ctx.stroke();
    ctx.globalAlpha = 1;
    ctx.beginPath();
    ctx.moveTo(xLeft - 4, y);
    ctx.lineTo(xLeft, y);
    ctx.moveTo(xRight, y);
    ctx.lineTo(xRight + 4, y);
    ctx.stroke();
    const txt = formatPriceText(p, 2);
    ctx.fillText(txt, 4, y + (chartConfig.yAxis.fontSize / 2.5));
    const tw = ctx.measureText(txt).width;
    ctx.fillText(txt, s.w - tw - 4, y + (chartConfig.yAxis.fontSize / 2.5));
  }
  ctx.restore();
  
  if (s.subPanels.length > 0) {
    ctx.font = "10px Consolas";
    for (const panel of s.subPanels) {
      ctx.beginPath();
      ctx.moveTo(xLeft, panel.top);
      ctx.lineTo(xLeft, panel.bottom);
      ctx.lineTo(xRight, panel.bottom);
      ctx.stroke();
      ctx.fillStyle = cssVar("--muted", "#475569");
      ctx.fillText(`#${panel.slot} ${panel.type.toUpperCase()}`, xLeft + 6, panel.top + 12);
    }
    drawXTicks(s, s.contentBottom);
  } else {
    drawXTicks(s, yBase);
  }
}

function drawXTicks(s, yPos) {
  const span = s.xMax - s.xMin;
  if (span <= 0) return;
  const interval = chartConfig.xAxis.interval || 10;
  const tickXs = [];
  const startX = Math.ceil(s.xMin / interval) * interval;
  for (let x = startX; x <= s.xMax; x += interval) {
    tickXs.push(x);
  }
  const uniq = [...new Set(tickXs)];

  ctx.save();
  ctx.font = `${chartConfig.xAxis.fontWeight || "normal"} ${chartConfig.xAxis.fontSize || 12}px Consolas`;
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
    const rad = (chartConfig.xAxis.rotation || -45) * (Math.PI / 180);
    ctx.rotate(rad);
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.fillText(t, 0, 0);
    ctx.restore();
  }
  ctx.restore();
}

function drawCrosshair(s) {
  if (!crosshairEnabled || crosshairX === null || crosshairY === null) return;
  const chart = lastPayload && lastPayload.chart ? lastPayload.chart : null;
  if (!chart) return;
  const refK = getReferenceK(chart, s);
  if (!refK) return;
  const x = s.x(refK.x);
  const y = Math.max(PAD_T, Math.min(s.contentBottom, crosshairY));
  const t = refK.t || "-";
  const crossPrice = s.yFromPx(y);
  const bspTags = getBspAtX(chart, refK.x);
  const infoRows = [
    formatDateWithWeekday(t),
    `Open:  ${formatPriceText(refK.o)}`,
    `High:  ${formatPriceText(refK.h)}`,
    `Low:   ${formatPriceText(refK.l)}`,
    `Close: ${formatPriceText(refK.c)}`,
    bspTags.length > 0 ? `信号:${bspTags.join(" | ")}` : "信号:-",
  ];

  ctx.save();
  ctx.strokeStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.lineWidth = chartConfig.crosshair.width;
  ctx.setLineDash([4, 4]);
  ctx.beginPath();
  ctx.moveTo(x, PAD_T);
  ctx.lineTo(x, s.contentBottom);
  ctx.moveTo(PAD_L, y);
  ctx.lineTo(s.w - PAD_R, y);
  ctx.stroke();
  ctx.setLineDash([]);

  // Dynamic horizontal-line price label on both y-axes.
  const crossFontSize = chartConfig.crosshair.fontSize;
  ctx.font = `bold ${crossFontSize}px Consolas`;
  const axisPrice = formatPriceText(crossPrice, 3);
  const axisPad = 8;
  const axisH = crossFontSize + 10;
  const axisW = ctx.measureText(axisPrice).width + axisPad * 2;
  const axisY = y - axisH / 2;
  const leftX = Math.max(2, PAD_L - axisW - 4);
  const rightX = s.w - PAD_R + 4;
  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.95)");
  ctx.strokeStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.fillRect(leftX, axisY, axisW, axisH);
  ctx.strokeRect(leftX, axisY, axisW, axisH);
  ctx.fillRect(rightX, axisY, axisW, axisH);
  ctx.strokeRect(rightX, axisY, axisW, axisH);
  ctx.fillStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.fillText(axisPrice, leftX + axisPad, y + (crossFontSize / 2) - 2);
  ctx.fillText(axisPrice, rightX + axisPad, y + (crossFontSize / 2) - 2);

  // OHLC + date + weekday + BSP
  ctx.font = `bold ${crossFontSize}px Consolas`;
  let maxW = 0;
  for (const row of infoRows) {
    const w = ctx.measureText(row).width;
    if (w > maxW) maxW = w;
  }
  const cardPad = 10;
  const rowH = crossFontSize + 6;
  const boxW = Math.max(170 + (crossFontSize - 12) * 10, maxW + cardPad * 2);
  const boxH = cardPad * 2 + rowH * infoRows.length;
  let boxX = x + 12;
  if (boxX + boxW > s.w - PAD_R - 4) boxX = x - boxW - 12;
  boxX = Math.max(PAD_L + 4, Math.min(s.w - PAD_R - boxW - 4, boxX));
  let boxY = y - boxH - 10;
  boxY = Math.max(PAD_T + 4, Math.min(s.contentBottom - boxH - 4, boxY));

  ctx.fillStyle = cssVar("--legendBg", "rgba(255,255,255,0.95)");
  ctx.strokeStyle = getCfgColor(chartConfig.crosshair.color);
  ctx.fillRect(boxX, boxY, boxW, boxH);
  ctx.strokeRect(boxX, boxY, boxW, boxH);
  ctx.fillStyle = getCfgColor(chartConfig.crosshair.color);
  for (let i = 0; i < infoRows.length; i++) {
    ctx.fillText(infoRows[i], boxX + cardPad, boxY + cardPad + crossFontSize + i * rowH);
  }
  ctx.restore();
}

function drawGridLines(s) {
  // Keep chart background clean: no horizontal grid lines.
}

function drawChips(chart, s) {
  if (!chartConfig.chip.enabled) return;
  const ksAll = getChipBaseKs(chart);
  const visibleKs = s.visibleK || [];
  const latestVisibleK = visibleKs.length > 0 ? visibleKs[visibleKs.length - 1] : ((chart.kline && chart.kline.length > 0) ? chart.kline[chart.kline.length - 1] : null);
  const crossRefK = (crosshairEnabled && crosshairX !== null && canvasHovered) ? getReferenceK(chart, s) : null;
  const refMode = String(chartConfig.chip.peakRefMode || "latest_visible");
  const getTurnRef = (type) => {
    const arr = type === "seg" ? (chart.seg || []) : (chart.bi || []);
    let best = null;
    for (const l of arr) {
      if (!l || !Number.isFinite(l.x2)) continue;
      if (!latestVisibleK || l.x2 > latestVisibleK.x) continue;
      if (!best || l.x2 > best.x) best = { x: l.x2 };
    }
    if (!best) return null;
    return (chart.kline || []).find((k) => k.x === best.x) || null;
  };
  let refK = crossRefK;
  if (!refK) {
    if (refMode === "seg_turn") refK = getTurnRef("seg");
    else if (refMode === "bi_turn") refK = getTurnRef("bi");
    if (!refK) refK = latestVisibleK || (ksAll.length > 0 ? ksAll[ksAll.length - 1] : null);
  }
  const refText = `日期:${refK?.t || "-"}`;
  if (ksAll.length === 0 || !refK) return;
  const priceStep = chartConfig.chip.bucketStep || 0.1;
  const stepMul = 1 / priceStep;
  // Cutoff by date/time (stable across different x indexing bases)
  const refT = String(refK.t || "");
  const useKs = refT ? ksAll.filter((k) => String(k.t || "") <= refT) : ksAll;

  let allMin = Infinity;
  let allMax = -Infinity;
  for (const k of useKs) {
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

  // Visual-only stretch (monotonic): keep all historical chips unchanged,
  // only amplify contrast on rendering.
  const stretchExp = getChipStretchExponent();
  const stretchVol = (v) => Math.pow(Math.max(0, v), stretchExp);
  let maxVVisible = 0;
  for (let i = 0; i < tickCount; i++) {
    const p = (minTick + i) / stepMul;
    const v = stretchVol(arr[i]);
    if (p < s.yMin || p > s.yMax) continue;
    if (v > maxVVisible) maxVVisible = v;
  }
  if (maxVVisible <= 0) return;
  const chipW = Math.max(96, Math.min(220, s.plotW * 0.2));
  const xR = s.w - PAD_R - 2;
  const xL = xR - chipW;
  const fill = getCfgColor(chartConfig.chip.color);
  const bg = cssVar("--chipBg", "rgba(148,163,184,0.12)");
  const edge = cssVar("--chipEdge", "rgba(59,130,246,0.75)");

  ctx.save();
  ctx.fillStyle = bg;
  ctx.fillRect(xL, PAD_T, chipW, s.plotBottomY - PAD_T);
  for (let i = 0; i < tickCount; i++) {
    const vRaw = arr[i];
    const v = stretchVol(vRaw);
    if (v <= 0) continue;
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    const len = (v / maxVVisible) * chipW;
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
  ctx.fillText(`筹码(${refText})`, xL + 6, PAD_T + 14);
  const peaks = [];
  for (let i = 1; i < tickCount - 1; i++) {
    const cur = arr[i];
    if (!(cur > arr[i - 1] && cur > arr[i + 1])) continue;
    const p = (minTick + i) / stepMul;
    if (p < s.yMin || p > s.yMax) continue;
    peaks.push(p);
  }
  if (peaks.length > 0) {
    ctx.save();
    ctx.strokeStyle = getCfgColor(chartConfig.chip.peakLineColor || "#2563eb");
    ctx.lineWidth = Number(chartConfig.chip.peakLineWidth || 1.2);
    ctx.setLineDash(getTradeLineDash(chartConfig.chip.peakLineStyle || "dashed"));
    if (chartConfig.chip.peakLineEnabled !== false) {
      for (const p of peaks) {
        const yPx = s.y(p);
        ctx.beginPath();
        ctx.moveTo(xL, yPx);
        ctx.lineTo(PAD_L, yPx);
        ctx.stroke();
      }
    }
    ctx.restore();
  }
  ctx.restore();
}

function drawCandles(chart, s) {
  const ks = s.visibleK;
  const bodyW = Math.max(3, (s.plotW) / Math.max(42, ks.length * 1.28));
  const upS = getCfgColor(chartConfig.candle.upColor);
  const dnS = getCfgColor(chartConfig.candle.downColor);
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
    ctx.lineWidth = chartConfig.candle.width;

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
    { label: "分型辅助线", color: getCfgColor(chartConfig.fx.color), dashed: true, w: chartConfig.fx.width },
    { label: "分型(确定)", color: getCfgColor(chartConfig.fract.color), dashed: false, w: chartConfig.fract.widthSure },
    { label: "分型(未完成)", color: getCfgColor(chartConfig.fract.color), dashed: true, w: chartConfig.fract.widthUnsure },
    { label: "笔(确定)", color: getCfgColor(chartConfig.bi.color), dashed: false, w: chartConfig.bi.widthSure },
    { label: "笔(未完成)", color: getCfgColor(chartConfig.bi.color), dashed: true, w: chartConfig.bi.widthUnsure },
    { label: "段(确定)", color: getCfgColor(chartConfig.seg.color), dashed: false, w: chartConfig.seg.widthSure },
    { label: "段(未完成)", color: getCfgColor(chartConfig.seg.color), dashed: true, w: chartConfig.seg.widthUnsure },
    { label: "2段(确定)", color: getCfgColor(chartConfig.segseg.color), dashed: false, w: chartConfig.segseg.widthSure },
    { label: "2段(未完成)", color: getCfgColor(chartConfig.segseg.color), dashed: true, w: chartConfig.segseg.widthUnsure },
    { label: "节奏线1", color: getRhythmVisualConfig("rhythm1").lineColor, dashed: getRhythmVisualConfig("rhythm1").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm1").lineWidth },
    { label: "节奏线2", color: getRhythmVisualConfig("rhythm2").lineColor, dashed: getRhythmVisualConfig("rhythm2").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm2").lineWidth },
    { label: "节奏线3", color: getRhythmVisualConfig("rhythm3").lineColor, dashed: getRhythmVisualConfig("rhythm3").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm3").lineWidth },
    { label: "节奏线4", color: getRhythmVisualConfig("rhythm4").lineColor, dashed: getRhythmVisualConfig("rhythm4").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm4").lineWidth },
    { label: "节奏线5", color: getRhythmVisualConfig("rhythm5").lineColor, dashed: getRhythmVisualConfig("rhythm5").lineStyle !== "solid", w: getRhythmVisualConfig("rhythm5").lineWidth },
  ];
  ctx.save();
  const fontSize = chartConfig.legend.fontSize;
  ctx.font = `${chartConfig.legend.fontWeight || "normal"} ${fontSize}px Consolas`;
  ctx.textBaseline = "middle";
  let maxW = 0;
  for (const L of lines) {
    const tw = ctx.measureText(L.label).width + 52;
    if (tw > maxW) maxW = tw;
  }
  const lh = fontSize + 6;
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
    ctx.fillStyle = getCfgColor(chartConfig.legend.color || cssVar("--legendText", "#0f172a"));
    ctx.fillText(L.label, xLine + 32, y);
    y += lh;
  }
  ctx.restore();
}

function drawTradeBands(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const lastX = chart.kline[chart.kline.length - 1].x;
  const fillHoldBackground = (x1, x2, color, alphaMul) => {
    if (x1 == null || x2 == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    ctx.save();
    ctx.fillStyle = color;
    ctx.globalAlpha = alphaMul;
    ctx.fillRect(Math.min(xa, xb), PAD_T, Math.abs(xb - xa), s.plotBottomY - PAD_T);
    ctx.restore();
  };

  const fillPnlBand = (x1, x2, buyPrice, endPrice) => {
    if (x1 == null || x2 == null || buyPrice == null || endPrice == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    const xa = s.x(lo);
    const xb = s.x(hi);
    const yBuy = s.y(buyPrice);
    const yEnd = s.y(endPrice);
    const top = Math.min(yBuy, yEnd);
    const height = Math.max(1, Math.abs(yEnd - yBuy));
    const isProfit = endPrice >= buyPrice;
    const pnlColor = isProfit ? getCfgColor(chartConfig.trade.profitBandColor) : getCfgColor(chartConfig.trade.lossBandColor);
    ctx.save();
    ctx.fillStyle = pnlColor;
    ctx.globalAlpha = 0.28;
    ctx.fillRect(Math.min(xa, xb), top, Math.abs(xb - xa), height);
    ctx.restore();
  };

  for (const tr of tradeHistory) {
    if (tr.buyX != null && tr.sellX != null) {
      fillHoldBackground(tr.buyX, tr.sellX, getCfgColor(chartConfig.trade.rangeFillSell), 0.11);
      fillPnlBand(tr.buyX, tr.sellX, tr.buyPrice, tr.sellPrice);
    }
  }
  if (lastPayload.account.position > 0 && activeTrade && activeTrade.buyX != null) {
    fillHoldBackground(activeTrade.buyX, lastX, getCfgColor(chartConfig.trade.rangeFillBuy), 0.11);
    fillPnlBand(activeTrade.buyX, lastX, activeTrade.buyPrice, lastPayload.price);
  }
}

function drawTradeMarkers(s, chart) {
  if (!lastPayload || !lastPayload.ready) return;
  const buyC = getCfgColor(chartConfig.trade.buyColor);
  const sellC = getCfgColor(chartConfig.trade.sellColor);

  const mark = (xBar, color, tag) => {
    if (xBar < s.xMin || xBar > s.xMax) return;
    const xp = s.x(xBar);
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = chartConfig.trade.markerLineWidth || 2;
    ctx.setLineDash(getTradeLineDash(chartConfig.trade.markerLineStyle || "dashed"));
    ctx.beginPath();
    ctx.moveTo(xp, PAD_T);
    ctx.lineTo(xp, s.plotBottomY);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = color;
    ctx.font = `${chartConfig.trade.markerFontWeight || "bold"} ${chartConfig.trade.markerFontSize}px Consolas`;
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
  const drawRay = (x1, y1, x2, color, style) => {
    if (x1 == null || x2 == null || y1 == null) return;
    const lo = Math.min(x1, x2);
    const hi = Math.max(x1, x2);
    if (hi < s.xMin || lo > s.xMax) return;
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = chartConfig.trade.closeLineWidth || 2;
    ctx.setLineDash(getTradeLineDash(style || "solid"));
    ctx.beginPath();
    ctx.moveTo(s.x(x1), s.y(y1));
    ctx.lineTo(s.x(x2), s.y(y1));
    ctx.stroke();
    ctx.restore();
  };

  const rayBuy = getCfgColor(chartConfig.trade.buyColor);
  const raySell = getCfgColor(chartConfig.trade.sellColor);
  for (const tr of tradeHistory) {
    drawRay(tr.buyX, tr.buyPrice, tr.sellX, rayBuy, chartConfig.trade.buyCloseLineStyle || "solid");
    drawRay(tr.sellX, tr.sellPrice, tr.buyX, raySell, chartConfig.trade.sellCloseLineStyle || "dashed");
  }
  if (activeTrade && activeTrade.buyX != null && activeTrade.buyPrice != null) {
    const rightTo = Math.max(s.xMax, activeTrade.buyX + 1);
    drawRay(activeTrade.buyX, activeTrade.buyPrice, rightTo, rayBuy, chartConfig.trade.buyCloseLineStyle || "solid");
  }
}

function drawIndicators(chart, s) {
  if (!chart || !chart.indicators || chart.indicators.length === 0) return;
  const visibleInd = s.visibleInd || [];
  if (visibleInd.length === 0) return;
  
  const theme = document.documentElement.getAttribute("data-theme") || "light";
  const lineMain = theme === "light" ? "#1e293b" : "#f8fafc";
  const mainTypeSet = new Set((s.mainTypes || []).map((m) => m.type));

  const drawPanelLine = (arr, getter, yFn, color) => {
    ctx.strokeStyle = color;
    ctx.beginPath();
    let first = true;
    for (const item of arr) {
      const yVal = getter(item);
      if (!Number.isFinite(yVal)) continue;
      const xp = s.x(item.x);
      const yp = yFn(yVal);
      if (first) ctx.moveTo(xp, yp);
      else ctx.lineTo(xp, yp);
      first = false;
    }
    if (!first) ctx.stroke();
  };

  const getPanelRange = (type) => {
    let min = Infinity;
    let max = -Infinity;
    if (type === "macd") {
      for (const i of visibleInd) {
        if (!i.macd) continue;
        min = Math.min(min, i.macd.dif, i.macd.dea, i.macd.macd);
        max = Math.max(max, i.macd.dif, i.macd.dea, i.macd.macd);
      }
    } else if (type === "kdj") {
      min = 0;
      max = 100;
      for (const i of visibleInd) {
        if (!i.kdj) continue;
        min = Math.min(min, i.kdj.k, i.kdj.d, i.kdj.j);
        max = Math.max(max, i.kdj.k, i.kdj.d, i.kdj.j);
      }
    } else if (type === "rsi") {
      min = 0;
      max = 100;
    }
    if (!isFinite(min) || !isFinite(max)) {
      min = 0;
      max = 1;
    }
    if (min === max) {
      min -= 1;
      max += 1;
    }
    return [min, max];
  };

  const drawSubPanel = (panel) => {
    const [subYMin, subYMax] = getPanelRange(panel.type);
    const subYSpan = subYMax - subYMin;
    const subY = (val) => panel.bottom - ((val - subYMin) / subYSpan) * panel.height;

    ctx.save();
    ctx.fillStyle = cssVar("--muted", "#475569");
    ctx.font = "10px Consolas";
    ctx.fillText(subYMax.toFixed(2), 4, panel.top + 10);
    ctx.fillText(subYMin.toFixed(2), 4, panel.bottom);
    if (panel.type === "macd") {
      for (const i of visibleInd) {
        if (!i.macd) continue;
        const xp = s.x(i.x);
        const yp = subY(i.macd.macd);
        const y0 = subY(0);
        ctx.fillStyle = i.macd.macd >= 0 ? cssVar("--candleUp", "#ef4444") : cssVar("--candleDown", "#22c55e");
        ctx.fillRect(xp - 1, Math.min(yp, y0), 2, Math.abs(yp - y0));
      }
      drawPanelLine(visibleInd, (i) => i.macd?.dif, subY, lineMain);
      drawPanelLine(visibleInd, (i) => i.macd?.dea, subY, "#fbbf24");
    } else if (panel.type === "kdj") {
      drawPanelLine(visibleInd, (i) => i.kdj?.k, subY, lineMain);
      drawPanelLine(visibleInd, (i) => i.kdj?.d, subY, "#fbbf24");
      drawPanelLine(visibleInd, (i) => i.kdj?.j, subY, "#f472b6");
    } else if (panel.type === "rsi") {
      drawPanelLine(visibleInd, (i) => i.rsi, subY, lineMain);
    }
    ctx.restore();
  };

  if (mainTypeSet.has("boll")) {
    ctx.save();
    ctx.lineWidth = 1;
    drawPanelLine(visibleInd, (i) => i.boll?.mid, s.y, "#94a3b8");
    drawPanelLine(visibleInd, (i) => i.boll?.up, s.y, "#f59e0b");
    drawPanelLine(visibleInd, (i) => i.boll?.down, s.y, "#f59e0b");
    ctx.restore();
  }
  if (mainTypeSet.has("demark")) {
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
  }
  if (mainTypeSet.has("trendline")) {
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
  }
  for (const panel of s.subPanels || []) drawSubPanel(panel);
}

function drawBsp(arr, s) {
  return drawBottomSignals({ bsp: arr || [], rhythm: [] }, s);
}

function drawRhythmLines(arr, s) {
  if (!chartConfig.rhythmLine || !chartConfig.rhythmLine.enabled) return;
  // 自定义术语说明：
  // - “推进峰值端点”指与父结构同向推进的子级端点（上升时对应 D/F/H...）。
  // - line.label_left 是节奏线编号，例如 2_1。
  // - line.label_right 是该线复用的回调比例，例如 0.618。
  for (const line of arr || []) {
    if (!line || !isRhythmLevelEnabled(line.level)) continue;
    if (!intersects(line, s.xMin, s.xMax)) continue;
    const visual = getRhythmVisualConfig(line.color_group);
    const x1Val = Math.max(s.xMin, Math.min(s.xMax, Number(line.x1)));
    const x2Val = Math.max(s.xMin, Math.min(s.xMax, Number(line.x2)));
    const xp1 = s.x(x1Val);
    const xp2 = s.x(x2Val);
    const yp = s.y(line.y1);
    ctx.save();
    ctx.lineWidth = visual.lineWidth;
    ctx.setLineDash(getTradeLineDash(visual.lineStyle));
    ctx.strokeStyle = visual.lineColor;
    ctx.beginPath();
    ctx.moveTo(xp1, yp);
    ctx.lineTo(xp2, yp);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = visual.textColor;
    ctx.font = `${visual.textFontWeight} ${visual.textFontSize}px Consolas`;
    ctx.textBaseline = "middle";
    ctx.textAlign = "right";
    ctx.fillText(String(line.label_left || ""), xp1 - 6, yp);
    ctx.textAlign = "left";
    ctx.fillText(String(line.label_right || ""), xp2 + 6, yp);
    ctx.restore();
  }
}

function buildBottomSignalGroups(chart, bspArr) {
  const groups = {};
  const push = (x, item) => {
    if (!Number.isFinite(x)) return;
    if (!groups[x]) groups[x] = [];
    groups[x].push(item);
  };
  const colBuy = getCfgColor(chartConfig.trade.buyColor);
  const colSell = getCfgColor(chartConfig.trade.sellColor);
  for (const p of bspArr || []) {
    if (!p || !Number.isFinite(p.x)) continue;
    const bspCfg = getBspConfig(p.level);
    const prefix = p.status === "correct" ? "✓" : (p.status === "wrong" ? "×" : "·");
    const text = `${prefix} ${getBspDisplayLabel(p)}`;
    const levelPriority = p.level === "segseg" ? 0 : (p.level === "seg" ? 1 : 2);
    const statusPriority = p.status === "correct" ? 0 : (p.status === "wrong" ? 1 : 2);
    push(Number(p.x), {
      kind: "bsp",
      priority: 0,
      sortKey: levelPriority * 10 + statusPriority,
      text,
      tipText: text,
      fontSize: Number(bspCfg.fontSize || 14),
      textColor: p.is_buy ? colBuy : colSell,
      borderColor: p.is_buy ? colBuy : colSell,
      lineColor: getCfgColor(bspCfg.lineColor),
      lineWidth: Number(bspCfg.lineWidth || 1),
      lineStyle: bspCfg.lineStyle || "dashed",
    });
  }
  return groups;
}

function drawBottomSignals(chart, s) {
  signalHoverBoxes = [];
  const groups = buildBottomSignalGroups(chart, bspHistory || []);
  const xs = Object.keys(groups).map((x) => Number(x)).filter((x) => x >= s.xMin && x <= s.xMax).sort((a, b) => a - b);
  const boxGap = 4;
  const boxPadX = 8;
  const boxPadY = 5;
  const overflowLimit = 6;
  const byX = new Map((s.visibleK || []).map((k) => [k.x, k]));

  for (const x of xs) {
    const xp = s.x(x);
    const items = (groups[x] || []).slice().sort((a, b) => (a.priority - b.priority) || (a.sortKey - b.sortKey) || String(a.text).localeCompare(String(b.text)));
    const groupTip = items.map((item) => item.tipText || item.text).join("\\n");
    let renderItems = items.slice();
    if (items.length > overflowLimit) {
      renderItems = items.slice(0, Math.max(0, overflowLimit - 1));
      renderItems.push({
        kind: "overflow",
        priority: 999,
        sortKey: 999,
        text: "!",
        tipText: groupTip,
        fontSize: Math.max(
          Number(chartConfig.bspBi && chartConfig.bspBi.fontSize) || 14,
          Number(chartConfig.bspSeg && chartConfig.bspSeg.fontSize) || 14,
          Number(chartConfig.bspSegseg && chartConfig.bspSegseg.fontSize) || 14,
        ),
        textColor: cssVar("--muted", "#475569"),
        borderColor: cssVar("--muted", "#475569"),
        lineColor: cssVar("--muted", "#475569"),
        lineWidth: 1,
        lineStyle: "dashed",
        hoverOnly: true,
      });
    }

    const boxBottom = s.h - 8;
    const k = byX.get(x);
    let offsetY = 0;
    for (const item of renderItems) {
      ctx.save();
      ctx.font = `bold ${item.fontSize}px Consolas`;
      const textW = ctx.measureText(item.text).width;
      const lineH = item.fontSize + boxPadY * 2;
      const rectW = textW + boxPadX * 2;
      const rectX = xp - rectW / 2;
      const rectY = boxBottom - offsetY - lineH;
      if (k) {
        const anchorY = s.y(k.l);
        const toY = Math.max(PAD_T + 2, Math.min(s.h - PAD_B + 8, rectY - 6));
        ctx.save();
        ctx.lineWidth = Number(item.lineWidth || 1);
        ctx.setLineDash(getTradeLineDash(item.lineStyle || "dashed"));
        ctx.strokeStyle = item.lineColor;
        ctx.beginPath();
        ctx.moveTo(xp, anchorY);
        ctx.lineTo(xp, toY);
        ctx.stroke();
        ctx.restore();
      }
      ctx.fillStyle = cssVar("--panel", "#ffffff");
      ctx.strokeStyle = item.borderColor;
      ctx.lineWidth = 1.5;
      ctx.fillRect(rectX, rectY, rectW, lineH);
      ctx.strokeRect(rectX, rectY, rectW, lineH);
      ctx.fillStyle = item.textColor;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(item.text, xp, rectY + lineH / 2);
      if (item.tipText) {
        signalHoverBoxes.push({
          x1: rectX,
          y1: rectY,
          x2: rectX + rectW,
          y2: rectY + lineH,
          text: item.tipText,
          overflowOnly: !!item.hoverOnly,
        });
      }
      ctx.restore();
      offsetY += lineH + boxGap;
    }
  }
}

function drawUserRays(s) {
  if (!userRays || userRays.length === 0) return;
  ctx.save();
  ctx.font = `${chartConfig.userRay.fontSize}px Consolas`;
  // 这里刻意使用 forEach + return。
  // 注意：forEach 回调里不能写 continue，否则会触发
  // "Illegal continue statement" 并导致整段前端脚本失效。
  userRays.forEach((ray, idx) => {
    ctx.lineWidth = getRayLineWidth(ray);
    ctx.strokeStyle = getRayLineColor(ray);
    ctx.setLineDash(getTradeLineDash(getRayLineStyle(ray)));
    const xp = s.x(ray.x);
    const yp = s.y(ray.y);
    const xEnd = s.w - PAD_R;
    if (xp > xEnd) return;
    ctx.beginPath();
    ctx.moveTo(xp, yp);
    ctx.lineTo(xEnd, yp);
    ctx.stroke();
    
    // Draw price at the end
    ctx.fillStyle = getRayLineColor(ray);
    ctx.fillText(ray.y.toFixed(2), xEnd + 4, yp + (chartConfig.userRay.fontSize / 3));
    if (selectedDrawing && selectedDrawing.type === "ray" && selectedDrawing.index === idx) {
      ctx.save();
      ctx.setLineDash([]);
      ctx.strokeStyle = "#2563eb";
      ctx.lineWidth = 2;
      ctx.strokeRect(xp - 4, yp - 4, 8, 8);
      ctx.restore();
    }
    
    // label for deletion if crosshair or mouse is near
    if (crosshairX !== null && crosshairY !== null) {
      const cxp = crosshairX;
      const cyp = crosshairY;
      if (Math.abs(cyp - yp) < 8 && cxp >= xp - 10 && cxp <= xEnd + 10) {
         ctx.fillStyle = "#ef4444";
         ctx.font = `bold ${chartConfig.userRay.fontSize}px sans-serif`;
         ctx.fillText("双击删除射线", xp + 5, yp - 5);
      }
    }
  });
  ctx.restore();
}

function xFromPx(s, px) {
  const xSpan = Math.max(1, s.xMax - s.xMin);
  const plotW = Math.max(1, s.plotW);
  const clamped = Math.max(PAD_L, Math.min(s.w - PAD_R, px));
  return s.xMin + ((clamped - PAD_L) / plotW) * xSpan;
}

function getNearestBiEndpoint(chart, s, px, py, maxDistPx = 12) {
  if (!chart || !Array.isArray(chart.bi)) return null;
  const list = chart.bi || [];
  let best = null;
  let bestD2 = maxDistPx * maxDistPx;
  const pushCandidate = (x, y) => {
    const cx = s.x(x);
    const cy = s.y(y);
    const dx = cx - px;
    const dy = cy - py;
    const d2 = dx * dx + dy * dy;
    if (d2 <= bestD2) {
      bestD2 = d2;
      best = { x, y };
    }
  };
  for (const bi of list) {
    if (bi == null) continue;
    if (Number.isFinite(bi.x1) && Number.isFinite(bi.y1)) pushCandidate(bi.x1, bi.y1);
    if (Number.isFinite(bi.x2) && Number.isFinite(bi.y2)) pushCandidate(bi.x2, bi.y2);
  }
  return best;
}

function drawUserBiRays(s, chart) {
  if (!userBiRays || userBiRays.length === 0) return;
  ctx.save();
  // 同上：需要跳过当前回调时统一使用 return，避免继续踩到 JS 语法坑。
  userBiRays.forEach((r, idx) => {
    ctx.lineWidth = getRayLineWidth(r);
    ctx.strokeStyle = getRayLineColor(r);
    ctx.setLineDash(getTradeLineDash(getRayLineStyle(r)));
    const x1 = Number(r.x1), y1 = Number(r.y1), x2 = Number(r.x2), y2 = Number(r.y2);
    if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(x2) || !Number.isFinite(y2)) return;
    const dx = (x2 - x1);
    if (!Number.isFinite(dx) || dx === 0) return;
    const slope = (y2 - y1) / dx;
    const xEnd = s.xMax;
    const yEnd = y1 + slope * (xEnd - x1);
    const p1x = s.x(x1);
    const p1y = s.y(y1);
    const p2x = s.x(xEnd);
    const p2y = s.y(yEnd);
    if (p1x > s.w - PAD_R) return;
    ctx.beginPath();
    ctx.moveTo(p1x, p1y);
    ctx.lineTo(p2x, p2y);
    ctx.stroke();
    if (selectedDrawing && selectedDrawing.type === "biRay" && selectedDrawing.index === idx) {
      ctx.save();
      ctx.setLineDash([]);
      ctx.strokeStyle = "#2563eb";
      ctx.lineWidth = 2;
      ctx.strokeRect(p1x - 4, p1y - 4, 8, 8);
      ctx.restore();
    }

    if (crosshairX !== null && crosshairY !== null) {
      const xVal = xFromPx(s, crosshairX);
      if (xVal >= x1) {
        const yVal = y1 + slope * (xVal - x1);
        const yPx = s.y(yVal);
        if (Math.abs(yPx - crosshairY) < 8) {
          ctx.fillStyle = "#ef4444";
          ctx.font = `bold ${chartConfig.userRay.fontSize}px sans-serif`;
          ctx.fillText("双击删除射线", p1x + 5, yPx - 5);
        }
      }
    }
  });
  ctx.restore();
}

function drawPendingBiEndpointCircle(s) {
  if (!pendingBiRayPts || pendingBiRayPts.length !== 1) return;
  const pt = pendingBiRayPts[0];
  if (!pt || !Number.isFinite(pt.x) || !Number.isFinite(pt.y)) return;
  const xp = s.x(pt.x);
  const yp = s.y(pt.y);
  if (!Number.isFinite(xp) || !Number.isFinite(yp)) return;
  ctx.save();
  ctx.beginPath();
  ctx.arc(xp, yp, 10, 0, Math.PI * 2);
  ctx.strokeStyle = "#2563eb";
  ctx.lineWidth = 2;
  ctx.setLineDash([]);
  ctx.stroke();
  ctx.restore();
}

function drawZsRects(arr, s, color, width) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  for (const zs of arr || []) {
    const loX = Math.min(zs.x1, zs.x2);
    const hiX = Math.max(zs.x1, zs.x2);
    if (hiX < s.xMin || loX > s.xMax) continue;
    const x1 = s.x(loX);
    const x2 = s.x(hiX);
    const yTop = s.y(zs.high);
    const yBottom = s.y(zs.low);
    const rectX = Math.min(x1, x2);
    const rectY = Math.min(yTop, yBottom);
    const rectW = Math.max(1, Math.abs(x2 - x1));
    const rectH = Math.max(1, Math.abs(yBottom - yTop));
    if (!zs.is_sure) ctx.setLineDash([6, 4]);
    else ctx.setLineDash([]);
    ctx.strokeRect(rectX, rectY, rectW, rectH);
  }
  ctx.restore();
}

function draw(chart) {
  const cw = canvas.clientWidth;
  const ch = canvas.clientHeight;
  ctx.clearRect(0, 0, cw, ch);
  signalHoverBoxes = [];
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
  if (chartConfig.fractZs.enabled) {
    drawZsRects(chart.fract_zs || [], s, getCfgColor(chartConfig.fractZs.color), chartConfig.fractZs.width);
  }
  if (chartConfig.biZs.enabled) {
    drawZsRects(chart.bi_zs || [], s, getCfgColor(chartConfig.biZs.color), chartConfig.biZs.width);
  }
  if (chartConfig.segZs.enabled) {
    drawZsRects(chart.seg_zs || [], s, getCfgColor(chartConfig.segZs.color), chartConfig.segZs.width);
  }
  if (chartConfig.segsegZs.enabled) {
    drawZsRects(chart.segseg_zs || [], s, getCfgColor(chartConfig.segsegZs.color), chartConfig.segsegZs.width);
  }
  // 分型辅助线最细虚线 → 分型 → 笔 → 段 → 2段
  drawLines(chart.fx_lines || [], s, getCfgColor(chartConfig.fx.color), chartConfig.fx.width, true);
  drawLines((chart.fract || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.fract.color), chartConfig.fract.widthSure, false);
  drawLines((chart.fract || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.fract.color), chartConfig.fract.widthUnsure, true);
  drawLines((chart.bi || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.bi.color), chartConfig.bi.widthSure, false);
  drawLines((chart.bi || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.bi.color), chartConfig.bi.widthUnsure, true);
  drawLines((chart.seg || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.seg.color), chartConfig.seg.widthSure, false);
  drawLines((chart.seg || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.seg.color), chartConfig.seg.widthUnsure, true);
  drawLines((chart.segseg || []).filter((x) => x.is_sure), s, getCfgColor(chartConfig.segseg.color), chartConfig.segseg.widthSure, false);
  drawLines((chart.segseg || []).filter((x) => !x.is_sure), s, getCfgColor(chartConfig.segseg.color), chartConfig.segseg.widthUnsure, true);
  drawRhythmLines(chart.rhythm_lines || [], s);
  drawBottomSignals(chart, s);
  drawUserRays(s);
  drawUserBiRays(s, chart);
  drawPendingBiEndpointCircle(s);
  drawTradeMarkers(s, chart);
  drawCrosshair(s);
  drawLegend();
}

async function api(path, body, method = "POST") {
  const options = {
    method,
    headers: {"Content-Type": "application/json"}
  };
  if (body !== null && body !== undefined) options.body = JSON.stringify(body);
  const res = await fetch(path, options);
  const data = await res.json();
  if (!res.ok) throw new Error(data.detail || JSON.stringify(data));
  return data;
}

async function checkBspJudge(reason) {
  if (!lastPayload || !lastPayload.ready) return;
  const payload = await api("/api/judge_bsp", { reason: reason || "manual_check" });
  refreshUI(payload, { afterStep: false });
}

function detectBspPromptOnLastBar(payload) {
  return getLatestBspNotice(payload);
}

async function stepOnce(logMessage) {
  const prevStepIdx = lastPayload && Number.isFinite(lastPayload.step_idx) ? Number(lastPayload.step_idx) : null;
  const payload = await api("/api/step", { judge_mode: systemConfig.bspJudgeMode || "auto" });
  const bspNotice = isBspJudgeManual() ? null : detectBspPromptOnLastBar(payload);
  const noticeText = buildStepNoticeText(payload, bspNotice);
  refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
  const noticeShown = showCombinedNotice(noticeText);
  if (logMessage && !noticeShown) setMsg(payload.message || "步进成功");
  const reachedEnd = prevStepIdx !== null && Number(payload.step_idx) === prevStepIdx;
  return { payload, interrupted: !!bspNotice, reachedEnd, noticeShown };
}

function updateDataSourceStatus(payload) {
  const el = $("dataSourceStatus");
  if (!el) return;
  if (!payload || !payload.ready || !payload.data_source) {
    el.textContent = "当前数据源：未加载";
    el.title = "";
    return;
  }
  const info = payload.data_source || {};
  const label = String(info.label || "-");
  const logs = Array.isArray(info.logs) ? info.logs.map((item) => String(item || "").trim()).filter(Boolean) : [];
  el.textContent = `当前数据源：${label}`;
  el.title = logs.join("\\n");
}

function updateCompactLayout() {
  const left = document.querySelector(".left");
  const content = $("leftContent");
  if (!left || !content) return;
  left.classList.remove("compact");
  const available = Math.max(100, left.clientHeight - 4);
  const contentHeight = content.scrollHeight;
  content.style.transform = "";
  content.style.width = "100%";
  if (window.innerWidth <= 1180 || contentHeight <= available) return;
  left.classList.add("compact");
}

function refreshUI(payload, options) {
  const afterStep = options && options.afterStep;
  const showStandaloneNotices = options && Object.prototype.hasOwnProperty.call(options, "showStandaloneNotices")
    ? !!options.showStandaloneNotices
    : !afterStep;
  lastPayload = payload;
  sessionFinished = !!payload.finished;
  syncTradesFromPayload(payload);
  syncIndicatorControls();
  if (payload.ready && Array.isArray(payload.bsp_history)) {
    bspHistory = payload.bsp_history.slice();
    bspHistoryKey = new Set(bspHistory.map((p) => p.key || `${p.level}|${p.x}|${p.label}|${p.is_buy ? 1 : 0}`));
  } else {
    bspHistory = [];
    bspHistoryKey = new Set();
  }
  setState(payload);
  updateDataSourceStatus(payload);
  updateTradeStatusOverlay(payload);
  if (showStandaloneNotices && payload && Array.isArray(payload.rhythm_notice_hits) && payload.rhythm_notice_hits.length > 0) {
    showRhythmHitNotices(payload);
  }
  if (showStandaloneNotices && payload && payload.judge_notice) {
    showJudgeNotice(payload);
  }
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
      lastSeenBspKey = new Set(
        [...lastSeenBspKey].filter((k) => {
          const x = Number(String(k).split("|")[0]);
          return Number.isFinite(x) && x <= allXMax;
        })
      );
      draw(payload.chart);
    }
  }
  syncStepButtonState();
  $("btnFinish").disabled = !payload.ready || sessionFinished;
  $("btnBuy").disabled = !payload.ready || sessionFinished || payload.price === null || payload.account.position > 0;
  $("btnSell").disabled = !payload.ready || sessionFinished || !payload.account.can_sell;
  $("configCard").classList.toggle("collapsed", payload.ready);
  updateBspJudgeUI();
  requestAnimationFrame(updateCompactLayout);
}

$("btnInit").onclick = async () => {
  const initBtn = $("btnInit");
  if (initBtn.disabled) return;
  let initSucceeded = false;
  const initBtnHtml = initBtn.innerHTML;
  setGlobalLoading(true, "正在加载会话，首次加载历史数据可能较慢，请稍候...");
  setMsg("正在加载会话...");
  initBtn.disabled = true;
  initBtn.innerHTML = "加载中...";
  try {
    const processedConfig = JSON.parse(JSON.stringify(chanConfig));
    ["mean_metrics", "trend_metrics"].forEach(k => {
      if (typeof processedConfig[k] === "string") {
        processedConfig[k] = processedConfig[k].split(/[,，\s]+/).map(v => parseInt(v.trim())).filter(v => !isNaN(v));
      }
    });
    const payload = await api("/api/init", {
      code: $("code").value,
      begin_date: $("begin").value,
      end_date: $("end").value || null,
      initial_cash: Number($("cash").value),
      autype: $("autype").value,
      chan_config: processedConfig
    });
    initSucceeded = true;
  document.title = `复盘 - ${(payload.name ? payload.name : payload.code)}`;
    setMsg(payload.message || `加载成功：${payload.name ? payload.name : payload.code}`);
    initBtn.disabled = true;
    initBtn.innerHTML = "已加载";
    // $("btnChanSettingsOpen").disabled = true;
    updateShortcutUI();
    $("code").disabled = true;
    $("begin").disabled = true;
    $("end").disabled = true;
    $("cash").disabled = true;
    $("autype").disabled = true;
    userAdjustedView = false;
    viewReady = false;
    viewYShiftRatio = 0;
    viewYZoomRatio = 1.0;
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    sessionFinished = false;
    stepInFlight = false;
    clearBspPrompt();
    refreshUI(payload);
  } catch (e) {
    setMsg("加载失败：" + e.message);
  } finally {
    if (!initSucceeded) {
      initBtn.disabled = false;
      initBtn.innerHTML = initBtnHtml;
      updateShortcutUI();
    }
    hideGlobalLoading();
  }
};

$("btnStep").onclick = async () => {
  if ($("btnStep").disabled || stepInFlight) return;
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    await stepOnce(true);
  } catch (e) {
    setMsg("步进失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

$("btnStepN").onclick = async () => {
  if ($("btnStepN").disabled || stepInFlight) return;
  const n = getStepNValue();
  let done = 0;
  let lastResult = null;
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    for (let i = 0; i < n; i++) {
      const result = await stepOnce(false);
      lastResult = result;
      done += 1;
      if (result.interrupted || result.reachedEnd) break;
    }
    if (!lastResult || !lastResult.noticeShown) {
      setMsg(`步进N（${done}）根完成`);
    }
  } catch (e) {
    setMsg("步进 N 失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

$("btnBackN").onclick = async () => {
  if ($("btnBackN").disabled || stepInFlight) return;
  const n = getStepNValue();
  stepInFlight = true;
  syncStepButtonState();
  hideGlobalLoading();
  try {
    clearBspPrompt();
    const payload = await api("/api/back_n", { n });
    lastSeenBspKey = new Set();
    refreshUI(payload, { afterStep: true, showStandaloneNotices: false });
    setMsg(payload.message || `后退 N 完成：N=${n}`);
  } catch (e) {
    setMsg("后退 N 失败：" + e.message);
  } finally {
    stepInFlight = false;
    syncStepButtonState();
  }
};

$("btnBuy").onclick = async () => {
  try {
    const payload = await api("/api/buy");
    setMsg(payload.message || "买入成功");
    refreshUI(payload);
  } catch (e) {
    setMsg("买入失败：" + e.message);
  }
};

$("btnSell").onclick = async () => {
  try {
    const payload = await api("/api/sell");
    setMsg(payload.message || "卖出成功");
    refreshUI(payload);
    
    // Show settlement for the last completed trade
    if (tradeHistory.length > 0) {
      const lastTrade = tradeHistory[tradeHistory.length - 1];
      showSettlement(lastTrade, payload.name || payload.code);
    }
  } catch (e) {
    setMsg("卖出失败：" + e.message);
  }
};
markUiBound("btnInit");
markUiBound("btnStep");
markUiBound("btnStepN");
markUiBound("btnBackN");
markUiBound("btnBuy");
markUiBound("btnSell");

$("btnFinish").onclick = async () => {
  try {
  if (!confirmAndLog("确定要结束当前训练吗？")) return;
    const payload = await api("/api/finish");
    refreshUI(payload);
    setMsg("训练已结束。");
  if (confirmAndLog("训练结束，是否下载训练结果？")) {
      downloadTradeExport(payload);
    }
  } catch (e) {
    setMsg("结束失败：" + e.message);
  }
};

$("btnReset").onclick = async () => {
  try {
  if (!confirmAndLog("确定要重新训练吗？当前会话状态将被清空。")) return;
    hideGlobalLoading();
    const payload = await api("/api/reset");
    $("btnInit").disabled = false;
    $("btnChanSettingsOpen").disabled = false;
    updateShortcutUI();
    $("code").disabled = false;
    $("begin").disabled = false;
    $("end").disabled = false;
    $("cash").disabled = false;
    $("autype").disabled = false;
    $("configCard").classList.remove("collapsed");
  document.title = "复盘";
    activeTrade = null;
    tradeHistory = [];
    bspHistory = [];
    bspHistoryKey = new Set();
    lastSeenBspKey = new Set();
    lastPayload = null;
    sessionFinished = false;
    stepInFlight = false;
    userAdjustedView = false;
    viewReady = false;
    viewYShiftRatio = 0;
    clearBspPrompt();
    setState(payload);
    updateDataSourceStatus(payload);
    ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
    setMsg("已重置，可重新配置并加载会话。");
    requestAnimationFrame(updateCompactLayout);
  } catch (e) {
    setMsg("重置失败：" + e.message);
  }
};

$("btnExit").onclick = async () => {
  if (!confirmAndLog("确定要退出并终止后台服务吗？")) return;
  maybeSaveUserBiRaysOnExit();
  setMsg("正在尝试终止后台服务并关闭页面...");
  try {
    await fetch("/api/exit", { method: "POST" });
  } catch (e) {
    console.warn("Failed to notify backend exit:", e);
  }
  window.close();
  setTimeout(() => {
    setMsg("服务已关闭。浏览器可能拦截了自动关窗，请手动关闭此页面。");
  }, 400);
};

// BSP Prompt Confirmation - Make it more robust
const bspConfirm = (e) => {
  if (e) {
    e.preventDefault();
    e.stopPropagation();
  }
  clearBspPrompt();
};
if ($("bspPromptConfirm")) {
  $("bspPromptConfirm").addEventListener("mousedown", (e) => {
    if (e.button === 0) bspConfirm(e);
  });
  $("bspPromptConfirm").addEventListener("click", bspConfirm);
}
if ($("bspPrompt")) {
  const panel = $("bspPrompt").querySelector(".panel");
  if (panel) panel.addEventListener("click", (e) => e.stopPropagation());
  $("bspPrompt").addEventListener("mousedown", (e) => {
    if (e.button === 0 && e.target === $("bspPrompt")) bspConfirm(e);
  });
  $("bspPrompt").addEventListener("click", (e) => {
    if (e.target === $("bspPrompt")) bspConfirm(e);
  });
}

let rldPayload = null;
let rldCrosshairTime = null;
let rldActiveTopTab = "trainer";
let settingsHubActiveTab = "shared";
let dataSourcePriorityState = { priority: [], available: [] };
const RLD_LEVEL_OPTIONS = [
  { value: "day", label: "日线" },
  { value: "week", label: "周线" },
  { value: "month", label: "月线" },
  { value: "60m", label: "60分钟" },
  { value: "30m", label: "30分钟" },
  { value: "15m", label: "15分钟" },
  { value: "5m", label: "5分钟" },
  { value: "3m", label: "3分钟" },
  { value: "1m", label: "1分钟" },
];
const RLD_ENTRY_RULE_OPTIONS = [
  { value: "rld_bs_buy", label: "RLD_BS 买入" },
  { value: "one_line", label: "一根筋" },
  { value: "stupid_buy_bi", label: "无脑买入(笔)" },
  { value: "stupid_buy_seg", label: "无脑买入(线段)" },
  { value: "bsp_buy", label: "最近买点" },
  { value: "zs_breakout_up", label: "上离开中枢" },
  { value: "chdl_ge_20", label: "CHDL>=20" },
  { value: "chdl_ge_40", label: "CHDL>=40" },
];
const RLD_EXIT_RULE_OPTIONS = [
  { value: "rld_bs_sell", label: "RLD_BS 卖出" },
  { value: "trend_down", label: "趋势转空" },
  { value: "bsp_sell", label: "最近卖点" },
  { value: "chdl_le_-20", label: "CHDL<=-20" },
  { value: "chdl_le_-40", label: "CHDL<=-40" },
  { value: "take_profit_8", label: "止盈8%" },
  { value: "stop_loss_5", label: "止损5%" },
];
const RLD_DEFAULT_LEVEL_ROWS = [
  { value: "day", weight: 50 },
  { value: "60m", weight: 30 },
  { value: "15m", weight: 20 },
];

function rldNormalizeLevelRows(rawRows) {
  const rows = ensureArray(rawRows, []).map((item, idx) => {
    if (typeof item === "string") {
      return { value: item, weight: idx === 0 ? 50 : (idx === 1 ? 30 : 20) };
    }
    return {
      value: item && item.value ? String(item.value) : (RLD_DEFAULT_LEVEL_ROWS[idx] ? RLD_DEFAULT_LEVEL_ROWS[idx].value : "day"),
      weight: Number(item && item.weight != null ? item.weight : (RLD_DEFAULT_LEVEL_ROWS[idx] ? RLD_DEFAULT_LEVEL_ROWS[idx].weight : 10)),
    };
  }).filter((item) => item && item.value);
  return rows.length > 0 ? rows : RLD_DEFAULT_LEVEL_ROWS.map((item) => ({ ...item }));
}

function rldLevelOptionsHtml(selected) {
  return RLD_LEVEL_OPTIONS.map((item) => `<option value="${item.value}" ${item.value === selected ? "selected" : ""}>${item.label}</option>`).join("");
}

function rldLevelRowHtml(row, idx) {
  return `
    <div class="rldLevelRow" data-level-row="${idx}">
      <div class="rldLevelCell">
        <label>周期 ${idx + 1}</label>
        <select class="rldLevelSelect">${rldLevelOptionsHtml(row.value)}</select>
      </div>
      <div class="rldLevelCell rldLevelWeightCell">
        <label>权重</label>
        <input class="rldLevelWeight" type="number" step="1" min="0" value="${escapeHtmlAttr(String(row.weight ?? 0))}" />
      </div>
      <button class="rldLevelRemove" type="button" data-remove-level="${idx}" ${idx === 0 ? "disabled" : ""}>删除</button>
    </div>
  `;
}

function rldRenderLevelRows(rawRows) {
  const host = $("rldLevelList");
  if (!host) return;
  const rows = rldNormalizeLevelRows(rawRows);
  host.innerHTML = rows.map((row, idx) => rldLevelRowHtml(row, idx)).join("");
  host.querySelectorAll("[data-remove-level]").forEach((btn) => {
    btn.onclick = () => {
      const current = rldReadLevelRows();
      const removeIdx = Number(btn.getAttribute("data-remove-level"));
      const next = current.filter((_, idx) => idx !== removeIdx);
      rldRenderLevelRows(next);
      rldSaveForm();
    };
  });
  host.querySelectorAll(".rldLevelSelect,.rldLevelWeight").forEach((input) => {
    input.onchange = () => rldSaveForm();
  });
}

function rldReadLevelRows() {
  const host = $("rldLevelList");
  if (!host) return rldNormalizeLevelRows(null);
  const rows = [];
  host.querySelectorAll(".rldLevelRow").forEach((row) => {
    const value = row.querySelector(".rldLevelSelect") ? row.querySelector(".rldLevelSelect").value : "day";
    const weightRaw = row.querySelector(".rldLevelWeight") ? row.querySelector(".rldLevelWeight").value : "0";
    rows.push({
      value,
      weight: Number.isFinite(Number(weightRaw)) ? Number(weightRaw) : 0,
    });
  });
  return rldNormalizeLevelRows(rows);
}

function rldGetSavedLevelRows() {
  const saved = ensureObject(rldGetStoredJson("form", {}), {});
  const savedWeights = ensureArray(saved.strategy_config && saved.strategy_config.weights, []);
  if (Array.isArray(saved.level_rows) && saved.level_rows.length > 0) {
    return rldNormalizeLevelRows(saved.level_rows);
  }
  if (Array.isArray(saved.lv_list) && saved.lv_list.length > 0) {
    return rldNormalizeLevelRows(saved.lv_list.map((value, idx) => ({
      value,
      weight: savedWeights[idx] != null ? Number(savedWeights[idx]) : (RLD_DEFAULT_LEVEL_ROWS[idx] ? RLD_DEFAULT_LEVEL_ROWS[idx].weight : 10),
    })));
  }
  return rldNormalizeLevelRows([
    { value: storageGet(rldStorageKey("lv1")) || "day", weight: 50 },
    { value: storageGet(rldStorageKey("lv2")) || "60m", weight: 30 },
    { value: storageGet(rldStorageKey("lv3")) || "15m", weight: 20 },
  ]);
}

function buildSettingsHubMarkup() {
  return `
    <div class="settingsHubPage">
      <div class="settingsHubHero">
        <div class="settingsHubHeroTitle">设置中心</div>
        <div class="settingsHubHeroText">通用设置、复盘参数、融立得参数统一在这里维护。父标签页仅保留必要操作按钮，缩放时优先保证图表与信息展示。</div>
      </div>
      <div class="settingsHubTabs">
        <button id="settingsHubTabShared" class="settingsHubTab active" type="button" data-settings-tab="shared">共享</button>
        <button id="settingsHubTabTrainer" class="settingsHubTab" type="button" data-settings-tab="trainer">复盘</button>
        <button id="settingsHubTabRld" class="settingsHubTab" type="button" data-settings-tab="rld">融立得</button>
      </div>
      <div id="settingsPanelShared" class="settingsHubPanel active">
        <section class="settingsHubCard">
          <div class="settingsHubHead">共享设置</div>
          <div id="settingsSharedMount"></div>
        </section>
        <section class="settingsHubCard">
          <div class="settingsHubHead">说明</div>
          <div class="settingsHubHint">
            复盘与融立得共用缩放、全屏、画线、缠论配置、图表显示设置、系统配置与快捷键逻辑。
          </div>
        </section>
      </div>
      <div id="settingsPanelTrainer" class="settingsHubPanel">
        <section class="settingsHubCard">
          <div class="settingsHubHead">复盘参数</div>
          <div id="settingsTrainerMount"></div>
        </section>
      </div>
      <div id="settingsPanelRld" class="settingsHubPanel">
        <section class="settingsHubCard">
          <div class="settingsHubHead">融立得参数</div>
          <div id="settingsRldMount"></div>
        </section>
      </div>
    </div>
  `;
}

function buildRldSettingsMarkup() {
  const saved = ensureObject(rldGetStoredJson("form", {}), {});
  const entryRules = ensureArray(saved.entry_rules, ["rld_bs_buy", "one_line"]);
  const exitRules = ensureArray(saved.exit_rules, ["rld_bs_sell", "trend_down"]);
  const levelRows = rldGetSavedLevelRows();
  return `
    <div class="settingsHubStack">
      <section class="settingsHubInner">
        <div class="settingsHubSectionTitle">工作台参数</div>
        <div class="rldFormGrid">
          <div class="rldField"><label>代码</label><input id="rldCode" value="${escapeHtmlAttr(saved.code || "600340")}" /></div>
          <div class="rldField"><label>复权</label><select id="rldAutype"><option value="qfq">前复权</option><option value="hfq">后复权</option><option value="none">不复权</option></select></div>
          <div class="rldField"><label>开始日期</label><input id="rldBegin" type="date" value="${escapeHtmlAttr(saved.begin_date || "2018-01-01")}" /></div>
          <div class="rldField"><label>结束日期</label><input id="rldEnd" type="date" value="${escapeHtmlAttr(saved.end_date || "")}" /></div>
          <div class="rldField"><label>逻辑</label><select id="rldRuleLogic"><option value="and">AND</option><option value="or">OR</option></select></div>
          <div class="rldField"><label>手续费</label><input id="rldFee" type="number" step="0.0001" value="${escapeHtmlAttr(saved.fee || "0.001")}" /></div>
          <div class="rldField"><label>滑点</label><input id="rldSlippage" type="number" step="0.0001" value="${escapeHtmlAttr(saved.slippage || "0.0005")}" /></div>
          <div class="rldField full"><label>股票池 / 板块</label><textarea id="rldWatchlist" rows="3" placeholder="输入 600340,000001,600519 或板块名">${escapeHtmlAttr(saved.watchlist_or_sector || "600340,000001,600519")}</textarea></div>
          <div class="rldField full">
            <div class="settingsInlineHead">
              <label>多周期列表</label>
              <button id="rldAddLevel" class="miniAction" type="button">＋ 添加周期</button>
            </div>
            <div id="rldLevelList" class="rldLevelList">${levelRows.map((row, idx) => rldLevelRowHtml(row, idx)).join("")}</div>
          </div>
        </div>
      </section>
      <section class="settingsHubInner">
        <div class="settingsHubSectionTitle">回测规则</div>
        <div class="rldField full">
          <label>入场规则</label>
          <div class="rldRuleList">${rldRuleHtml("rldEntryRule", RLD_ENTRY_RULE_OPTIONS, entryRules)}</div>
        </div>
        <div class="rldField full" style="margin-top:10px;">
          <label>出场规则</label>
          <div class="rldRuleList">${rldRuleHtml("rldExitRule", RLD_EXIT_RULE_OPTIONS, exitRules)}</div>
        </div>
      </section>
    </div>
  `;
}

function rldSetSettingsHubTab(tab) {
  settingsHubActiveTab = tab === "trainer" || tab === "rld" ? tab : "shared";
  storageSet("chan_settings_hub_tab", settingsHubActiveTab);
  const allTabs = {
    shared: $("settingsHubTabShared"),
    trainer: $("settingsHubTabTrainer"),
    rld: $("settingsHubTabRld"),
  };
  const allPanels = {
    shared: $("settingsPanelShared"),
    trainer: $("settingsPanelTrainer"),
    rld: $("settingsPanelRld"),
  };
  Object.entries(allTabs).forEach(([key, el]) => {
    if (el) el.classList.toggle("active", key === settingsHubActiveTab);
  });
  Object.entries(allPanels).forEach(([key, el]) => {
    if (el) el.classList.toggle("active", key === settingsHubActiveTab);
  });
}

function rldMountSettingsHub() {
  const sharedMount = $("settingsSharedMount");
  const trainerMount = $("settingsTrainerMount");
  const rldMount = $("settingsRldMount");
  const configCard = $("configCard");
  if (sharedMount && sharedMount.dataset.mounted !== "1") {
    sharedMount.dataset.mounted = "1";
    const box = document.createElement("div");
    box.className = "settingsHubStack";
    const sharedBlock = document.createElement("section");
    sharedBlock.className = "settingsHubInner";
    sharedBlock.innerHTML = `
      <div class="settingsHubSectionTitle">统一入口</div>
      <div class="settingsHubHint">缠论配置、图表显示设置、系统配置都从这里进入。快捷键逻辑仍沿用原实现。</div>
    `;
    const sharedActions = configCard ? configCard.querySelector(".btnRow") : null;
    if (sharedActions) sharedBlock.appendChild(sharedActions);
    box.appendChild(sharedBlock);
    const sourceBlock = document.createElement("section");
    sourceBlock.className = "settingsHubInner";
    sourceBlock.innerHTML = `
      <div class="settingsHubSectionTitle">数据源优先级</div>
      <div class="settingsHubHint">拖拽排序后会同时作用于复盘与融立得。默认优先级为 BaoStock，其次 AKShare、Tushare、OfflineTXT。</div>
      <div id="dataSourcePriorityList" class="sourcePriorityList"></div>
      <div id="dataSourcePriorityNote" class="settingsHubHint" style="margin-top:8px;"></div>
    `;
    box.appendChild(sourceBlock);
    sharedMount.appendChild(box);
  }
  if (trainerMount && trainerMount.dataset.mounted !== "1") {
    trainerMount.dataset.mounted = "1";
    const box = document.createElement("div");
    box.className = "settingsHubStack";
    const trainerBlock = document.createElement("section");
    trainerBlock.className = "settingsHubInner";
    trainerBlock.innerHTML = `<div class="settingsHubSectionTitle">会话参数</div>`;
    if (configCard) {
      Array.from(configCard.querySelectorAll(".cfg-editable")).forEach((row) => trainerBlock.appendChild(row));
    }
    box.appendChild(trainerBlock);
    trainerMount.appendChild(box);
  }
  if (rldMount && rldMount.dataset.mounted !== "1") {
    rldMount.dataset.mounted = "1";
    rldMount.innerHTML = buildRldSettingsMarkup();
  }
  document.querySelectorAll("[data-settings-tab]").forEach((btn) => {
    if (btn.dataset.bound === "1") return;
    btn.dataset.bound = "1";
    btn.onclick = () => rldSetSettingsHubTab(btn.getAttribute("data-settings-tab"));
  });
  loadDataSourceSettings();
  rldSetSettingsHubTab(storageGet("chan_settings_hub_tab") || settingsHubActiveTab);
}

function normalizeSourcePriority(rawPriority, available) {
  const base = ensureArray(available, []);
  const preferred = ensureArray(rawPriority, []).map((item) => String(item || "").trim()).filter(Boolean);
  return Array.from(new Set(preferred.concat(base))).filter((item) => base.includes(item));
}

async function saveDataSourceSettings(priority) {
  const note = $("dataSourcePriorityNote");
  const available = ensureArray(dataSourcePriorityState.available, []);
  const normalized = normalizeSourcePriority(priority, available);
  storageSet("chan_data_source_priority", JSON.stringify(normalized));
  if (note) note.textContent = "正在保存数据源优先级...";
  const payload = await api("/api/source-settings", { priority: normalized }, "POST");
  dataSourcePriorityState = {
    priority: normalizeSourcePriority(payload.priority, payload.available),
    available: ensureArray(payload.available, []),
  };
  renderDataSourcePriorityList(dataSourcePriorityState.priority, dataSourcePriorityState.available);
  if (note) note.textContent = `当前顺序：${dataSourcePriorityState.priority.join(" > ")}`;
}

function renderDataSourcePriorityList(priority, available) {
  const host = $("dataSourcePriorityList");
  if (!host) return;
  const normalized = normalizeSourcePriority(priority, available);
  dataSourcePriorityState = { priority: normalized.slice(), available: ensureArray(available, []).slice() };
  host.innerHTML = normalized.map((label, idx) => `
    <div class="sourcePriorityItem" draggable="true" data-source-item="${label}">
      <span class="sourcePriorityGrip">⋮⋮</span>
      <span class="sourcePriorityName">${label}</span>
      <span class="sourcePriorityRank">${idx + 1}</span>
    </div>
  `).join("");
  const note = $("dataSourcePriorityNote");
  if (note) note.textContent = `当前顺序：${normalized.join(" > ")}`;
  let dragLabel = null;
  host.querySelectorAll(".sourcePriorityItem").forEach((item) => {
    item.addEventListener("dragstart", () => {
      dragLabel = item.getAttribute("data-source-item");
      item.classList.add("dragging");
    });
    item.addEventListener("dragend", () => {
      dragLabel = null;
      host.querySelectorAll(".sourcePriorityItem").forEach((node) => node.classList.remove("dragging", "dragover"));
    });
    item.addEventListener("dragover", (e) => {
      e.preventDefault();
      item.classList.add("dragover");
    });
    item.addEventListener("dragleave", () => item.classList.remove("dragover"));
    item.addEventListener("drop", async (e) => {
      e.preventDefault();
      item.classList.remove("dragover");
      const targetLabel = item.getAttribute("data-source-item");
      if (!dragLabel || !targetLabel || dragLabel === targetLabel) return;
      const current = dataSourcePriorityState.priority.slice();
      const fromIdx = current.indexOf(dragLabel);
      const toIdx = current.indexOf(targetLabel);
      if (fromIdx < 0 || toIdx < 0) return;
      current.splice(fromIdx, 1);
      current.splice(toIdx, 0, dragLabel);
      renderDataSourcePriorityList(current, dataSourcePriorityState.available);
      try {
        await saveDataSourceSettings(current);
      } catch (e2) {
        showToast(`数据源优先级保存失败：${e2.message}`, { record: false });
        if (note) note.textContent = `保存失败：${e2.message}`;
      }
    });
  });
}

async function loadDataSourceSettings() {
  const host = $("dataSourcePriorityList");
  if (!host || host.dataset.loading === "1") return;
  host.dataset.loading = "1";
  try {
    const payload = await api("/api/source-settings", null, "GET");
    const available = ensureArray(payload.available, []);
    const localPriority = safeJsonParse(storageGet("chan_data_source_priority"), null);
    const priority = normalizeSourcePriority(localPriority || payload.priority, available);
    renderDataSourcePriorityList(priority, available);
    if (JSON.stringify(priority) !== JSON.stringify(ensureArray(payload.priority, []))) {
      await saveDataSourceSettings(priority);
    }
  } catch (e) {
    const note = $("dataSourcePriorityNote");
    if (note) note.textContent = `数据源优先级读取失败：${e.message}`;
  } finally {
    host.dataset.loading = "0";
  }
}

function rldStorageKey(key) {
  return `rld_${key}`;
}

function rldGetStoredJson(key, fallback) {
  return safeJsonParse(storageGet(rldStorageKey(key)), fallback);
}

function rldSetStoredJson(key, value) {
  storageSet(rldStorageKey(key), JSON.stringify(value));
}

function rldInjectStyles() {
  if ($("rldWorkbenchStyles")) return;
  const style = document.createElement("style");
  style.id = "rldWorkbenchStyles";
  style.textContent = `
    .topTabBar {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
      background: linear-gradient(180deg, rgba(255,255,255,0.96), rgba(241,245,249,0.96));
      position: relative;
      z-index: 40;
    }
    .topTabBar .tabButton {
      border-radius: 999px;
      padding: 8px 16px;
      font-weight: 700;
      background: rgba(255,255,255,0.75);
      border: 1px solid var(--border);
      width: auto;
      text-align: center;
    }
    .topTabBar .tabButton.active {
      background: #0f172a;
      color: #fff;
      border-color: #0f172a;
      box-shadow: 0 8px 24px rgba(15, 23, 42, 0.2);
    }
    #topPageShell {
      height: calc(100vh - 58px);
      overflow: hidden;
    }
    .topPage {
      display: none;
      height: 100%;
    }
    .topPage.active {
      display: block;
    }
    .topPage .wrap {
      height: 100%;
    }
    #pageRld, #pageSettings {
      height: 100%;
      overflow: auto;
    }
    .settingsHubPage {
      min-height: 100%;
      box-sizing: border-box;
      padding: 16px;
      background:
        radial-gradient(circle at top right, rgba(14,165,233,0.08), transparent 28%),
        radial-gradient(circle at bottom left, rgba(249,115,22,0.1), transparent 30%),
        linear-gradient(180deg, #f8fafc, #eef2f7);
    }
    .settingsHubHero {
      border: 1px solid rgba(148,163,184,0.35);
      background: rgba(255,255,255,0.9);
      border-radius: 18px;
      padding: 16px 18px;
      box-shadow: 0 10px 30px rgba(15,23,42,0.08);
      margin-bottom: 14px;
    }
    .settingsHubHeroTitle {
      font-size: 20px;
      font-weight: 800;
      color: #0f172a;
      margin-bottom: 6px;
    }
    .settingsHubHeroText {
      color: #475569;
      font-size: 13px;
      line-height: 1.7;
      max-width: 920px;
    }
    .settingsHubTabs {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 14px;
    }
    .settingsHubTab {
      width: auto;
      border-radius: 999px;
      padding: 8px 16px;
      font-weight: 700;
      background: rgba(255,255,255,0.82);
      border: 1px solid rgba(148,163,184,0.45);
    }
    .settingsHubTab.active {
      background: #0f172a;
      color: #fff;
      border-color: #0f172a;
      box-shadow: 0 8px 24px rgba(15, 23, 42, 0.2);
    }
    .settingsHubPanel {
      display: none;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 14px;
      align-items: start;
    }
    .settingsHubPanel.active {
      display: grid;
    }
    .settingsHubCard,
    .settingsHubInner {
      border: 1px solid rgba(148,163,184,0.5);
      background: rgba(255,255,255,0.92);
      border-radius: 16px;
      box-shadow: 0 10px 30px rgba(15,23,42,0.08);
      padding: 14px;
      min-height: 0;
      backdrop-filter: blur(6px);
    }
    .settingsHubStack {
      display: flex;
      flex-direction: column;
      gap: 14px;
    }
    .settingsHubHead,
    .settingsHubSectionTitle {
      font-size: 15px;
      font-weight: 800;
      color: #0f172a;
      margin-bottom: 10px;
    }
    .settingsHubHint {
      color: #475569;
      font-size: 13px;
      line-height: 1.7;
    }
    .settingsInlineHead {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      margin-bottom: 8px;
    }
    .settingsInlineHead label {
      margin: 0;
    }
    .miniAction {
      width: auto;
      padding: 6px 10px;
      border-radius: 10px;
      font-size: 12px;
      font-weight: 700;
    }
    .sourcePriorityList {
      display: flex;
      flex-direction: column;
      gap: 8px;
      margin-top: 10px;
    }
    .sourcePriorityItem {
      display: grid;
      grid-template-columns: 28px minmax(0, 1fr) 32px;
      align-items: center;
      gap: 10px;
      padding: 10px 12px;
      border-radius: 12px;
      border: 1px solid rgba(226,232,240,0.9);
      background: rgba(248,250,252,0.92);
      cursor: grab;
      user-select: none;
    }
    .sourcePriorityItem.dragover {
      border-color: #2563eb;
      box-shadow: 0 0 0 2px rgba(37,99,235,0.12);
    }
    .sourcePriorityItem.dragging {
      opacity: 0.55;
    }
    .sourcePriorityGrip {
      color: #94a3b8;
      font-weight: 700;
      letter-spacing: 0.08em;
    }
    .sourcePriorityName {
      color: #0f172a;
      font-weight: 700;
    }
    .sourcePriorityRank {
      color: #475569;
      font-size: 12px;
      text-align: right;
    }
    .rldLevelList {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .rldLevelRow {
      display: grid;
      grid-template-columns: minmax(0, 1.6fr) 120px auto;
      gap: 8px;
      align-items: end;
      padding: 10px;
      border-radius: 12px;
      border: 1px solid rgba(226,232,240,0.9);
      background: rgba(248,250,252,0.9);
    }
    .rldLevelCell {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .rldLevelWeightCell {
      min-width: 0;
    }
    .rldLevelRemove {
      width: auto;
      padding: 8px 12px;
      border-radius: 10px;
    }
    .rldWorkbench {
      display: flex;
      flex-direction: column;
      gap: 14px;
      min-height: 100%;
      padding: 14px;
      box-sizing: border-box;
      background:
        radial-gradient(circle at top right, rgba(14,165,233,0.12), transparent 28%),
        radial-gradient(circle at bottom left, rgba(249,115,22,0.12), transparent 32%),
        linear-gradient(180deg, #f8fafc, #eef2f7);
    }
    .rldSidebar, .rldMain {
      min-height: 0;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .rldCard, .rldPanel {
      border: 1px solid rgba(148,163,184,0.5);
      background: rgba(255,255,255,0.92);
      border-radius: 16px;
      box-shadow: 0 10px 30px rgba(15,23,42,0.08);
      padding: 14px;
      min-height: 0;
      backdrop-filter: blur(6px);
    }
    .rldCardTitle {
      font-size: 15px;
      font-weight: 800;
      margin-bottom: 12px;
      color: #0f172a;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .rldStatus {
      color: #334155;
      font-size: 12px;
      white-space: pre-wrap;
      line-height: 1.6;
      max-height: 140px;
      overflow: auto;
    }
    .rldFormGrid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }
    .rldField {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .rldField.full {
      grid-column: 1 / -1;
    }
    .rldField label {
      width: auto;
      font-size: 12px;
      color: #475569;
      font-weight: 700;
    }
    .rldField input, .rldField select, .rldField textarea {
      width: 100%;
      box-sizing: border-box;
      border-radius: 10px;
      border: 1px solid rgba(148,163,184,0.6);
      background: rgba(255,255,255,0.92);
      padding: 8px 10px;
      resize: vertical;
    }
    .rldActions {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
      margin-top: 10px;
    }
    .rldActions button {
      width: 100%;
      text-align: center;
      border-radius: 12px;
      padding: 9px 10px;
      font-weight: 700;
    }
    .rldMainActions {
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    }
    .rldRuleList {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 6px;
      font-size: 12px;
    }
    .rldRuleItem {
      display: flex;
      align-items: center;
      gap: 6px;
      border: 1px solid rgba(226,232,240,0.8);
      border-radius: 10px;
      padding: 6px 8px;
      background: rgba(248,250,252,0.85);
    }
    .rldRuleItem input {
      width: auto;
      flex: none;
    }
    .rldHeaderBar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 4px;
    }
    .rldHeaderText {
      font-weight: 800;
      color: #0f172a;
      font-size: 18px;
    }
    .rldHeaderSub {
      color: #64748b;
      font-size: 12px;
    }
    .rldSummaryGrid {
      display: grid;
      grid-template-columns: repeat(6, minmax(0, 1fr));
      gap: 10px;
    }
    .rldSummaryCard {
      border-radius: 14px;
      padding: 12px;
      background: linear-gradient(180deg, rgba(255,255,255,0.98), rgba(241,245,249,0.95));
      border: 1px solid rgba(148,163,184,0.45);
      min-height: 88px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 6px;
    }
    .rldSummaryCard .k {
      font-size: 11px;
      color: #64748b;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .rldSummaryCard .v {
      font-size: 22px;
      font-weight: 800;
      color: #0f172a;
    }
    .rldSummaryCard .d {
      font-size: 12px;
      color: #475569;
    }
    .rldChartStack {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
      grid-auto-rows: minmax(320px, 1fr);
      gap: 10px;
      min-height: 0;
      align-items: stretch;
    }
    .rldChartCard {
      border: 1px solid rgba(148,163,184,0.55);
      background: rgba(255,255,255,0.95);
      border-radius: 16px;
      padding: 10px;
      min-height: 0;
      display: flex;
      flex-direction: column;
      gap: 8px;
      resize: vertical;
      overflow: auto;
      min-height: 320px;
    }
    .rldChartHead {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 12px;
      color: #475569;
      font-weight: 700;
    }
    .rldChartCanvas {
      width: 100%;
      height: 100%;
      min-height: 260px;
      flex: 1;
      display: block;
      border-radius: 12px;
      background:
        linear-gradient(180deg, rgba(255,255,255,0.95), rgba(248,250,252,0.95)),
        linear-gradient(90deg, rgba(148,163,184,0.08), transparent);
      border: 1px solid rgba(226,232,240,0.85);
    }
    .rldChartEmpty {
      border: 1px dashed rgba(148,163,184,0.7);
      border-radius: 16px;
      background: rgba(255,255,255,0.85);
      min-height: 280px;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #64748b;
      font-weight: 700;
      text-align: center;
      padding: 24px;
    }
    .rldBottomGrid {
      display: grid;
      grid-template-columns: 1.15fr 1fr;
      gap: 12px;
      min-height: 280px;
    }
    .rldScroll {
      min-height: 0;
      overflow: auto;
    }
    .rldPerspectiveTime {
      font-size: 16px;
      font-weight: 800;
      color: #0f172a;
      margin-bottom: 10px;
    }
    .rldPerspectiveGrid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 10px;
    }
    .rldPerspectiveCard {
      border-radius: 12px;
      border: 1px solid rgba(148,163,184,0.35);
      background: rgba(248,250,252,0.92);
      padding: 10px;
      font-size: 12px;
      color: #334155;
      line-height: 1.6;
    }
    .rldTable {
      width: 100%;
      border-collapse: collapse;
      font-size: 12px;
    }
    .rldTable th, .rldTable td {
      border-bottom: 1px solid rgba(226,232,240,0.9);
      padding: 8px 6px;
      text-align: left;
      white-space: nowrap;
    }
    .rldTable th {
      position: sticky;
      top: 0;
      background: rgba(248,250,252,0.98);
      z-index: 1;
    }
    .rldBadge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      border-radius: 999px;
      padding: 2px 10px;
      font-size: 11px;
      font-weight: 700;
      background: rgba(226,232,240,0.75);
      color: #0f172a;
    }
    .rldBadge.buy {
      background: rgba(220,38,38,0.12);
      color: #b91c1c;
    }
    .rldBadge.sell {
      background: rgba(22,163,74,0.12);
      color: #15803d;
    }
    .rldMetaRow {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 8px;
      font-size: 12px;
      color: #475569;
    }
    @media (max-width: 1380px) {
      .rldSummaryGrid {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }
      .rldBottomGrid {
        grid-template-columns: 1fr;
      }
    }
    @media (max-width: 1024px) {
      .settingsHubPanel {
        grid-template-columns: 1fr;
      }
      .rldChartStack {
        grid-template-columns: 1fr;
      }
      .rldSummaryGrid, .rldPerspectiveGrid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
      .rldLevelRow {
        grid-template-columns: 1fr;
      }
    }
    @media (max-width: 720px) {
      .rldSummaryGrid, .rldPerspectiveGrid {
        grid-template-columns: 1fr;
      }
      .settingsHubPage,
      .rldWorkbench {
        padding: 12px;
      }
    }
  `;
  document.head.appendChild(style);
}

function rldRuleHtml(name, options, checked) {
  return options.map((item) => {
    const isChecked = checked.includes(item.value) ? "checked" : "";
    return `<label class="rldRuleItem"><input type="checkbox" name="${name}" value="${item.value}" ${isChecked} /> <span>${item.label}</span></label>`;
  }).join("");
}

function rldWorkbenchMarkup() {
  return `
    <div class="rldWorkbench">
      <div class="rldPanel">
        <div class="rldHeaderBar">
          <div>
            <div class="rldHeaderText">融立得多周期工作台</div>
            <div id="rldHeaderSub" class="rldHeaderSub">尚未加载数据</div>
          </div>
          <div id="rldHeaderBadge" class="rldBadge">空闲</div>
        </div>
        <div class="rldMetaRow">
          <span>核心参数已迁移到“设置”页。</span>
          <span>多周期 K 线区域支持纵向拉伸与自适应换列。</span>
        </div>
        <div class="rldActions rldMainActions">
          <button id="rldBtnInit">加载工作台</button>
          <button id="rldBtnReconfig">应用配置</button>
          <button id="rldBtnMatrix">刷新矩阵</button>
          <button id="rldBtnBacktest">运行回测</button>
          <button id="rldBtnReset">重置</button>
          <button id="rldBtnGoSettings">打开设置</button>
        </div>
      </div>
      <div class="rldPanel">
        <div class="rldCardTitle">状态 / 数据源</div>
        <div id="rldStatus" class="rldStatus">等待加载...</div>
      </div>
      <div class="rldPanel">
        <div class="rldCardTitle">综合摘要</div>
        <div id="rldSummaryGrid" class="rldSummaryGrid"></div>
      </div>
      <div id="rldChartStack" class="rldChartStack">
        <div class="rldChartEmpty">请先到“设置”页配置周期并加载数据。</div>
      </div>
      <div class="rldBottomGrid">
        <div class="rldPanel rldScroll">
          <div class="rldCardTitle">时间线 / 透视信息</div>
          <div id="rldPerspective"></div>
        </div>
        <div class="rldPanel rldScroll">
          <div class="rldCardTitle">个股矩阵 / 板块轮动</div>
          <div id="rldMatrixContainer"></div>
        </div>
      </div>
      <div class="rldPanel rldScroll">
        <div class="rldCardTitle">回归评测系统</div>
        <div id="rldBacktestContainer"></div>
      </div>
    </div>
  `;
}

function rldEnsureShell() {
  rldInjectStyles();
  if ($("topPageShell")) return;
  const wrap = document.querySelector(".wrap");
  if (!wrap) return;
  const tabBar = document.createElement("div");
  tabBar.id = "topTabBar";
  tabBar.className = "topTabBar";
  tabBar.innerHTML = `
    <button id="topTabTrainer" class="tabButton active" type="button">复盘</button>
    <button id="topTabRld" class="tabButton" type="button">融立得</button>
    <button id="topTabSettings" class="tabButton" type="button">设置</button>
  `;
  const shell = document.createElement("div");
  shell.id = "topPageShell";
  const trainerPage = document.createElement("div");
  trainerPage.id = "pageTrainer";
  trainerPage.className = "topPage active";
  const rldPage = document.createElement("div");
  rldPage.id = "pageRld";
  rldPage.className = "topPage";
  rldPage.innerHTML = rldWorkbenchMarkup();
  const settingsPage = document.createElement("div");
  settingsPage.id = "pageSettings";
  settingsPage.className = "topPage";
  settingsPage.innerHTML = buildSettingsHubMarkup();
  wrap.parentNode.insertBefore(tabBar, wrap);
  wrap.parentNode.insertBefore(shell, wrap);
  trainerPage.appendChild(wrap);
  shell.appendChild(trainerPage);
  shell.appendChild(rldPage);
  shell.appendChild(settingsPage);
}

function rldPopulateLevelSelect(id, value) {
  const el = $(id);
  if (!el) return;
  el.innerHTML = RLD_LEVEL_OPTIONS.map((item) => `<option value="${item.value}">${item.label}</option>`).join("");
  el.value = value;
}

function rldSaveForm() {
  const form = rldCollectForm();
  rldSetStoredJson("form", {
    ...form,
    level_rows: form.lv_list.map((value, idx) => ({
      value,
      weight: form.strategy_config && Array.isArray(form.strategy_config.weights) ? form.strategy_config.weights[idx] : 0,
    })),
    fee: $("rldFee") ? $("rldFee").value : "0.001",
    slippage: $("rldSlippage") ? $("rldSlippage").value : "0.0005",
    rule_logic: $("rldRuleLogic") ? $("rldRuleLogic").value : "and",
    entry_rules: rldGetSelectedRules("rldEntryRule"),
    exit_rules: rldGetSelectedRules("rldExitRule"),
  });
}

function rldSetStatus(text, tone = "idle") {
  const el = $("rldStatus");
  if (el) el.textContent = text || "等待加载...";
  const badge = $("rldHeaderBadge");
  if (badge) {
    badge.textContent = tone === "error" ? "错误" : tone === "busy" ? "处理中" : tone === "ready" ? "已就绪" : "空闲";
    badge.className = `rldBadge ${tone === "error" ? "sell" : tone === "ready" ? "buy" : ""}`;
  }
}

function rldCollectForm() {
  const levelRows = rldReadLevelRows();
  const lvList = levelRows.map((item) => item.value);
  return {
    code: $("rldCode") ? $("rldCode").value : "600340",
    begin_date: $("rldBegin") ? $("rldBegin").value : "2018-01-01",
    end_date: $("rldEnd") && $("rldEnd").value ? $("rldEnd").value : null,
    autype: $("rldAutype") ? $("rldAutype").value : "qfq",
    lv_list: lvList,
    watchlist_or_sector: $("rldWatchlist") ? $("rldWatchlist").value : "",
    strategy_config: {
      weights: levelRows.map((item) => Number(item.weight) || 0),
    },
    chan_config: {
      chan_algo: chanConfig.chan_algo,
      bi_strict: chanConfig.bi_strict,
      bi_algo: chanConfig.bi_algo,
      bi_fx_check: chanConfig.bi_fx_check,
      gap_as_kl: chanConfig.gap_as_kl,
      bi_end_is_peak: chanConfig.bi_end_is_peak,
      bi_allow_sub_peak: chanConfig.bi_allow_sub_peak,
      seg_algo: chanConfig.seg_algo,
      left_seg_method: chanConfig.left_seg_method,
      zs_algo: chanConfig.zs_algo,
      zs_combine: chanConfig.zs_combine,
      zs_combine_mode: chanConfig.zs_combine_mode,
      one_bi_zs: chanConfig.one_bi_zs,
      divergence_rate: chanConfig.divergence_rate,
      min_zs_cnt: chanConfig.min_zs_cnt,
      bsp1_only_multibi_zs: chanConfig.bsp1_only_multibi_zs,
      max_bs2_rate: chanConfig.max_bs2_rate,
      macd_algo: chanConfig.macd_algo,
      bs1_peak: chanConfig.bs1_peak,
      bs_type: chanConfig.bs_type,
      bsp2_follow_1: chanConfig.bsp2_follow_1,
      bsp3_follow_1: chanConfig.bsp3_follow_1,
      bsp3_peak: chanConfig.bsp3_peak,
      bsp2s_follow_2: chanConfig.bsp2s_follow_2,
      max_bsp2s_lv: chanConfig.max_bsp2s_lv,
      strict_bsp3: chanConfig.strict_bsp3,
      bsp3a_max_zs_cnt: chanConfig.bsp3a_max_zs_cnt,
      macd: chanConfig.macd,
    },
  };
}

function rldGetSelectedRules(name) {
  return Array.from(document.querySelectorAll(`input[name="${name}"]:checked`)).map((node) => node.value);
}

async function rldCall(path, body, method = "POST", loadingText = "融立得工作台处理中...") {
  setGlobalLoading(true, loadingText);
  try {
    return await api(path, body, method);
  } finally {
    hideGlobalLoading();
  }
}

function rldNumber(value, digits = 2) {
  if (value === null || value === undefined || value === "" || Number.isNaN(Number(value))) return "-";
  return Number(value).toFixed(digits);
}

function rldPct(value, digits = 2) {
  if (value === null || value === undefined || value === "" || Number.isNaN(Number(value))) return "-";
  return `${(Number(value) * 100).toFixed(digits)}%`;
}

function rldSideBadge(side) {
  const cls = side === "buy" ? "buy" : side === "sell" ? "sell" : "";
  const text = side === "buy" ? "偏多" : side === "sell" ? "偏空" : "中性";
  return `<span class="rldBadge ${cls}">${text}</span>`;
}

function rldRenderSummary(payload) {
  const grid = $("rldSummaryGrid");
  if (!grid) return;
  if (!payload || !payload.ready || !payload.analysis) {
    grid.innerHTML = `<div class="rldSummaryCard"><div class="k">状态</div><div class="v">未加载</div><div class="d">请先加载融立得工作台。</div></div>`;
    return;
  }
  const agg = payload.analysis.aggregate || {};
  const rows = [
    { k: "CHDL", v: rldNumber(agg.weighted_chdl), d: "结构方向 + 中枢位置 + BSP + MACD 面积的综合分" },
    { k: "多周期 MACD", v: rldNumber(agg.three_macd), d: "多周期 MACD 动量加权结果" },
    { k: "一根筋", v: agg.one_line ? "是" : "否", d: "多周期同向且最近无明显逆向破坏" },
    { k: "无脑买入(笔)", v: agg.stupid_buy_bi ? "触发" : "未触发", d: "激进笔级模板" },
    { k: "无脑买入(线段)", v: agg.stupid_buy_seg ? "触发" : "未触发", d: "激进线段模板" },
    { k: "RLD_BS", v: `${agg.rld_bs ? rldNumber(agg.rld_bs.score) : "-"} ${agg.rld_bs ? (agg.rld_bs.side || "neutral") : ""}`, d: agg.rld_bs && agg.rld_bs.reasons ? compactReasText(agg.rld_bs.reasons) : "解释型交易建议" },
  ];
  grid.innerHTML = rows.map((item) => `<div class="rldSummaryCard"><div class="k">${item.k}</div><div class="v">${item.v}</div><div class="d">${item.d}</div></div>`).join("");
}

function compactReasText(reasons) {
  return ensureArray(reasons, []).slice(0, 3).join("；") || "-";
}

function rldRenderHeader(payload) {
  const headerSub = $("rldHeaderSub");
  if (!headerSub) return;
  if (!payload || !payload.ready) {
    headerSub.textContent = "尚未加载数据";
    return;
  }
  const lvLabels = ensureArray(payload.lv_labels, []).join(" / ");
  headerSub.textContent = `${payload.name || payload.code} | ${lvLabels}`;
}

function rldRenderStatus(payload, fallbackText) {
  if (fallbackText) {
    rldSetStatus(fallbackText, payload && payload.ready ? "ready" : "idle");
    return;
  }
  if (!payload || !payload.ready) {
    rldSetStatus("请先加载融立得工作台。");
    return;
  }
  const logs = payload.data_source && payload.data_source.logs ? payload.data_source.logs : [];
  const lines = [
    `标的：${payload.name || payload.code}`,
    `周期：${ensureArray(payload.lv_labels, []).join(" / ")}`,
    ...logs,
  ];
  rldSetStatus(lines.join("\\n"), "ready");
}

function rldFindNearestK(chart, timeText) {
  const ks = chart && chart.kline ? chart.kline : [];
  if (ks.length <= 0) return null;
  if (!timeText) return ks[ks.length - 1];
  const target = rldToTs(timeText);
  let best = ks[0];
  let bestGap = Math.abs(rldToTs(best.t) - target);
  for (const item of ks) {
    const gap = Math.abs(rldToTs(item.t) - target);
    if (gap < bestGap) {
      best = item;
      bestGap = gap;
    }
  }
  return best;
}

function rldToTs(text) {
  const raw = String(text || "").trim().replace(/\//g, "-");
  const dt = new Date(raw);
  const t = dt.getTime();
  return Number.isFinite(t) ? t : 0;
}

function rldChartColor(kind) {
  const palette = {
    candleUp: "#dc2626",
    candleDown: "#16a34a",
    bi: "#f59e0b",
    seg: "#059669",
    segseg: "#2563eb",
    zs: "rgba(14,165,233,0.12)",
    macdPos: "rgba(220,38,38,0.45)",
    macdNeg: "rgba(22,163,74,0.45)",
    cross: "#0f172a",
  };
  return palette[kind] || "#334155";
}

function rldPrepareCanvas(canvas) {
  if (!canvas) return null;
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const width = Math.max(320, Math.floor(rect.width));
  const height = Math.max(180, Math.floor(rect.height || 210));
  if (canvas.width !== Math.floor(width * dpr) || canvas.height !== Math.floor(height * dpr)) {
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
  }
  const ctx2 = canvas.getContext("2d");
  ctx2.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx: ctx2, width, height };
}

function rldDrawChart(canvas, levelItem) {
  const prepared = rldPrepareCanvas(canvas);
  if (!prepared) return;
  const { ctx: ctx2, width, height } = prepared;
  ctx2.clearRect(0, 0, width, height);
  ctx2.fillStyle = "#ffffff";
  ctx2.fillRect(0, 0, width, height);
  if (!levelItem || !levelItem.chart || !Array.isArray(levelItem.chart.kline) || levelItem.chart.kline.length <= 0) {
    ctx2.fillStyle = "#64748b";
    ctx2.font = "12px Arial";
    ctx2.fillText("暂无数据", 20, 24);
    return;
  }
  const chart = levelItem.chart;
  const ks = chart.kline;
  const padL = 56;
  const padR = 14;
  const padT = 16;
  const padB = 26;
  const macdH = Math.max(38, Math.floor(height * 0.2));
  const priceH = height - macdH - padT - padB - 8;
  const maxPrice = Math.max(...ks.map((k) => Number(k.h)), ...chart.seg_zs.map((z) => Number(z.high)));
  const minPrice = Math.min(...ks.map((k) => Number(k.l)), ...chart.seg_zs.map((z) => Number(z.low)));
  const range = Math.max(1e-6, maxPrice - minPrice);
  const stepX = (width - padL - padR) / Math.max(1, ks.length - 1);
  const xByIndex = (idx) => padL + idx * stepX;
  const yByPrice = (price) => padT + priceH - ((price - minPrice) / range) * priceH;
  const macdItems = chart.indicators || [];
  const macdAbs = Math.max(1e-6, ...macdItems.map((item) => Math.abs(Number(item.macd && item.macd.macd || 0))));
  const macdBaseY = padT + priceH + 12 + macdH / 2;
  const macdScale = (macdH / 2 - 8) / macdAbs;

  ctx2.strokeStyle = "rgba(148,163,184,0.35)";
  ctx2.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padT + (priceH / 4) * i;
    ctx2.beginPath();
    ctx2.moveTo(padL, y);
    ctx2.lineTo(width - padR, y);
    ctx2.stroke();
  }
  ctx2.fillStyle = "#64748b";
  ctx2.font = "11px Arial";
  for (let i = 0; i <= 4; i++) {
    const price = maxPrice - (range / 4) * i;
    const y = padT + (priceH / 4) * i;
    ctx2.fillText(Number(price).toFixed(2), 8, y + 4);
  }

  for (let i = 0; i < ks.length; i++) {
    const k = ks[i];
    const x = xByIndex(i);
    const openY = yByPrice(Number(k.o));
    const closeY = yByPrice(Number(k.c));
    const highY = yByPrice(Number(k.h));
    const lowY = yByPrice(Number(k.l));
    const isUp = Number(k.c) >= Number(k.o);
    ctx2.strokeStyle = isUp ? rldChartColor("candleUp") : rldChartColor("candleDown");
    ctx2.beginPath();
    ctx2.moveTo(x, highY);
    ctx2.lineTo(x, lowY);
    ctx2.stroke();
    ctx2.fillStyle = isUp ? "rgba(220,38,38,0.2)" : "rgba(22,163,74,0.55)";
    const bodyY = Math.min(openY, closeY);
    const bodyH = Math.max(2, Math.abs(closeY - openY));
    ctx2.fillRect(x - Math.max(1.4, stepX * 0.24), bodyY, Math.max(3, stepX * 0.48), bodyH);
  }

  const drawLineSet = (arr, color, widthPx) => {
    ctx2.strokeStyle = color;
    ctx2.lineWidth = widthPx;
    for (const line of arr || []) {
      ctx2.beginPath();
      ctx2.moveTo(xByIndex(Number(line.x1)), yByPrice(Number(line.y1)));
      ctx2.lineTo(xByIndex(Number(line.x2)), yByPrice(Number(line.y2)));
      ctx2.stroke();
    }
  };
  const drawZsSet = (arr, stroke, fill) => {
    for (const zs of arr || []) {
      const x1 = xByIndex(Number(zs.x1));
      const x2 = xByIndex(Number(zs.x2));
      const y1 = yByPrice(Number(zs.high));
      const y2 = yByPrice(Number(zs.low));
      ctx2.fillStyle = fill;
      ctx2.fillRect(x1, y1, Math.max(4, x2 - x1), Math.max(4, y2 - y1));
      ctx2.strokeStyle = stroke;
      ctx2.lineWidth = 1;
      ctx2.strokeRect(x1, y1, Math.max(4, x2 - x1), Math.max(4, y2 - y1));
    }
  };
  drawZsSet(chart.bi_zs || [], "rgba(249,115,22,0.45)", "rgba(249,115,22,0.08)");
  drawZsSet(chart.seg_zs || [], "rgba(14,165,233,0.45)", "rgba(14,165,233,0.08)");
  drawLineSet(chart.bi || [], rldChartColor("bi"), 1.3);
  drawLineSet(chart.seg || [], rldChartColor("seg"), 2.0);
  drawLineSet(chart.segseg || [], rldChartColor("segseg"), 2.6);

  for (const item of chart.bsp || []) {
    const x = xByIndex(Number(item.x));
    const y = item.is_buy ? yByPrice(Number(item.y)) + 14 : yByPrice(Number(item.y)) - 12;
    ctx2.fillStyle = item.is_buy ? "#b91c1c" : "#15803d";
    ctx2.font = "bold 11px Arial";
    ctx2.fillText(item.display_label || item.label || "", x - 10, y);
  }

  ctx2.strokeStyle = "rgba(100,116,139,0.35)";
  ctx2.beginPath();
  ctx2.moveTo(padL, macdBaseY);
  ctx2.lineTo(width - padR, macdBaseY);
  ctx2.stroke();
  for (let i = 0; i < macdItems.length; i++) {
    const item = macdItems[i];
    const x = xByIndex(i);
    const val = Number(item.macd && item.macd.macd || 0);
    const barH = val * macdScale;
    ctx2.strokeStyle = val >= 0 ? rldChartColor("macdPos") : rldChartColor("macdNeg");
    ctx2.beginPath();
    ctx2.moveTo(x, macdBaseY);
    ctx2.lineTo(x, macdBaseY - barH);
    ctx2.stroke();
  }

  const selectedK = rldFindNearestK(chart, rldCrosshairTime);
  if (selectedK) {
    const idx = ks.findIndex((item) => Number(item.x) === Number(selectedK.x));
    const x = xByIndex(Math.max(0, idx));
    ctx2.strokeStyle = rldChartColor("cross");
    ctx2.setLineDash([5, 4]);
    ctx2.beginPath();
    ctx2.moveTo(x, padT);
    ctx2.lineTo(x, height - padB);
    ctx2.stroke();
    ctx2.setLineDash([]);
    ctx2.fillStyle = "#0f172a";
    ctx2.font = "11px Arial";
    ctx2.fillText(String(selectedK.t), Math.max(padL, x - 50), height - 8);
  }
}

function rldDrawAllCharts() {
  const stack = $("rldChartStack");
  if (!stack) return;
  if (!rldPayload || !rldPayload.ready || !rldPayload.analysis) {
    stack.innerHTML = `<div class="rldChartEmpty">请先到“设置”页配置周期并加载数据。</div>`;
    return;
  }
  const levels = ensureArray(rldPayload.analysis.levels, []);
  if (levels.length <= 0) {
    stack.innerHTML = `<div class="rldChartEmpty">当前结果没有可绘制的周期数据。</div>`;
    return;
  }
  stack.innerHTML = levels.map((levelItem, idx) => `
    <div class="rldChartCard">
      <div id="rldChartHead${idx + 1}" class="rldChartHead">
        ${levelItem ? `${levelItem.label} <span>${levelItem.summary ? `${levelItem.summary.trend_label} / CHDL ${rldNumber(levelItem.summary.chdl_score)}` : ""}</span>` : `周期${idx + 1}`}
      </div>
      <canvas id="rldChart${idx + 1}" class="rldChartCanvas" data-rld-chart-index="${idx}"></canvas>
    </div>
  `).join("");
  levels.forEach((levelItem, idx) => {
    rldDrawChart($(`rldChart${idx + 1}`), levelItem);
  });
  rldBindCanvasInteractions();
}

function rldRenderPerspective() {
  const box = $("rldPerspective");
  if (!box) return;
  if (!rldPayload || !rldPayload.ready || !rldPayload.analysis) {
    box.innerHTML = `<div class="rldPerspectiveTime">等待加载</div>`;
    return;
  }
  const levels = ensureArray(rldPayload.analysis.levels, []);
  let pivotTime = rldCrosshairTime;
  if (!pivotTime && levels[0] && levels[0].chart && levels[0].chart.kline && levels[0].chart.kline.length > 0) {
    pivotTime = levels[0].chart.kline[levels[0].chart.kline.length - 1].t;
  }
  const cards = levels.map((level) => {
    const nearest = rldFindNearestK(level.chart, pivotTime);
    const ind = ensureArray(level.chart && level.chart.indicators, []).find((item) => nearest && Number(item.x) === Number(nearest.x));
    return `
      <div class="rldPerspectiveCard">
        <div style="font-weight:800;color:#0f172a;margin-bottom:6px;">${level.label}</div>
        <div>时间：${nearest ? nearest.t : "-"}</div>
        <div>OHLC：${nearest ? `${rldNumber(nearest.o, 3)} / ${rldNumber(nearest.h, 3)} / ${rldNumber(nearest.l, 3)} / ${rldNumber(nearest.c, 3)}` : "-"}</div>
        <div>趋势：${level.summary.trend_label}</div>
        <div>BSP：${level.summary.latest_bsp ? level.summary.latest_bsp.display_label : "无"}</div>
        <div>中枢：${level.summary.zs_state.kind}${level.summary.zs_state.label}</div>
        <div>MACD：${ind && ind.macd ? rldNumber(ind.macd.macd, 4) : "-"}</div>
        <div>笔面积 / 段面积：${rldNumber(level.summary.macd_bi_area, 3)} / ${rldNumber(level.summary.macd_seg_area, 3)}</div>
        <div>CHDL：${rldNumber(level.summary.chdl_score)}</div>
      </div>
    `;
  }).join("");
  const agg = rldPayload.analysis.aggregate || {};
  box.innerHTML = `
    <div class="rldPerspectiveTime">${pivotTime || "-"}</div>
    <div class="rldMetaRow">
      ${rldSideBadge(agg.rld_bs ? agg.rld_bs.side : "neutral")}
      <span>RLD_BS 分数：${agg.rld_bs ? rldNumber(agg.rld_bs.score) : "-"}</span>
      <span>一根筋：${agg.one_line ? "是" : "否"}</span>
      <span>无脑买入(笔)：${agg.stupid_buy_bi ? "是" : "否"}</span>
      <span>无脑买入(线段)：${agg.stupid_buy_seg ? "是" : "否"}</span>
    </div>
    <div class="rldPerspectiveGrid">${cards}</div>
    <div style="margin-top:10px;font-size:12px;color:#475569;line-height:1.6;">${agg.rld_bs && agg.rld_bs.reasons ? compactReasText(agg.rld_bs.reasons) : "-"}</div>
  `;
}

function rldRenderLevelMatrix(payload) {
  const target = $("rldMatrixContainer");
  if (!target) return;
  if (!payload || !payload.analysis || !Array.isArray(payload.analysis.level_matrix)) {
    target.innerHTML = `<div class="muted">尚未生成矩阵。</div>`;
    return;
  }
  const headers = ensureArray(payload.lv_labels, []);
  const rows = ensureArray(payload.analysis.level_matrix, []);
  const matrixTable = `
    <div class="rldCardTitle" style="margin-top:0;">当前标的矩阵</div>
    <div class="rldScroll" style="max-height:220px;">
      <table class="rldTable">
        <thead><tr><th>指标</th>${headers.map((h) => `<th>${h}</th>`).join("")}</tr></thead>
        <tbody>
          ${rows.map((row) => `<tr><td>${row.metric || "-"}</td>${headers.map((h) => `<td>${row[h] || "-"}</td>`).join("")}</tr>`).join("")}
        </tbody>
      </table>
    </div>
  `;
  const multi = payload.matrix && payload.matrix.rows && payload.matrix.rows.length > 0 ? `
    <div class="rldCardTitle" style="margin-top:14px;">多股矩阵 / 板块轮动</div>
    <div class="rldMetaRow">
      <span>标的数：${payload.matrix.meta ? payload.matrix.meta.count : 0}</span>
      <span>平均 CHDL：${payload.matrix.meta ? rldNumber(payload.matrix.meta.avg_chdl) : "-"}</span>
      <span>买入广度：${payload.matrix.meta ? rldPct(payload.matrix.meta.buy_breadth, 1) : "-"}</span>
      <span>MACD 广度：${payload.matrix.meta ? rldPct(payload.matrix.meta.macd_breadth, 1) : "-"}</span>
    </div>
    <div class="rldScroll" style="max-height:280px;">
      <table class="rldTable">
        <thead>
          <tr>
            <th>代码</th><th>名称</th><th>轮动分</th><th>CHDL</th><th>三级别MACD</th><th>一根筋</th><th>无脑买入(笔)</th><th>无脑买入(段)</th><th>RLD_BS</th><th>原因</th>
          </tr>
        </thead>
        <tbody>
          ${payload.matrix.rows.map((row) => `
            <tr>
              <td>${row.code || "-"}</td>
              <td>${row.name || "-"}</td>
              <td>${rldNumber(row.rotation_score)}</td>
              <td>${rldNumber(row.chdl)}</td>
              <td>${rldNumber(row.three_macd)}</td>
              <td>${row.one_line ? "是" : "否"}</td>
              <td>${row.stupid_buy_bi ? "是" : "否"}</td>
              <td>${row.stupid_buy_seg ? "是" : "否"}</td>
              <td>${row.rld_bs_side || "-"} ${rldNumber(row.rld_bs_score)}</td>
              <td>${ensureArray(row.reasons, []).join("；")}</td>
            </tr>`).join("")}
        </tbody>
      </table>
    </div>
  ` : `<div class="muted" style="margin-top:10px;">尚未生成多股矩阵，可点击“刷新矩阵”。</div>`;
  target.innerHTML = matrixTable + multi;
}

function rldRenderBacktest(payload) {
  const target = $("rldBacktestContainer");
  if (!target) return;
  const backtest = payload && payload.backtest;
  if (!backtest || !Array.isArray(backtest.rows) || backtest.rows.length <= 0) {
    target.innerHTML = `<div class="muted">尚未执行回测。</div>`;
    return;
  }
  target.innerHTML = `
    <div class="rldMetaRow">
      <span>标的数：${backtest.summary ? backtest.summary.count : 0}</span>
      <span>平均收益：${backtest.summary ? rldPct(backtest.summary.avg_return) : "-"}</span>
      <span>平均回撤：${backtest.summary ? rldPct(backtest.summary.avg_max_drawdown) : "-"}</span>
      <span>入场规则：${ensureArray(backtest.params && backtest.params.entry_rules, []).join(" + ")}</span>
      <span>出场规则：${ensureArray(backtest.params && backtest.params.exit_rules, []).join(" + ")}</span>
    </div>
    <div class="rldScroll" style="max-height:260px;">
      <table class="rldTable">
        <thead><tr><th>代码</th><th>名称</th><th>交易数</th><th>收益</th><th>最大回撤</th><th>胜率</th><th>Profit Factor</th></tr></thead>
        <tbody>
          ${backtest.rows.map((row) => `<tr><td>${row.code}</td><td>${row.name || "-"}</td><td>${row.trade_count}</td><td>${rldPct(row.return)}</td><td>${rldPct(row.max_drawdown)}</td><td>${rldPct(row.win_rate)}</td><td>${row.profit_factor === null || row.profit_factor === undefined ? "-" : rldNumber(row.profit_factor, 3)}</td></tr>`).join("")}
        </tbody>
      </table>
    </div>
    <div class="rldCardTitle" style="margin-top:12px;">最近交易明细</div>
    <div class="rldScroll" style="max-height:220px;">
      <table class="rldTable">
        <thead><tr><th>代码</th><th>方向</th><th>时间</th><th>价格</th><th>股数</th><th>盈亏</th><th>原因</th></tr></thead>
        <tbody>
          ${ensureArray(backtest.trades, []).slice(-80).reverse().map((row) => `<tr><td>${row.code}</td><td>${row.side}</td><td>${row.time || "-"}</td><td>${rldNumber(row.price, 4)}</td><td>${row.shares || "-"}</td><td>${row.pnl === undefined ? "-" : rldNumber(row.pnl, 2)}</td><td>${ensureArray(row.reason, []).join("；")}</td></tr>`).join("")}
        </tbody>
      </table>
    </div>
  `;
}

function rldRefresh(payload, message) {
  rldPayload = payload;
  rldRenderHeader(payload);
  rldRenderSummary(payload);
  rldRenderLevelMatrix(payload);
  rldRenderBacktest(payload);
  rldRenderStatus(payload, message || payload.message || "");
  const firstLevel = payload && payload.analysis && payload.analysis.levels && payload.analysis.levels[0];
  if (!rldCrosshairTime && firstLevel && firstLevel.chart && firstLevel.chart.kline && firstLevel.chart.kline.length > 0) {
    rldCrosshairTime = firstLevel.chart.kline[firstLevel.chart.kline.length - 1].t;
  }
  rldRenderPerspective();
  rldDrawAllCharts();
}

function rldBindCanvasInteractions() {
  document.querySelectorAll("#rldChartStack .rldChartCanvas").forEach((canvasEl) => {
    if (!canvasEl || canvasEl.dataset.bound === "1") return;
    canvasEl.dataset.bound = "1";
    canvasEl.addEventListener("mousemove", (e) => {
      if (!rldPayload || !rldPayload.ready) return;
      const idx = Number(canvasEl.getAttribute("data-rld-chart-index") || 0);
      const levelItem = rldPayload.analysis && rldPayload.analysis.levels ? rldPayload.analysis.levels[idx] : null;
      const chart = levelItem && levelItem.chart;
      if (!chart || !chart.kline || chart.kline.length <= 0) return;
      const rect = canvasEl.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const kIdx = Math.max(0, Math.min(chart.kline.length - 1, Math.round(((x - 56) / Math.max(1, rect.width - 70)) * (chart.kline.length - 1))));
      const k = chart.kline[kIdx];
      if (!k) return;
      rldCrosshairTime = k.t;
      rldRenderPerspective();
      rldDrawAllCharts();
    });
  });
}

function rldSetTopTab(tab) {
  rldActiveTopTab = tab === "rld" || tab === "settings" ? tab : "trainer";
  storageSet("chan_top_active_tab", rldActiveTopTab);
  $("topTabTrainer").classList.toggle("active", rldActiveTopTab === "trainer");
  $("topTabRld").classList.toggle("active", rldActiveTopTab === "rld");
  $("topTabSettings").classList.toggle("active", rldActiveTopTab === "settings");
  $("pageTrainer").classList.toggle("active", rldActiveTopTab === "trainer");
  $("pageRld").classList.toggle("active", rldActiveTopTab === "rld");
  $("pageSettings").classList.toggle("active", rldActiveTopTab === "settings");
  if (rldActiveTopTab === "trainer") {
    requestAnimationFrame(() => {
      resizeCanvas();
      if (lastPayload && lastPayload.ready) draw(lastPayload.chart);
      updateCompactLayout();
    });
  } else if (rldActiveTopTab === "rld") {
    requestAnimationFrame(() => {
      rldDrawAllCharts();
      rldRenderPerspective();
    });
  } else {
    requestAnimationFrame(() => {
      updateCompactLayout();
    });
  }
}

function rldBindUi() {
  rldMountSettingsHub();
  const savedForm = ensureObject(rldGetStoredJson("form", {}), {});
  rldRenderLevelRows(rldGetSavedLevelRows());
  if ($("rldAutype")) $("rldAutype").value = savedForm.autype || storageGet(rldStorageKey("autype")) || "qfq";
  if ($("rldRuleLogic")) $("rldRuleLogic").value = savedForm.rule_logic || storageGet(rldStorageKey("logic")) || "and";
  if ($("topTabTrainer") && !$("topTabTrainer").dataset.bound) {
    $("topTabTrainer").dataset.bound = "1";
    $("topTabTrainer").onclick = () => rldSetTopTab("trainer");
    $("topTabRld").onclick = () => rldSetTopTab("rld");
    $("topTabSettings").onclick = () => rldSetTopTab("settings");
  }
  if ($("rldAddLevel") && $("rldAddLevel").dataset.bound !== "1") {
    $("rldAddLevel").dataset.bound = "1";
    $("rldAddLevel").onclick = () => {
      const next = rldReadLevelRows();
      next.push({ value: RLD_LEVEL_OPTIONS[Math.min(next.length, RLD_LEVEL_OPTIONS.length - 1)].value, weight: Math.max(1, Math.round(100 / (next.length + 1))) });
      rldRenderLevelRows(next);
      rldSaveForm();
    };
  }
  document.querySelectorAll("#settingsRldMount input, #settingsRldMount select, #settingsRldMount textarea").forEach((input) => {
    if (input.dataset.persistBound === "1") return;
    input.dataset.persistBound = "1";
    input.addEventListener("change", () => rldSaveForm());
  });
  const bindBtn = (id, fn) => {
    const el = $(id);
    if (!el || el.dataset.bound === "1") return;
    el.dataset.bound = "1";
    el.onclick = fn;
  };
  bindBtn("rldBtnInit", async () => {
    try {
      const body = rldCollectForm();
      const payload = await rldCall("/api/rld/init", body, "POST", "正在加载融立得工作台...");
      storageSet(rldStorageKey("lv1"), body.lv_list[0] || "day");
      storageSet(rldStorageKey("lv2"), body.lv_list[1] || "60m");
      storageSet(rldStorageKey("lv3"), body.lv_list[2] || "15m");
      storageSet(rldStorageKey("autype"), body.autype);
      storageSet(rldStorageKey("logic"), $("rldRuleLogic").value);
      rldSaveForm();
      rldRefresh(payload, payload.message || "加载成功");
    } catch (e) {
      rldSetStatus(`加载失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnReconfig", async () => {
    try {
      const form = rldCollectForm();
      const payload = await rldCall("/api/rld/reconfig", {
        chan_config: form.chan_config,
        strategy_config: form.strategy_config,
        watchlist_or_sector: form.watchlist_or_sector,
        lv_list: form.lv_list,
      }, "POST", "正在应用融立得配置...");
      rldSaveForm();
      rldRefresh(payload, payload.message || "配置已更新");
    } catch (e) {
      rldSetStatus(`应用配置失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnMatrix", async () => {
    try {
      const payload = await rldCall("/api/rld/matrix", {
        watchlist_or_sector: $("rldWatchlist").value,
      }, "POST", "正在刷新多股矩阵...");
      rldRefresh(payload, payload.message || "矩阵已刷新");
    } catch (e) {
      rldSetStatus(`矩阵刷新失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnBacktest", async () => {
    try {
      const payload = await rldCall("/api/rld/backtest", {
        entry_rules: rldGetSelectedRules("rldEntryRule"),
        exit_rules: rldGetSelectedRules("rldExitRule"),
        logic: $("rldRuleLogic").value,
        execution_mode: "next_open",
        fee: Number($("rldFee").value),
        slippage: Number($("rldSlippage").value),
        codes: parseCodeListForBacktest($("rldWatchlist").value),
        watchlist_or_sector: $("rldWatchlist").value,
      }, "POST", "正在运行回归评测...");
      rldSaveForm();
      rldRefresh(payload, payload.message || "回测完成");
    } catch (e) {
      rldSetStatus(`回测失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnReset", async () => {
    try {
      const payload = await rldCall("/api/rld/reset", {}, "POST", "正在重置融立得工作台...");
      rldPayload = null;
      rldCrosshairTime = null;
      rldRefresh(payload, payload.message || "已重置");
    } catch (e) {
      rldSetStatus(`重置失败：${e.message}`, "error");
    }
  });
  bindBtn("rldBtnGoSettings", () => {
    rldSetTopTab("settings");
    rldSetSettingsHubTab("rld");
  });
  rldBindCanvasInteractions();
  const savedTab = storageGet("chan_top_active_tab") || "trainer";
  rldSetTopTab(savedTab);
}

function parseCodeListForBacktest(text) {
  const matched = String(text || "").match(/\d{6}/g);
  return matched ? matched.slice(0, 12) : [];
}

async function rldRestoreState() {
  try {
    const payload = await api("/api/rld/state", null, "GET");
    if (payload && payload.ready) {
      rldRefresh(payload, "已恢复融立得工作台会话。");
    } else {
      rldRenderSummary(null);
      rldRenderLevelMatrix(null);
      rldRenderBacktest(null);
      rldRenderPerspective();
    }
  } catch (e) {
    console.warn("恢复融立得工作台失败:", e);
  }
}

function verifyCriticalUiBindings() {
  const checks = [
    { id: "btnInit", ok: () => typeof $("btnInit").onclick === "function" || $("btnInit").dataset.bound === "1" },
    { id: "btnStep", ok: () => typeof $("btnStep").onclick === "function" || $("btnStep").dataset.bound === "1" },
    { id: "btnBuy", ok: () => typeof $("btnBuy").onclick === "function" || $("btnBuy").dataset.bound === "1" },
    { id: "btnSell", ok: () => typeof $("btnSell").onclick === "function" || $("btnSell").dataset.bound === "1" },
    { id: "btnSettingsOpen", ok: () => $("btnSettingsOpen").dataset.bound === "1" },
    { id: "btnFullscreen", ok: () => typeof $("btnFullscreen").onclick === "function" || $("btnFullscreen").dataset.bound === "1" },
    { id: "toolHorizontalRay", ok: () => $("toolHorizontalRay").dataset.bound === "1" },
    { id: "toolBiRay", ok: () => $("toolBiRay").dataset.bound === "1" },
  ];
  const broken = checks
    .map((check) => {
      const el = $(check.id);
      if (!el) return `${check.id}: 缺少 DOM 节点`;
      try {
        return check.ok() ? null : `${check.id}: 事件绑定缺失`;
      } catch (err) {
        return `${check.id}: 自检异常 (${err && err.message ? err.message : err})`;
      }
    })
    .filter(Boolean);
  if (broken.length <= 0) {
    console.info("UI binding self-check passed.");
    return;
  }
  const text = `前端脚本自检发现异常：
${broken.join("\\n")}
请重点检查 forEach 回调里是否误用了 continue。`;
  console.error(text);
  setTimeout(() => showToast(text, { record: false }), 0);
}

(async () => {
  rldEnsureShell();
  rldBindUi();
  loadSessionConfig();
  applyThemeFromSelect();
  hideGlobalLoading();
  try {
    const payload = await api("/api/state", null, "GET");
    if (payload && payload.ready) {
      document.title = `复盘 - ${(payload.name ? payload.name : payload.code)}`;
      $("btnInit").disabled = true;
      // $("btnChanSettingsOpen").disabled = true;
      $("code").disabled = true;
      $("begin").disabled = true;
      $("end").disabled = true;
      $("cash").disabled = true;
      $("autype").disabled = true;
      refreshUI(payload);
      setMsg("已自动恢复上次会话。");
    }
  } catch (e) {
    console.error("恢复会话失败:", e);
  }
  updateDataSourceStatus(lastPayload);
  updateCompactLayout();
  await rldRestoreState();
  verifyCriticalUiBindings();
})();

"""
