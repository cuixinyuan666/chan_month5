FRONTEND_BODY = """\
<body>
  <div class="wrap">
    <div class="left">
      <div class="title">复盘 <span class="tip-icon" data-tip="Chan.py 缠论复盘交易系统"></span></div>
      <div id="dataSourceStatus" class="sourceStatus mono">当前数据源：未加载</div>
      <div id="leftContent" class="leftContent">
      <div id="chartToolsPanel" class="chartToolsPanel">
        <button id="btnFullscreen" class="fullscreen-btn" data-tip="切换图表区域全屏显示。">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg>
          全屏显示 (F11)
        </button>
        <button id="btnJudgeBsp" class="judge-bsp-btn" data-tip="手动检查买卖点（仅手动判定模式下可用）。" disabled>检查买卖点</button>
        <div id="toolbox" class="toolbox">
          <span class="label">画线工具箱</span>
          <button id="toolNone" type="button" class="active" data-tip="选择模式：可选中画线并使用“画线属性”进行编辑。">选择</button>
          <button id="toolHorizontalRay" type="button" data-tip="生成水平射线：点击图表在当前价位生成一条水平射线。">水平射线</button>
          <button id="toolBiRay" type="button" data-tip="笔端点射线：依次点击两个笔端点生成一条向右延伸的射线。再次点击可退出。">笔端点射线</button>
          <button id="toolLineProps" type="button" data-tip="先使用“选择”并点击某条画线，再点此按钮编辑粗细/颜色/线型。">画线属性</button>
        </div>
      </div>
      <div class="card" id="configCard">
        <div class="btnRow">
          <button id="btnChanSettingsOpen" data-tip="打开缠论逻辑配置面板，可调整笔、线段、中枢等算法。">缠论配置... <small>(L)</small></button>
          <button id="btnSettingsOpen" data-tip="打开图表显示设置面板，可调整主题、指标与绘制项。">图表显示设置... <small>(P)</small></button>
          <button id="btnSystemSettingsOpen" data-tip="打开系统配置面板，可统一维护快捷键。">系统配置... <small>(Shift+P)</small></button>
        </div>
        <div class="row cfg-editable">
          <label>代码</label>
          <input id="code" value="600340" />
          <span class="tip-icon" data-tip="输入6位数字代码"></span>
        </div>
        <div class="row cfg-editable"><label>开始日期</label><input id="begin" type="date" value="2018-01-01" /><span class="tip-icon" data-tip="复盘回放的起始日期。"></span></div>
        <div class="row cfg-editable"><label>结束日期</label><input id="end" type="date" value="" placeholder="可空" /><span class="tip-icon" data-tip="默认为空，表示截止当前日期。"></span></div>
        <div class="row cfg-editable"><label>初始资金</label><input id="cash" value="10000" /><span class="tip-icon" data-tip="模拟交易使用的初始资金，买入按钮会基于该资金全仓买入。"></span></div>
        <div class="row cfg-editable">
          <label>复权</label>
          <select id="autype">
            <option value="qfq">前复权</option>
            <option value="hfq">后复权</option>
            <option value="none">不复权</option>
          </select>
          <span class="tip-icon" data-tip="选择K线数据的复权方式。"></span>
        </div>
        <div class="btnRow">
          <button id="btnInit" data-tip="根据当前代码、日期区间、初始资金加载复盘会话。首次加载历史数据可能较慢。">加载会话 <small>(Ctrl+I)</small></button>
          <button id="btnReset" data-tip="清空当前会话并恢复到可重新配置的初始状态。">重新训练 <small>(Ctrl+R)</small></button>
          <button id="btnFinish" data-tip="结束当前训练，并可选择导出本次交易总结文件。" disabled>结束训练</button>
          <button id="btnExit" data-tip="尝试关闭当前页面。浏览器可能会拦截关闭操作。">退出</button>
          <button id="btnStep" data-tip="步进到下一根K线。若当前K线命中买卖点或 1382 提示，会合并为一个弹窗提示。" disabled>下一根K线 <small>(Space)</small></button>
        </div>
        <div class="stepNRow">
          <label for="stepN">步进数量 N</label>
          <span id="tipStepN" class="tip-icon" data-tip="设置连续步进或回退时使用的根数。遇到买卖点将以弹窗提示（自动消失）。"></span>
          <input id="stepN" type="number" min="1" step="1" value="5" />
          <div class="btnRow" style="width:100%; margin-top:4px;">
            <button id="btnStepN" data-tip="按步进数量 N 连续推进，若中途遇到买卖点则自动停止。" disabled>步进 N 根 <small>(Ctrl+Alt+N)</small></button>
            <button id="btnBackN" data-tip="按步进数量 N 回退，会自动重建到更早的状态。" disabled>后退 N 根 <small>(Ctrl+Alt+M)</small></button>
          </div>
        </div>
        <div class="row" style="margin:6px 0 4px 0;">
          <span class="muted">交易规则</span>
          <span class="tip-icon" data-tip="规则：单持仓、T+1、每步最多一笔。"></span>
        </div>
        <div class="btnRow" style="margin-top:6px;">
          <button id="btnBuy" data-tip="按当前收盘价使用全部可用现金买入，遵循单持仓和每步最多一笔规则。" disabled>买入（全仓） <small>(PageUp)</small></button>
          <button id="btnSell" data-tip="按当前收盘价全部卖出，若受 T+1 约束则按钮不可用。" disabled>卖出（全量） <small>(PageDown)</small></button>
        </div>
      </div>
      <div class="card">
        <div class="title" style="margin:0 0 12px 0; display:flex; justify-content:space-between; align-items:center;">
          历史记录
          <button id="btnMsgHistory" style="padding:2px 6px; font-size:12px; width:auto;">历史记录</button>
        </div>
        <div class="muted">账户状态信息已迁移到“当前持仓状态”浮窗（仅持仓时显示）。</div>
      </div>
      </div>
    </div>
    <div class="resizer" id="resizer"></div>
    <div class="right">
      <div id="modalOverlay" class="modal-overlay">
        <div id="chanSettingsModal" class="settingsModal" aria-hidden="true">
          <div class="panel">
            <div class="settingsTitle">
              缠论配置
              <button id="btnChanSettingsClose" style="margin:0; padding:4px 8px;">&times;</button>
            </div>
            <div id="chanSettingsContent">
              <!-- Generated by JS -->
            </div>
            <div class="settingsActions">
              <button id="btnChanSettingsReset">恢复默认</button>
              <button id="btnChanSettingsSave">保存并应用 (S)</button>
            </div>
          </div>
        </div>
        <div id="settingsModal" class="settingsModal" aria-hidden="true">
          <div class="panel">
            <div class="settingsTitle">
              图表显示设置
              <button id="btnSettingsClose" style="margin:0; padding:4px 8px;">&times;</button>
            </div>
            <div id="settingsContent">
              <!-- Generated by JS -->
            </div>
            <div class="settingsActions">
              <button id="btnSettingsReset">恢复默认</button>
              <button id="btnSettingsSave">保存并应用 (S)</button>
            </div>
          </div>
        </div>
        <div id="systemSettingsModal" class="settingsModal" aria-hidden="true">
          <div class="panel">
            <div class="settingsTitle">
              系统配置
              <button id="btnSystemSettingsClose" style="margin:0; padding:4px 8px;">&times;</button>
            </div>
            <div id="systemSettingsContent">
              <!-- Generated by JS -->
            </div>
            <div class="settingsActions">
              <button id="btnSystemSettingsReset">恢复默认</button>
              <button id="btnSystemSettingsSave">保存并应用 (S)</button>
            </div>
          </div>
        </div>
      </div>
      
      <div id="toastContainer"></div>
  <div id="tipContent" class="tip-content"></div>

      <div id="msgHistoryModal" class="msgHistoryModal" aria-hidden="true">
        <div class="panel">
          <div class="settingsTitle">
            消息历史记录
            <button id="btnMsgHistoryClose" style="margin:0; padding:4px 8px;">&times;</button>
          </div>
          <div id="msgHistoryList" class="msgHistoryList"></div>
          <div class="settingsActions">
            <button id="btnMsgHistoryClear">清空记录</button>
            <button id="btnMsgHistoryOk">确 认</button>
          </div>
        </div>
      </div>
      <div id="bspPrompt" class="bspPrompt" aria-hidden="true">
        <div class="panel">
          <div id="bspPromptTitle" class="bspPromptTitle">检测到当前K线出现买卖点</div>
          <div id="bspPromptBody" class="bspPromptBody"></div>
          <div class="bspPromptHint">只能按 Enter 或左键点击确认，确认前将禁止步进到下一根K线。</div>
          <div class="bspPromptActions">
            <button id="bspPromptConfirm" type="button">确认（Enter / 左键）</button>
          </div>
        </div>
      </div>
      <!-- 交易结算弹窗 -->
      <div id="settlementModal" class="settlementModal" aria-hidden="true">
        <div class="panel">
          <div id="settlementTitle" class="settlementTitle">交易结算</div>
          <div id="settlementBody" class="settlementBody"></div>
          <div class="settlementActions">
            <button id="btnSettlementClose">确 认</button>
          </div>
        </div>
      </div>
      <div id="globalLoading" class="globalLoading" aria-hidden="true">
        <div class="panel">
          <div class="spinner"></div>
          <div id="globalLoadingText">正在加载数据...</div>
        </div>
      </div>

      <!-- 交易状态悬浮窗 -->
      <div id="tradeStatusOverlay" class="tradeStatusOverlay" style="display: none;">
        <div class="tradeStatusTitleBar">
          <div class="tradeStatusTitle"><span class="tradeStatusDot"></span><span>当前持仓状态</span></div>
          <div class="tradeStatusActions">
            <button id="btnTradeStatusMin" class="tradeStatusMiniBtn" type="button">-</button>
            <button id="btnTradeStatusMax" class="tradeStatusMiniBtn" type="button">+</button>
          </div>
        </div>
        <div class="tradeStatusBody">
          <div class="tradeStatusGrid">
            <div class="tsItem"><label>持仓时间</label><span id="ts_hold_bars">-</span></div>
            <div class="tsItem"><label>持仓股数</label><span id="ts_pos">-</span></div>
            <div class="tsItem"><label>买入价格</label><span id="ts_buy_price">-</span></div>
            <div class="tsItem"><label>当前价格</label><span id="ts_curr_price">-</span></div>
            <div class="tsItem"><label>持仓盈亏</label><span id="ts_pnl">-</span></div>
            <div class="tsItem"><label>盈亏比例</label><span id="ts_pnl_pct">-</span></div>
            <div class="tsItem"><label>可用现金</label><span id="ts_cash">-</span></div>
            <div class="tsItem"><label>总资产</label><span id="ts_equity">-</span></div>
            <div class="tsItem"><label>总盈亏</label><span id="ts_total_pnl">-</span></div>
          </div>
        </div>
        <div class="tradeStatusResizeHandle"></div>
      </div>

      <canvas id="chart"></canvas>
    </div>
  </div>

"""
