FRONTEND_EXT = """\
(function () {
  const SHARED_SETTINGS_DEFAULT = {
    data_quality: "network_direct",
    cycle_form: "standard",
    chip_data_quality: "kline_estimate",
    offline_kline_path: "",
    offline_tick_path: "",
  };
  const TRAIN_DEFAULT_FORM = {
    code: "600340",
    begin_date: "2018-01-01",
    end_date: "",
    autype: "qfq",
    initial_cash: "100000",
    lv_tokens: ["day", "60m", "15m"],
  };
  let sharedSettingsState = { ...SHARED_SETTINGS_DEFAULT };
  let rldSubtabState = storageGet("rld_subtab_active") || "analysis";
  let rldTrainPayload = null;
  let rldTrainCrosshair = {};

  function ensureArrayText(raw, fallback) {
    if (!Array.isArray(raw)) return fallback.slice();
    const rows = raw.map((item) => String(item || "").trim()).filter(Boolean);
    return rows.length > 0 ? rows : fallback.slice();
  }

  function getTrainForm() {
    const stored = ensureObject(safeJsonParse(storageGet("rld_train_form"), {}), {});
    return {
      code: String(stored.code || TRAIN_DEFAULT_FORM.code),
      begin_date: String(stored.begin_date || TRAIN_DEFAULT_FORM.begin_date),
      end_date: String(stored.end_date || TRAIN_DEFAULT_FORM.end_date),
      autype: String(stored.autype || TRAIN_DEFAULT_FORM.autype),
      initial_cash: String(stored.initial_cash || TRAIN_DEFAULT_FORM.initial_cash),
      lv_tokens: ensureArrayText(stored.lv_tokens, TRAIN_DEFAULT_FORM.lv_tokens),
    };
  }

  function saveTrainForm(form) {
    storageSet("rld_train_form", JSON.stringify({
      ...TRAIN_DEFAULT_FORM,
      ...form,
      lv_tokens: ensureArrayText(form.lv_tokens, TRAIN_DEFAULT_FORM.lv_tokens),
    }));
  }

  function getSourcePriorityHint() {
    const priority = ensureArray(dataSourcePriorityState && dataSourcePriorityState.priority, []);
    return priority.length > 0 ? priority.join(" > ") : "BaoStock > AKShare > Ashare > AData > Tushare > OfflineTXT > Tencent > Sina > Eastmoney > Yahoo";
  }

  async function loadSharedSettings() {
    try {
      const payload = await api("/api/shared-settings", null, "GET");
      sharedSettingsState = { ...SHARED_SETTINGS_DEFAULT, ...ensureObject(payload, {}) };
    } catch (e) {
      sharedSettingsState = { ...SHARED_SETTINGS_DEFAULT };
    }
    return sharedSettingsState;
  }

  async function persistSharedSettings(nextState, quiet) {
    const payload = await api("/api/shared-settings", nextState, "POST");
    sharedSettingsState = { ...SHARED_SETTINGS_DEFAULT, ...ensureObject(payload, {}) };
    if (!quiet) showToast("共享系统设置已保存", { record: false });
    renderSharedSettingsSummary();
    return sharedSettingsState;
  }

  function sharedSettingsFieldHtml(id, label, options, value, tip) {
    return `
      <div class="settingsItem">
        <label>${label} <span class="tip-icon" data-tip="${escapeHtmlAttr(tip)}">!</span></label>
        <select id="${id}">
          ${options.map((item) => `<option value="${item.value}" ${item.value === value ? "selected" : ""}>${item.label}</option>`).join("")}
        </select>
      </div>
    `;
  }

  function appendSharedSettingsToSystemModal() {
    const container = $("systemSettingsContent");
    if (!container || container.querySelector("[data-shared-settings='1']")) return;
    const section = document.createElement("div");
    section.className = "settingsSection";
    section.dataset.sharedSettings = "1";
    section.style.background = "rgba(249, 115, 22, 0.08)";
    section.innerHTML = `
      <div class="settingsSectionTitle" style="color:#c2410c">共享数据 / 周期 / 筹码设置</div>
      <div class="settingsGrid">
        ${sharedSettingsFieldHtml(
          "sysDataQuality",
          "数据质量",
          [
            { value: "network_direct", label: "网络直接获取" },
            { value: "network_agg", label: "网络小周期聚合大周期" },
            { value: "offline_direct", label: "离线文件直接获取" },
            { value: "offline_agg", label: "离线小周期聚合大周期" },
          ],
          sharedSettingsState.data_quality,
          "复盘与融立得统一使用这一套取数策略。聚合模式会优先拿更小周期，再在本地聚合成大周期。"
        )}
        ${sharedSettingsFieldHtml(
          "sysCycleForm",
          "周期形式",
          [
            { value: "standard", label: "标准K线" },
            { value: "custom_group", label: "自定义周期N" },
          ],
          sharedSettingsState.cycle_form,
          "仅融立得-缠论训练会读取这个选项。切到自定义周期后，可输入 day2、60m5 这类格式。"
        )}
        ${sharedSettingsFieldHtml(
          "sysChipQuality",
          "筹码数据质量",
          [
            { value: "kline_estimate", label: "原逻辑 / K线估算" },
            { value: "network_tick", label: "网络获取分笔数据" },
            { value: "offline_tick", label: "离线分笔文件" },
          ],
          sharedSettingsState.chip_data_quality,
          "若网络或离线分笔读取失败，训练页会隐藏对应筹码图，并在状态区给出提示。"
        )}
        <div class="settingsItem" style="grid-column:1 / -1;">
          <label>离线K线路径 <span class="tip-icon" data-tip="可填单个 txt 文件，也可填目录。目录下会按 *#股票代码.txt 自动匹配。">!</span></label>
          <input id="sysOfflineKlinePath" type="text" value="${escapeHtmlAttr(sharedSettingsState.offline_kline_path || "")}" placeholder="例如 F:\\\\my_file\\\\3\\\\chan.py\\\\a_Data\\\\SZ#001312\\\\KLine\\\\SZ#001312.txt" />
        </div>
        <div class="settingsItem" style="grid-column:1 / -1;">
          <label>离线分笔路径 <span class="tip-icon" data-tip="可填单个 txt 文件，也可填 TickData 目录。目录下会按 *_股票代码.txt 自动匹配。">!</span></label>
          <input id="sysOfflineTickPath" type="text" value="${escapeHtmlAttr(sharedSettingsState.offline_tick_path || "")}" placeholder="例如 F:\\\\my_file\\\\3\\\\chan.py\\\\a_Data\\\\SZ#001312\\\\TickData" />
        </div>
      </div>
    `;
    container.appendChild(section);
    initTooltips();
  }

  function readSharedSettingsFromSystemModal() {
    return {
      data_quality: $("sysDataQuality") ? $("sysDataQuality").value : sharedSettingsState.data_quality,
      cycle_form: $("sysCycleForm") ? $("sysCycleForm").value : sharedSettingsState.cycle_form,
      chip_data_quality: $("sysChipQuality") ? $("sysChipQuality").value : sharedSettingsState.chip_data_quality,
      offline_kline_path: $("sysOfflineKlinePath") ? $("sysOfflineKlinePath").value.trim() : sharedSettingsState.offline_kline_path,
      offline_tick_path: $("sysOfflineTickPath") ? $("sysOfflineTickPath").value.trim() : sharedSettingsState.offline_tick_path,
    };
  }

  function renderSharedSettingsSummary() {
    const host = $("settingsSharedSummary");
    if (!host) return;
    host.innerHTML = `
      <div class="sharedSettingChip"><span>数据质量</span><strong>${sharedSettingsState.data_quality}</strong></div>
      <div class="sharedSettingChip"><span>周期形式</span><strong>${sharedSettingsState.cycle_form}</strong></div>
      <div class="sharedSettingChip"><span>筹码质量</span><strong>${sharedSettingsState.chip_data_quality}</strong></div>
      <div class="sharedSettingChip wide"><span>当前优先级</span><strong>${escapeHtmlAttr(getSourcePriorityHint())}</strong></div>
    `;
  }

  function wrapSystemSettingsFunctions() {
    if (window.__sharedSettingsWrapped === true) return;
    window.__sharedSettingsWrapped = true;
    const originalRender = renderSystemSettingsForm;
    renderSystemSettingsForm = function () {
      originalRender();
      appendSharedSettingsToSystemModal();
    };
    const originalSave = saveSystemSettingsFromForm;
    saveSystemSettingsFromForm = async function () {
      const nextShared = readSharedSettingsFromSystemModal();
      originalSave();
      try {
        await persistSharedSettings(nextShared, true);
      } catch (e) {
        showToast(`共享设置保存失败：${e.message}`, { record: false });
      }
    };
    const originalReset = resetSystemSettings;
    resetSystemSettings = async function () {
      originalReset();
      sharedSettingsState = { ...SHARED_SETTINGS_DEFAULT };
      try {
        await persistSharedSettings(sharedSettingsState, true);
      } catch (e) {
        showToast(`共享设置重置失败：${e.message}`, { record: false });
      }
      renderSystemSettingsForm();
    };
    const saveBtn = $("btnSystemSettingsSave");
    if (saveBtn && saveBtn.dataset.extBound !== "1") {
      const cloned = saveBtn.cloneNode(true);
      saveBtn.replaceWith(cloned);
      cloned.dataset.extBound = "1";
      cloned.addEventListener("click", () => saveSystemSettingsFromForm());
    }
    const resetBtn = $("btnSystemSettingsReset");
    if (resetBtn && resetBtn.dataset.extBound !== "1") {
      const cloned = resetBtn.cloneNode(true);
      resetBtn.replaceWith(cloned);
      cloned.dataset.extBound = "1";
      cloned.addEventListener("click", () => resetSystemSettings());
    }
  }

  function injectSharedSummaryIntoSettingsHub() {
    const mount = $("settingsSharedMount");
    if (!mount || mount.querySelector("#settingsSharedSummary")) return;
    const box = document.createElement("section");
    box.className = "settingsHubInner";
    box.innerHTML = `
      <div class="settingsHubSectionTitle">共享系统摘要</div>
      <div id="settingsSharedSummary" class="sharedSettingGrid"></div>
      <div class="settingsHubHint">共享系统设置会同时作用于复盘、融立得多周期分析、融立得缠论训练。</div>
    `;
    mount.appendChild(box);
    renderSharedSettingsSummary();
  }

  function trainLevelRowHtml(value, idx) {
    return `
      <div class="trainLevelRow" data-train-level-row="${idx}">
        <div class="rldLevelCell">
          <label>训练周期 ${idx + 1}</label>
          <input class="trainLevelToken" type="text" value="${escapeHtmlAttr(value)}" placeholder="day / 60m / day2 / 15m5" />
        </div>
        <button class="rldLevelRemove" type="button" data-remove-train-level="${idx}" ${idx === 0 ? "disabled" : ""}>删除</button>
      </div>
    `;
  }

  function readTrainLevelTokens() {
    const host = $("trainLevelList");
    if (!host) return getTrainForm().lv_tokens.slice();
    const values = Array.from(host.querySelectorAll(".trainLevelToken"))
      .map((input) => String(input.value || "").trim())
      .filter(Boolean);
    return values.length > 0 ? values : TRAIN_DEFAULT_FORM.lv_tokens.slice();
  }

  function renderTrainLevelRows(values) {
    const host = $("trainLevelList");
    if (!host) return;
    const rows = ensureArrayText(values, TRAIN_DEFAULT_FORM.lv_tokens);
    host.innerHTML = rows.map((value, idx) => trainLevelRowHtml(value, idx)).join("");
    host.querySelectorAll("[data-remove-train-level]").forEach((btn) => {
      btn.onclick = () => {
        const idx = Number(btn.getAttribute("data-remove-train-level"));
        const next = readTrainLevelTokens().filter((_, rowIdx) => rowIdx !== idx);
        renderTrainLevelRows(next);
        persistTrainSettingsFromHub();
      };
    });
    host.querySelectorAll(".trainLevelToken").forEach((input) => {
      input.onchange = () => persistTrainSettingsFromHub();
    });
  }

  function buildTrainSettingsMarkup() {
    const form = getTrainForm();
    return `
      <section class="settingsHubInner">
        <div class="settingsHubSectionTitle">缠论训练参数</div>
        <div class="rldFormGrid">
          <div class="rldField"><label>代码</label><input id="trainCode" value="${escapeHtmlAttr(form.code)}" /></div>
          <div class="rldField"><label>复权</label><select id="trainAutype"><option value="qfq">前复权</option><option value="hfq">后复权</option><option value="none">不复权</option></select></div>
          <div class="rldField"><label>开始日期</label><input id="trainBegin" type="date" value="${escapeHtmlAttr(form.begin_date)}" /></div>
          <div class="rldField"><label>结束日期</label><input id="trainEnd" type="date" value="${escapeHtmlAttr(form.end_date)}" /></div>
          <div class="rldField"><label>初始资金</label><input id="trainCash" type="number" step="1000" min="1000" value="${escapeHtmlAttr(form.initial_cash)}" /></div>
          <div class="rldField full">
            <div class="settingsInlineHead">
              <label>训练周期列表</label>
              <button id="trainAddLevel" class="miniAction" type="button">＋ 添加周期</button>
            </div>
            <div id="trainLevelList" class="rldLevelList"></div>
            <div class="settingsHubHint">标准K线示例：day、60m、15m。自定义周期示例：day2、60m5。只有当系统设置中的“周期形式”切到 custom_group 时，才允许带数字后缀。</div>
          </div>
        </div>
      </section>
    `;
  }

  function persistTrainSettingsFromHub() {
    const next = {
      code: $("trainCode") ? $("trainCode").value.trim() : TRAIN_DEFAULT_FORM.code,
      begin_date: $("trainBegin") ? $("trainBegin").value : TRAIN_DEFAULT_FORM.begin_date,
      end_date: $("trainEnd") ? $("trainEnd").value : "",
      autype: $("trainAutype") ? $("trainAutype").value : "qfq",
      initial_cash: $("trainCash") ? $("trainCash").value : TRAIN_DEFAULT_FORM.initial_cash,
      lv_tokens: readTrainLevelTokens(),
    };
    saveTrainForm(next);
  }

  function mountTrainSettingsIntoHub() {
    const mount = $("settingsRldMount");
    if (!mount || mount.querySelector("#trainCode")) return;
    const wrap = document.createElement("div");
    wrap.innerHTML = buildTrainSettingsMarkup();
    mount.appendChild(wrap);
    const form = getTrainForm();
    if ($("trainAutype")) $("trainAutype").value = form.autype;
    renderTrainLevelRows(form.lv_tokens);
    ["trainCode", "trainBegin", "trainEnd", "trainAutype", "trainCash"].forEach((id) => {
      const el = $(id);
      if (el) el.addEventListener("change", persistTrainSettingsFromHub);
    });
    const addBtn = $("trainAddLevel");
    if (addBtn) {
      addBtn.onclick = () => {
        const next = readTrainLevelTokens();
        next.push(sharedSettingsState.cycle_form === "custom_group" ? "day2" : "day");
        renderTrainLevelRows(next);
        persistTrainSettingsFromHub();
      };
    }
    initTooltips();
  }

  function injectTrainStyle() {
    if ($("rldTrainStyle")) return;
    const style = document.createElement("style");
    style.id = "rldTrainStyle";
    style.textContent = `
      .rldSubtabBar {
        display:flex;
        gap:8px;
        margin-bottom:12px;
      }
      .rldSubtabBtn {
        width:auto;
        padding:8px 14px;
        border-radius:999px;
        border:1px solid rgba(148,163,184,0.45);
        background:rgba(255,255,255,0.82);
        font-weight:700;
      }
      .rldSubtabBtn.active {
        background:#0f172a;
        color:#fff;
        border-color:#0f172a;
      }
      .rldSubpanel { display:none; }
      .rldSubpanel.active { display:block; }
      .trainShell {
        display:flex;
        flex-direction:column;
        gap:12px;
      }
      .trainPanel {
        border-radius:18px;
        border:1px solid rgba(148,163,184,0.28);
        background:linear-gradient(180deg, rgba(255,255,255,0.98), rgba(248,250,252,0.96));
        box-shadow:0 10px 30px rgba(15,23,42,0.06);
        padding:16px;
      }
      .trainHead {
        display:flex;
        justify-content:space-between;
        gap:12px;
        align-items:flex-start;
        flex-wrap:wrap;
      }
      .trainHeadTitle {
        font-size:20px;
        font-weight:800;
        color:#0f172a;
      }
      .trainHeadSub {
        color:#475569;
        font-size:13px;
        line-height:1.7;
        max-width:720px;
      }
      .trainActionRow {
        display:flex;
        flex-wrap:wrap;
        gap:8px;
      }
      .trainActionRow button {
        width:auto;
        padding:8px 12px;
      }
      .trainSummaryGrid, .sharedSettingGrid {
        display:grid;
        grid-template-columns:repeat(auto-fit, minmax(180px, 1fr));
        gap:10px;
      }
      .trainSummaryCard, .sharedSettingChip {
        border-radius:14px;
        border:1px solid rgba(226,232,240,0.9);
        background:rgba(255,255,255,0.92);
        padding:12px;
      }
      .trainSummaryCard .k, .sharedSettingChip span {
        display:block;
        color:#64748b;
        font-size:12px;
        margin-bottom:4px;
      }
      .trainSummaryCard .v, .sharedSettingChip strong {
        color:#0f172a;
        font-size:18px;
        font-weight:800;
      }
      .sharedSettingChip.wide {
        grid-column:1 / -1;
      }
      .trainChartStack {
        display:grid;
        grid-template-columns:repeat(auto-fit, minmax(440px, 1fr));
        gap:12px;
        align-items:start;
      }
      .trainChartCard {
        border-radius:18px;
        border:1px solid rgba(148,163,184,0.28);
        background:#fff;
        padding:12px;
        resize:vertical;
        overflow:auto;
        min-height:440px;
      }
      .trainChartHead {
        display:flex;
        justify-content:space-between;
        align-items:flex-start;
        gap:10px;
        margin-bottom:10px;
        flex-wrap:wrap;
      }
      .trainChartMeta {
        display:flex;
        flex-direction:column;
        gap:4px;
      }
      .trainChartTitle {
        color:#0f172a;
        font-size:16px;
        font-weight:800;
      }
      .trainChartSub {
        color:#475569;
        font-size:12px;
      }
      .trainChartActions {
        display:flex;
        flex-wrap:wrap;
        gap:6px;
      }
      .trainChartActions button {
        width:auto;
        padding:6px 10px;
        font-size:12px;
      }
      .trainCanvasWrap {
        position:relative;
        border-radius:14px;
        background:linear-gradient(180deg, #ffffff, #f8fafc);
        border:1px solid rgba(226,232,240,0.9);
        padding:8px;
      }
      .trainChartCanvas {
        width:100%;
        height:260px;
        display:block;
      }
      .trainChipCanvas {
        width:100%;
        height:96px;
        display:block;
        margin-top:6px;
        border-top:1px dashed rgba(148,163,184,0.45);
        padding-top:6px;
      }
      .trainHoverPanel {
        position:absolute;
        top:10px;
        right:10px;
        width:min(240px, calc(100% - 24px));
        border-radius:12px;
        background:rgba(15,23,42,0.92);
        color:#fff;
        padding:10px 12px;
        font-size:12px;
        line-height:1.6;
        pointer-events:auto;
        opacity:0;
        transform:translateY(-4px);
        transition:opacity .16s ease, transform .16s ease;
      }
      .trainHoverPanel.visible {
        opacity:1;
        transform:translateY(0);
      }
      .trainHoverPanel:hover {
        opacity:1;
      }
      .trainTimelineTable {
        width:100%;
        border-collapse:collapse;
        font-size:12px;
      }
      .trainTimelineTable th, .trainTimelineTable td {
        border-bottom:1px solid rgba(226,232,240,0.9);
        padding:8px 6px;
        text-align:left;
        white-space:nowrap;
      }
      .trainStatusBox {
        white-space:pre-line;
        font-size:12px;
        line-height:1.7;
        color:#334155;
      }
      @media (max-width: 1100px) {
        .trainChartStack {
          grid-template-columns:1fr;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function ensureRldSubtabs() {
    injectTrainStyle();
    const page = $("pageRld");
    if (!page || page.querySelector("#rldSubtabBar")) return;
    const analysisNode = page.querySelector(".rldWorkbench");
    if (!analysisNode) return;
    const bar = document.createElement("div");
    bar.id = "rldSubtabBar";
    bar.className = "rldSubtabBar";
    bar.innerHTML = `
      <button id="rldSubtabAnalysis" class="rldSubtabBtn" type="button">多周期分析</button>
      <button id="rldSubtabTrain" class="rldSubtabBtn" type="button">缠论训练</button>
    `;
    const analysisWrap = document.createElement("div");
    analysisWrap.id = "rldSubpanelAnalysis";
    analysisWrap.className = "rldSubpanel";
    analysisNode.parentNode.insertBefore(analysisWrap, analysisNode);
    analysisWrap.appendChild(analysisNode);
    const trainWrap = document.createElement("div");
    trainWrap.id = "rldSubpanelTrain";
    trainWrap.className = "rldSubpanel";
    trainWrap.innerHTML = `
      <div class="trainShell">
        <section class="trainPanel">
          <div class="trainHead">
            <div>
              <div class="trainHeadTitle">融立得 / 缠论训练</div>
              <div class="trainHeadSub">训练态按最小周期驱动，再把大周期对齐到当前小周期进度，避免高周期提前显示未来K线。周期支持无限扩展，支持标准周期和自定义周期N。</div>
            </div>
            <div class="trainActionRow">
              <button id="trainBtnInit" data-tip="加载缠论训练会话，周期和参数读取自“设置 > 融立得 > 缠论训练参数”。">加载训练</button>
              <button id="trainBtnReset" data-tip="重置当前训练状态并清空持仓。">重置</button>
              <button id="trainBtnGoSettings" data-tip="打开设置页并定位到融立得参数。">打开设置</button>
            </div>
          </div>
        </section>
        <section class="trainPanel">
          <div id="trainSummaryGrid" class="trainSummaryGrid"></div>
        </section>
        <section class="trainPanel">
          <div id="trainStatusBox" class="trainStatusBox">等待加载训练状态...</div>
        </section>
        <section class="trainPanel">
          <div id="trainChartStack" class="trainChartStack"></div>
        </section>
        <section class="trainPanel">
          <div class="rldCardTitle" style="margin:0 0 10px 0;">多周期时间线</div>
          <div style="overflow:auto;">
            <table class="trainTimelineTable">
              <thead><tr><th>周期</th><th>时间</th><th>价格</th><th>趋势</th><th>买卖点</th><th>CHDL</th><th>MACD</th></tr></thead>
              <tbody id="trainTimelineBody"></tbody>
            </table>
          </div>
        </section>
      </div>
    `;
    page.insertBefore(bar, analysisWrap);
    page.appendChild(trainWrap);
    const setTab = (tab) => {
      rldSubtabState = tab === "train" ? "train" : "analysis";
      storageSet("rld_subtab_active", rldSubtabState);
      $("rldSubtabAnalysis").classList.toggle("active", rldSubtabState === "analysis");
      $("rldSubtabTrain").classList.toggle("active", rldSubtabState === "train");
      $("rldSubpanelAnalysis").classList.toggle("active", rldSubtabState === "analysis");
      $("rldSubpanelTrain").classList.toggle("active", rldSubtabState === "train");
      if (rldSubtabState === "train") {
        requestAnimationFrame(() => renderTrainPayload(rldTrainPayload));
      }
    };
    $("rldSubtabAnalysis").onclick = () => setTab("analysis");
    $("rldSubtabTrain").onclick = () => setTab("train");
    setTab(rldSubtabState);
    initTooltips();
  }

  function trainCollectPayload() {
    const form = getTrainForm();
    const lvList = ensureArrayText(form.lv_tokens, TRAIN_DEFAULT_FORM.lv_tokens);
    if (sharedSettingsState.cycle_form !== "custom_group" && lvList.some((item) => /\\d+$/.test(item) && !/^(1m|3m|5m|15m|30m|60m)$/.test(item))) {
      throw new Error("当前周期形式为 standard，请先在系统设置把“周期形式”切到 custom_group 后再使用 day2 / 60m5 这类格式。");
    }
    return {
      code: form.code,
      begin_date: form.begin_date,
      end_date: form.end_date || null,
      autype: form.autype,
      initial_cash: Number(form.initial_cash || "100000"),
      lv_list: lvList,
      chan_config: JSON.parse(JSON.stringify(chanConfig)),
    };
  }

  async function callTrainApi(path, body, method, loadingText) {
    setGlobalLoading(true, loadingText);
    try {
      return await api(path, body, method || "POST");
    } finally {
      hideGlobalLoading();
    }
  }

  function updateTrainSummary(payload) {
    const grid = $("trainSummaryGrid");
    if (!grid) return;
    if (!payload || !payload.ready) {
      grid.innerHTML = `<div class="trainSummaryCard"><span class="k">状态</span><span class="v">未加载</span></div>`;
      return;
    }
    grid.innerHTML = `
      <div class="trainSummaryCard"><span class="k">当前时间</span><span class="v">${payload.time || "-"}</span></div>
      <div class="trainSummaryCard"><span class="k">驱动周期</span><span class="v">${payload.raw_level_label || "-"}</span></div>
      <div class="trainSummaryCard"><span class="k">当前索引</span><span class="v">${payload.raw_index + 1} / ${payload.raw_total}</span></div>
      <div class="trainSummaryCard"><span class="k">数据源</span><span class="v">${payload.data_source ? payload.data_source.label : "-"}</span></div>
      <div class="trainSummaryCard"><span class="k">现金</span><span class="v">${rldNumber(payload.account ? payload.account.cash : null, 2)}</span></div>
      <div class="trainSummaryCard"><span class="k">总资产</span><span class="v">${rldNumber(payload.account ? payload.account.equity : null, 2)}</span></div>
      <div class="trainSummaryCard"><span class="k">持仓股数</span><span class="v">${payload.account ? payload.account.position : "-"}</span></div>
      <div class="trainSummaryCard"><span class="k">持仓成本</span><span class="v">${rldNumber(payload.account ? payload.account.avg_cost : null, 4)}</span></div>
    `;
  }

  function updateTrainStatus(payload, message) {
    const box = $("trainStatusBox");
    if (!box) return;
    if (!payload || !payload.ready) {
      box.textContent = "等待加载训练状态...";
      return;
    }
    const lines = [
      `标的：${payload.name || payload.code}`,
      `当前时间：${payload.time}`,
      `周期：${ensureArray(payload.levels, []).map((item) => item.label).join(" / ")}`,
      `数据源：${payload.data_source ? payload.data_source.label : "-"}`,
      `尝试顺序：${getSourcePriorityHint()}`,
      ...(payload.data_source && payload.data_source.logs ? payload.data_source.logs : []),
    ];
    if (message) lines.unshift(message);
    box.textContent = lines.join("\\n");
  }

  function drawTrainChip(canvas, chip) {
    const prepared = rldPrepareCanvas(canvas);
    if (!prepared) return;
    const { ctx, width, height } = prepared;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, width, height);
    const buckets = ensureArray(chip && chip.buckets, []);
    if (!chip || !chip.available || buckets.length <= 0) {
      ctx.fillStyle = "#64748b";
      ctx.font = "12px Arial";
      ctx.fillText(chip && chip.source ? `${chip.source} 暂无筹码数据` : "暂无筹码数据", 10, 18);
      return;
    }
    const maxVol = Math.max(1, ...buckets.map((item) => Number(item.volume || 0)));
    const barW = Math.max(4, (width - 28) / buckets.length);
    ctx.fillStyle = "rgba(37,99,235,0.22)";
    ctx.fillRect(0, 0, width, height);
    buckets.forEach((item, idx) => {
      const h = Math.max(2, (Number(item.volume || 0) / maxVol) * (height - 26));
      const x = 14 + idx * barW;
      const y = height - h - 12;
      ctx.fillStyle = "rgba(37,99,235,0.62)";
      ctx.fillRect(x, y, Math.max(2, barW - 2), h);
    });
    ctx.fillStyle = "#0f172a";
    ctx.font = "11px Arial";
    ctx.fillText(chip.source || "Chip", 10, 14);
  }

  function nearestTrainK(chart, timeText) {
    return rldFindNearestK(chart, timeText);
  }

  function drawTrainChart(canvas, levelItem) {
    const prepared = rldPrepareCanvas(canvas);
    if (!prepared) return;
    const { ctx, width, height } = prepared;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, width, height);
    if (!levelItem || !levelItem.chart || !Array.isArray(levelItem.chart.kline) || levelItem.chart.kline.length <= 0) {
      ctx.fillStyle = "#64748b";
      ctx.font = "12px Arial";
      ctx.fillText("暂无K线", 16, 22);
      return;
    }
    const chart = levelItem.chart;
    const ks = chart.kline;
    const padL = 56;
    const padR = 14;
    const padT = 18;
    const padB = 26;
    const macdH = Math.max(46, Math.floor(height * 0.22));
    const priceH = height - macdH - padT - padB - 8;
    const maxPrice = Math.max(...ks.map((item) => Number(item.h)), ...ensureArray(chart.seg_zs, []).map((item) => Number(item.high || item.h || 0)));
    const minPrice = Math.min(...ks.map((item) => Number(item.l)), ...ensureArray(chart.seg_zs, []).map((item) => Number(item.low || item.l || 9999999)));
    const range = Math.max(1e-6, maxPrice - minPrice);
    const stepX = (width - padL - padR) / Math.max(1, ks.length - 1);
    const xByIndex = (idx) => padL + idx * stepX;
    const yByPrice = (price) => padT + priceH - ((price - minPrice) / range) * priceH;
    const macdItems = ensureArray(chart.indicators, []);
    const macdAbs = Math.max(1e-6, ...macdItems.map((item) => Math.abs(Number(item.macd && item.macd.macd || 0))));
    const macdBaseY = padT + priceH + 12 + macdH / 2;
    const macdScale = (macdH / 2 - 8) / macdAbs;

    ctx.strokeStyle = "rgba(148,163,184,0.35)";
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i += 1) {
      const y = padT + (priceH / 4) * i;
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(width - padR, y);
      ctx.stroke();
    }
    ctx.fillStyle = "#64748b";
    ctx.font = "11px Arial";
    for (let i = 0; i <= 4; i += 1) {
      const price = maxPrice - (range / 4) * i;
      const y = padT + (priceH / 4) * i;
      ctx.fillText(Number(price).toFixed(2), 8, y + 4);
    }
    ks.forEach((k, idx) => {
      const x = xByIndex(idx);
      const openY = yByPrice(Number(k.o));
      const closeY = yByPrice(Number(k.c));
      const highY = yByPrice(Number(k.h));
      const lowY = yByPrice(Number(k.l));
      const isUp = Number(k.c) >= Number(k.o);
      ctx.strokeStyle = isUp ? rldChartColor("candleUp") : rldChartColor("candleDown");
      ctx.beginPath();
      ctx.moveTo(x, highY);
      ctx.lineTo(x, lowY);
      ctx.stroke();
      ctx.fillStyle = isUp ? "rgba(220,38,38,0.18)" : "rgba(22,163,74,0.55)";
      ctx.fillRect(x - Math.max(1.5, stepX * 0.22), Math.min(openY, closeY), Math.max(3, stepX * 0.44), Math.max(2, Math.abs(closeY - openY)));
    });
    const drawLineSet = (rows, color, widthPx) => {
      ensureArray(rows, []).forEach((line) => {
        ctx.strokeStyle = color;
        ctx.lineWidth = widthPx;
        ctx.beginPath();
        ctx.moveTo(xByIndex(Number(line.x1)), yByPrice(Number(line.y1)));
        ctx.lineTo(xByIndex(Number(line.x2)), yByPrice(Number(line.y2)));
        ctx.stroke();
      });
    };
    const drawZsSet = (rows, stroke, fill) => {
      ensureArray(rows, []).forEach((zs) => {
        const x1 = xByIndex(Number(zs.x1));
        const x2 = xByIndex(Number(zs.x2));
        const y1 = yByPrice(Number(zs.high));
        const y2 = yByPrice(Number(zs.low));
        ctx.fillStyle = fill;
        ctx.fillRect(x1, y1, Math.max(4, x2 - x1), Math.max(4, y2 - y1));
        ctx.strokeStyle = stroke;
        ctx.lineWidth = 1;
        ctx.strokeRect(x1, y1, Math.max(4, x2 - x1), Math.max(4, y2 - y1));
      });
    };
    drawZsSet(chart.bi_zs, "rgba(249,115,22,0.45)", "rgba(249,115,22,0.08)");
    drawZsSet(chart.seg_zs, "rgba(14,165,233,0.45)", "rgba(14,165,233,0.08)");
    drawLineSet(chart.bi, rldChartColor("bi"), 1.3);
    drawLineSet(chart.seg, rldChartColor("seg"), 2.0);
    drawLineSet(chart.segseg, rldChartColor("segseg"), 2.5);
    ensureArray(chart.bsp, []).forEach((item) => {
      const idx = ks.findIndex((k) => Number(k.x) === Number(item.x));
      if (idx < 0) return;
      const x = xByIndex(idx);
      const y = item.is_buy ? yByPrice(Number(item.y)) + 15 : yByPrice(Number(item.y)) - 12;
      ctx.fillStyle = item.is_buy ? "#b91c1c" : "#15803d";
      ctx.font = "bold 11px Arial";
      ctx.fillText(item.display_label || item.label || "", x - 10, y);
    });
    ctx.strokeStyle = "rgba(100,116,139,0.35)";
    ctx.beginPath();
    ctx.moveTo(padL, macdBaseY);
    ctx.lineTo(width - padR, macdBaseY);
    ctx.stroke();
    macdItems.forEach((item, idx) => {
      const x = xByIndex(idx);
      const val = Number(item.macd && item.macd.macd || 0);
      ctx.strokeStyle = val >= 0 ? rldChartColor("macdPos") : rldChartColor("macdNeg");
      ctx.beginPath();
      ctx.moveTo(x, macdBaseY);
      ctx.lineTo(x, macdBaseY - val * macdScale);
      ctx.stroke();
    });
    const crossTime = rldTrainCrosshair[levelItem.token] || (ks.length > 0 ? ks[ks.length - 1].t : null);
    const selectedK = nearestTrainK(chart, crossTime);
    if (selectedK) {
      const idx = ks.findIndex((item) => Number(item.x) === Number(selectedK.x));
      const x = xByIndex(Math.max(0, idx));
      ctx.setLineDash([5, 4]);
      ctx.strokeStyle = "#0f172a";
      ctx.beginPath();
      ctx.moveTo(x, padT);
      ctx.lineTo(x, height - padB);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = "#0f172a";
      ctx.font = "11px Arial";
      ctx.fillText(String(selectedK.t), Math.max(padL, x - 40), height - 6);
    }
  }

  function trainHoverHtml(levelItem, k) {
    return `
      <div><strong>${levelItem.label}</strong></div>
      <div>时间：${k ? k.t : "-"}</div>
      <div>OHLC：${k ? `${rldNumber(k.o, 3)} / ${rldNumber(k.h, 3)} / ${rldNumber(k.l, 3)} / ${rldNumber(k.c, 3)}` : "-"}</div>
      <div>趋势：${levelItem.summary ? levelItem.summary.trend_label : "-"}</div>
      <div>买卖点：${levelItem.summary && levelItem.summary.latest_bsp ? levelItem.summary.latest_bsp.display_label : "无"}</div>
      <div>中枢：${levelItem.summary ? `${levelItem.summary.zs_state.kind}${levelItem.summary.zs_state.label}` : "-"}</div>
      <div>CHDL：${levelItem.summary ? rldNumber(levelItem.summary.chdl_score) : "-"}</div>
      <div>MACD：${levelItem.summary ? rldNumber(levelItem.summary.macd_bias) : "-"}</div>
    `;
  }

  function renderTrainCharts(payload) {
    const stack = $("trainChartStack");
    if (!stack) return;
    if (!payload || !payload.ready) {
      stack.innerHTML = `<div class="trainChartCard">请先在设置页配置训练周期并加载训练。</div>`;
      return;
    }
    const levels = ensureArray(payload.levels, []);
    stack.innerHTML = levels.map((levelItem, idx) => `
      <article class="trainChartCard">
        <div class="trainChartHead">
          <div class="trainChartMeta">
            <div class="trainChartTitle">${levelItem.label}</div>
            <div class="trainChartSub">${levelItem.summary ? `${levelItem.summary.trend_label} / CHDL ${rldNumber(levelItem.summary.chdl_score)}` : ""}</div>
          </div>
          <div class="trainChartActions">
            <button type="button" data-train-step-back="${levelItem.token}" data-tip="按当前周期后退一根训练K线。">后退</button>
            <button type="button" data-train-step="${levelItem.token}" data-tip="按当前周期步进一根训练K线。">步进</button>
            <button type="button" data-train-buy="${levelItem.token}" data-tip="按当前周期最后一根可见K线收盘价执行买入。">买入</button>
            <button type="button" data-train-sell="${levelItem.token}" data-tip="按当前周期最后一根可见K线收盘价执行卖出。">卖出</button>
          </div>
        </div>
        <div class="trainCanvasWrap">
          <canvas id="trainChartCanvas${idx + 1}" class="trainChartCanvas" data-train-token="${levelItem.token}"></canvas>
          <canvas id="trainChipCanvas${idx + 1}" class="trainChipCanvas"></canvas>
          <div id="trainHover${idx + 1}" class="trainHoverPanel"></div>
        </div>
      </article>
    `).join("");
    levels.forEach((levelItem, idx) => {
      drawTrainChart($("trainChartCanvas" + (idx + 1)), levelItem);
      drawTrainChip($("trainChipCanvas" + (idx + 1)), levelItem.chip);
      const hoverEl = $("trainHover" + (idx + 1));
      const canvas = $("trainChartCanvas" + (idx + 1));
      if (!canvas || !hoverEl) return;
      const chart = levelItem.chart || {};
      const ks = ensureArray(chart.kline, []);
      if (ks.length > 0) hoverEl.innerHTML = trainHoverHtml(levelItem, ks[ks.length - 1]);
      hoverEl.onmouseenter = () => {
        hoverEl.dataset.locked = "1";
        hoverEl.classList.add("visible");
      };
      hoverEl.onmouseleave = () => {
        hoverEl.dataset.locked = "";
        hoverEl.classList.remove("visible");
      };
      canvas.onmousemove = (e) => {
        if (!ks.length) return;
        const rect = canvas.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const idx2 = Math.max(0, Math.min(ks.length - 1, Math.round(((x - 56) / Math.max(1, rect.width - 70)) * (ks.length - 1))));
        const k = ks[idx2];
        rldTrainCrosshair[levelItem.token] = k.t;
        hoverEl.innerHTML = trainHoverHtml(levelItem, k);
        hoverEl.classList.add("visible");
        drawTrainChart(canvas, levelItem);
      };
      canvas.onmouseleave = () => {
        if (hoverEl.dataset.locked !== "1") hoverEl.classList.remove("visible");
      };
    });
    stack.querySelectorAll("[data-train-step]").forEach((btn) => btn.onclick = () => trainStep(btn.getAttribute("data-train-step"), true));
    stack.querySelectorAll("[data-train-step-back]").forEach((btn) => btn.onclick = () => trainStep(btn.getAttribute("data-train-step-back"), false));
    stack.querySelectorAll("[data-train-buy]").forEach((btn) => btn.onclick = () => trainTrade(btn.getAttribute("data-train-buy"), "buy"));
    stack.querySelectorAll("[data-train-sell]").forEach((btn) => btn.onclick = () => trainTrade(btn.getAttribute("data-train-sell"), "sell"));
    initTooltips();
  }

  function renderTrainTimeline(payload) {
    const body = $("trainTimelineBody");
    if (!body) return;
    if (!payload || !payload.ready) {
      body.innerHTML = `<tr><td colspan="7">等待训练数据...</td></tr>`;
      return;
    }
    body.innerHTML = ensureArray(payload.timeline, []).map((item) => `
      <tr>
        <td>${item.label || "-"}</td>
        <td>${item.time || "-"}</td>
        <td>${rldNumber(item.price, 4)}</td>
        <td>${item.trend || "-"}</td>
        <td>${item.bsp || "-"}</td>
        <td>${rldNumber(item.chdl, 2)}</td>
        <td>${rldNumber(item.macd, 2)}</td>
      </tr>
    `).join("");
  }

  function renderTrainPayload(payload, message) {
    rldTrainPayload = payload;
    updateTrainSummary(payload);
    updateTrainStatus(payload, message || (payload && payload.message) || "");
    renderTrainCharts(payload);
    renderTrainTimeline(payload);
  }

  async function restoreTrainState() {
    try {
      const payload = await api("/api/rld-train/state", null, "GET");
      if (payload && payload.ready) renderTrainPayload(payload, "已恢复缠论训练会话。");
      else renderTrainPayload(null);
    } catch (e) {
      renderTrainPayload(null);
    }
  }

  async function trainLoad() {
    persistTrainSettingsFromHub();
    const body = trainCollectPayload();
    updateTrainStatus(rldTrainPayload, `正在按优先级取数：${getSourcePriorityHint()}`);
    const payload = await callTrainApi("/api/rld-train/init", body, "POST", "正在加载融立得缠论训练...");
    renderTrainPayload(payload, payload.message || "缠论训练已加载");
    return payload;
  }

  async function trainLoadSafe() {
    try {
      return await trainLoad();
    } catch (e) {
      showToast(`缂犺璁粌鍔犺浇澶辫触锛?{e.message}`, { record: false });
      if ((e.message || "").includes("离线分笔读取失败")) {
        const goSettings = window.confirm("离线分笔读取失败。是否现在跳转到“设置 > 共享”手动补充分笔路径？");
        if (goSettings) {
          rldSetTopTab("settings");
          rldSetSettingsHubTab("shared");
        }
      }
      throw e;
    }
  }

  async function trainStep(levelToken, forward) {
    try {
      const payload = await callTrainApi(forward ? "/api/rld-train/step" : "/api/rld-train/back", { level: levelToken, n: 1 }, "POST", forward ? "正在训练步进..." : "正在训练后退...");
      renderTrainPayload(payload, payload.message || (forward ? "训练步进成功" : "训练后退成功"));
    } catch (e) {
      showToast(`${forward ? "步进" : "后退"}失败：${e.message}`, { record: false });
    }
  }

  async function trainTrade(levelToken, side) {
    try {
      const payload = await callTrainApi("/api/rld-train/trade", { level: levelToken, side }, "POST", side === "buy" ? "正在执行买入..." : "正在执行卖出...");
      renderTrainPayload(payload, payload.message || "训练交易已执行");
    } catch (e) {
      showToast(`训练交易失败：${e.message}`, { record: false });
    }
  }

  function bindTrainButtons() {
    const bind = (id, fn) => {
      const el = $(id);
      if (!el || el.dataset.boundExt === "1") return;
      el.dataset.boundExt = "1";
      el.onclick = fn;
    };
    bind("trainBtnInit", () => trainLoadSafe());
    bind("trainBtnReset", async () => {
      try {
        const payload = await callTrainApi("/api/rld-train/reset", null, "POST", "正在重置缠论训练...");
        rldTrainPayload = null;
        renderTrainPayload(payload, payload.message || "缠论训练已重置");
      } catch (e) {
        showToast(`训练重置失败：${e.message}`, { record: false });
      }
    });
    bind("trainBtnGoSettings", () => {
      rldSetTopTab("settings");
      rldSetSettingsHubTab("rld");
    });
  }

  function wrapLoadButtonsForSourceHint() {
    const replayInit = $("btnInit");
    if (replayInit && replayInit.dataset.sourceWrapped !== "1" && typeof replayInit.onclick === "function") {
      const original = replayInit.onclick;
      replayInit.dataset.sourceWrapped = "1";
      replayInit.onclick = async function () {
        const el = $("dataSourceStatus");
        if (el) {
          el.textContent = `当前数据源尝试顺序：${getSourcePriorityHint()}`;
          el.title = "正在按优先级尝试数据源";
        }
        return original.apply(this, arguments);
      };
    }
    const rldInit = $("rldBtnInit");
    if (rldInit && rldInit.dataset.sourceWrapped !== "1" && typeof rldInit.onclick === "function") {
      const original = rldInit.onclick;
      rldInit.dataset.sourceWrapped = "1";
      rldInit.onclick = async function () {
        rldSetStatus(`正在按优先级尝试：${getSourcePriorityHint()}`, "busy");
        return original.apply(this, arguments);
      };
    }
  }

  function enhanceLoadButtonsFinal() {
    const replayInit = $("btnInit");
    if (replayInit && replayInit.dataset.sourceWrappedFinal !== "1" && typeof replayInit.onclick === "function") {
      const original = replayInit.onclick;
      replayInit.dataset.sourceWrappedFinal = "1";
      replayInit.onclick = async function () {
        const originalSetGlobalLoading = window.setGlobalLoading;
        if (typeof originalSetGlobalLoading === "function") {
          window.setGlobalLoading = function (visible, text) {
            const nextText = visible ? "正在加载复盘会话..." : text;
            return originalSetGlobalLoading.call(this, visible, nextText);
          };
        }
        try {
          return await original.apply(this, arguments);
        } finally {
          if (typeof originalSetGlobalLoading === "function") window.setGlobalLoading = originalSetGlobalLoading;
        }
      };
    }
    const rldInit = $("rldBtnInit");
    if (rldInit && rldInit.dataset.sourceWrappedFinal !== "1" && typeof rldInit.onclick === "function") {
      const original = rldInit.onclick;
      rldInit.dataset.sourceWrappedFinal = "1";
      rldInit.onclick = async function () {
        try {
          return await original.apply(this, arguments);
        } catch (e) {
          const useOfflineFirst = (sharedSettingsState.data_quality || "").startsWith("offline") || getSourcePriorityHint().startsWith("OfflineTXT");
          if (useOfflineFirst && String((e && e.message) || "").includes("离线")) {
            const goSettings = window.confirm("离线K线读取失败。是否现在跳转到“设置 > 共享”手动补充离线K线路径？");
            if (goSettings) {
              rldSetTopTab("settings");
              rldSetSettingsHubTab("shared");
            }
          }
          throw e;
        }
      };
    }
  }

  async function bootstrapRldTrainExtension() {
    await loadSharedSettings();
    wrapSystemSettingsFunctions();
    if (typeof renderSystemSettingsForm === "function" && isSystemSettingsOpen()) renderSystemSettingsForm();
    injectSharedSummaryIntoSettingsHub();
    mountTrainSettingsIntoHub();
    ensureRldSubtabs();
    bindTrainButtons();
    wrapLoadButtonsForSourceHint();
    enhanceLoadButtonsFinal();
    renderSharedSettingsSummary();
    await restoreTrainState();
  }

  window.addEventListener("resize", () => {
    if (rldSubtabState === "train") renderTrainPayload(rldTrainPayload);
  });

  bootstrapRldTrainExtension();
})();
"""
