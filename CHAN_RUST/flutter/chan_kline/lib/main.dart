import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/chan_bridge.dart';
import 'data/mobile_data_root.dart';
import 'data/telegram_data_source.dart';
import 'data/telegram_tick_source.dart';
import 'ui/mobile/android_shell.dart';
import 'compute/chip_profile_compute.dart';
import 'compute/tick_dist_profile_compute.dart';
import 'compute/class1_bs_compute.dart';
import 'compute/class2_bs_compute.dart';
import 'compute/class_n_bs_compute.dart';
import 'compute/bs_verdict_compute.dart';
import 'compute/zs_signal_compute.dart';
import 'compute/k1_bar_view_compute.dart';
import 'history/app_debug_snapshot.dart';
import 'history/audit_probe_snapshot.dart';
import 'history/msg_history.dart';
import 'ml/ml_bsp_labeler.dart';
import 'ml/ml_bsp_sample.dart';
import 'ml/ml_bsp_sampler.dart';
import 'ml/ml_dataset_split.dart';
import 'ml/ml_experience_trainer.dart';
import 'ml/ml_feature_schema.dart';
import 'ml/ml_label_config.dart';
import 'ml/ml_session_controller.dart';
import 'ml/ml_split_config.dart';
import 'ml/ml_workbench.dart';
import 'ml/ml_xgb_trainer.dart';
import 'backtest/backtest_link.dart';
import 'backtest/backtest_run.dart';
import 'backtest/order_models.dart';
import 'backtest/signal_event.dart';
import 'backtest/strategy_config.dart';
import 'backtest/strategy_trade_round.dart';
import 'backtest/backtest_step_harness.dart';
import 'backtest/backtest_workbench.dart';
import 'backtest/condition_ast.dart';
import 'backtest/trade_clock.dart';
import 'backtest/chan_event_store.dart';
import 'backtest/chart_line_store.dart';
import 'backtest/condition_indicators.dart';
import 'app/background_keep_alive.dart';
import 'settings/interaction_mode_store.dart';
import 'settings/peer_sync_settings_store.dart';
import 'sync/peer_sync_service.dart';
import 'ui/settings_panel_widgets.dart';
import 'ui/peer_sync_dialog.dart';
import 'ui/telegram_settings_dialog.dart';
import 'ui/ticks_full_upload_panel.dart';
import 'models/zs_frame.dart';
import 'models/buy1_frame.dart';
import 'models/sell1_frame.dart';
import 'models/buy2_frame.dart';
import 'models/sell2_frame.dart';
import 'models/buy_n_frame.dart';
import 'models/sell_n_frame.dart';
import 'models/kline_bar.dart';
import 'models/tick_quality.dart';
import 'models/k0_confirm_signal.dart';
import 'models/bar_crosshair_feature.dart';
import 'models/bar_feature_lookup.dart';
import 'models/k0_line.dart';import 'models/k1_bar_view.dart';
import 'models/chart_indicator.dart';
import 'models/chip_config.dart';
import 'models/tick_dist_config.dart';
import 'models/kline_combine_frame.dart';
import 'models/pre_first_fractal_mode.dart';
import 'models/level_models.dart';
import 'models/k1_analysis.dart';
import 'models/kline_combine_bundle.dart';
import 'settings/chip_settings_store.dart';
import 'settings/telegram_settings_store.dart';
import 'settings/math_indicator_settings_store.dart';
import 'settings/indicator_search_last_result_store.dart';
import 'settings/indicator_search_settings_store.dart';
import 'settings/level_window_settings_store.dart';
import 'indicator_search/search_verdict_views.dart';
import 'widgets/indicator_search_dialog.dart';
import 'widgets/key_point_stats_dialog.dart';
import 'models/math_indicator_config.dart';
import 'models/trend_model_config.dart';
import 'widgets/datetime_picker_dialog.dart';
import 'widgets/edge_control_panel.dart';
import 'widgets/kline_chart.dart';
import 'widgets/chart_sync_controller.dart';
import 'chart/level_window_layout.dart';
import 'widgets/level_chart_grid.dart';
import 'widgets/level_window_settings_dialog.dart';
import 'widgets/crosshair_tooltip_panel.dart';
import 'widgets/crosshair_tooltip_bridge.dart';
import 'widgets/kline_axis_format.dart';
import 'widgets/yin_yang_mark.dart';
import 'widgets/yin_yang_native_overlay.dart';
import 'widgets/test_ohlc_editor_dialog.dart';
import 'widgets/tick_draw_board.dart';
import 'window_work_area.dart';
import 'robot_verify/robot_verify_app.dart';
import 'robot_verify/robot_verify_paths.dart';
import 'step_freeze/step_freeze_merger.dart';
import 'step_freeze/step_freeze_session_state.dart';
import 'agent_api/agent_api_host.dart';
import 'agent_api/agent_api_server.dart';
import 'agent_api/agent_data_export_runner.dart';
import 'agent_api/agent_backtest_json.dart';
import 'agent_api/agent_config_key.dart';
import 'agent_api/agent_task.dart';
import 'agent_api/indicator_label_map.dart';
import 'indicator_search/indicator_search_job.dart';
import 'indicator_search/search_core.dart';
import 'package:chan_kline/theme/app_palette.dart';
import 'package:chan_kline/theme/theme_settings_store.dart';
import 'package:chan_kline/theme/theme_chooser.dart';

const _robotVerifyDefine = bool.fromEnvironment('ROBOT_VERIFY');
const _robotVerifySuiteDefine = String.fromEnvironment(
  'ROBOT_VERIFY_SUITE',
  defaultValue: 'jiyou_keypoint_20261001',
);
const _chanKlineRootDefine = String.fromEnvironment('CHAN_KLINE_ROOT');

bool _robotVerifyEnabled() =>
    _robotVerifyDefine ||
    Platform.environment['CHAN_ROBOT_VERIFY'] == '1' ||
    RobotVerifyPaths.sessionAuthorized(
      klineRoot: Platform.environment['CHAN_KLINE_ROOT'] ?? _chanKlineRootDefine,
    );

String _robotVerifySuite() {
  final fromEnv = Platform.environment['CHAN_ROBOT_VERIFY_SUITE'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final fromSession = readSuiteIdFromSession(
    klineRoot: Platform.environment['CHAN_KLINE_ROOT'] ?? _chanKlineRootDefine,
  );
  if (fromSession != null && fromSession.isNotEmpty) return fromSession;
  return _robotVerifySuiteDefine;
}

String _chanKlineRoot() =>
    Platform.environment['CHAN_KLINE_ROOT'] ?? _chanKlineRootDefine;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先把主题偏好读回来（深色/浅色/护眼），第一帧就用对的配色
  AppThemeController.instance.loadFromDisk();
  if (_robotVerifyEnabled()) {
    final klineRoot = _chanKlineRoot();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      final opts = WindowOptions(
        size: Size(480, 420),
        center: true,
        title: '机器人验证',
        titleBarStyle: TitleBarStyle.normal,
        backgroundColor: AppPalette.canvasBg,
      );
      await windowManager.waitUntilReadyToShow(opts, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }
    runApp(
      RobotVerifyApp(
        suiteId: _robotVerifySuite(),
        klineRoot: klineRoot,
      ),
    );
    return;
  }
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: AppPalette.rgb(0x00000000),
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppPalette.canvasBg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }
  // 方案B：Flutter 层号彻底改（structure 0 起编）
  MsgHistory.instance.appendPlanBLayerRemap();
  // 命名变更追踪：笔/线段 → K0连线/K1连线；中枢/买卖点口径见 appendZSSplitNormalOverSeg
  MsgHistory.instance.appendNamingRename();
  // 新特性追踪：构建中合并框（虚线），便于调试时从历史记录追溯口径演进
  MsgHistory.instance.appendBuildingCombineFrame();
  // 画线口径：构建中虚线尾端取区间内首次方向极值所在 K0（全层同构）
  MsgHistory.instance.appendBuildingDashTailFirstExtreme();
  // 展示轨动态 KN 合并框：冻+进行中重算，永久结构不回写
  MsgHistory.instance.appendDisplayTrackDynamicKnCombine();
  // 主图「KN合并」拆出「KN线」指标（合并框 / 淡实体线分开控制）
  MsgHistory.instance.appendKnSplit();
  // 主图键盘交互：方向键←/→（十字线态=十字线左右移；非十字线态=步退/步进）
  MsgHistory.instance.appendKeyboardNav();
  // 展示轨动态分型判断副图（全层同构）
  MsgHistory.instance.appendDisplayTrackFractalJudgment();
  // Kn中枢判断/确认；对象=未确认结构（非新芽）
  MsgHistory.instance.appendKnZsJudgeConfirm();
  MsgHistory.instance.appendFxZsJudgeConfirmTarget();
  // 副图十字 as-of：确认/极点距/截断与成交量/判断同构
  MsgHistory.instance.appendSubChartCrosshairAsOf();
  // 主图中枢十字 as-of（消费 Rust zs_* JSON）
  MsgHistory.instance.appendZSCrosshairAsOf();
  // 删除跨段中枢；原生统一为 Kn中枢；放弃 Auto
  MsgHistory.instance.appendZSSplitNormalOverSeg();
  // 中枢确定/不确定虚实线（对齐动态Kn）
  MsgHistory.instance.appendZSSureDashFrames();
  // 主图层色：同层合并/连线/中枢同色
  MsgHistory.instance.appendMainLevelUnifiedColors();
  // 主图命名/层序 + 副图顶底色自定义
  MsgHistory.instance.appendMainZsRenameOrderAndFxColors();
  // K0中枢命名纠偏 + 单段雏形
  MsgHistory.instance.appendK0ZsRenameAndPrototype();
  MsgHistory.instance.appendZsSingleSeedIsomorphic();
  // ZG/ZD 常见命名 + Kn一类BS
  MsgHistory.instance.appendBuy1AndZgZdCommonNaming();
  MsgHistory.instance.appendBuy2Class2Naming();
  MsgHistory.instance.appendBuyNClass3PlusNaming();
  MsgHistory.instance.appendBsOnlineVerdict();
  MsgHistory.instance.appendPipelineStateSession();
  MsgHistory.instance.appendIncrementalLookup();
  MsgHistory.instance.appendSessionAsOfSnapshot();
  // Kn相邻比例 + Kn步进节奏（节奏已迁主图）
  MsgHistory.instance.appendAdjacentRatioAndStepRhythm();
  MsgHistory.instance.appendStepRhythmToMainAndTipCats();
  MsgHistory.instance.appendStepRhythmHoldBeforeChildReopen();
  // Kn连线斜率副图（全层同构；复用比例出现链）
  MsgHistory.instance.appendKnLineSlope();
  // 主图 K{n}三极平行线 / K{n}顶底对弦线
  MsgHistory.instance.appendKnFxExtendLines();
  // 主图无脑买入线段（相邻两段价格区间完全分开）
  MsgHistory.instance.appendKnWnmrSegment();
  // 主图 Kn趋势线（段内支撑/压力）
  MsgHistory.instance.appendKnTrendLine();
  // 主图 K{n}底极贴合线 / K{n}顶极贴合线
  MsgHistory.instance.appendKnFxPoleSnug();
  // 主图 Kn均线 / Kn通道 + MACD/BOLL/RSI/KDJ/Demark
  MsgHistory.instance.appendKnTrendModel();
  MsgHistory.instance.appendKnMathClassicIndicators();
  // 主图 Kn回归通道（父层连线绑定；已接入冻结仓/回测 MAIN.Kn.REGRESS.* / 十字读数）
  MsgHistory.instance.appendKnRegressionChannel();
  // 主图 Kn唐奇安通道（经典海龟口径；已接入冻结仓/回测 MAIN.Kn.DONCHIAN.* / 十字读数）
  MsgHistory.instance.appendKnDonchianChannel();
  MsgHistory.instance.appendKnDivergenceIndicators();
  MsgHistory.instance.appendDiverLineSlopeAsciiKey();
  MsgHistory.instance.appendTickK0NativePeriod();
  // 展示轨：动态KN当确认段画虚线；确认优先纠正/改实线
  MsgHistory.instance.appendDisplayTrackDynamicKnBuildingLines();
  // 种子框 / 第一条虚线限制 / 种子包含截断（全层同构，常驻历史）
  MsgHistory.instance.appendSeedBoxFirstSeg();
  MsgHistory.instance.appendSeedFirstDashRules();
  MsgHistory.instance.appendSeedContainTruncation();
  // test 自定义 OHLC：前端编辑 → custom.ohlc.csv 直读上图
  MsgHistory.instance.appendTestCustomOhlc();
  // 智能体长期记忆：Task Log + test 验收口径（a_Data/test）
  MsgHistory.instance.appendAgentLongTermMemory();
  // 确认执行门禁 + 演示白话 + 接任务必读
  MsgHistory.instance.appendAgentConfirmExecuteGate();
  // 桌面：工作区全屏不盖任务栏；tooltip 分隔线贴边框
  MsgHistory.instance.appendDesktopWorkAreaAndTooltipSep();
  MsgHistory.instance.appendAndroidBundledDataRoot();
  MsgHistory.instance.appendAndroidMobileLayout();
  MsgHistory.instance.appendAndroidTouchUiAndBacktestSplit();
  MsgHistory.instance.appendDualPlatformUiOptimization();
  MsgHistory.instance.appendTickLoadYinYangAndTooltipPass();
  MsgHistory.instance.appendTickYinYangFullscreen();
  MsgHistory.instance.appendAuditProbeCopyButton();
  MsgHistory.instance.appendAuditFixBsZsFeature();
  MsgHistory.instance.appendAuditBatch2ProbePeakAsOf();
  // 主/副图指标 UI + Kn成交量归属口径
  MsgHistory.instance.appendIndicatorUiAndKnVolume();
  MsgHistory.instance.appendIndicatorMuteToggleAndVolReadout();
  MsgHistory.instance.appendKnVolumeCumulativeStep();
  // Kn笔数：Rust 分笔第4列真实笔数（任务前必读·常驻）
  MsgHistory.instance.appendKnTickCountRealTicks();
  // 分笔第4列显式 0 → 副图/笔数分布全无柱（勿默认成 1）
  MsgHistory.instance.appendTickCountZeroLiteral();
  // 主/副图启动默认=「K0指标」层全选（与选择栏同口径）
  MsgHistory.instance.appendDefaultIndicatorsK0();
  MsgHistory.instance.appendChipDistribution();
  MsgHistory.instance.appendChipToMainAndRatioInSubLevel();
  // 十字 tooltip 标签格式化：idx 统一命名 + 合并 GG/DD（全层同构）
  MsgHistory.instance.appendTooltipFormatting();
  // 合并 GG/DD 口径修正：GG/DD=组内原始区间极值，MG/MD=合并框框体高低点
  MsgHistory.instance.appendMergeRangeExtreme();
  // tooltip VOL/笔数 B/S/G + 应显尽显槽位（不按指标勾选）
  MsgHistory.instance.appendTooltipVolBsgAndSlots();
  // tooltip 成交量独立行 + Kn比例/节奏命名与多节奏动态行
  MsgHistory.instance.appendTooltipVolIndepAndRhythm();
  // K0 筹码峰/笔数峰 + 左侧笔数分布
  MsgHistory.instance.appendChipTickPeaksAndTickDist();
  // K0 分型确认/极点距/截断：统一读 k0/feat，禁 level==1 双轨误判
  MsgHistory.instance.appendK0FractalSourceUnified();
  // tooltip 四准则：asOf禁末态 / K0合并Rust / 上一中枢确认 / BS禁兜底
  MsgHistory.instance.appendTooltipFourRulesMlReady();
  // 机器学习：设置入口 + 图面使用权交接（不改 tip 生产）
  MsgHistory.instance.appendMlWorkbenchHandoff();
  // ML 特征数值化：*_code / labelInt / demark_marks；字符串汇总禁 flatten
  MsgHistory.instance.appendMlNumericFeatures();
  MsgHistory.instance.appendMlXgbTrainServe();
  // 交易条件变量目录阶段0（只登记可取值变量，不改缠论内核）
  MsgHistory.instance.appendTradeSignalCatalogPhase0();
  MsgHistory.instance.appendTradeClockContract();
  MsgHistory.instance.appendTradeCrossEval();
  MsgHistory.instance.appendTradeMiniLoop();
  MsgHistory.instance.appendTradeBacktestResult();
  MsgHistory.instance.appendTradeBacktestWorkbench();
  MsgHistory.instance.appendTradeConditionBuilder();
  MsgHistory.instance.appendTradeIndicatorVars();
  MsgHistory.instance.appendTradeChanEvents();
  MsgHistory.instance.appendTradeZsObjects();
  MsgHistory.instance.appendTradeDivergenceRelations();
  MsgHistory.instance.appendTradeChanComplete();
  MsgHistory.instance.appendTradeEventPulse();
  MsgHistory.instance.appendTradeSignalDisplay();
  MsgHistory.instance.appendTradeSignalTable();
  MsgHistory.instance.appendTradeFillPriceMode();
  MsgHistory.instance.appendTradeRoundLabel();
  MsgHistory.instance.appendTradeCatalogFull();
  MsgHistory.instance.appendChipPeakVars();
  MsgHistory.instance.appendChipPeakDerivedVars();
  MsgHistory.instance.appendP0TrustGates();
  MsgHistory.instance.appendCrossKnBsJoin();
  MsgHistory.instance.appendWorkbenchLayoutAndK0BarEvents();
  MsgHistory.instance.appendWorkbenchBelowCaptionAndClose();
  MsgHistory.instance.appendTdxProtocolTicks();
  MsgHistory.instance.appendK0BarJoinYinYangCenterPriceAxis();
  MsgHistory.instance.appendUiBsPickerSettings20260905();
  MsgHistory.instance.appendBsNAllClass20260905();
  MsgHistory.instance.appendCrossKnIndicatorJoin20260905();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    final opts = WindowOptions(
      // 隐藏系统标题文字与白底标题栏，自绘右上角三键
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: AppPalette.canvasBg,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setTitle('');
      // 先显示再铺满工作区（不盖任务栏；hidden 标题栏下原生 maximize 会盖住）
      await windowManager.show();
      await fillDesktopWorkArea();
      await windowManager.focus();
    });
  }
  // Windows 无障碍桥在 Tooltip/设置面板开关等场景会刷 AXTree 报错（引擎已知问题），
  // K 线桌面端不依赖读屏，直接关掉 Semantics 避免干扰排查。
  Widget app = const ChanKlineApp();
  if (Platform.isWindows) {
    app = ExcludeSemantics(child: app);
  }
  runApp(app);
}

class ChanKlineApp extends StatefulWidget {
  const ChanKlineApp({super.key});

  @override
  State<ChanKlineApp> createState() => _ChanKlineAppState();
}

class _ChanKlineAppState extends State<ChanKlineApp> {
  final _theme = AppThemeController.instance;

  @override
  void initState() {
    super.initState();
    _theme.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _theme.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 深色/浅色/护眼：整棵树跟着重建，绘图代码里的颜色都从 AppPalette 取，画布不会被漏掉
    final isDark = _theme.mode == AppThemeMode.dark;
    final brightness = isDark ? Brightness.dark : Brightness.light;
    return MaterialApp(
      title: 'CHAN_RUST K线',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppPalette.accent,
          brightness: brightness,
        ),
        scaffoldBackgroundColor: AppPalette.canvasBg,
        canvasColor: AppPalette.canvasBg,
        useMaterial3: true,
      ),
      home: const KlineHomePage(),
    );
  }
}

class KlineHomePage extends StatefulWidget {
  const KlineHomePage({super.key});

  @override
  State<KlineHomePage> createState() => _KlineHomePageState();
}

class _KlineHomePageState extends State<KlineHomePage>
    with WindowListener
    implements AgentApiHost {
  final _bridge = ChanBridge.instance;
  final _msgHistory = MsgHistory.instance;
  /// 层级分窗联动：所有窗共用同一份视口 / 主副比例 / 十字线 / as-of 缓存。
  /// 单图模式下不传给 KlineChart，行为与分窗上线前完全一致。
  final _chartSync = ChartSyncController();
  /// 步进序号：每次 `_stepIdx` 变化 +1，随 KlineChart 传入。
  /// 图表据此区分「步进」与「换股/换周期/重载」——只有步进才走
  /// 「保持最新 K 屏幕位置」的新口径（且需用户手动缩放/平移过）。
  int _stepSerial = 0;
  /// 「恢复布局」序号：点一次 +1，各窗视口复位并清除手动调整标记。
  int _resetViewSerial = 0;
  /// Phase 1.5：Rust PipelineState 会话句柄（Flutter 不存核心 state）
  ChanPipelineSession? _pipelineSession;
  /// 工作区全屏前的窗口矩形（还原用）
  Rect? _preWorkAreaBounds;
  DateTime _beginDate = _standardBeginDate;
  DateTime _endDate = _standardEndDate;

  List<String> _codes = [];
  String? _selectedCode;
  String _period = 'tick';
  String _dataRoot = '';
  List<KlineBar> _allBars = [];
  List<KlineCombineFrame> _combineFrames = [];
  List<K0ConfirmSignal> _k0ConfirmSignals = [];
  List<BarCrosshairFeature> _barFeatures = [];
  List<K0Line> _k0Lines = [];
  List<K1BarView> _k1BarViews = [];
  List<KlineCombineFrame> _k1CombineFrames = [];
  K1AnalysisBundle _k1Analysis = K1AnalysisBundle.empty();
  List<LevelBundle> _levels = [];
  List<ZSFrame> _zsK0Frames = [];
  List<Buy1Frame> _buy1K0Frames = [];
  List<Sell1Frame> _sell1K0Frames = [];
  List<Buy2Frame> _buy2K0Frames = [];
  List<Sell2Frame> _sell2K0Frames = [];
  List<BuyNFrame> _buyNK0Frames = [];
  List<SellNFrame> _sellNK0Frames = [];
  // 默认=选择栏「K0指标」层全选（主图 K0/K0合并/K0中枢/K0连线；副图同层）
  Set<MainChartIndicator> _mainIndicators = defaultMainIndicatorsK0();
  Set<SubChartIndicator> _subIndicators = defaultSubIndicatorsK0();
  // 层级分窗专用勾选：与单图完全分开，互不影响。
  // 默认每窗勾本层 Kn + 本层合并 + 本层连线，其余主图指标与副图一项不启用。
  Set<MainChartIndicator> _splitMainIndicators = <MainChartIndicator>{};

  /// 子窗口全屏：非空时只显示这一层，占满图表区；再点一次回到分窗网格。
  int? _splitFullscreenLevel;
  /// 当前是否为层级分窗模式（桌面、非筹码-only、设置开启）。
  bool get _splitActive =>
      !_useAndroidInteraction &&
      !_chipOnlyMode &&
      LevelWindowSettingsStore.enabled;
  Set<SubChartIndicator> _splitSubIndicators = <SubChartIndicator>{};
  /// 分窗指标是否已按当前层级初始化过（首次开分窗时铺默认）。
  bool _splitIndicatorsReady = false;
  int _stepIdx = -1; // -1 表示尚未步进
  bool _playing = false;
  /// 静默播放：右边界长按触发的播放不弹「自动播放」胶囊；中间区域播放仍弹。
  bool _silentPlay = false;
  Timer? _playTimer;
  /// 左边界长按：按住连续步退、松开即停。
  bool _stepBackHolding = false;
  Timer? _stepBackTimer;
  String? _error;
  bool _defaultK0Purged = false;
  String _defaultK0Policy = 'pending';
  bool _bootstrapping = false;
  bool _loadingChart = false;
  /// 分笔：加载中/刚进图时铺满屏幕太极；点一下或步进后收起。
  bool _tickYinYangCover = false;
  /// 太极图总开关（2026-11-13 用户明确）：默认关闭，资源保留，后续可按需开启。
  bool _yinYangEnabled = false;
  bool _runningToEnd = false;
  bool _cancelRunToEnd = false;
  bool _nativeYinYangActive = false;
  final YinYangNativeOverlay _runToEndYinYang = YinYangNativeOverlay();
  final ValueNotifier<String> _longOpHint = ValueNotifier<String>('');
  /// 计算库缺失/版本不对：中文停机，禁止继续算出另一套点。
  bool _libHalt = false;
  String? _libHaltMessage;
  bool _panelExpanded = false;
  int _panelEdge = 1; // 默认右贴边（设置按钮在右上）
  /// Android 设置抽屉局部刷新（开关即时反馈）
  StateSetter? _settingsSheetSetState;
  /// 是否走安卓交互（手势/壳层）；默认跟随系统，可手动覆盖。
  bool _useAndroidInteraction = InteractionModeStore.resolveUseAndroidLogic();
  bool? _interactionManualOverride = InteractionModeStore.manualOverride;
  late final BackgroundKeepAlive _keepAlive = BackgroundKeepAlive(
    onSessionActive: () =>
        _playing ||
        _runningToEnd ||
        _backtestPanelOpen ||
      _mlSession.isActive,
  );
  /// Agent API 服务器（仅在 agent 模式下启动；robot_verify 模式不启动）。
  AgentApiServer? _agentApiServer;
  /// 图表 RepaintBoundary key（用于智能体验证截图）。
  final GlobalKey _chartRepaintKey = GlobalKey();
  /// 启动时刻（用于智能体验证计算运行时长）。
  late final DateTime _startedAt = DateTime.now();
  /// 截断监察：开=当前口径；关=添加截断前旧行为（暴力反转被吸收）
  bool _truncationCheck = true;
  /// 层级早生成动态单元：开=每层首个单元在父层首确认当根以动态态出现；
  /// 关=经典口径（等引擎自己攒够输入）。默认开，可在设置里切换。
  bool _earlyDynamicUnit = true;
  /// 首分型前合并框口径：种子框=不合并 / 高高（默认）/ 低低。
  /// 只影响首分型前那段合并框的绘制与 tooltip 的 MG/MD，不动其它结构。
  PreFirstFractalMode _preFirstFractalMode = PreFirstFractalMode.defaultMode;
  /// 构建中合并框（虚线）开关：开=末组合并画虚线；关=全部实线（默认开）
  bool _showBuildingDash = true;
  /// 分笔画板：只在 TEST 股票设置中打开，编辑 K0 后自动生成上层窗口。
  bool _tickDrawBoardOpen = false;
  TickDrawBoardModel? _tickDrawBoard;
  KlineCombineBundle? _tickDrawBundle;
  /// 筹码分布配置（落盘 .chan_chip_config.json）
  ChipConfig _chipConfig = const ChipConfig();
  /// 笔数分布配置（主图左侧；同 JSON 嵌套 tickDist）
  TickDistConfig _tickDistConfig = const TickDistConfig();
  TelegramSettings _telegramSettings = const TelegramSettings();
  /// 本会话是否允许筹码/笔数依赖（弹窗选「不继续」后关掉，不改落盘）
  bool _chipTickDepsAllowed = true;
  /// 本会话是否画笔数分布（「分笔笔数为 0」弹窗专用）
  bool _tickDistSessionAllowed = true;

  ChipConfig get _sessionChipConfig => _chipTickDepsAllowed
      ? _chipConfig
      : _chipConfig.copyWith(enabled: false, peakLineEnabled: false);

  TickDistConfig get _sessionTickDistConfig => _tickDistSessionAllowed
      ? _tickDistConfig
      : _tickDistConfig.copyWith(enabled: false, peakLineEnabled: false);

  Set<SubChartIndicator> get _sessionSubIndicators {
    if (_chipTickDepsAllowed) return _subIndicators;
    return _subIndicators
        .where((e) => e.kind != SubIndicatorKind.tickCount)
        .toSet();
  }

  /// 分窗副图勾选（同 [_sessionSubIndicators] 的依赖过滤，但走分窗专用集合）。
  Set<SubChartIndicator> get _sessionSplitSubIndicators {
    if (_chipTickDepsAllowed) return _splitSubIndicators;
    return _splitSubIndicators
        .where((e) => e.kind != SubIndicatorKind.tickCount)
        .toSet();
  }

  String _tickSourceFor(String code) => code == 'test' ? 'file' : 'protocol';

  bool get _useTelegramDaily =>
      _telegramSettings.telegramEnabled &&
      _period == 'day' &&
      _selectedCode != 'test';

  /// 需要分笔的周期（分笔 + 各分钟级）；日线及以上不需要。
  static bool _needsTickData(String period) {
    const noTick = {
      'day',
      '3d',
      'week',
      'month',
      '3mon',
      '6mon',
      '9mon',
      '12mon',
      'quarter',
      'year',
      '3y',
      '6y',
    };
    return !noTick.contains(period);
  }

  /// 从 Telegram 预取分笔到本地缓存（命中后 protocol 不再联网）。
  Future<bool> _prefetchTelegramTicks(String code) async {
    if (!_telegramSettings.telegramEnabled ||
        !_needsTickData(_period) ||
        code == 'test') {
      return false;
    }
    try {
      final ts = TelegramTickSource(
        settings: _telegramSettings,
        cacheRoot: Directory(_dataRoot),
      );
      final ok = await ts.ensureTicks(
        code: code,
        begin: _beginDate,
        end: _endDate,
      );
      if (!ok) {
        _msgHistory.append('Telegram 分笔部分包缺失，剩余日期将走通达信');
      }
      return ok;
    } catch (e) {
      _msgHistory.append('Telegram 分笔不可用，回退通达信：$e');
      return false;
    }
  }

  Future<void> _openTelegramSettings({bool closeSettingsSheet = false}) async {
    if (closeSettingsSheet && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    final next = await showTelegramSettingsDialog(
      context,
      _telegramSettings,
      onUpdateTicksNow: () => _triggerTicksDailyUpdate(),
    );
    if (next == null || !mounted) return;
    setState(() => _telegramSettings = next);
    await TelegramSettingsStore.save(next);
    _msgHistory.append(
      next.telegramEnabled
          ? '已启用 Telegram 日线数据源（分笔仍走通达信/本地缓存）'
          : '已切回通达信协议数据源',
    );
  }

  bool _closePromptOpen = false;

  /// 关主图：下载还在时，问要不要留在托盘里继续。
  Future<void> _requestCloseApp() async {
    if (_closePromptOpen) return;
    final running = (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
        await ticksUploadSupervisorAlive(_fullUploadDataRoot());
    if (!mounted) return;
    if (!running) {
      await windowManager.destroy();
      return;
    }
    _closePromptOpen = true;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全市场分笔还在下载'),
        content: const Text(
          '关闭主图后，下载可以留在任务栏托盘里继续。\n'
          '托盘上能看到进度，右键可以暂停或结束本机任务。',
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'stop'),
            child: const Text('停止下载并关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'tray'),
            child: const Text('托盘继续并关闭主图'),
          ),
        ],
      ),
    );
    _closePromptOpen = false;
    if (!mounted || action == null) return;
    if (action == 'stop') {
      final repo = RobotVerifyPaths.resolveRepoRoot(klineRoot: _chanKlineRoot());
      final jobDir = (repo == null || repo.isEmpty)
          ? ''
          : '$repo${Platform.pathSeparator}a_Data${Platform.pathSeparator}agent_live';
      await stopTicksUploadTask(
        dataRoot: _fullUploadDataRoot(),
        jobDir: jobDir,
      );
    }
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    unawaited(_requestCloseApp());
  }

  /// 分笔缓存盘：优先可写的 G，其次 D，再其次当前数据根。
  ///
  /// 2026-11-09 补：原来只看 G 盘存不存在。PCB 的 G 盘随后出现文件系统损坏
  /// （缓存目录里全是乱码文件名、体积虚报成 2~4GB），预览「存在」照样通过，
  /// 结果整批任务空跑成 1 天残包。改为真写一个探针文件再读回来，
  /// 坏盘直接跳过，落到下一个盘。
  String _fullUploadDataRoot() {
    final roots = <String>[
      r'G:\chan_month5_data',
      r'D:\chan_month5_data',
      if (_dataRoot.isNotEmpty) _dataRoot,
      r'C:\chan_month5_data',
    ];
    for (final root in roots) {
      final drive = '${root.substring(0, 2)}\\';
      if (!Directory(drive).existsSync()) continue;
      if (!_dataRootUsable(root)) continue;
      return root;
    }
    return _dataRoot.isNotEmpty ? _dataRoot : r'C:\chan_month5_data';
  }

  /// 试写 + 读回 + 删除，任一步失败就判这个数据根不可用。
  bool _dataRootUsable(String root) {
    File? probe;
    try {
      final dir = Directory('$root\\local');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp = 'probe-${DateTime.now().microsecondsSinceEpoch}';
      probe = File('$root\\local\\.data_root_probe');
      probe.writeAsStringSync(stamp, flush: true);
      final back = probe.readAsStringSync().trim();
      probe.deleteSync();
      return back == stamp;
    } catch (_) {
      try {
        probe?.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  /// 从环境变量、当前目录、程序所在目录往上找登记脚本，避免工作目录一变就找不到仓库。
  String? _resolveFullUploadRepoRoot() {
    final sep = Platform.pathSeparator;
    bool hasScript(String root) {
      if (root.trim().isEmpty) return false;
      return File(
        '$root${sep}CHAN_RUST${sep}scripts${sep}register_ticks_full_upload.ps1',
      ).existsSync();
    }

    final env = Platform.environment['CHAN_REPO_ROOT']?.trim() ?? '';
    if (hasScript(env)) return env;

    final starts = <String>[
      Directory.current.path,
      File(Platform.resolvedExecutable).parent.path,
      _chanKlineRoot(),
    ];
    for (final start in starts) {
      if (start.trim().isEmpty) continue;
      var dir = Directory(start);
      for (var i = 0; i < 8; i++) {
        if (hasScript(dir.path)) return dir.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    final fallback = RobotVerifyPaths.resolveRepoRoot(klineRoot: _chanKlineRoot());
    if (fallback != null && hasScript(fallback)) return fallback;
    return null;
  }

  Future<String> _createFullTicksUploadTask(TelegramSettings draft) async {
    // 共享进度目录留空就用局域网默认目录，不再报「请先填写」
    final share = draft.shareDir.trim().isEmpty
        ? defaultTicksShareDir()
        : draft.shareDir.trim();
    final token = draft.botToken.trim();
    final chat = draft.chatId.trim();
    String finish(String msg) {
      _msgHistory.append(msg);
      return msg;
    }

    if (token.isEmpty || chat.isEmpty) {
      return finish('请先在电报设置里保存机器人令牌和聊天号');
    }

    final next = draft;
    setState(() => _telegramSettings = next);
    await TelegramSettingsStore.save(next);

    final repo = _resolveFullUploadRepoRoot();
    if (repo == null || repo.isEmpty) {
      return finish('找不到仓库，无法登记本机上传任务');
    }
    final sep = Platform.pathSeparator;
    final scriptsDir = '$repo${sep}CHAN_RUST${sep}scripts';
    final regPs1 = File('$scriptsDir${sep}register_ticks_full_upload.ps1');
    if (!regPs1.existsSync()) {
      return finish('找不到登记脚本：${regPs1.path}');
    }

    final liveDir = Directory('$repo${sep}a_Data${sep}agent_live');
    if (!liveDir.existsSync()) {
      liveDir.createSync(recursive: true);
    }
    final jobPath = '${liveDir.path}${sep}ticks_full_upload_job.json';
    final resultPath =
        '${liveDir.path}${sep}ticks_full_upload_register_result.json';
    final dataRoot = _fullUploadDataRoot();
    final aliveBefore = await ticksUploadSupervisorAlive(dataRoot);
    final jobFile = File(jobPath);
    String? previousJob;
    if (jobFile.existsSync()) {
      try {
        previousJob = await jobFile.readAsString();
      } catch (_) {}
    }
    final job = <String, dynamic>{
      'shareDir': share,
      'settingsPath': TelegramSettingsStore.settingsFilePath,
      'machineName': Platform.localHostname,
      'dataRoot': dataRoot,
      'repoRoot': repo,
      'scriptsDir': scriptsDir,
    };
    await jobFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(job),
    );
    final resultFile = File(resultPath);
    if (resultFile.existsSync()) {
      try {
        resultFile.deleteSync();
      } catch (_) {}
    }

    try {
      final run = await _runHiddenPowerShell(<String>[
        '-File',
        regPs1.path,
        '-JobPath',
        jobPath,
        '-ScriptsDir',
        scriptsDir,
        '-ResultPath',
        resultPath,
      ]);
      if (run.timedOut) {
        final still = await ticksUploadSupervisorAlive(dataRoot);
        if (aliveBefore || still) {
          return finish('登记超时。本机监视已在跑，没有再开一个。');
        }
        return finish('登记超时（超过 60 秒没有返回）。请再点一次；若托盘已有图标，说明已经在跑。');
      }
      var raw = '';
      if (resultFile.existsSync()) {
        raw = await resultFile.readAsString();
      }
      if (raw.trim().isEmpty) raw = run.stdout;
      final parsed = _extractJsonObject(raw);
      final code = '${parsed?['code'] ?? ''}';
      const keepJob = {'started', 'already_running', 'run_failed'};
      if (!keepJob.contains(code)) {
        await _restoreUploadJob(jobFile, previousJob);
      }
      final msg = await _describeUploadRegister(
        raw: raw,
        exitCode: run.code,
        stderr: run.stderr,
        dataRoot: dataRoot,
        repo: repo,
      );
      return finish(msg);
    } catch (e) {
      if (!await ticksUploadSupervisorAlive(dataRoot)) {
        await _restoreUploadJob(jobFile, previousJob);
      }
      return finish('登记失败：$e');
    }
  }

  Future<void> _restoreUploadJob(File jobFile, String? previous) async {
    try {
      if (previous == null) {
        if (jobFile.existsSync()) jobFile.deleteSync();
      } else {
        await jobFile.writeAsString(previous);
      }
    } catch (_) {}
  }

  /// 隐藏窗口跑 PowerShell，同时读完两路输出，避免编码错误把结果弄丢。
  Future<({int code, String stdout, String stderr, bool timedOut})>
      _runHiddenPowerShell(List<String> args) async {
    final proc = await Process.start(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        ...args,
      ],
      runInShell: false,
    );
    final outBytes = <int>[];
    final errBytes = <int>[];
    final outDone = proc.stdout
        .listen((chunk) => outBytes.addAll(chunk))
        .asFuture<void>();
    final errDone = proc.stderr
        .listen((chunk) => errBytes.addAll(chunk))
        .asFuture<void>();
    var timedOut = false;
    var code = -1;
    try {
      code = await proc.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      timedOut = true;
      try {
        proc.kill();
      } catch (_) {}
    }
    try {
      await outDone.timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await errDone.timeout(const Duration(seconds: 2));
    } catch (_) {}
    return (
      code: code,
      stdout: _decodeProcessText(outBytes),
      stderr: _decodeProcessText(errBytes),
      timedOut: timedOut,
    );
  }

  Future<String> _describeUploadRegister({
    required String raw,
    required int exitCode,
    required String stderr,
    required String dataRoot,
    required String repo,
  }) async {
    final map = _extractJsonObject(raw);
    if (map == null) {
      final extra = stderr.trim().isNotEmpty ? stderr.trim() : raw.trim();
      final short = extra.length > 180 ? extra.substring(0, 180) : extra;
      final why = short.isEmpty ? '脚本没有说明原因' : short;
      return '登记失败（退出码 $exitCode）。$why';
    }
    final code = '${map['code'] ?? ''}';
    final detail = '${map['message'] ?? ''}'.trim();
    final reported = map['exitCode'];
    final shownCode = reported is int ? reported : exitCode;
    switch (code) {
      case 'started':
        final alive = await _waitUploadSupervisor(dataRoot);
        if (alive) return '本机上传任务已登记，监视已在跑。';
        final log = _tailLocalLog(dataRoot);
        final stop = _uploadStopFlagPresent(dataRoot, repo);
        final extra = <String>[
          if (stop) '本机还有停止标记',
          if (log.isNotEmpty) '最近：$log',
        ].join('。');
        final tail = extra.isEmpty ? '' : '$extra。';
        return '计划任务已登记，启动命令已发出，但监视进程没有留住（退出码 $shownCode）。$tail';
      case 'already_running':
        return '本机监视已在跑。登录任务已更新，没有再开一个。';
      case 'run_failed':
        final runExit = map['runExit'] ?? shownCode;
        final why = detail.isEmpty ? '' : ' $detail';
        return '任务已登记，但启动失败（退出码 $runExit）。$why';
      case 'share_missing':
        final where = detail.isEmpty ? '路径为空' : detail;
        return '共享进度目录不存在或读不到：$where（退出码 $shownCode）';
      case 'no_pythonw':
        return '本机没有找到 pythonw，无法在不弹出黑框的情况下启动监视（退出码 $shownCode）。';
      case 'no_supervisor':
        return '找不到监视脚本（退出码 $shownCode）。${detail.isEmpty ? '' : ' $detail'}';
      case 'schtasks_create':
        final why = detail.isEmpty ? '' : ' $detail';
        return '登记计划任务失败（退出码 $shownCode）。$why';
      default:
        if (map['ok'] == true) {
          return '本机上传任务已登记。';
        }
        final why = detail.isEmpty ? '脚本没有说明原因' : detail;
        return '登记失败（退出码 $shownCode）。$why';
    }
  }

  Future<bool> _waitUploadSupervisor(String dataRoot) async {
    // conda 的 pythonw 起来可能要几秒，锁文件写在托盘之前。
    for (var i = 0; i < 24; i++) {
      if (await ticksUploadSupervisorAlive(dataRoot)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  bool _uploadStopFlagPresent(String dataRoot, String repo) {
    final sep = Platform.pathSeparator;
    final paths = <String>[
      '$dataRoot${sep}local${sep}stop.flag',
      '$repo${sep}a_Data${sep}agent_live${sep}stop.flag',
    ];
    for (final path in paths) {
      try {
        if (File(path).existsSync()) return true;
      } catch (_) {}
    }
    return false;
  }

  String _tailLocalLog(String dataRoot) {
    try {
      final log = File(
        '$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}supervisor.log',
      );
      if (!log.existsSync()) return '';
      final lines = log
          .readAsStringSync()
          .split(RegExp(r'\r?\n'))
          .where((e) => e.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) return '';
      final last = lines.last.trim();
      if (last.length <= 160) return last;
      return last.substring(last.length - 160);
    } catch (_) {
      return '';
    }
  }

  String _decodeProcessText(List<int> bytes) {
    if (bytes.isEmpty) return '';
    var nul = 0;
    for (final b in bytes) {
      if (b == 0) nul++;
    }
    final bom = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
    if (bom || nul * 4 > bytes.length) {
      final codes = <int>[];
      var i = bom ? 2 : 0;
      if (i == 0 && bytes.length.isOdd) {
        return utf8.decode(bytes, allowMalformed: true).trim();
      }
      for (; i + 1 < bytes.length; i += 2) {
        codes.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(codes).replaceAll('\u0000', '').trim();
    }
    return utf8.decode(bytes, allowMalformed: true).trim();
  }

  Map<String, dynamic>? _extractJsonObject(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.codeUnitAt(0) == 0xFEFF) text = text.substring(1).trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final obj = jsonDecode(text.substring(start, end + 1));
      if (obj is Map) return Map<String, dynamic>.from(obj);
    } catch (_) {}
    return null;
  }

  Timer? _ticksDailyTimer;
  String? _lastTicksDailyRun;

  File get _ticksDailyMarkFile =>
      File('${_dataRoot}${Platform.pathSeparator}.chan_ticks_daily_last.txt');

  void _startTicksDailyScheduler() {
    _ticksDailyTimer?.cancel();
    _ticksDailyTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_maybeAutoTicksDaily()),
    );
  }

  Future<void> _maybeAutoTicksDaily() async {
    if (!_telegramSettings.telegramEnabled || !_telegramSettings.autoTicksDaily) {
      return;
    }
    final now = DateTime.now();
    if (now.weekday >= 6) return;
    if (now.hour < 15 || (now.hour == 15 && now.minute < 35)) return;
    final today = '${now.year}-${now.month}-${now.day}';
    if (_lastTicksDailyRun == today) return;
    _lastTicksDailyRun = today;
    try {
      _ticksDailyMarkFile.writeAsStringSync(today, flush: true);
    } catch (_) {}
    await _triggerTicksDailyUpdate(auto: true);
  }

  Future<void> _triggerTicksDailyUpdate({bool auto = false}) async {
    try {
      final task = await AgentDataExportRunner.instance.startTicksDaily();
      _msgHistory.append(
        '${auto ? "自动" : "手动"}分笔日更已启动：${task.id}（目标日期由盘中/收盘规则自动判定）',
      );
    } catch (e) {
      _msgHistory.append('分笔日更启动失败：$e');
    }
  }
  /// 数学指标参数（均线/通道/MACD/BOLL/RSI/KDJ/Demark）
  MathIndicatorConfig _mathIndicatorConfig = const MathIndicatorConfig();
  /// 步进冻结仓（与机器人验证 `StepFreezeMerger` 同源）
  final StepFreezeSessionState _stepFreeze = StepFreezeSessionState();
  /// chip 分支：仅显示筹码分布，关闭所有缠论渲染（关=正常缠论+筹码可并存）
  final bool _chipOnlyMode = false;

  /// 副图 Kn类BS 错标叠加 X；对的不叠加
  bool _overlayBsVerdictWrong = true;

  /// 机器学习会话：true=主区挂 ML（不展示 K 线图）
  final MlSessionController _mlSession = MlSessionController();
  MlPreparePhase _mlPhase = MlPreparePhase.setup;
  List<MlBspSample> _mlSamples = [];
  MlRunReport? _mlReport;
  String? _mlError;
  String _mlProgressHint = '';
  MlSplitConfig _mlSplitConfig = const MlSplitConfig();
  MlLabelConfig _mlLabelConfig = const MlLabelConfig();
  /// 测试集已评估一次：禁止改比例重跑（须退出 ML 再进）
  bool _mlTestLocked = false;
  /// false=逻辑回归；true=XGB（Python 训 + Rust 推）
  bool _isXgbMode = false;
  XgbTrainParams _xgbParams = const XgbTrainParams();
  bool _forceXgbRetrain = true;
  final MlBspSampler _mlSampler = MlBspSampler();

  /// 策略回测工作台（条件树 + 指标变量 + 结构事件 + 确认中枢数值）
  bool _backtestPanelOpen = false;
  StrategyConfig _strategyConfig = const StrategyConfig();
  BacktestRun? _backtestRun;
  BacktestWorkbenchTab _btTab = BacktestWorkbenchTab.conditions;
  String? _btSelectedSignalId;
  String? _btSelectedTradeId;
  Set<String> _btHighlightIds = {};
  int? _btFocusBarIdx;
  int _btFocusEpoch = 0;
  /// 策略回测打开时：桌面=K 线占横向比例；手机竖屏=K 线占竖向比例
  double _backtestChartFraction = Platform.isAndroid ? 0.42 : 0.64;
  static const _minBacktestChartFraction = 0.22;
  static const _maxBacktestChartFraction = 0.85;
  bool _backtestSplitDragging = false;

  bool _indicatorSearchRunning = false;

  /// 计优（关键点位指标统计）运行中；仅置位/复位，不参与任何缠论计算。
  bool _keyPointStatRunning = false;

  /// 十字线 tooltip 桥：KlineChart 向本层广播「是否显示 + 当前行」，停靠为左侧子窗口。
  final CrosshairTooltipBridge _tooltipBridge = CrosshairTooltipBridge();
  /// 左侧停靠子窗口宽度（可拖拽调整）
  double _tooltipPanelWidth = 320.0;
  static const double _minTooltipPanelWidth = 200.0;
  static const double _maxTooltipPanelWidth = 600.0;
  bool _tooltipPanelDragging = false;
  double _backtestSplitDragStartY = 0;
  double _backtestSplitDragStartFraction = 0.58;

  /// 「在 K 线图查看」后缓存的可恢复寻优会话（排序/展开/身份）。
  /// 供回测台横幅上的「返回寻优结果」原样恢复，无需重新扫描。主图会话变更时清空。
  IndicatorSearchSessionSnapshot? _lastSearchSession;

  /// catalog 三类..N 类上限（至少 9；随会话观察到的更高类扩大）
  int get _maxBsClass => math.max(
        9,
        maxBuyNClassObserved(
          buyNHistoryByKn: _stepFreeze.buyNHistoryByKn,
          sellNHistoryByKn: _stepFreeze.sellNHistoryByKn,
        ),
      );

  bool get _busy =>
      _bootstrapping || _loadingChart || _runningToEnd || _libHalt;
  bool get _hasSession => _allBars.isNotEmpty;

  /// 其它周期加载用小转圈 + 取数时间范围提示；分笔走全屏太极层。
  Widget _chartLoadingIndicator() {
    final rangeText =
        '获取数据 ${_fmtDateTime(_beginDate)} ~ ${_fmtDateTime(_endDate)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 8),
        Text(
          rangeText,
          style: TextStyle(fontSize: 12, color: AppPalette.rgb(0xB3FFFFFF)),
        ),
      ],
    );
  }

  void _dismissTickYinYang() {
    if (!_tickYinYangCover) return;
    setState(() => _tickYinYangCover = false);
  }

  /// 分笔太极：正圆，直径=当前窗口高度。
  Widget _buildTickYinYangOverlay(BuildContext context) {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _loadingChart ? null : (_) => _dismissTickYinYang(),
        child: const YinYangFullscreenCover(),
      ),
    );
  }

  /// 一次性走完：Windows 用独立窗口转太极；其它平台仍用 Flutter 层。
  /// 正中心对齐当前窗口（含标题条），不再为进度条/边距人为下移。
  Widget _buildRunToEndYinYangOverlay(BuildContext context) {
    if (_nativeYinYangActive) {
      return const SizedBox.shrink();
    }
    return const Positioned.fill(
      child: IgnorePointer(
        child: YinYangFullscreenCover(
          heightFactor: 0.25,
          opacity: 0.5,
          dimBackground: false,
        ),
      ),
    );
  }

  /// 计算库对不上：全屏中文停机说明。
  Widget _buildLibHaltOverlay() {
    final msg = _libHaltMessage ?? '缠论计算库不可用。';
    return Positioned.fill(
      child: ColoredBox(
        color: AppPalette.rgb(0xF2121212),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Material(
              color: AppPalette.rgb(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '计算库对不上，已停机',
                      style: TextStyle(
                        color: AppPalette.rgb(0xFFFFA726),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      msg,
                      style: TextStyle(
                        color: AppPalette.rgb(0xFFE2E8F0),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '请覆盖为本次安装包里的那一份动态库，关掉软件再打开。不要混用旧备份，否则副图买卖点会对成另一套。',
                      style: TextStyle(color: AppPalette.rgb(0xFF94A3B8), fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 走完进度条 / 自动播放悬浮胶囊：只刷这行字，不刷整张图。
  /// 仅在「中间区域触发的播放」时显示；右/左边界长按的按住播放/步退为静默模式，不弹胶囊。
  Widget _buildLongOpBanner({double top = 44}) {
    if (!_runningToEnd && !_playing) return const SizedBox.shrink();
    if (_playing && _silentPlay) return const SizedBox.shrink();
    final total = _allBars.length;

    if (_runningToEnd) {
      return Positioned(
        left: 12,
        right: 12,
        top: top,
        child: Material(
          color: AppPalette.rgb(0xE61A1A1A),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _longOpHint,
                    builder: (_, hint, __) => Text(
                      hint.isEmpty ? '一次性走完，请稍候…' : hint,
                      style: TextStyle(color: AppPalette.rgb(0xFFFFFFFF), fontSize: 13),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _cancelRunToEnd = true,
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Center(
        child: Material(
          color: AppPalette.rgb(0xE61A1A1A),
          borderRadius: BorderRadius.circular(20),
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  '自动播放 ${_stepIdx + 1} / $total',
                  style: TextStyle(color: AppPalette.rgb(0xFFFFFFFF), fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int get _visibleCount => _stepIdx < 0 ? 0 : math.min(_stepIdx + 1, _allBars.length);
  List<KlineBar> get _visibleBars =>
      _visibleCount <= 0 ? const [] : _allBars.sublist(0, _visibleCount);

  /// 默认 tick=原生分笔一字线；其余先聚 1m 再升周期。
  static const _periods = <String, String>{
    'tick': '分笔',
    '1m': '1分钟',
    '5m': '5分钟',
    '15m': '15分钟',
    '30m': '30分钟',
    '60m': '60分钟',
    '2h': '2小时',
    '4h': '4小时',
    '1d': '1日',
    '3d': '3日',
    '1w': '1周',
    '1mon': '1月',
    '3mon': '3月',
    '6mon': '6月',
    '9mon': '9月',
    '12mon': '12月',
    '1y': '1年',
    '3y': '3年',
    '6y': '6年',
  };

  /// 002003 专用默认区间；其它代码回落到标准区间。
  static final _codeDefaultRanges = <String, (DateTime, DateTime)>{
    '002003': (
      DateTime(2004, 7, 19, 10, 47, 0),
      DateTime(2004, 7, 20, 13, 9, 0),
    ),
  };

  static final _standardBeginDate = DateTime(2024, 1, 1, 9, 30, 0);
  static final _standardEndDate = DateTime(2024, 12, 31, 15, 0, 0);

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    _keepAlive.attach();
    _loadInteractionMode();
    _loadMathIndicatorConfig();
    _loadLevelWindowSettings();
    IndicatorSearchSettingsStore.load();
    IndicatorSearchLastResultStore.load();
    _bootstrapApp();
  }

  /// 层级分窗本机偏好（开关 / 窗口数 / 每窗层级）。
  /// 默认关闭：读不到或没开时主界面与分窗上线前完全一致。
  Future<void> _loadLevelWindowSettings() async {
    await LevelWindowSettingsStore.load();
    if (!mounted) return;
    final early = LevelWindowSettingsStore.earlyDynamicUnit;
    if (early != _earlyDynamicUnit) {
      _earlyDynamicUnit = early;
      // 开关口径变了：旧会话按旧 opt 建，必须丢弃；冻结仓同步作废。
      _disposePipelineSession();
      _clearSessionFreezeHistory();
    }
    _preFirstFractalMode = LevelWindowSettingsStore.preFirstFractalMode;
    // 启动时若分窗已开启，按落盘层级铺默认：每窗只有本层 Kn，副图不勾。
    if (LevelWindowSettingsStore.enabled) _resetSplitIndicators();
    setState(() {});
  }

  Future<void> _loadInteractionMode() async {
    await InteractionModeStore.load();
    if (!mounted) return;
    setState(() {
      _interactionManualOverride = InteractionModeStore.manualOverride;
      _useAndroidInteraction = InteractionModeStore.resolveUseAndroidLogic();
    });
  }

  Future<void> _bootstrapApp() async {
    await _loadChipConfig();
    await _bootstrap();
    // 首帧后注册截图回调（需 _chartRepaintKey 已挂载）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registerScreenshotCallback();
    });
  }

  Future<void> _loadChipConfig() async {
    final both = await ChipSettingsStore.loadBoth();
    final tg = await TelegramSettingsStore.load();
    if (!mounted) return;
    setState(() {
      _chipConfig = both.$1;
      _tickDistConfig = both.$2;
      if (tg.botToken.isNotEmpty || tg.chatId.isNotEmpty) {
        _telegramSettings = tg;
      }
    });
    try {
      if (_ticksDailyMarkFile.existsSync()) {
        _lastTicksDailyRun = _ticksDailyMarkFile.readAsStringSync().trim();
      }
    } catch (_) {}
    _startTicksDailyScheduler();
  }

  /// 注册截图回调供智能体验证使用。
  void _registerScreenshotCallback() {
    if (!mounted) return;
    final renderBox = _chartRepaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (renderBox == null) return;
    AgentApiServer.bindScreenshot(() async {
      final image = await renderBox.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List() ?? <int>[];
    });
  }

  Future<void> _loadMathIndicatorConfig() async {
    final cfg = await MathIndicatorSettingsStore.load();
    if (!mounted) return;
    setState(() => _mathIndicatorConfig = cfg);
  }

  Future<void> _updateMathIndicatorConfig(MathIndicatorConfig cfg) async {
    setState(() => _mathIndicatorConfig = cfg);
    await MathIndicatorSettingsStore.save(cfg);
    // 参数变了：清空 Math/背驰冻结仓，再从 0 步进重冻到当前（避免旧参数残值）
    _stepFreeze.mathFreezeStore.clear();
    _stepFreeze.diverFreezeStore.clear();
    _stepFreeze.chipPeakStore.clear();
    _stepFreeze.diverRelationStore.clear();
    if (_hasSession && !_chipOnlyMode && _stepIdx >= 0) {
      _refreezeMathFromStart();
    }
  }

  /// 参数变更后：0..当前步逐K重冻 Math + 背驰序列。
  void _refreezeMathFromStart() {
    final end = _stepIdx;
    if (end < 0 || _allBars.isEmpty) return;
    // 背驰确认同拍：与中枢确认历史解耦，按相邻步 is_sure 跃迁合成
    Map<int, Set<int>> prevSureByKn = {};
    for (var i = 0; i <= end; i++) {
      final visible = _allBars.sublist(0, i + 1);
      try {
        final bundle = _bundleForVisible(visible);
        final curZs = collectZsFramesByKn(bundle);
        final confirmedByKn = <int, Set<int>>{};
        for (final e in curZs.entries) {
          final prevSure = prevSureByKn[e.key] ?? const <int>{};
          final nowSure = {
            for (final f in e.value)
              if (f.isSure) f.x1,
          };
          confirmedByKn[e.key] = nowSure.difference(prevSure);
          prevSureByKn[e.key] = nowSure;
        }
        _mergeMathFreeze(bundle, bars: visible, asOf: i);
        _mergeDivergenceFreeze(
          bundle,
          bars: visible,
          asOf: i,
          confirmedX1ByKn: confirmedByKn,
        );
      } catch (_) {
        break;
      }
    }
  }

  Future<void> _updateChipConfig(ChipConfig cfg) async {
    final stepChanged =
        (cfg.bucketStep - _chipConfig.bucketStep).abs() > 1e-12;
    final rankChanged = cfg.peakRankSpatialConfig.schemeId !=
            _chipConfig.peakRankSpatialConfig.schemeId ||
        cfg.peakRankVolumeConfig.schemeId !=
            _chipConfig.peakRankVolumeConfig.schemeId ||
        cfg.peakRankPureConfig.schemeId !=
            _chipConfig.peakRankPureConfig.schemeId;
    _panelUi(() => _chipConfig = cfg);
    await ChipSettingsStore.save(cfg, tickDist: _tickDistConfig);
    if (stepChanged || rankChanged) {
      _stepFreeze.chipPeakStore.clear();
      ChipProfileCompute.clearCache();
      TickDistProfileCompute.clearCache();
      if (_hasSession && _stepIdx >= 0 && _visibleBars.isNotEmpty) {
        _ingestAllChipPeakSchemes(
          asOf: _stepIdx,
          bars: _visibleBars,
          bucketStep: cfg.bucketStep,
        );
      }
    }
  }

  /// 一次性写入空间序 / 量级序 / 纯量级三套编号方案（按 scheme 分区，互不覆盖）。
  void _ingestAllChipPeakSchemes({
    required int asOf,
    required List<KlineBar> bars,
    required double bucketStep,
  }) {
    StepFreezeMerger.ingestAllChipPeakSchemes(
      state: _stepFreeze,
      asOf: asOf,
      bars: bars,
      chipConfig: _chipConfig,
    );
  }

  Future<void> _updateTickDistConfig(TickDistConfig cfg) async {
    _panelUi(() => _tickDistConfig = cfg);
    await ChipSettingsStore.save(_chipConfig, tickDist: cfg);
  }

  /// 设置面板与主界面同步刷新（底部抽屉内开关即时可见）
  void _panelUi(VoidCallback fn, {StateSetter? sheetSetState}) {
    setState(fn);
    (sheetSetState ?? _settingsSheetSetState)?.call(() {});
  }

  void _applyBucketStepFromSettings(
    String text, {
    StateSetter? sheetSetState,
  }) {
    final v = double.tryParse(text.trim());
    if (v == null || !v.isFinite || v < 0.01) {
      _showSnack('桶宽无效：请输入不小于 0.01 的数字');
      return;
    }
    _updateChipConfig(_chipConfig.copyWith(bucketStep: v));
    _updateTickDistConfig(_tickDistConfig.copyWith(bucketStep: v));
    _panelUi(() {}, sheetSetState: sheetSetState);
    _msgHistory.append('筹码/笔数分布桶宽=${v.toStringAsFixed(2)}');
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    _keepAlive.detach();
    _playTimer?.cancel();
    _stepBackTimer?.cancel();
    _longOpHint.dispose();
    _disposePipelineSession();
    // 整个 app 收摊才拆 overlay 窗口（拆窗+注销窗口类+isolate 自行退出）
    unawaited(_runToEndYinYang.dispose());
    _tooltipBridge.dispose();
    _chartSync.dispose();
    _agentApiServer?.stop();
    super.dispose();
  }

  // ================= AgentApiHost 实现 =================

  @override
  bool get hasSession => _hasSession;

  @override
  String? get selectedCode => _selectedCode;

  @override
  String get period => _period;

  @override
  String get periodLabel => _periods[_period] ?? _period;

  @override
  String get dataRoot => _dataRoot;

  @override
  int get stepIdx => _stepIdx;

  @override
  int get totalBars => _allBars.length;

  @override
  bool get isPlaying => _playing;

  @override
  Set<MainChartIndicator> get mainIndicators => _mainIndicators;

  @override
  Set<SubChartIndicator> get subIndicators => _subIndicators;

  @override
  ChipConfig get chipConfig => _chipConfig;

  @override
  TickDistConfig get tickDistConfig => _tickDistConfig;

  @override
  MathIndicatorConfig get mathIndicatorConfig => _mathIndicatorConfig;

  @override
  bool get truncationCheck => _truncationCheck;

  @override
  List<KlineBar> get bars => List<KlineBar>.unmodifiable(_allBars);

  @override
  DateTime get startedAt => _startedAt;

  @override
  String get appVersion => '1.0.9+9';

  @override
  int get ffiAbiVersion => _bridge.loadedFfiAbiVersion;

  @override
  void stepTo(int idx) {
    if (!_hasSession) return;
    _stopPlay();
    _dismissTickYinYang();
    final target = idx.clamp(0, _allBars.length - 1);
    if (target == _stepIdx) return;
    setState(() {
      _stepIdx = target;
      _stepSerial += 1;
    });
    _rebuildCombine();
  }

  @override
  void stepRelative(int dir) {
    if (!_hasSession) return;
    _stopPlay();
    _dismissTickYinYang();
    if (dir > 0) {
      _stepForward();
    } else if (dir < 0) {
      _stepBack();
    }
  }

  @override
  void togglePlay() => _togglePlay();

  @override
  Future<void> runToEnd() => _runToEnd();

  @override
  void stop() => _stopPlay();

  @override
  Future<void> loadCode({required String code, String? period}) async {
    if (_bootstrapping || _busy) return;
    if (period != null && period != _period) {
      setState(() => _period = period);
      _syncDateRangeForCode(code);
    } else if (_selectedCode != code) {
      _syncDateRangeForCode(code);
    }
    setState(() => _selectedCode = code);
    await _loadKlines();
  }

  @override
  Future<void> setPeriod(String period) async {
    if (_bootstrapping || _busy) return;
    if (_period == period) return;
    setState(() => _period = period);
    await _loadKlines();
  }

  @override
  List<AgentTooltipRow> tooltipRowsAt(int idx) {
    if (!_hasSession || idx < 0 || idx >= _allBars.length) return const [];
    final bar = _allBars[idx];
    final asOf = bar.idx;
    final asOfBundle = _bundleForVisible(_visibleBars);
    // 复用现有 tooltip 构建逻辑：委托给 KlineChart 的公开静态辅助（见下方）。
    return _buildTooltipRowsForBar(bar, asOf, asOfBundle);
  }

  @override
  AgentSnapshot snapshot() {
    if (!_hasSession) {
      return AgentSnapshot(
        code: _selectedCode ?? '',
        period: _period,
        periodLabel: periodLabel,
        stepIdx: _stepIdx,
        totalBars: _allBars.length,
        isPlaying: _playing,
        maxKn: 0,
        levels: const [],
        zsK0Frames: const [],
        buy1K0Frames: const [],
        sell1K0Frames: const [],
        buy2K0Frames: const [],
        sell2K0Frames: const [],
        buyNK0Frames: const [],
        sellNK0Frames: const [],
        k0Confirms: const [],
        k0Lines: const [],
        tailBarFeature: null,
      );
    }
    final bundle = _bundleForVisible(_visibleBars);
    final tail = _visibleBars.isNotEmpty ? _visibleBars.last : null;
    AgentBarFeature? tailFeature;
    if (tail != null && _barFeatures.isNotEmpty) {
      final feat = _barFeatures.firstWhere(
        (f) => f.idx == tail.idx,
        orElse: () => _barFeatures.last,
      );
      tailFeature = toAgentBarFeature(feat);
    }
    return bundleToSnapshot(
      bundle: bundle,
      code: _selectedCode ?? '',
      period: _period,
      periodLabel: periodLabel,
      stepIdx: _stepIdx,
      totalBars: _allBars.length,
      isPlaying: _playing,
      tailBarFeature: tailFeature,
    );
  }

  /// 主图勾选指标落地（设置面板/图表弹窗/Agent API 共用同一条路径）。
  void _applyMainIndicators(Set<MainChartIndicator> v) {
    setState(() => _mainIndicators = v);
  }

  /// 副图勾选指标落地（同上；MACD 类背驰会自动并入同号 MACD）。
  void _applySubIndicators(Set<SubChartIndicator> v) {
    setState(() => _subIndicators = ensureMacdForDivergenceArea(v));
  }

  /// 分窗主图勾选落地：只改分窗集合，不动单图设置。
  void _applySplitMainIndicators(Set<MainChartIndicator> v) {
    setState(() => _splitMainIndicators = v);
  }

  /// 分窗副图勾选落地：只改分窗集合，不动单图设置。
  void _applySplitSubIndicators(Set<SubChartIndicator> v) {
    setState(() => _splitSubIndicators = ensureMacdForDivergenceArea(v));
  }

  /// 按当前可见层级重置分窗指标：每窗勾本层 Kn + 合并 + 连线，副图一项不勾。
  void _resetSplitIndicators() {
    _splitIndicatorsReady = true;
    _splitMainIndicators = defaultLevelWindowMainIndicators(
      LevelWindowSettingsStore.activeLevels,
    );
    _splitSubIndicators = <SubChartIndicator>{};
  }

  /// 首次进分窗时铺默认；已初始化过则保留用户本轮在窗内的勾选。
  void _ensureSplitIndicators() {
    if (_splitIndicatorsReady) return;
    _resetSplitIndicators();
  }

  @override
  Future<String> setIndicators({
    Set<String>? mainLabels,
    Set<String>? subLabels,
  }) async {
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    final resolved = resolveIndicatorLabels(
      mainLabels: mainLabels ?? const <String>{},
      subLabels: subLabels ?? const <String>{},
      mainCatalog: buildMainIndicatorCatalog(maxKn),
      subCatalog: buildSubIndicatorCatalog(
        maxKn,
        truncationCheck: _truncationCheck,
        maxBsClass: _maxBsClass,
      ),
    );
    if (resolved.hasUnknown) throw AgentApiError(resolved.unknownMessage);
    final changed = <String>[];
    if (mainLabels != null) {
      _applyMainIndicators(resolved.main);
      // 分窗开着时同步到分窗集合，Agent API 才能看到指标变化。
      if (LevelWindowSettingsStore.enabled) {
        _applySplitMainIndicators(resolved.main);
      }
      changed.add('主图 ${resolved.main.length} 项');
    }
    if (subLabels != null) {
      _applySubIndicators(resolved.sub);
      if (LevelWindowSettingsStore.enabled) {
        _applySplitSubIndicators(resolved.sub);
      }
      changed.add('副图 ${resolved.sub.length} 项');
    }
    return '指标已切换：${changed.join(' / ')}';
  }

  @override
  Future<String> updateConfig(String key, String value) async {
    final change = parseAgentConfigChange(key, value);
    switch (change.key) {
      case AgentConfigKey.chipEnabled:
        final v = change.asBool!;
        await _updateChipConfig(_chipConfig.copyWith(enabled: v));
        _msgHistory.append('筹码开关=${v ? "开" : "关"}（Agent API）');
        return 'chip_enabled=$v';
      case AgentConfigKey.tickEnabled:
        final v = change.asBool!;
        await _updateTickDistConfig(_tickDistConfig.copyWith(enabled: v));
        _msgHistory.append('笔数分布开关=${v ? "开" : "关"}（Agent API）');
        return 'tick_enabled=$v';
      case AgentConfigKey.chipBucket:
        final v = change.asNum!;
        await _updateChipConfig(_chipConfig.copyWith(bucketStep: v));
        _msgHistory.append('筹码桶宽=${v.toStringAsFixed(2)}（Agent API）');
        // GUI 一个输入框同时写筹码与笔数分布；走 API 只改本侧，
        // 要与手动操作完全等价请再设 tick_bucket 为同值。
        return 'chip_bucket=${v.toStringAsFixed(2)}'
            '（GUI 同框双写：等价手动请再设 tick_bucket）';
      case AgentConfigKey.tickBucket:
        final v = change.asNum!;
        await _updateTickDistConfig(_tickDistConfig.copyWith(bucketStep: v));
        _msgHistory.append('笔数分布桶宽=${v.toStringAsFixed(2)}（Agent API）');
        return 'tick_bucket=${v.toStringAsFixed(2)}'
            '（GUI 同框双写：等价手动请再设 chip_bucket）';
      case AgentConfigKey.truncationCheck:
        final v = change.asBool!;
        _setTruncationCheck(v);
        return 'truncation_check=$v';
      case AgentConfigKey.earlyDynamicUnit:
        final v = change.asBool!;
        _setEarlyDynamicUnit(v);
        return 'early_dynamic_unit=$v';
      case AgentConfigKey.bollN:
        final v = change.asInt!;
        await _updateMathIndicatorConfig(_mathIndicatorConfig.copyWith(bollN: v));
        _msgHistory.append('BOLL 窗口 N=$v（Agent API）');
        return 'boll_n=$v';
      case AgentConfigKey.donchianN:
        final v = change.asInt!;
        await _updateMathIndicatorConfig(
          _mathIndicatorConfig.copyWith(donchianN: v),
        );
        _msgHistory.append('唐奇安窗口 N=$v（Agent API）');
        return 'donchian_n=$v';
      case AgentConfigKey.regressK:
        final v = change.asNum!;
        await _updateMathIndicatorConfig(
          _mathIndicatorConfig.copyWith(regressK: v),
        );
        _msgHistory.append('回归通道倍数 k=$v（Agent API）');
        return 'regress_k=$v';
    }
  }

  /// ---------------- Agent 异步任务（寻优 / 回测） ----------------

  /// 后台任务表（ID → 状态）；只保留近期任务，避免长时间挂机越积越多。
  final Map<String, AgentTask> _agentTasks = {};
  int _agentTaskSeq = 0;
  final Map<String, IndicatorSearchJob> _agentSearchJobs = {};

  @override
  List<Map<String, dynamic>> agentTasks() =>
      (_agentTasks.values.toList()
            ..sort((a, b) => b.startedAt.compareTo(a.startedAt)))
          .map((t) => t.toJson())
          .toList();

  AgentTask _newAgentTask(String kind) {
    final task = AgentTask(
      id: '${kind}_${++_agentTaskSeq}',
      kind: kind,
      startedAt: DateTime.now(),
    );
    _agentTasks[task.id] = task;
    // 超过 20 条时，从最老的终态任务开始清。
    while (_agentTasks.length > 20) {
      final finished = _agentTasks.values.where((t) => !t.running).toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      if (finished.isEmpty) break;
      final drop = finished.first.id;
      _agentTasks.remove(drop);
      _agentBacktestRuns.remove(drop);
      _agentBacktestJson.remove(drop);
      _agentSearchJobs.remove(drop);
    }
    return task;
  }

  AgentTask _requireAgentTask(String id) {
    final task = _agentTasks[id];
    if (task == null) {
      throw AgentApiError(
        '未知 task_id：$id（可用：${_agentTasks.keys.join(",")}）',
      );
    }
    return task;
  }

  /// 寻优 / 回测共用前置校验：会话已加载、已步进到区间末根、代码/周期/区间一致。
  ///
  /// 两条任务都读主图冻结仓，必须保证「区间末根」这一前提；不一致必须让 agent
  /// 显式 load_code / set_period，**不偷偷替它换会话**。
  ({String code, String period, String begin, String end})
      _requireAgentFrozenSession({
    required String taskLabel,
    String? code,
    String? period,
    String? begin,
    String? end,
  }) {
    if (!_hasSession || _allBars.isEmpty) {
      throw AgentApiError('请先加载 K 线（load_code）');
    }
    if (_stepIdx < 0) {
      throw AgentApiError('尚未步进：请先 step 或 run_to_end 至少到第 0 根');
    }
    if (_stepIdx < _allBars.length - 1) {
      throw AgentApiError(
        '$taskLabel与策略回测共用主图冻结：当前 step_idx=$_stepIdx，'
        '请先 run_to_end 步进到区间最后一根（idx=${_allBars.length - 1}）',
      );
    }
    final curCode = _selectedCode ?? '';
    final wantCode = (code ?? curCode).trim();
    if (wantCode.isEmpty) {
      throw AgentApiError('未选择股票：请先 load_code');
    }
    if (wantCode != curCode) {
      throw AgentApiError(
        'code=$wantCode 与当前会话 $curCode 不一致：请先 load_code 同一代码',
      );
    }
    final curPeriod = _period;
    final wantPeriod = (period ?? curPeriod).trim();
    if (wantPeriod != curPeriod) {
      throw AgentApiError(
        'period=$wantPeriod 与当前会话 $curPeriod 不一致：请先 set_period',
      );
    }
    final curBegin = _fmtDateTime(_beginDate);
    final curEnd = _fmtDateTime(_endDate);
    final wantBegin = (begin ?? curBegin).trim();
    final wantEnd = (end ?? curEnd).trim();
    if (wantBegin != curBegin || wantEnd != curEnd) {
      throw AgentApiError(
        'begin/end=$wantBegin~$wantEnd 与当前会话区间 $curBegin~$curEnd 不一致：'
        '请先用 load_code 指定同一区间',
      );
    }
    return (code: curCode, period: curPeriod, begin: curBegin, end: curEnd);
  }

  @override
  Future<String> startSearch({
    String? code,
    String? period,
    String? begin,
    String? end,
    int? maxCandidates,
    double inRatio = 0.7,
  }) async {
    if (_mlSession.isActive) {
      throw AgentApiError('机器学习运行中：请先退出机器学习再寻优');
    }
    final sess = _requireAgentFrozenSession(
      taskLabel: '寻优',
      code: code,
      period: period,
      begin: begin,
      end: end,
    );
    final curCode = sess.code;
    final curPeriod = sess.period;
    final curBegin = sess.begin;
    final curEnd = sess.end;
    if (inRatio <= 0 || inRatio >= 1) {
      throw AgentApiError('in_ratio 必须在 (0,1) 之间（默认 0.7）');
    }
    if (maxCandidates != null && maxCandidates < 1) {
      throw AgentApiError('max_candidates 必须为正整数');
    }
    if (_hasRunningAgentTask('search')) {
      throw AgentApiError('已有寻优任务在跑：请先 cancel_search 或等它结束');
    }

    final resultsPath =
        (await IndicatorSearchSettingsStore.resultsFile()).path;
    final logPath = (await IndicatorSearchSettingsStore.logFile()).path;
    if (!mounted) throw AgentApiError('主界面未就绪');
    final task = _newAgentTask('search');
    final job = IndicatorSearchJob(IndicatorSearchJobParams(
      code: curCode,
      period: curPeriod,
      beginText: curBegin,
      endText: curEnd,
      dataRoot: _dataRoot,
      tickSource: _tickSourceFor(curCode),
      mathConfig: _mathIndicatorConfig,
      chipConfig: _chipConfig,
      strategyConfig: _strategyConfig,
      resultsPath: resultsPath,
      logPath: logPath,
      featureLookup: _pipelineSession?.cache.lookup,
      truncationCheck: _truncationCheck,
      earlyDynamicUnit: _earlyDynamicUnit,
      mainSessionHarness: _mainSessionHarnessForSearch(),
      initialBars: List<KlineBar>.from(_allBars),
      maxCandidates: maxCandidates,
      inRatio: inRatio,
    ));
    _agentSearchJobs[task.id] = job;
    setState(() => _indicatorSearchRunning = true);
    _msgHistory.append('智能体寻优开始：$curCode $curPeriod task=${task.id}');
    unawaited(_runAgentSearch(task, job));
    return task.id;
  }

  Future<void> _runAgentSearch(AgentTask task, IndicatorSearchJob job) async {
    try {
      final result = await job.run(onProgress: (p) {
        task.detail = '${p.phase}：${p.detail}';
        task.fraction = p.fraction;
        final m = RegExp(r'(\d+)/(\d+)').firstMatch(p.detail);
        if (m != null) {
          task.done = int.parse(m.group(1)!);
          task.total = int.parse(m.group(2)!);
        }
        _agentApiServer?.refreshStateFile();
      });
      task.finishedAt = DateTime.now();
      if (result == null) {
        task.phase = 'cancelled';
        task.detail = '冻结阶段已取消（未产生结果）';
        _msgHistory.append('智能体寻优已取消（冻结阶段）task=${task.id}');
      } else {
        task.done = result.stats.ran;
        task.total = result.stats.total;
        task.fraction = 1;
        task.payload = result.stats.verdicts;
        task.summary = {
          'code': job.params.code,
          'period': job.params.period,
          'begin': job.params.beginText,
          'end': job.params.endText,
          'bar_count': result.barCount,
          'max_kn': result.maxKn,
          'split_x': result.splitX,
          'in_ratio': job.params.inRatio,
          'compiled': result.stats.compiled,
          'ran': result.stats.ran,
          'total': result.stats.total,
          'cancelled': result.stats.cancelled,
          'elapsed_seconds': result.stats.elapsed.inSeconds,
          'results_path': result.resultsPath,
          'use_optimized_build': result.useOptimizedBuild,
          'candidate_limit': result.maxCandidates,
          'build_summary': result.buildSummary.toDisplayLine(),
        };
        task.phase = result.stats.cancelled ? 'cancelled' : 'done';
        task.detail = '编译${result.stats.compiled} 跑通${result.stats.ran} · '
            '耗时 ${result.stats.elapsed.inMinutes}分'
            '${result.stats.elapsed.inSeconds % 60}秒';
        _msgHistory.append(
          '智能体寻优${result.stats.cancelled ? "已取消" : "完成"}：'
          '跑通${result.stats.ran}条 task=${task.id}',
        );
      }
    } catch (e) {
      task.finishedAt = DateTime.now();
      task.phase = 'failed';
      task.error = '$e';
      task.detail = '失败';
      _msgHistory.append('智能体寻优失败：$e task=${task.id}');
    } finally {
      _agentSearchJobs.remove(task.id);
      if (mounted) setState(() => _indicatorSearchRunning = false);
      _agentApiServer?.refreshStateFile();
    }
  }

  @override
  Map<String, dynamic> searchTaskStatus(
    String taskId, {
    int offset = 0,
    int limit = 200,
  }) {
    final task = _requireAgentTask(taskId);
    final payload = task.payload;
    final verdicts = payload is List<ComboVerdict> ? payload : const <ComboVerdict>[];
    final begin = offset.clamp(0, verdicts.length);
    final end = (begin + limit).clamp(begin, verdicts.length);
    return {
      ...task.toJson(),
      'verdicts_total': verdicts.length,
      'offset': begin,
      'limit': limit,
      'verdicts': [
        for (var i = begin; i < end; i++) verdicts[i].toJson(),
      ],
    };
  }

  @override
  bool cancelSearch(String taskId) {
    final task = _agentTasks[taskId];
    if (task == null || task.kind != 'search' || !task.running) return false;
    final job = _agentSearchJobs[taskId];
    if (job == null) return false;
    job.cancel();
    task.detail = '已请求取消…';
    return true;
  }

  /// ---------------- Agent 回测任务 ----------------

  /// 已完成回测的原始结果（trades 分页从这里取，不重复计算）。
  final Map<String, BacktestRun> _agentBacktestRuns = {};

  /// 已完成回测的摘要 JSON（指标 + 段指标，避免每次轮询重算）。
  final Map<String, Map<String, dynamic>> _agentBacktestJson = {};

  /// 已请求取消、尚未开始计算的回测任务。
  final Set<String> _agentBacktestCancelRequests = {};

  @override
  Future<String> runBacktest({
    required Map<String, dynamic> buyAst,
    required Map<String, dynamic> sellAst,
    String? code,
    String? period,
    String? begin,
    String? end,
    int? quantity,
    double? commissionRate,
    double? slippageAmount,
    String? fillPriceMode,
  }) async {
    if (_mlSession.isActive) {
      throw AgentApiError('机器学习运行中：请先退出机器学习再回测');
    }
    _requireAgentFrozenSession(
      taskLabel: '回测',
      code: code,
      period: period,
      begin: begin,
      end: end,
    );
    if (quantity != null && quantity <= 0) {
      throw AgentApiError('quantity 必须为正整数（默认 100）');
    }
    if (commissionRate != null && commissionRate < 0) {
      throw AgentApiError('commission_rate 不能为负（0=免手续费）');
    }
    if (slippageAmount != null && slippageAmount < 0) {
      throw AgentApiError('slippage_amount 不能为负（0=无滑点）');
    }
    final fillMode = _parseAgentFillPriceMode(fillPriceMode);
    if (_hasRunningAgentTask('backtest')) {
      throw AgentApiError('已有回测任务在跑：请先 cancel_backtest 或等它结束');
    }

    final TradeAst buy;
    final TradeAst sell;
    try {
      buy = tradeAstFromJson(buyAst);
      sell = tradeAstFromJson(sellAst);
    } catch (e) {
      throw AgentApiError('买卖条件 AST 无法解析：$e');
    }
    // 基准一律用 StrategyConfig 默认值（与回测台默认一致），
    // 不继承 GUI 上一次对话框里的临时参数，保证 agent 结果可复现。
    final cfg = StrategyConfig(
      buyAst: buy,
      sellAst: sell,
      quantity: quantity ?? 100,
      commissionRate: commissionRate ?? 0,
      slippageAmount: slippageAmount ?? 0,
      fillPriceMode: fillMode ?? kDefaultTradeFillPriceMode,
    );
    final task = _newAgentTask('backtest');
    _msgHistory.append(
      '智能体回测开始：${_selectedCode ?? ""} ${cfg.buyLabel} / ${cfg.sellLabel} '
      'task=${task.id}',
    );
    unawaited(_runAgentBacktest(task, cfg));
    return task.id;
  }

  Future<void> _runAgentBacktest(AgentTask task, StrategyConfig cfg) async {
    // 先让出一拍，把 task_id 回给 HTTP/文件通道，再跑重计算。
    await Future<void>.delayed(Duration.zero);
    if (_agentBacktestCancelRequests.remove(task.id)) {
      task
        ..finishedAt = DateTime.now()
        ..phase = 'cancelled'
        ..detail = '已取消（未开始计算）';
      _msgHistory.append('智能体回测已取消：task=${task.id}');
      _agentApiServer?.refreshStateFile();
      return;
    }
    try {
      task.detail = '回测计算中…（同步执行，界面可能短暂无响应）';
      final run = _computeStrategyBacktest(cfg);
      final json = agentBacktestRunJson(run);
      _agentBacktestRuns[task.id] = run;
      _agentBacktestJson[task.id] = json;
      task
        ..finishedAt = DateTime.now()
        ..payload = run
        ..summary = {
          'ok': json['ok'],
          'run_id': json['run_id'],
          'engine_version': json['engine_version'],
          'scope': json['scope'],
          'config': json['config'],
          if (json['ok'] == true) ...{
            'metrics': json['metrics'],
            'summary': json['summary'],
          },
          if (json['ok'] != true) 'error': json['error'],
        };
      if (json['ok'] == true) {
        final m = run.result!.metrics;
        task
          ..phase = 'done'
          ..fraction = 1
          ..detail = '闭合${m.totalTrades} 笔 · 净利${m.netProfit.toStringAsFixed(2)} '
              '· 胜率${m.winRate.display}';
        _msgHistory.append(
          '智能体回测完成：${cfg.buyLabel} / ${cfg.sellLabel}；'
          '净利${m.netProfit.toStringAsFixed(2)} 胜率${m.winRate.display} '
          '最大回撤${m.maxDrawdown.toStringAsFixed(2)} task=${task.id}',
        );
      } else {
        task
          ..phase = 'failed'
          ..error = '${json['error']}'
          ..detail = '回测未跑成：${json['error']}';
        _msgHistory.append('智能体回测未跑成：${json['error']} task=${task.id}');
      }
    } catch (e) {
      task
        ..finishedAt = DateTime.now()
        ..phase = 'failed'
        ..error = '$e'
        ..detail = '失败';
      _msgHistory.append('智能体回测失败：$e task=${task.id}');
    } finally {
      _agentBacktestCancelRequests.remove(task.id);
      _agentApiServer?.refreshStateFile();
    }
  }

  @override
  Map<String, dynamic> backtestTaskStatus(
    String taskId, {
    int offset = 0,
    int limit = 200,
  }) {
    final task = _requireAgentTask(taskId);
    final run = _agentBacktestRuns[taskId];
    final result = run?.result;
    final trades = result?.trades ?? const <TradeRecord>[];
    final begin = offset.clamp(0, trades.length);
    final end = (begin + limit).clamp(begin, trades.length);
    final json = _agentBacktestJson[taskId];
    return {
      ...task.toJson(),
      if (json != null) ...json,
      'trades_total': trades.length,
      'offset': begin,
      'limit': limit,
      'trades': [
        for (var i = begin; i < end; i++) agentTradeJson(trades[i]),
      ],
    };
  }

  @override
  bool cancelBacktest(String taskId) {
    final task = _agentTasks[taskId];
    if (task == null || task.kind != 'backtest' || !task.running) return false;
    _agentBacktestCancelRequests.add(taskId);
    task.detail = '已请求取消…';
    return true;
  }

  /// 成交价模式：接受 `sameBarClose` / `nextBarOpen`（忽略大小写与下划线）。
  TradeFillPriceMode? _parseAgentFillPriceMode(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final norm = text.replaceAll('_', '').toLowerCase();
    for (final mode in TradeFillPriceMode.values) {
      if (mode.name.toLowerCase() == norm) return mode;
    }
    throw AgentApiError(
      'fill_price_mode=$text 不合法（可用：sameBarClose=本周期收盘 / '
      'nextBarOpen=次周期开盘）',
    );
  }

  bool _hasRunningAgentTask(String kind) =>
      _agentTasks.values.any((t) => t.kind == kind && t.running);

  /// 运行消息历史（与界面「历史记录」同源，按时间正序取末 N 条）。
  @override
  List<AgentMessageRow> historyMessages({int limit = 50}) {
    final rows = MsgHistory.instance.rows;
    if (limit <= 0) return const [];
    final begin = rows.length > limit ? rows.length - limit : 0;
    return [
      for (var i = begin; i < rows.length; i++)
        AgentMessageRow(time: rows[i].time, text: rows[i].text),
    ];
  }

  /// 截断监察开关落地（设置面板开关与 Agent API 共用同一条路径）。
  ///
  /// 截断机制会改段划分 → 段变化会让采样钟时间线与冻结仓整体作废，
  /// 必须连冻结仓一起清（与 :1752 / :1797 两条兄弟路径同口径）。
  /// 只 dispose 不清 → 时间线保留旧口径，且 recordKnClockStep 的
  /// lastAsOf>=stepIdx 守卫会让它不再重记，采样钟与新段划分对不上。
  void _setTruncationCheck(bool v, {StateSetter? sheetSetState}) {
    _panelUi(() {
      _truncationCheck = v;
      _defaultK0Purged = false;
      // 关截断时从副图勾选里摘掉 Kn截断（目录也不可选）
      final maxKn = chartMaxKn(
        levels: _levels,
        k0Lines: _k0Lines,
      );
      _subIndicators = pruneIndicators(
        _subIndicators,
        buildSubIndicatorCatalog(
          maxKn,
          truncationCheck: v,
          maxBsClass: _maxBsClass,
        ),
      );
    }, sheetSetState: sheetSetState);
    // opt 变了：重建 PipelineState 会话再重算。
    _clearSessionFreezeHistory();
    _disposePipelineSession();
    _msgHistory.append('截断机制=${v ? "开" : "关"}，重算当前步进');
    _rebuildCombine();
    _logCombineSummary(prefix: '截断开关后汇总');
  }

  /// 层级早生成动态单元开关落地（设置面板与 Agent API 共用同一条路径）。
  ///
  /// 该开关改变每层首个单元的可见时点 → 采样钟/冻结仓必须整体作废，
  /// 只 dispose 会话不清冻结仓会残留旧口径的“第0根”记录。
  void _setEarlyDynamicUnit(bool v, {StateSetter? sheetSetState}) {
    _panelUi(() {
      _earlyDynamicUnit = v;
    }, sheetSetState: sheetSetState);
    unawaited(LevelWindowSettingsStore.save(earlyDynamicUnit: v));
    _clearSessionFreezeHistory();
    _disposePipelineSession();
    _msgHistory.append('层级早生成动态单元=${v ? "开" : "关"}，重算当前步进');
    _rebuildCombine();
    _logCombineSummary(prefix: '层级早生成开关后汇总');
  }

  /// 首分型前合并框口径落地（设置面板与 Agent API 共用同一条路径）。
  ///
  /// 只改「首个分型之前」那段合并框的绘制与 tooltip 的 MG/MD：
  /// 不动结构计算、不动会话管道与冻结仓，重算当前步进只为让增量 Lookup
  /// 把这一口径的行重种一遍（否则十字线上的 MG/MD 还是旧口径）。
  void _setPreFirstFractalMode(
    PreFirstFractalMode mode, {
    StateSetter? sheetSetState,
  }) {
    if (_preFirstFractalMode == mode) return;
    _panelUi(() => _preFirstFractalMode = mode, sheetSetState: sheetSetState);
    unawaited(LevelWindowSettingsStore.save(preFirstFractalMode: mode));
    _msgHistory.append('首分型前合并框=${mode.label}');
    _rebuildCombine();
  }

  @override
  AgentHealth health() {
    return AgentHealth(
      appVersion: appVersion,
      ffiAbiVersion: ffiAbiVersion,
      pid: 0, // 占位：Dart 无跨平台获取当前进程 ID 的公开 API
      dataRoot: dataRoot,
      uptime: DateTime.now().difference(startedAt),
    );
  }

  /// 第 idx 根 K 的 tooltip 行（与画面 tooltip 同源）。
  /// 需要 KlineChart 的 `_tooltipRowsForBar` 逻辑，这里通过主界面已有的
  /// bundle + bar_feature 组装轻量行（OHLC + 中枢 + 分型）。
  List<AgentTooltipRow> _buildTooltipRowsForBar(
    KlineBar bar,
    int asOf,
    KlineCombineBundle bundle,
  ) {
    final rows = <AgentTooltipRow>[];
    final minuteLike = KlineAxisFormat.isMinuteLike(_allBars);
    final secondLike = _period == 'tick' || KlineAxisFormat.isSecondLike(_allBars);
    final timePart = KlineAxisFormat.xLabel(
      bar.timeText,
      minuteLike: minuteLike,
      secondLike: secondLike,
    );
    rows.add(AgentTooltipRow(label: '日期时间', value: timePart));
    rows.add(AgentTooltipRow(
      label: 'K0 idx',
      value: AgentTooltipRow.boxNum(bar.idx),
    ));
    rows.add(AgentTooltipRow(
      label: 'K0',
      value: AgentTooltipRow.boxNumInString(
        'O${bar.open.toStringAsFixed(2)} H${bar.high.toStringAsFixed(2)} '
        'L${bar.low.toStringAsFixed(2)} C${bar.close.toStringAsFixed(2)} '
        'V${bar.volume}',
      ),
    ));
    // K0 分型确认（当步）。
    final confirmsAt = bundle.k0Confirms.where((c) => c.x == bar.idx).toList();
    for (final c in confirmsAt) {
      rows.add(AgentTooltipRow(
        label: 'K0分型 ${c.fx}',
        value: 'x=${c.x} value=${c.value.toStringAsFixed(2)}',
      ));
    }
    // 各层中枢命中。
    final feat = _barFeatures.firstWhere(
      (f) => f.idx == bar.idx,
      orElse: () => _barFeatures.isNotEmpty ? _barFeatures.last : null!,
    );
    for (final z in feat.zsHits) {
      rows.add(AgentTooltipRow(
        label: 'K${z.kn}中枢#${z.seq}',
        value: 'ZG=${z.high.toStringAsFixed(2)} ZD=${z.low.toStringAsFixed(2)} ${z.isSure ? '确定' : ''}',
      ));
    }
    // 一类BS。
    for (final b in feat.bs1Hits) {
      rows.add(AgentTooltipRow(
        label: 'K${b.kn}一类${b.side}',
        value: '${b.label} x=${b.x} price=${b.price.toStringAsFixed(2)}',
      ));
    }
    return rows;
  }

  // ================= Agent API 生命周期 =================

  /// 启动智能体验证（仅在非 robot_verify 模式且满足条件时调用）。
  Future<void> _startAgentApiIfEnabled() async {
    // 已在运行：换股/换周期会再次走到这里，不可重复 bind，也不可覆盖令牌文件。
    if (_agentApiServer != null) return;
    final env = Platform.environment['CHAN_AGENT_API']?.trim();
    final enabled = env == '1' || env == 'true' || env == 'yes';
    if (!enabled) return;
    try {
      _agentApiServer = await AgentApiServer.start(
        host: this,
        startedAt: _startedAt,
        appVersion: appVersion,
      );
      _msgHistory.append('智能体验证已启动：127.0.0.1:12321（令牌见 a_Data/agent_live/agent_api_token.txt）');
    } catch (e) {
      _msgHistory.append('智能体验证启动失败：$e');
    }
  }

  void _refreshKeepAlive() => _keepAlive.refresh();

  /// 释放 Rust 侧 PipelineState（换股/换周期/关页/截断开关重建前）
  void _disposePipelineSession() {
    _pipelineSession?.dispose();
    _pipelineSession = null;
  }

  /// 清空会话冻结历史：回首 K / 从 0 重跑走完前必须清，避免重复 merge 崩溃。
  void _clearSessionFreezeHistory() {
    _stepFreeze.clear();
  }

  /// 取与可见前缀同步的 bundle：前进 append；步退优先当步仓，无仓才 reset+replay
  KlineCombineBundle _bundleForVisible(List<KlineBar> visible) {
    if (_pipelineSession == null ||
        !_pipelineSession!.isAlive ||
        _pipelineSession!.truncationCheck != _truncationCheck ||
        _pipelineSession!.earlyDynamicUnit != _earlyDynamicUnit) {
      _disposePipelineSession();
      _pipelineSession = ChanPipelineSession.create(
        truncationCheck: _truncationCheck,
        earlyDynamicUnit: _earlyDynamicUnit,
        bridge: _bridge,
      );
    }
    return _pipelineSession!.syncTo(visible);
  }

  /// 把当前步 History + Math 冻仓打进增量 Lookup（Painter 只消费这份）。
  void _syncPresentationLookup(List<KlineBar> bars, KlineCombineBundle bundle) {
    final sess = _pipelineSession;
    if (sess == null || !sess.isAlive) return;
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    sess.cache.syncLookup(
      bars: bars,
      buy1HistoryByKn: _stepFreeze.buy1HistoryByKn,
      sell1HistoryByKn: _stepFreeze.sell1HistoryByKn,
      buy2HistoryByKn: _stepFreeze.buy2HistoryByKn,
      sell2HistoryByKn: _stepFreeze.sell2HistoryByKn,
      buyNHistoryByKn: _stepFreeze.buyNHistoryByKn,
      sellNHistoryByKn: _stepFreeze.sellNHistoryByKn,
      adjacentRatioHistoryByKn: _stepFreeze.adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: _stepFreeze.stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: _stepFreeze.lineSlopeHistoryByKn,
      judgmentHistoryByKn: _stepFreeze.judgmentHistoryByKn,
      zsJudgmentHistoryByKn: _stepFreeze.zsJudgmentHistoryByKn,
      zsConfirmHistoryByKn: _stepFreeze.zsConfirmHistoryByKn,
      subIndicators: buildSubIndicatorCatalog(
        maxKn,
        truncationCheck: _truncationCheck,
        maxBsClass: _maxBsClass,
      ).toSet(),
      truncationCheck: _truncationCheck,
      preFirstFractalMode: _preFirstFractalMode,
      preFirstFractalSubWindow: LevelWindowSettingsStore.enabled,
      earlyDynamicUnit: _earlyDynamicUnit,
      mathIndicatorConfig: _mathIndicatorConfig,
      mathFreezeStore: _stepFreeze.mathFreezeStore,
      diverFreezeStore: _stepFreeze.diverFreezeStore,
      maxBsClass: _maxBsClass,
    );
  }

  /// 切换股票时对齐各自默认加载区间。
  void _syncDateRangeForCode(String code) {
    // Android 内置种子仅含 002003 的 2025Q1
    if (Platform.isAndroid && code == MobileDataRoot.bundledStockCode) {
      _beginDate = MobileDataRoot.bundledBeginDate;
      _endDate = MobileDataRoot.bundledEndDate;
      return;
    }
    // test：数据源即分笔（custom.ohlc.csv），周期、起止时间自动对齐分笔配置。
    if (code == 'test') {
      _period = 'tick';
      if (_hasTestOhlcCsv()) {
        try {
          final bars = _bridge.loadKlines(
            dataRoot: _dataRoot,
            code: 'test',
            beginDate: '1990/01/01 00:00:00',
            endDate: '2100/12/31 23:59:59',
            period: 'tick',
          );
          if (bars.isNotEmpty) {
            final b0 = _tryParseBarTime(bars.first.timeText);
            final b1 = _tryParseBarTime(bars.last.timeText);
            if (b0 != null && b1 != null) {
              _beginDate = b0;
              _endDate = b1;
              return;
            }
          }
        } catch (_) {
          // 回落标准区间
        }
      }
    }
    final range = _codeDefaultRanges[code];
    if (range != null) {
      _beginDate = range.$1;
      _endDate = range.$2;
    } else {
      _beginDate = _standardBeginDate;
      _endDate = _standardEndDate;
    }
  }

  bool _hasTestOhlcCsv() {
    if (_dataRoot.isEmpty) return false;
    final path =
        '$_dataRoot${Platform.pathSeparator}test${Platform.pathSeparator}custom.ohlc.csv';
    return File(path).existsSync();
  }

  DateTime? _tryParseBarTime(String raw) {
    final s = raw.trim().replaceAll('-', '/');
    final m = RegExp(
      r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})(?::(\d{2}))?$',
    ).firstMatch(s);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      m.group(6) != null ? int.parse(m.group(6)!) : 0,
    );
  }

  /// 默认加载的股票：TEST 自定义股票（`a_Data/test`）。
  /// 取不到 `test` 目录时回退到 `002003`，再回退到列表第一个。
  String? _preferredCode(List<String> codes) {
    if (codes.contains('test')) return 'test';
    if (codes.contains('002003')) return '002003';
    return codes.isEmpty ? null : codes.first;
  }

  String _fmtDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  Future<void> _pickDateTime({required bool isBegin}) async {
    final initial = isBegin ? _beginDate : _endDate;
    final first = DateTime(1990);
    final last = DateTime(2100, 12, 31, 23, 59, 59);
    final picked = await showDateTimePickerDialog(
      context: context,
      initial: initial,
      firstDate: first,
      lastDate: last,
      title: isBegin ? '选择加载起始时间' : '选择加载截止时间',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isBegin) {
        _beginDate = picked;
        if (_endDate.isBefore(_beginDate)) _endDate = _beginDate;
      } else {
        _endDate = picked;
        if (_endDate.isBefore(_beginDate)) _beginDate = _endDate;
      }
    });
    // 选定加载区间后立即按时间从 a_Data 重载
    await _loadKlines();
  }

  Future<String> _resolveDataRoot() async {
    if (Platform.isAndroid) {
      return MobileDataRoot.ensureReady();
    }
    final env = Platform.environment['CHAN_DATA_ROOT']?.trim();
    if (env != null && env.isNotEmpty) {
      return env;
    }
    return _bridge.defaultDataRoot();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _error = null;
    });
    try {
      final root = await _resolveDataRoot();
      final codes = _bridge.listStockCodes(dataRoot: root);
      if (codes.isEmpty) {
        throw StateError('a_Data 下未找到股票目录，请检查: $root');
      }
      setState(() {
        _dataRoot = root;
        _codes = codes;
        _selectedCode = _preferredCode(codes);
        _syncDateRangeForCode(_selectedCode!);
      });
      await _loadKlines();
      _msgHistory.append(
        '初始化完成：代码=$_selectedCode 周期=${_periods[_period] ?? _period} '
        '根目录=$_dataRoot；口径=K0原始K/K1=K0连线/K2=K1连线/Kn第n层；'
        '截断=${_truncationCheck ? "开" : "关"}',
      );
    } catch (e) {
      setState(() {
        _error = e.toString();
        if (e is ChanFfiVersionException) {
          _libHalt = true;
          _libHaltMessage = e.message;
        }
      });
      _msgHistory.append('启动失败：$e');
    } finally {
      if (mounted) setState(() => _bootstrapping = false);
    }
  }

  Future<void> _loadKlines() async {
    final code = _selectedCode;
    if (code == null) {
      setState(() => _error = '请先选择股票代码');
      return;
    }
    _stopPlay();
    setState(() {
      _loadingChart = true;
      _error = null;
      _tickYinYangCover = _period == 'tick' && _yinYangEnabled;
      _chipTickDepsAllowed = true;
      _tickDistSessionAllowed = true;
    });
    _disposePipelineSession();
    TickQuality? quality;
    List<KlineBar> bars = const [];
    var srcHint = '';
    try {
      if (_useTelegramDaily) {
        try {
          final tg = TelegramDataSource(
            settings: _telegramSettings,
            cacheRoot: Directory(_dataRoot),
          );
          bars = await tg.loadDailyBars(
            code: code,
            begin: _beginDate,
            end: _endDate,
          );
          quality = const TickQuality(
            source: 'telegram',
            skipPrompts: true,
            hasBuy: true,
            hasSell: true,
            hasNeutral: true,
          );
          srcHint = '（Telegram 日线 CSV）';
        } catch (e) {
          _msgHistory.append('Telegram 取数失败，回退通达信：$e');
          final loaded = _bridge.loadKlinesEx(
            dataRoot: _dataRoot,
            code: code,
            beginDate: _fmtDateTime(_beginDate),
            endDate: _fmtDateTime(_endDate),
            period: _period,
            tickSource: _tickSourceFor(code),
          );
          quality = loaded.quality;
          bars = loaded.bars;
          srcHint = loaded.quality.source == 'protocol'
              ? '（通达信协议分笔）'
              : '（本地分笔文件）';
        }
      } else {
        final tgTicks = await _prefetchTelegramTicks(code);
        final loaded = _bridge.loadKlinesEx(
          dataRoot: _dataRoot,
          code: code,
          beginDate: _fmtDateTime(_beginDate),
          endDate: _fmtDateTime(_endDate),
          period: _period,
          tickSource: _tickSourceFor(code),
        );
        quality = loaded.quality;
        bars = loaded.bars;
        final directOhlc = code == 'test' && _hasTestOhlcCsv();
        srcHint = directOhlc
            ? '（直读custom.ohlc.csv，忽略周期聚合）'
            : tgTicks
                ? '（Telegram 分笔包 + 本地缓存）'
                : (quality.source == 'protocol'
                    ? '（通达信协议分笔）'
                    : '（本地分笔文件）');
      }
      final tickDistOn = _tickDistConfig.enabled;
      final pendingMute = quality.shouldPrompt(tickDistEnabled: tickDistOn);
      setState(() {
        _allBars = bars;
        _stepIdx = bars.isEmpty ? -1 : 0;
        _defaultK0Purged = false;
        _chipTickDepsAllowed = true;
        _tickDistSessionAllowed = !pendingMute;
        _stepFreeze.judgmentHistoryByKn.clear();
        _stepFreeze.zsJudgmentHistoryByKn.clear();
        _stepFreeze.zsConfirmHistoryByKn.clear();
        _stepFreeze.zsObjectStore.clear();
        _stepFreeze.diverRelationStore.clear();
        _stepFreeze.buy1HistoryByKn.clear();
        _stepFreeze.sell1HistoryByKn.clear();
        _stepFreeze.buy2HistoryByKn.clear();
        _stepFreeze.sell2HistoryByKn.clear();
        _stepFreeze.buyNHistoryByKn.clear();
        _stepFreeze.sellNHistoryByKn.clear();
        _stepFreeze.bsVerdictHistoryByKn.clear();
        _stepFreeze.adjacentRatioHistoryByKn.clear();
        _stepFreeze.lineSlopeHistoryByKn.clear();
        _stepFreeze.stepRhythmHistoryByKn.clear();
        for (final s in _stepFreeze.stepRhythmStateByKn.values) {
          s.reset();
        }
        _stepFreeze.stepRhythmStateByKn.clear();
        _stepFreeze.mathFreezeStore.clear();
        _stepFreeze.diverFreezeStore.clear();
        _stepFreeze.chipPeakStore.clear();
        _stepFreeze.knClockTimeline.clear();
        _stepFreeze.knClockSeenUnits.clear();
        _clearBacktestSession();
      });
      final directOhlc = code == 'test' && _hasTestOhlcCsv();
      if (srcHint.isEmpty) {
        srcHint = directOhlc
            ? '（直读custom.ohlc.csv，忽略周期聚合）'
            : (quality!.source == 'protocol'
                ? '（通达信协议分笔）'
                : '（本地分笔文件）');
      }
      _msgHistory.append(
        '加载K0：$code ${_fmtDateTime(_beginDate)}~${_fmtDateTime(_endDate)} '
        '${_periods[_period] ?? _period} 共${bars.length}根$srcHint',
      );
      if (_chipOnlyMode) {
        // 仅筹码分布：跳过缠论合并/线段/中枢/BS 计算，清空相关数据
        ChipProfileCompute.clearCache();
        TickDistProfileCompute.clearCache();
        setState(() {
          _combineFrames = const [];
          _k0ConfirmSignals = const [];
          _barFeatures = const [];
          _k0Lines = const [];
          _k1BarViews = const [];
          _k1CombineFrames = const [];
          _k1Analysis = K1AnalysisBundle.empty();
          _levels = const [];
          _zsK0Frames = const [];
          _buy1K0Frames = const [];
          _sell1K0Frames = const [];
          _buy2K0Frames = const [];
          _sell2K0Frames = const [];
          _buyNK0Frames = const [];
          _sellNK0Frames = const [];
          // 筹码已迁设置控制（仅K0），不再进主图指标选择集
          _mainIndicators = {};
          _subIndicators = {};
        });
        // 预热全量前缀（即便当前只显示首根，跳末后即可秒切）
        unawaited(
          ChipProfileCompute.warmUpInBackground(
            bars,
            bucketStep: _chipConfig.bucketStep,
          ),
        );
      } else {
        ChipProfileCompute.clearCache();
        TickDistProfileCompute.clearCache();
        _rebuildCombine();
        _logCombineSummary(prefix: '加载后汇总');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _allBars = [];
        _combineFrames = [];
        _k0ConfirmSignals = [];
        _barFeatures = [];
        _k0Lines = [];
        _k1BarViews = [];
        _k1CombineFrames = [];
        _k1Analysis = K1AnalysisBundle.empty();
        _levels = [];
        _zsK0Frames = [];
        _buy1K0Frames = [];
        _sell1K0Frames = [];
        _buy2K0Frames = [];
        _sell2K0Frames = [];
        _buyNK0Frames = [];
        _sellNK0Frames = [];
        _stepIdx = -1;
        _chipTickDepsAllowed = true;
        _tickDistSessionAllowed = true;
        _stepFreeze.judgmentHistoryByKn.clear();
        _stepFreeze.zsJudgmentHistoryByKn.clear();
        _stepFreeze.zsConfirmHistoryByKn.clear();
        _stepFreeze.zsObjectStore.clear();
        _stepFreeze.diverRelationStore.clear();
        _stepFreeze.buy1HistoryByKn.clear();
        _stepFreeze.sell1HistoryByKn.clear();
        _stepFreeze.buy2HistoryByKn.clear();
        _stepFreeze.sell2HistoryByKn.clear();
        _stepFreeze.buyNHistoryByKn.clear();
        _stepFreeze.sellNHistoryByKn.clear();
        _stepFreeze.bsVerdictHistoryByKn.clear();
        _stepFreeze.adjacentRatioHistoryByKn.clear();
        _stepFreeze.lineSlopeHistoryByKn.clear();
        _stepFreeze.stepRhythmHistoryByKn.clear();
        for (final s in _stepFreeze.stepRhythmStateByKn.values) {
          s.reset();
        }
        _stepFreeze.stepRhythmStateByKn.clear();
        _stepFreeze.mathFreezeStore.clear();
        _stepFreeze.diverFreezeStore.clear();
        _stepFreeze.chipPeakStore.clear();
        _stepFreeze.knClockTimeline.clear();
        _stepFreeze.knClockSeenUnits.clear();
        _clearBacktestSession();
      });
      _msgHistory.append('加载K0失败：$e');
    } finally {
      if (mounted) setState(() => _loadingChart = false);
    }
    if (quality != null && mounted) {
      await _promptTickQuality(quality);
    }
    // 智能体验证：K 线加载成功后启动 HTTP API + 文件轮询（不在 robot_verify 专用模式下启用）
    if (mounted && !_robotVerifyEnabled() && _allBars.isNotEmpty) {
      await _startAgentApiIfEnabled();
    }
  }

  /// 笔数分布已开启且笔数为 0 时询问是否继续用该图。
  Future<void> _promptTickQuality(TickQuality q) async {
    final tickDistOn = _tickDistConfig.enabled;
    final need = q.shouldPrompt(tickDistEnabled: tickDistOn);
    if (q.skipPrompts || !need) {
      if (!_tickDistSessionAllowed) {
        setState(() => _tickDistSessionAllowed = true);
      }
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    var allow = true;
    if (q.zeroTickCount && tickDistOn) {
      final go = await _askChipTickContinue(
        title: '分笔笔数为 0',
        body: '笔数分布图已开启，但所选区间里有分笔的笔数是 0。'
            '主图左侧笔数分布会没有柱。'
            '要继续用笔数分布吗？\n\n'
            '点「不继续」：K 线和缠论仍加载；本会话关掉笔数分布（不改你保存的设置）。',
      );
      allow = go && allow;
    }
    if (!mounted) return;
    setState(() {
      _tickDistSessionAllowed = allow;
    });
    if (!allow) {
      _msgHistory.append(
        '本会话已关掉笔数分布（K 线与缠论仍在；不改保存的设置）',
      );
    } else {
      _msgHistory.append('已选择继续使用笔数分布');
    }
  }

  Future<bool> _askChipTickContinue({
    required String title,
    required String body,
  }) async {
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不继续'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续用'),
          ),
        ],
      ),
    ));
    return go == true;
  }

  /// 把当前可见窗口的展示轨分型判断并入会话日志（追加去重，不删旧点）。
  void _mergeJudgmentHistory({
    required List<KlineBar> bars,
    required List<LevelBundle> levels,
    required List<BarCrosshairFeature> barFeatures,
    required List<K0Line> k0Lines,
    bool copyForPaint = true,
  }) {
    StepFreezeMerger.mergeJudgmentHistory(
      state: _stepFreeze,
      bars: bars,
      levels: levels,
      barFeatures: barFeatures,
      k0Lines: k0Lines,
      stepIdx: _stepIdx,
      truncationCheck: _truncationCheck,
      copyForPaint: copyForPaint,
    );
  }

  /// 本步中枢帧 → 判断/确认会话历史（先确认后判断；确认同拍共点）。
  /// 返回各层本步新确认的 x1（供背驰本枢启动）。
  Map<int, Set<int>> _mergeZsSignalHistory(
    KlineCombineBundle bundle, {
    bool copyForPaint = true,
  }) {
    return StepFreezeMerger.mergeZsSignalHistory(
      state: _stepFreeze,
      bundle: bundle,
      stepIdx: _stepIdx,
      copyForPaint: copyForPaint,
    );
  }

  void _mergeBsHistory(KlineCombineBundle bundle, {bool copyForPaint = true}) {
    StepFreezeMerger.mergeBsHistory(
      state: _stepFreeze,
      bundle: bundle,
      stepIdx: _stepIdx,
      copyForPaint: copyForPaint,
    );
  }

  /// 本步相邻比例 + 步进节奏 + 连线斜率并入会话（全层；禁止整表覆盖消点）。
  /// 指标遵循动态计算：传入 bars/barFeatures，子线含展示轨虚线。
  void _mergeRatioAndRhythm(
    KlineCombineBundle bundle, {
    List<KlineBar>? bars,
    bool copyForPaint = true,
  }) {
    StepFreezeMerger.mergeRatioAndRhythm(
      state: _stepFreeze,
      bundle: bundle,
      bars: bars ?? _visibleBars,
      stepIdx: _stepIdx,
      truncationCheck: _truncationCheck,
      copyForPaint: copyForPaint,
    );
  }

  /// 本步 Math/均线/通道/Demark 并入会话冻结（禁 activeUnit 整表回写）。
  void _mergeMathFreeze(
    KlineCombineBundle bundle, {
    List<KlineBar>? bars,
    int? asOf,
    bool ingestChip = true,
  }) {
    StepFreezeMerger.mergeMathFreeze(
      state: _stepFreeze,
      bundle: bundle,
      bars: bars ?? _visibleBars,
      stepIdx: _stepIdx,
      truncationCheck: _truncationCheck,
      mathConfig: _mathIndicatorConfig,
      chipConfig: _chipConfig,
      ingestChip: ingestChip,
      asOf: asOf,
    );
  }

  /// 本步背驰并入会话冻结（本层力度；旧格不改、新 x 追加）。
  void _mergeDivergenceFreeze(
    KlineCombineBundle bundle, {
    List<KlineBar>? bars,
    int? asOf,
    Map<int, Set<int>> confirmedX1ByKn = const {},
  }) {
    StepFreezeMerger.mergeDivergenceFreeze(
      state: _stepFreeze,
      bundle: bundle,
      bars: bars ?? _visibleBars,
      stepIdx: _stepIdx,
      mathConfig: _mathIndicatorConfig,
      confirmedX1ByKn: confirmedX1ByKn,
      asOf: asOf,
    );
  }

  /// K1+ 采样钟：记下本步「当时」的 K1 段划分（已确认段增量 + 正在生长的那段）。
  ///
  /// 每根 K 都要记一条：K1 及以上的穿越/事件按「虚拟 K 样本」取样，采样点落在哪根 K
  /// 取决于当时那一段走到哪。少了这一步，主图会话的采样钟时间线恒为空，
  /// 策略回测 / 寻优会退回「一段一个点」的最终态口径，把动态段中途成立的信号推到段尾。
  /// 独立 harness 走 `StepFreezeMerger.mergeRebuildCombineFreeze`（内含这一步），
  /// 主图这两条合并链是逐个 statics 手写的，必须自己补上，否则两条口径不等。
  void _recordKnClockStep(KlineCombineBundle bundle) {
    StepFreezeMerger.recordKnClockStep(
      state: _stepFreeze,
      bundle: bundle,
      stepIdx: _stepIdx,
    );
  }

  List<LevelBundle> _levelsWithFrozenBs(List<LevelBundle> levels) {
    final with1 = levelsWithFrozenClass1Bs(
      levels,
      buy1HistoryByKn: _stepFreeze.buy1HistoryByKn,
      sell1HistoryByKn: _stepFreeze.sell1HistoryByKn,
    );
    final with2 = levelsWithFrozenClass2Bs(
      with1,
      buy2HistoryByKn: _stepFreeze.buy2HistoryByKn,
      sell2HistoryByKn: _stepFreeze.sell2HistoryByKn,
    );
    final withN = levelsWithFrozenClassNBs(
      with2,
      buyNHistoryByKn: _stepFreeze.buyNHistoryByKn,
      sellNHistoryByKn: _stepFreeze.sellNHistoryByKn,
    );
    return levelsWithFrozenBsVerdict(
      withN,
      historyByKn: _stepFreeze.bsVerdictHistoryByKn,
    );
  }

  void _rebuildCombine({bool skipFreezeMerge = false}) {
    if (_chipOnlyMode) return;
    if (_visibleBars.isEmpty) {
      _pipelineSession?.cache.reset();
      setState(() {
        _combineFrames = [];
        _k0ConfirmSignals = [];
        _barFeatures = [];
        _k0Lines = [];
        _k1BarViews = [];
        _k1CombineFrames = [];
        _k1Analysis = K1AnalysisBundle.empty();
        _levels = [];
        _zsK0Frames = [];
        _buy1K0Frames = [];
        _sell1K0Frames = [];
        _buy2K0Frames = [];
        _sell2K0Frames = [];
        _buyNK0Frames = [];
        _sellNK0Frames = [];
        _stepFreeze.clear();
      });
      return;
    }
    try {
      final bundle = _bundleForVisible(_visibleBars);
      if (bundle.defaultK0Policy == 'purged') {
        _defaultK0Purged = true;
      }
      var virtualBars = bundle.k1Bars;
      // 会话级 purge：种子框首段为 A→B；步退回首K0连线确认前不再展示默认 K1 bar
      if (_defaultK0Purged &&
          (bundle.defaultK0Policy == 'pending' ||
              bundle.defaultK0Policy == 'seed') &&
          bundle.k0Lines.isEmpty) {
        virtualBars = const [];
      }
      final k1Views = buildK1BarViews(virtualBars);
      // 管道仍长于画面：步退用当步仓，冻结历史已有，禁止再合并
      final sessNow = _pipelineSession;
      final asofKeep = sessNow != null && sessNow.len > _visibleCount;
      Map<int, Set<int>> zsConfirmed = const {};
      if (!asofKeep && !skipFreezeMerge) {
        // 本步展示轨判断事件 → 追加进会话日志
        _mergeJudgmentHistory(
          bars: _visibleBars,
          levels: bundle.levels,
          barFeatures: bundle.barFeatures,
          k0Lines: bundle.k0Lines,
        );
        // 会话冻结：并入本步一类BS，禁止下一步整表覆盖消掉上步显示
        _mergeBsHistory(bundle);
        zsConfirmed = _mergeZsSignalHistory(bundle);
        _recordKnClockStep(bundle);
        _mergeRatioAndRhythm(bundle);
        _mergeMathFreeze(bundle);
        _mergeDivergenceFreeze(bundle, confirmedX1ByKn: zsConfirmed);
      }
      _syncPresentationLookup(_visibleBars, bundle);
      final frozenLevels = _levelsWithFrozenBs(bundle.levels);
      setState(() {
        _combineFrames = bundle.frames;
        _k0ConfirmSignals = bundle.k0Confirms;
        _barFeatures = bundle.barFeatures;
        _k0Lines = bundle.k0Lines;
        _k1BarViews = k1Views;
        _k1CombineFrames = bundle.k1CombineFrames;
        _k1Analysis = bundle.k1Analysis;
        _defaultK0Policy = bundle.defaultK0Policy;
        _levels = frozenLevels;
        _zsK0Frames = bundle.zsK0Frames;
        _buy1K0Frames = _stepFreeze.buy1HistoryByKn[0] ?? const [];
        _sell1K0Frames = _stepFreeze.sell1HistoryByKn[0] ?? const [];
        _buy2K0Frames = _stepFreeze.buy2HistoryByKn[0] ?? const [];
        _sell2K0Frames = _stepFreeze.sell2HistoryByKn[0] ?? const [];
        _buyNK0Frames = _stepFreeze.buyNHistoryByKn[0] ?? const [];
        _sellNK0Frames = _stepFreeze.sellNHistoryByKn[0] ?? const [];
        // 按当前最高 Kn 动态裁剪已选指标（层变少时去掉失效项）
        final maxKn = chartMaxKn(
          levels: _levels,
          k0Lines: _k0Lines,
        );
        _mainIndicators = pruneIndicators(
          _mainIndicators,
          buildMainIndicatorCatalog(maxKn),
        );
        _subIndicators = pruneIndicators(
          _subIndicators,
          buildSubIndicatorCatalog(
            maxKn,
            truncationCheck: _truncationCheck,
            maxBsClass: _maxBsClass,
          ),
        );
      });
      // 智能体验证：刷新文件轮询状态
      _agentApiServer?.refreshStateFile();
    } catch (e) {
      setState(() => _error = e.toString());
      _msgHistory.append('Kn合并计算失败：$e');
    }
  }

  /// 写入历史记录：当前步可见K0 与各层段数（便于一键复制排查）。
  void _logCombineSummary({String prefix = '逐K汇总'}) {
    if (_visibleBars.isEmpty) return;
    final tail = _visibleBars.last;
    final levelCount = _levels.length;
    final lastLevelSegs =
        _levels.isNotEmpty ? _levels.last.segments.length : _k0Lines.length;
    _msgHistory.append(
      '$prefix @$_visibleCount/${_allBars.length} idx=${tail.idx} '
      '层数=$levelCount 末层Kn段=$lastLevelSegs K1段=${_k0Lines.length} '
      'policy=$_defaultK0Policy 截断=${_truncationCheck ? "开" : "关"}',
    );
  }

  String _buildDebugSnapshotText() {
    return AppDebugSnapshot.build(
      dataRoot: _dataRoot,
      code: _selectedCode,
      period: _period,
      periodLabel: _periods[_period] ?? _period,
      beginDate: _fmtDateTime(_beginDate),
      endDate: _fmtDateTime(_endDate),
      stepIdx: _stepIdx,
      totalBars: _allBars.length,
      visibleCount: _visibleCount,
      playing: _playing,
      defaultK0Policy: _defaultK0Policy,
      truncationCheck: _truncationCheck,
      subIndicatorLabels: _subIndicators.map((e) => e.label).toSet(),
      mainIndicatorLabels: _mainIndicators.map((e) => e.label).toSet(),
      visibleBars: _visibleBars,
      combineFrames: _combineFrames,
      k0Confirms: _k0ConfirmSignals,
      barFeatures: _barFeatures,
      k0Lines: _k0Lines,
      k1CombineFrames: _k1CombineFrames,
      k1Analysis: _k1Analysis,
      levels: _levels,
      buy1K0Frames: _buy1K0Frames,
      sell1K0Frames: _sell1K0Frames,
      buy2K0Frames: _buy2K0Frames,
      sell2K0Frames: _sell2K0Frames,
      buyNK0Frames: _buyNK0Frames,
      sellNK0Frames: _sellNK0Frames,
      lastError: _error,
    );
  }

  String _shortProbeTime(DateTime t) {
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  /// 整合排查快照：页面状态（已去静态口径文档）+ 最近历史 + 验收探针，去重精简。
  /// 替代原「一键复制历史记录 / 查看历史记录 / 复制页面快照 / 复制调试信息」四个按钮。
  String _buildConsolidatedProbeText() {
    final buf = StringBuffer();
    // 1) 页面状态快照（AppDebugSnapshot 已移除静态口径文档与历史尾，避免重复）
    buf.writeln(_buildDebugSnapshotText());
    buf.writeln();
    // 2) 最近历史（紧凑尾段，替代原全量复制 + 快照“最近10条”两处重复）
    final hist = MsgHistory.instance.rows;
    buf.writeln('【历史记录最近20条】');
    if (hist.isEmpty) {
      buf.writeln('（无）');
    } else {
      final tail = hist.length <= 20 ? hist : hist.sublist(hist.length - 20);
      for (final e in tail) {
        buf.writeln('[${_shortProbeTime(e.time)}] ${e.text}');
      }
    }
    buf.writeln();
    // 3) 验收探针（常驻：T1/T2 验收，保留为段落）
    if (_allBars.isNotEmpty && _stepIdx >= 0) {
      try {
        final fed = _allBars.take(_stepIdx + 1).toList();
        final probe = AuditProbeSnapshot.build(
          code: _selectedCode ?? '',
          period: _period,
          periodLabel: _periods[_period] ?? _period,
          beginDate: _fmtDateTime(_beginDate),
          endDate: _fmtDateTime(_endDate),
          stepIdx: _stepIdx,
          bars: fed,
          sessionLevels: _levels,
          barFeatures: _barFeatures,
          stepRhythmHistoryByKn: _stepFreeze.stepRhythmHistoryByKn,
        );
        buf.writeln(probe);
      } catch (e) {
        buf.writeln('【验收探针生成失败】$e');
      }
    } else {
      buf.writeln('【验收探针】尚未加载或步进，跳过。');
    }
    return buf.toString().trim();
  }

  /// 单按钮：弹窗查看整合快照（可滚动 + 可复制），底部「复制」带走；
  /// 「完整历史」次级入口保留全量历史浏览与清空能力。
  void _showConsolidatedProbeDialog(BuildContext context) {
    final text = _buildConsolidatedProbeText();
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(
        child: AlertDialog(
          title: const Text('排查快照'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _msgHistory.showDialog(context),
              child: const Text('完整历史'),
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                Navigator.pop(ctx);
                _msgHistory.append('已复制排查快照（含最近历史+验收探针）');
                _showSnack('排查快照已复制');
              },
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _stopPlay() {
    _playTimer?.cancel();
    _playTimer = null;
    _playing = false;
    _silentPlay = false;
    // 互斥：开始播放/步退任一方时另一方必须停。
    _stepBackTimer?.cancel();
    _stepBackTimer = null;
    _stepBackHolding = false;
  }

  void _togglePlay() {
    if (!_hasSession || _stepIdx >= _allBars.length - 1) return;
    if (_playing) {
      _pausePlay();
      return;
    }
    _startPlay(silent: false);
  }

  /// 开始播放。
  ///
  /// [silent]：true（默认）= 右边界长按触发的按住播放，不弹「自动播放」胶囊；
  /// false = 中间区域点击触发的播放，仍弹胶囊。
  void _startPlay({bool silent = true}) {
    if (!_hasSession || _playing || _stepIdx >= _allBars.length - 1) return;
    _stopPlay();
    _silentPlay = silent;
    setState(() => _playing = true);
    _dismissTickYinYang();
    _refreshKeepAlive();
    unawaited(_playNextTick());
  }

  /// 暂停播放（长按松开）。
  void _pausePlay() {
    if (!_playing) return;
    _stopPlay();
    setState(() {});
    _refreshKeepAlive();
  }

  /// 链式播放：重算后再等至少一帧，避免 periodic 在重算>120ms 时把步进叠死。
  Future<void> _playNextTick() async {
    _playTimer?.cancel();
    _playTimer = null;
    if (!mounted || !_playing) return;
    if (_stepIdx >= _allBars.length - 1) {
      _stopPlay();
      setState(() {});
      return;
    }
    setState(() {
      _stepIdx += 1;
      _stepSerial += 1;
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !_playing) return;
    final sw = Stopwatch()..start();
    _rebuildCombine();
    if (!mounted || !_playing) return;
    final elapsed = sw.elapsedMilliseconds;
    final wait = math.max(16, 120 - elapsed);
    _playTimer = Timer(Duration(milliseconds: wait), () {
      unawaited(_playNextTick());
    });
  }

  void _stepForward() {
    if (!_hasSession || _stepIdx >= _allBars.length - 1) return;
    _stopPlay();
    _dismissTickYinYang();    setState(() {
      _stepIdx += 1;
      _stepSerial += 1;
    });
    _rebuildCombine();
  }

  void _stepBack() {
    if (!_hasSession || _stepIdx <= 0) return;
    _stopPlay();
    _dismissTickYinYang();
    setState(() {
      _stepIdx -= 1;
      _stepSerial += 1;
    });
    _rebuildCombine();
  }

  /// 左边界长按：按住连续步退，松开即停（与右边界"按住播放"同构）。
  void _startStepBackHold() {
    if (!_hasSession || _stepBackHolding || _stepIdx <= 0) return;
    _stopPlay();
    _stepBackHolding = true;
    _dismissTickYinYang();
    _refreshKeepAlive();
    unawaited(_stepBackNextTick());
  }

  /// 左边界长按松开：停止连续步退。
  void _stopStepBackHold() {
    if (!_stepBackHolding) return;
    _stepBackHolding = false;
    _stepBackTimer?.cancel();
    _stepBackTimer = null;
    setState(() {});
    _refreshKeepAlive();
  }

  /// 顶栏「步退至开始」：回到首根 K、重置步进会话（恢复左边界长按原重置逻辑）。
  void _restartFromBeginning() {
    if (!_hasSession) return;
    _stopPlay();
    _dismissTickYinYang();
    _clearSessionFreezeHistory();
    _disposePipelineSession();
    setState(() => _stepIdx = 0);
    _rebuildCombine();
  }

  /// 链式连续步退：每次步退一根 K；退到首根自动停。
  Future<void> _stepBackNextTick() async {
    _stepBackTimer?.cancel();
    _stepBackTimer = null;
    if (!mounted || !_stepBackHolding) return;
    if (_stepIdx <= 0) {
      _stepBackHolding = false;
      setState(() {});
      return;
    }
    setState(() {
      _stepIdx -= 1;
      _stepSerial += 1;
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !_stepBackHolding) return;
    final sw = Stopwatch()..start();
    _rebuildCombine();
    if (!mounted || !_stepBackHolding) return;
    final wait = math.max(16, 120 - sw.elapsedMilliseconds);
    _stepBackTimer = Timer(Duration(milliseconds: wait), () {
      unawaited(_stepBackNextTick());
    });
  }

  /// 「恢复布局」：各窗视口复位到默认布局，并清除"手动调整过"标记——
  /// 之后的步进回到旧的自动归位口径（全量/居中），直到再次手动缩放/平移。
  void _resetLayout() {
    if (_bootstrapping || _busy) return;
    setState(() => _resetViewSerial += 1);
  }

  /// 顶栏「子窗口全屏」下拉：列出各分窗层级，选中的层铺满图表区。
  void _showSplitFullscreenMenu(BuildContext btnCtx) {
    final levels = LevelWindowSettingsStore.activeLevels;
    final overlay =
        Overlay.of(btnCtx).context.findRenderObject() as RenderBox?;
    final btn = btnCtx.findRenderObject() as RenderBox?;
    Navigator.of(btnCtx)
        .push<int>(
      _SplitFullscreenPopupRoute(
        items: [
          for (final lv in levels)
            PopupMenuItem<int>(
              value: lv,
              height: 32,
              child: Text(
                'K$lv',
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
        position: btn != null && overlay != null
            ? RelativeRect.fromRect(
                Rect.fromPoints(
                  btn.localToGlobal(
                    Offset(0, btn.size.height),
                    ancestor: overlay,
                  ),
                  btn.localToGlobal(
                    btn.size.bottomRight(Offset.zero),
                    ancestor: overlay,
                  ),
                ),
                Offset.zero & overlay.size,
              )
            : RelativeRect.fromLTRB(0, 0, 0, 0),
      ),
    )
        .then((picked) {
      if (picked != null && mounted) {
        setState(() => _splitFullscreenLevel = picked);
        _msgHistory.append('子窗口全屏：K$picked');
      }
    });
  }

  Future<void> _runToEnd({MlBspSampler? mlSampler}) async {
    if (!_hasSession || _runningToEnd) return;
    _stopPlay();
    final end = _allBars.length - 1;
    final start = _stepIdx < 0 ? 0 : _stepIdx;
    if (_chipOnlyMode) {
      // 仅筹码：直接跳到末尾，跳过缠论逻辑
      setState(() => _stepIdx = end);
      // 后台预热前缀索引，避免首帧主线程 build 卡一下
      unawaited(
        ChipProfileCompute.warmUpInBackground(
          _allBars,
          bucketStep: _chipConfig.bucketStep,
        ),
      );
      return;
    }
    _cancelRunToEnd = false;
    _runningToEnd = true;
    final total = end - start + 1;
    _longOpHint.value = '一次性走完 0 / $total，请稍候…';
    setState(() {});
    _refreshKeepAlive();
    _dismissTickYinYang();
    if (Platform.isWindows) {
      try {
        await _runToEndYinYang.showCentered(
          heightFactor: 0.25,
          opacity: 0.5,
        );
        _nativeYinYangActive = _runToEndYinYang.isShowing;
        if (mounted) setState(() {});
      } catch (_) {
        _nativeYinYangActive = false;
      }
    }
    var cancelled = false;
    var lastYield = DateTime.fromMillisecondsSinceEpoch(0);
    if (start == 0) {
      _clearSessionFreezeHistory();
      _disposePipelineSession();
    }
    try {
      final growing =
          start > 0 ? _allBars.sublist(0, start) : <KlineBar>[];
      final sess = _pipelineSession;
      sess?.slimDeltaStructure = true;
      for (var i = start; i <= end; i++) {
        _stepIdx = i;
        growing.add(_allBars[i]);
        if (i == end) {
          sess?.slimDeltaStructure = false;
        }
        try {
          final bundle = _bundleForVisible(growing);
          if (bundle.defaultK0Policy == 'purged') {
            _defaultK0Purged = true;
          }
          _mergeJudgmentHistory(
            bars: growing,
            levels: bundle.levels,
            barFeatures: bundle.barFeatures,
            k0Lines: bundle.k0Lines,
            copyForPaint: false,
          );
          // 一类/二类BS 也逐K并入会话冻结，避免一次性走完只剩末态
          _mergeBsHistory(bundle, copyForPaint: false);
          final zsConfirmed = _mergeZsSignalHistory(
            bundle,
            copyForPaint: false,
          );
          _recordKnClockStep(bundle);
          _mergeRatioAndRhythm(
            bundle,
            bars: growing,
            copyForPaint: false,
          );
          _mergeMathFreeze(
            bundle,
            bars: growing,
            asOf: i,
            ingestChip: false,
          );
          _mergeDivergenceFreeze(
            bundle,
            bars: growing,
            asOf: i,
            confirmedX1ByKn: zsConfirmed,
          );
          // 画面只在末态刷新：循环内不刷 Lookup（冻结仍逐步 merge）
          // 仅 ML 路径：采 K0 一类 BS 当下特征（不改复盘语义）
          mlSampler?.onStep(
            stepIdx: i,
            visibleBars: growing,
            buy1K0: _stepFreeze.buy1HistoryByKn[0] ?? const [],
            sell1K0: _stepFreeze.sell1HistoryByKn[0] ?? const [],
            buildLookup: () => _buildMlLookupFor(
              bars: growing,
              combineFrames: bundle.frames,
              k0Confirms: bundle.k0Confirms,
              barFeatures: bundle.barFeatures,
              k0Lines: bundle.k0Lines,
              levels: bundle.levels,
              k1CombineFrames: bundle.k1CombineFrames,
              k1Analysis: bundle.k1Analysis,
              zsK0Frames: bundle.zsK0Frames,
            ),
          );
          // α：展望窗到期用**当步 live 一类**打标，不用跳末末态
          if (mlSampler != null) {
            final liveBuy = collectBuy1EventsByKn(bundle)[0] ?? const [];
            final liveSell = collectSell1EventsByKn(bundle)[0] ?? const [];
            MlBspLabeler.labelDueSamples(
              samples: mlSampler.samples,
              asOfIdx: i,
              horizonBars: _mlLabelConfig.horizonBars,
              isLastBar: i == end,
              liveBuy1: liveBuy,
              liveSell1: liveSell,
              k0LinesAsOf: bundle.k0Lines,
              barsAsOf: growing,
            );
          }
        } catch (e) {
          _msgHistory.append('一次性走完@step=$i 失败：$e');
          break;
        }
        final now = DateTime.now();
        if (i == start ||
            i == end ||
            now.difference(lastYield).inMilliseconds >= 200) {
          final done = i - start + 1;
          _longOpHint.value =
              '一次性走完 $done / $total（第 ${i + 1} 根），请稍候…';
          await Future<void>.delayed(Duration.zero);
          lastYield = DateTime.now();
          if (!mounted) return;
          if (_cancelRunToEnd) {
            cancelled = true;
            sess?.slimDeltaStructure = false;
            _msgHistory.append('一次性走完已取消，停在第 ${i + 1} 根（冻结保留到这里）');
            break;
          }
        }
      }
      final chipAsOf = growing.isEmpty ? end : growing.last.idx;
      _ingestAllChipPeakSchemes(
        asOf: chipAsOf,
        bars: growing,
        bucketStep: _chipConfig.bucketStep,
      );
      // 循环里已逐 K 合并冻结，末态只刷查表和画面，避免再合一遍
      _rebuildCombine(skipFreezeMerge: true);
      _logCombineSummary(prefix: cancelled ? '一次性走完(取消)' : '一次性走完');
    } finally {
      _pipelineSession?.slimDeltaStructure = false;
      _runningToEnd = false;
      _nativeYinYangActive = false;
      await _runToEndYinYang.hide();
      if (mounted) {
        _longOpHint.value = '';
        setState(() {});
        _refreshKeepAlive();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_useAndroidInteraction) {
      return _buildAndroidShell(context);
    }
    return _buildDesktopShell(context);
  }

  /// 桌面：图表铺满 + 透明标题条 + 左右设置浮层。
  Widget _buildDesktopShell(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.canvasBg,
      // 工具条化：标题条作为 Column 第一行占位，图表整体下移一条
      // （kDesktopCaptionBarHeight），子窗口 K 标签贴极右缘不再压窗控。
      body: Column(
        children: [
          SizedBox(
            height: kDesktopCaptionBarHeight,
            width: double.infinity,
            child: _buildCaptionBar(),
          ),
          Expanded(
        child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(kDesktopShellInset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppPalette.canvasBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.rgb(0x33FFFFFF)),
                ),
                // ML：主区只挂成果页（无 K 线图）；否则复盘 K 线
                child: _mlSession.isActive
                    ? MlWorkbench(
                        statusLine: _mlStatusLine(),
                        progressHint: _mlProgressHint,
                        phase: _mlPhase,
                        splitConfig: _mlSplitConfig,
                        onSplitConfigChanged: _onMlSplitConfigChanged,
                        labelConfig: _mlLabelConfig,
                        onLabelConfigChanged: (c) =>
                            setState(() => _mlLabelConfig = c),
                        testLocked: _mlTestLocked,
                        code: _selectedCode ?? '',
                        period: _period,
                        dataRoot: _dataRoot,
                        isXgbMode: _isXgbMode,
                        onTrainerKindChanged: (k) {
                          if (_mlTestLocked) {
                            _showSnack('测试已锁定：不可切换训练器');
                            return;
                          }
                          setState(() {
                            _isXgbMode = k == MlTrainerKind.xgb;
                            _mlReport = null;
                            _mlSamples = [];
                            _mlPhase = MlPreparePhase.setup;
                            _mlError = null;
                          });
                        },
                        xgbParams: _xgbParams,
                        onXgbParamsChanged: (p) {
                          if (_mlTestLocked) return;
                          setState(() => _xgbParams = p);
                        },
                        forceXgbRetrain: _forceXgbRetrain,
                        onForceXgbRetrainChanged: (v) {
                          if (_mlTestLocked) return;
                          setState(() => _forceXgbRetrain = v);
                        },
                        samples: _mlSamples,
                        report: _mlReport,
                        errorText: _mlError,
                        onExit: _exitMlSession,
                        onLoad: _loadMlRun,
                      )
                    : _buildReplayBody(),
              ),
            ),
          ),
          if (_error != null)
            Positioned(
              left: 12,
              right: 120,
              // 标题条已工具条化占位到 body 之上，横幅贴 body 顶部即可。
              top: 8,
              child: Text(_error!, style: TextStyle(color: AppPalette.rgb(0xFFFFA726))),
            ),
          // 设置打开时：点非面板区域关闭，不穿透到 K 线播放手势
          if (_panelExpanded)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _panelExpanded = false),
                child: ColoredBox(color: AppPalette.rgb(0x33000000)),
              ),
            ),
          if (_panelExpanded)
            EdgeControlPanel(
              edge: _panelEdge,
              onClose: () => setState(() => _panelExpanded = false),
              onCycleEdge: () => setState(() => _panelEdge = 1 - _panelEdge),
              child: _buildPanelBody(),
            ),
          if (_period == 'tick' &&
              (_loadingChart || _tickYinYangCover) &&
              !_mlSession.isActive)
            _buildTickYinYangOverlay(context),
          if (_runningToEnd && !_mlSession.isActive)
            _buildRunToEndYinYangOverlay(context),
          if (_runningToEnd || _playing) _buildLongOpBanner(),
          if (_loadingChart && _period != 'tick')
            Positioned.fill(
              child: IgnorePointer(
                child: Center(child: _chartLoadingIndicator()),
              ),
            ),
          if (_libHalt) _buildLibHaltOverlay(),
          if (_tickDrawBoardOpen &&
              _tickDrawBoard != null &&
              _tickDrawBundle != null)
            Positioned.fill(
              child: TickDrawBoard(
                model: _tickDrawBoard!,
                bundle: _tickDrawBundle!,
                mainIndicators: _splitMainIndicators,
                subIndicators: _sessionSplitSubIndicators,
                truncationCheck: _truncationCheck,
                earlyDynamicUnit: _earlyDynamicUnit,
                preFirstFractalMode: _preFirstFractalMode,
                showBuildingDash: _showBuildingDash,
                chipConfig: _chipConfig,
                tickDistConfig: _tickDistConfig,
                onChanged: _updateTickDrawBoard,
                onMainIndicatorsChanged: _applySplitMainIndicators,
                onSubIndicatorsChanged: _applySplitSubIndicators,
              ),
            ),
        ],
      ),
          ),
        ],
      ),
    );
  }

  /// 手机：全屏图表 + 浮动设置钮；股票/周期在设置抽屉。
  Widget _buildAndroidShell(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: AppPalette.canvasBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: _mlSession.isActive
                ? MlWorkbench(
                    statusLine: _mlStatusLine(),
                    progressHint: _mlProgressHint,
                    phase: _mlPhase,
                    splitConfig: _mlSplitConfig,
                    onSplitConfigChanged: _onMlSplitConfigChanged,
                    labelConfig: _mlLabelConfig,
                    onLabelConfigChanged: (c) =>
                        setState(() => _mlLabelConfig = c),
                    testLocked: _mlTestLocked,
                    code: _selectedCode ?? '',
                    period: _period,
                    dataRoot: _dataRoot,
                    isXgbMode: _isXgbMode,
                    onTrainerKindChanged: (k) {
                      if (_mlTestLocked) {
                        _showSnack('测试已锁定：不可切换训练器');
                        return;
                      }
                      setState(() {
                        _isXgbMode = k == MlTrainerKind.xgb;
                        _mlReport = null;
                        _mlSamples = [];
                        _mlPhase = MlPreparePhase.setup;
                        _mlError = null;
                      });
                    },
                    xgbParams: _xgbParams,
                    onXgbParamsChanged: (p) {
                      if (_mlTestLocked) return;
                      setState(() => _xgbParams = p);
                    },
                    forceXgbRetrain: _forceXgbRetrain,
                    onForceXgbRetrainChanged: (v) {
                      if (_mlTestLocked) return;
                      setState(() => _forceXgbRetrain = v);
                    },
                    samples: _mlSamples,
                    report: _mlReport,
                    errorText: _mlError,
                    onExit: _exitMlSession,
                    onLoad: _loadMlRun,
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
                    child: _buildReplayBody(),
                  ),
          ),
          if (_error != null)
            Positioned(
              left: 8,
              right: 56,
              top: topInset + 4,
              child: Material(
                color: AppPalette.rgb(0x33FF9800),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    _error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppPalette.rgb(0xFFFFA726), fontSize: 12),
                  ),
                ),
              ),
            ),
          if (_period == 'tick' &&
              (_loadingChart || _tickYinYangCover) &&
              !_mlSession.isActive)
            _buildTickYinYangOverlay(context),
          if (_runningToEnd && !_mlSession.isActive)
            _buildRunToEndYinYangOverlay(context),
          // 2026-11-13 用户明确：顶边栏下方原有次级栏（步退/步进/恢复布局/设置等）
          // 全部移除，功能统一在顶边栏提供。
          if (_loadingChart && _period != 'tick')
            Positioned.fill(
              child: IgnorePointer(
                child: Center(child: _chartLoadingIndicator()),
              ),
            ),
          if (_runningToEnd || _playing) _buildLongOpBanner(top: topInset + 48),
          if (_libHalt) _buildLibHaltOverlay(),
        ],
      ),
    );
  }

  /// 安卓设置抽屉入口（2026-11-13 起桌面次级栏移除后暂无调用方，资源保留，
  /// 安卓侧可按需接回；桌面对应入口是顶边栏的「设置」按钮）。
  // ignore: unused_element
  void _openAndroidSettings() {
    showAndroidSettingsSheet(
      context: context,
      onClosed: () => _settingsSheetSetState = null,
      builder: (ctx, sheetSetState) {
        _settingsSheetSetState = sheetSetState;
        return _buildPanelBody(forMobileSheet: true, sheetSetState: sheetSetState);
      },
    );
  }

  void _openAndroidStockPicker() {
    _refreshStockList();
    showAndroidStockPicker(
      context: context,
      codes: _codes,
      selected: _selectedCode,
      onSelected: (v) {
        setState(() {
          _selectedCode = v;
          _syncDateRangeForCode(v);
        });
        _loadKlines();
      },
    );
  }

  /// 刷新股票列表（仅重新列举 a_Data 下股票目录，不改当前选择、不重载 K 线）。
  /// 用于「点击股票下拉框」时自动刷新；原「刷新股票列表」按钮已移除。
  void _refreshStockList() {
    if (_dataRoot == null || _busy) return;
    final codes = _bridge.listStockCodes(dataRoot: _dataRoot);
    if (codes.isEmpty) return;
    final keep = _selectedCode != null && codes.contains(_selectedCode)
        ? _selectedCode!
        : _preferredCode(codes);
    _panelUi(() {
      _codes = codes;
      _selectedCode = keep;
    });
  }

  /// 标题条：左侧空白拖拽区 + 右侧 [恢复布局][设置][最小化][最大化][关闭]。
  ///
  /// 工具条化：整条作为 Column 第一行占位（不再叠在图表上），图表整体下移。
  /// 五键统一 28×28 自绘，**不用** `WindowCaptionButton`（强制 46×32）和
  /// `IconButton`（强制 48px 最小命中区）——28px 工具条里会溢出并与相邻按钮
  /// 叠在一起（用户反馈「设置左边出现了两个重叠按钮」的根因）。
  Widget _buildCaptionBar() {
    // 画板模式：**替换**整组按钮（不是另加一条栏）；切回主图自动恢复原按钮。
    // 左侧放画板名称，窗口数量下拉放在「保存并加载」与「最小化」之间。
    if (_tickDrawBoardOpen) {
      return Row(
        children: [
          const SizedBox(width: 10),
          _buildTickDrawBoardTitle(),
          const Expanded(
            child: DragToMoveArea(
              child: SizedBox(
                height: kDesktopCaptionBarHeight,
                child: ColoredBox(color: Color(0x00000000)),
              ),
            ),
          ),
          _buildTickDrawCaptionButtons(),
        ],
      );
    }
    return Row(
      children: [
        // 左侧空白：整条可拖动（双击最大化/还原），不再是穿透区。
        const Expanded(
          child: DragToMoveArea(
            child: SizedBox(
              height: kDesktopCaptionBarHeight,
              child: ColoredBox(color: Color(0x00000000)),
            ),
          ),
        ),
        // 步退至开始：回到首根 K（双向左箭头），与「步进至最后」成对。
        _CaptionBarButton(
          tooltip: '步退至开始',
          onTap: !_hasSession || _busy ? null : _restartFromBeginning,
          child: Icon(
            Icons.fast_rewind,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        // 步进至最后：原窗口右边界长按功能迁到顶栏（右边界长按改为播放/暂停）。
        _CaptionBarButton(
          tooltip: '步进至最后',
          onTap: !_hasSession || _busy ? null : () { unawaited(_runToEnd()); },
          child: Icon(
            Icons.fast_forward,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        // 子窗口全屏：点开下拉选择目标子窗口；已全屏时显示退出按钮。
        if (_splitFullscreenLevel != null)
          _CaptionBarButton(
            tooltip: '退出子窗口全屏',
            onTap: _busy
                ? null
                : () => setState(() => _splitFullscreenLevel = null),
            child: Icon(
              Icons.fullscreen_exit,
              size: 16,
              color: AppPalette.controlInk,
            ),
          )
        else if (_splitActive)
          Builder(
            builder: (btnCtx) => _CaptionBarButton(
              tooltip: '子窗口全屏（选择目标层）',
              onTap: _busy ? null : () => _showSplitFullscreenMenu(btnCtx),
              child: Icon(
                Icons.fullscreen,
                size: 16,
                color: AppPalette.controlInk,
              ),
            ),
          ),
        // 恢复布局：复位各窗视口，并恢复旧的步进自动归位逻辑。
        _CaptionBarButton(
          tooltip: '恢复布局',
          onTap: _bootstrapping || _busy ? null : _resetLayout,
          child: Icon(
            Icons.autorenew,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        _CaptionBarButton(
          tooltip: _panelExpanded ? '收起设置' : '设置',
          onTap: () => setState(() => _panelExpanded = !_panelExpanded),
          child: Icon(
            _panelExpanded ? Icons.close : Icons.settings,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        _CaptionBarButton(
          tooltip: '最小化',
          onTap: () => windowManager.minimize(),
          child: Icon(
            Icons.remove,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        _CaptionBarButton(
          tooltip: '最大化',
          onTap: _toggleFillWorkArea,
          child: Icon(
            Icons.crop_square,
            size: 14,
            color: AppPalette.controlInk,
          ),
        ),
        _CaptionBarButton(
          tooltip: '关闭',
          onTap: _requestCloseApp,
          child: Icon(
            Icons.close,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
      ],
    );
  }

  /// 画板顶边栏左侧的名称。
  Widget _buildTickDrawBoardTitle() {
    return Text(
      '分笔画板',
      style: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// 画板顶边栏的窗口数量下拉：放在「保存并加载」与「最小化」之间。
  Widget _buildTickDrawWindowCountDropdown() {
    final board = _tickDrawBoard;
    final count = normalizeLevelWindowCount(board?.windowCount);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: DropdownButton<int>(
        value: count,
        dropdownColor: AppPalette.surfaceAlt,
        style: TextStyle(color: AppPalette.textPrimary, fontSize: 12),
        underline: const SizedBox.shrink(),
        isDense: true,
        items: [
          for (final c in kLevelWindowCountChoices)
            DropdownMenuItem(value: c, child: Text('$c窗')),
        ],
        onChanged: board == null
            ? null
            : (next) {
                if (next != null) {
                  _updateTickDrawBoard(board.copyWith(windowCount: next));
                }
              },
      ),
    );
  }

  /// 画板模式下的顶边栏按钮组：**替换**主图顶边栏的原有按钮（不是另加一条栏）。
  /// 切回主图时 [main.dart] 自动恢复原按钮。
  Widget _buildTickDrawCaptionButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionBarButton(
          tooltip: '保存并加载',
          onTap: _saveTickDrawBoard,
          child: Icon(
            Icons.save_alt,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        _buildTickDrawWindowCountDropdown(),
        _CaptionBarButton(
          tooltip: '最小化',
          onTap: () => windowManager.minimize(),
          child: Icon(
            Icons.remove,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
        _CaptionBarButton(
          tooltip: '最大化',
          onTap: _toggleFillWorkArea,
          child: Icon(
            Icons.crop_square,
            size: 14,
            color: AppPalette.controlInk,
          ),
        ),
        _CaptionBarButton(
          tooltip: '关闭画板',
          onTap: _closeTickDrawBoard,
          child: Icon(
            Icons.close,
            size: 16,
            color: AppPalette.controlInk,
          ),
        ),
      ],
    );
  }

  /// 铺满工作区 ↔ 还原；不走原生 maximize（会盖任务栏）。
  Future<void> _toggleFillWorkArea() async {
    if (await isFillingWorkArea()) {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else if (_preWorkAreaBounds != null) {
        await windowManager.setBounds(_preWorkAreaBounds!);
      } else {
        await windowManager.setSize(const Size(1280, 720));
        await windowManager.center();
      }
      _preWorkAreaBounds = null;
    } else {
      _preWorkAreaBounds = await windowManager.getBounds();
      await fillDesktopWorkArea();
    }
  }

  Widget _buildPanelBody({    bool forMobileSheet = false,
    StateSetter? sheetSetState,
  }) {
    final advanced = _buildPanelAdvancedSection(
      sheetSetState: sheetSetState,
      forMobileSheet: forMobileSheet,
    );
    // 设置面板内所有文字（标签、开关标题、按钮文字等）支持鼠标拖选 + Ctrl+C 复制；
    // 由设置面板打开的各子对话框（说明/参数/确认弹窗，含子子UI 参数对话框）同样用
    // SelectionArea 包裹，故设置内所有层级的字符串均可复制。单击仍触发按钮/输入框，
    // 拖拽才进入选择，二者不冲突。
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        if (forMobileSheet)
          SettingsOutlinedButton(
            label: _selectedCode == null
                ? '选择股票 (${_codes.length})'
                : '股票：$_selectedCode',
            icon: Icons.list_alt,
            onPressed: _bootstrapping || _busy || _codes.isEmpty
                ? null
                : _openAndroidStockPicker,
          )
        else
          DropdownButtonFormField<String>(
            isExpanded: true,
            onTap: _refreshStockList,
            value: _codes.contains(_selectedCode) ? _selectedCode : null,
            hint: Text(_codes.isEmpty ? '无股票' : '选择股票'),
            decoration: InputDecoration(
              labelText: '股票 (${_codes.length})',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: _codes
                .map(
                  (c) => DropdownMenuItem(
                    value: c,
                    child: Text(c, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: _bootstrapping || _codes.isEmpty
                ? null
                : (v) {
                    if (v == null) return;
                    _panelUi(() {
                      _selectedCode = v;
                      _syncDateRangeForCode(v);
                    }, sheetSetState: sheetSetState);
                    _loadKlines();
                  },
          ),
        if (_selectedCode == 'test') ...[
          const SizedBox(height: 8),
          SettingsOutlinedButton(
            label: '编辑/加载自定义 OHLC',
            icon: Icons.edit_note,
            onPressed: _busy ? null : _openTestOhlcEditor,
            onHelp: _showTestOhlcHelp,
            helpTooltip: '自定义 OHLC 说明',
          ),
          const SizedBox(height: 8),
          SettingsOutlinedButton(
            label: '分笔画板',
            icon: Icons.gesture,
            onPressed: _busy ? null : _openTickDrawBoard,
            onHelp: _showTickDrawBoardHelp,
            helpTooltip: '分笔画板说明',
          ),
        ],
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                value: _periods.containsKey(_period) ? _period : 'tick',
                decoration: const InputDecoration(
                  labelText: '周期',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: _periods.entries
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(e.value, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: _bootstrapping
                    ? null
                    : (v) {
                        final next = v ?? 'tick';
                        _panelUi(() => _period = next,
                            sheetSetState: sheetSetState);
                        if (_selectedCode != null) _loadKlines();
                        _msgHistory.appendPeriodAutoReload();
                        _showPeriodHelp();
                      },
              ),
            ),
            IconButton(
              tooltip: '周期说明',
              icon: const Icon(Icons.help_outline, size: 18),
              onPressed: _showPeriodHelp,
            ),
          ],
        ),
        const SizedBox(height: 10),
        _datePickerField(
          label: '加载起始时间',
          value: _fmtDateTime(_beginDate),
          onTap: _busy ? null : () => _pickDateTime(isBegin: true),
        ),
        const SizedBox(height: 10),
        _datePickerField(
          label: '加载截止时间',
          value: _fmtDateTime(_endDate),
          onTap: _busy ? null : () => _pickDateTime(isBegin: false),
        ),
        const SizedBox(height: 10),
        SettingsOutlinedButton(
          label: _telegramSettings.telegramEnabled
              ? 'Telegram 数据源（已启用日线）'
              : 'Telegram 数据源',
          icon: Icons.cloud_download_outlined,
          onPressed: _busy ? null : () => _openTelegramSettings(),
          onHelp: () => _openTelegramSettings(),
          helpTooltip: 'Telegram 取数说明',
        ),
        TicksFullUploadPanel(
          settings: _telegramSettings,
          dataRoot: _fullUploadDataRoot(),
          onCreateTask: _createFullTicksUploadTask,
          onShareDir: (share) async {
            final next = _telegramSettings.copyWith(shareDir: share);
            setState(() => _telegramSettings = next);
            await TelegramSettingsStore.save(next);
          },
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey(_chipConfig.bucketStep),
          initialValue: _chipConfig.bucketStep.toStringAsFixed(2),
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '筹码分布桶宽',
            helperText: '最小 0.01；筹码/笔数分布共用',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onFieldSubmitted: (text) =>
              _applyBucketStepFromSettings(text, sheetSetState: sheetSetState),
        ),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        SettingsOutlinedButton(
          label: _backtestPanelOpen ? '策略回测（已打开）' : '策略回测',
          icon: Icons.show_chart,
          onPressed: (_busy && !_backtestPanelOpen) || _mlSession.isActive
              ? null
              : () => _openBacktestWorkbench(closeSettingsSheet: forMobileSheet),
        ),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        SettingsFilledButton(
          label: _indicatorSearchRunning ? '寻优（进行中）' : '寻优',
          icon: Icons.travel_explore,
          onPressed: _indicatorSearchRunning ||
                  _mlSession.isActive ||
                  (_busy && !_indicatorSearchRunning)
              ? null
              : () => _openIndicatorSearch(closeSettingsSheet: forMobileSheet),
          onHelp: () => showIndicatorSearchHelp(context),
          helpTooltip: '指标寻优说明',
        ),
        Row(
          children: [
            TextButton(
              onPressed: _indicatorSearchRunning
                  ? null
                  : () => _showLastSearchResultDialog(),
              child: const Text('上次寻优结果', style: TextStyle(fontSize: 12)),
            ),
            const Spacer(),
            TextButton(
              onPressed: _indicatorSearchRunning
                  ? null
                  : () async {
                      await showIndicatorSearchSettingsSheet(context);
                    },
              child: const Text('寻优参数', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        SettingsFilledButton(
          label: _keyPointStatRunning ? '计优（进行中）' : '计优',
          icon: Icons.analytics_outlined,
          onPressed: _keyPointStatRunning ||
                  _mlSession.isActive ||
                  (_busy && !_keyPointStatRunning)
              ? null
              : () => _openKeyPointStats(closeSettingsSheet: forMobileSheet),
          onHelp: () => showKeyPointStatsHelp(context),
          helpTooltip: '计优说明',
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _keyPointStatRunning
                ? null
                : () async {
                    await showKeyPointStatsSettingsSheet(context);
                  },
            child: const Text('计优参数', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('是否启用安卓操作逻辑', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _interactionManualOverride == null
                ? '自动：当前为${_useAndroidInteraction ? "安卓" : "Windows"}交互'
                : (_useAndroidInteraction
                    ? '手动：安卓手势与布局'
                    : '手动：Windows手势与布局'),
            style: const TextStyle(fontSize: 11),
          ),
          value: _useAndroidInteraction,
          onChanged: _busy
              ? null
              : (v) async {
                  await InteractionModeStore.saveManualOverride(v);
                  _panelUi(() {
                    _interactionManualOverride = v;
                    _useAndroidInteraction = v;
                  }, sheetSetState: sheetSetState);
                  _msgHistory.append(
                    '交互模式=${v ? "安卓操作逻辑" : "Windows操作逻辑"}（手动）',
                  );
                },
        ),
        if (_interactionManualOverride != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await InteractionModeStore.saveManualOverride(null);
                      _panelUi(() {
                        _interactionManualOverride = null;
                        _useAndroidInteraction =
                            InteractionModeStore.resolveUseAndroidLogic();
                      }, sheetSetState: sheetSetState);
                      _msgHistory.append('交互模式=跟随系统自动');
                    },
              child: const Text('恢复跟随系统自动', style: TextStyle(fontSize: 12)),
            ),
          ),
        const SizedBox(height: 8),
        // 截断监察开关：对照「加截断前」旧行为
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('截断机制', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _truncationCheck ? '已开启（当前口径）' : '已关闭（旧吸收行为）',
            style: const TextStyle(fontSize: 11),
          ),
          value: _truncationCheck,
          onChanged: _busy
              ? null
              : (v) => _setTruncationCheck(v, sheetSetState: sheetSetState),
          secondary: IconButton(
            tooltip: '截断机制说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showTruncationHelp,
          ),
        ),
        const SizedBox(height: 8),
        // 层级早生成动态单元：每层首个单元在父层首确认当根以动态态出现，默认开
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('层级早生成动态单元', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _earlyDynamicUnit
                ? '已开启（动态K取高高；种子框不画）'
                : '已关闭（经典口径：种子框照旧）',
            style: const TextStyle(fontSize: 11),
          ),
          value: _earlyDynamicUnit,
          onChanged: _busy
              ? null
              : (v) => _setEarlyDynamicUnit(v, sheetSetState: sheetSetState),
          secondary: IconButton(
            tooltip: '层级早生成动态单元说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showEarlyDynamicUnitHelp,
          ),
        ),
        const SizedBox(height: 8),
        // 首分型前合并框：种子框 / 高高 / 低低（只影响首分型前那段框的绘制与 MG/MD）
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('首分型前合并框', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _preFirstFractalMode.shortHint,
            style: const TextStyle(fontSize: 11),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<PreFirstFractalMode>(
                value: _preFirstFractalMode,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: const TextStyle(fontSize: 12, color: Colors.black87),
                items: [
                  for (final m in PreFirstFractalMode.values)
                    DropdownMenuItem<PreFirstFractalMode>(
                      value: m,
                      child: Text(m.label, style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (m) {
                        if (m == null) return;
                        _setPreFirstFractalMode(m, sheetSetState: sheetSetState);
                      },
              ),
              IconButton(
                tooltip: '首分型前合并框说明',
                icon: const Icon(Icons.help_outline, size: 18),
                onPressed: _showPreFirstFractalModeHelp,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 构建中/未确认虚线开关：末组合并框 + K0/K1/KN 构建中连线统一用虚线区分，默认开
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('构建中/未确认虚线', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _showBuildingDash ? '已开启（构建中元素虚线）' : '已关闭（全部实线）',
            style: const TextStyle(fontSize: 11),
          ),
          value: _showBuildingDash,
          onChanged: _busy
              ? null
              : (v) {
                  _panelUi(() => _showBuildingDash = v,
                      sheetSetState: sheetSetState);
                  _msgHistory.append('构建中虚线=${v ? "开" : "关"}');
                },
          secondary: IconButton(
            tooltip: '构建中/未确认虚线说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showBuildingDashHelp,
          ),
        ),
        SizedBox(height: 8),
        // 太极图总开关（2026-11-13 用户明确）：**从设置面板隐藏**，默认关闭、
        // 资源保留，后续可按需开启。App 启动直接展示主图，不进太极层。
        // 层级分窗：默认关闭 = 现在这张「各层集成在一张图」的单图；开启后按所选层级切格。
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('层级分窗（每层一个窗口）', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            LevelWindowSettingsStore.enabled
                ? '已开启（${LevelWindowSettingsStore.count} 窗，每窗都能步进/缩放）'
                : '已关闭（单图集成，与原来完全一致）',
            style: const TextStyle(fontSize: 11),
          ),
          value: LevelWindowSettingsStore.enabled,
          onChanged: (v) => unawaited(
            _setLevelWindowSplitEnabled(v, sheetSetState: sheetSetState),
          ),
          secondary: IconButton(
            tooltip: '层级分窗说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showLevelWindowSplitHelp,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('窗口数量与每窗层级', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            LevelWindowSettingsStore.enabled
                ? '当前：${LevelWindowSettingsStore.activeLevels.map((e) => "K$e").join(" / ")}'
                : '开关关闭时不可调；请先打开上面的层级分窗',
            style: const TextStyle(fontSize: 11),
          ),
          enabled: LevelWindowSettingsStore.enabled,
          trailing: const Icon(Icons.tune, size: 18),
          onTap: LevelWindowSettingsStore.enabled
              ? () => unawaited(
                    _editLevelWindowLayout(sheetSetState: sheetSetState),
                  )
              : null,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('BSP对错叠加X', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _overlayBsVerdictWrong
                ? '已开启（错标叠加X，对的不叠加）'
                : '已关闭（只显示原 Kn类BS 标记）',
            style: const TextStyle(fontSize: 11),
          ),
          value: _overlayBsVerdictWrong,
          onChanged: _busy
              ? null
              : (v) {
                  _panelUi(() => _overlayBsVerdictWrong = v,
                      sheetSetState: sheetSetState);
                  _msgHistory.append('BSP对错叠加X=${v ? "开" : "关"}');
                },
          secondary: IconButton(
            tooltip: 'BSP对错叠加说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showBsVerdictOverlayHelp,
          ),
        ),
        const SizedBox(height: 8),
        // 筹码分布：总开关 + 峰线；桶宽/拉伸见说明弹窗（已迁设置·仅K0，不参与主图指标勾选）
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('数学指标参数', style: TextStyle(fontSize: 13)),
          trailing: IconButton(
            tooltip: '数学指标说明与设置',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showMathIndicatorHelp,
          ),
          onTap: _busy ? null : _editMathIndicatorParams,
        ),
        const SizedBox(height: 8),
        // 筹码 / 笔数分布：单一总开关（右侧筹码+左侧笔数同时显隐）；峰延长线合并为共享开关（颜色按 ±档自动区分）
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('筹码 / 笔数分布', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _chipConfig.enabled && _tickDistConfig.enabled
                ? '已开启（右侧筹码 + 左侧笔数，仅 K0）'
                : '已关闭',
            style: const TextStyle(fontSize: 11),
          ),
          value: _chipConfig.enabled && _tickDistConfig.enabled,
          onChanged: _busy
              ? null
              : (v) {
                  _updateChipConfig(_chipConfig.copyWith(enabled: v));
                  _updateTickDistConfig(_tickDistConfig.copyWith(enabled: v));
                  _msgHistory.append('筹码/笔数分布总开关=${v ? "开" : "关"}');
                },
          secondary: IconButton(
            tooltip: '筹码/笔数分布说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showChipHelp,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('峰延长线（按 ±档配色）', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _chipConfig.peakLineEnabled && _tickDistConfig.peakLineEnabled
                ? '已开启（±1同色、±2同色…；框内 INn 另色）'
                : '已关闭',
            style: const TextStyle(fontSize: 11),
          ),
          value: _chipConfig.peakLineEnabled && _tickDistConfig.peakLineEnabled,
          onChanged: (!_chipConfig.enabled && !_tickDistConfig.enabled) || _busy
              ? null
              : (v) {
                  _updateChipConfig(_chipConfig.copyWith(peakLineEnabled: v));
                  _updateTickDistConfig(
                      _tickDistConfig.copyWith(peakLineEnabled: v));
                  _msgHistory.append('峰延长线=${v ? "开" : "关"}');
                },
        ),
        if (forMobileSheet)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              '高级与工具',
              style: TextStyle(fontSize: 13, color: AppPalette.rgb(0xFFE2E8F0)),
            ),
            children: advanced,
          )
        else
          ...advanced,
      ],
      ),
    );
  }

  /// 设置面板：历史记录 / ML / 回测等（手机端收进 ExpansionTile）。
  List<Widget> _buildPanelAdvancedSection({
    StateSetter? sheetSetState,
    bool forMobileSheet = false,
  }) {
    final syncCfg = PeerSyncSettingsStore.loadSync();
    return [
        const SizedBox(height: 12),
        const ThemeChooser(),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        const SizedBox(height: SettingsPanelTheme.sectionGap),
        SettingsOutlinedButton(
          label: '复制排查信息',
          icon: Icons.summarize,
          onPressed: _busy ? null : () => _showConsolidatedProbeDialog(context),
        ),
        const SizedBox(height: 4),
        Text(
          '弹窗查看整合全文，底部「复制」一键带走；含页面状态、最近历史与验收探针，已去重精简。',
          style: TextStyle(fontSize: 11, color: AppPalette.rgb(0xFF616161), height: 1.3),
        ),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        // 双机同步：把本机当前项目推到局域网另一台（那边自动关/拉 App、校验指纹）
        SettingsFilledButton(
          label: '双机同步',
          icon: Icons.sync,
          onPressed: _busy
              ? null
              : () async {
                  final cfg = PeerSyncSettingsStore.loadSync();
                  await showPeerSyncDialog(context, initial: cfg);
                  if (mounted) setState(() {});
                },
        ),
        const SizedBox(height: 4),
        Text(
          PeerSyncService.lastSyncLine(
            syncCfg.lastSyncAt,
            syncCfg.lastSyncOk,
            syncCfg.lastSyncSummary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: AppPalette.rgb(0xFF616161), height: 1.3),
        ),
        const SizedBox(height: SettingsPanelTheme.fieldGap),
        SettingsFilledButton(
          label: _mlSession.isActive ? '机器学习（进行中）' : '机器学习',
          icon: Icons.psychology,
          onPressed: (_busy && !_mlSession.isActive) || _mlSession.isActive
              ? null
              : () => _enterMlSession(),
          onHelp: _showMlHelp,
          helpTooltip: '机器学习说明',
        ),
        if (_mlSession.isActive) ...[
          const SizedBox(height: SettingsPanelTheme.fieldGap),
          SettingsOutlinedButton(
            label: '退出机器学习',
            icon: Icons.exit_to_app,
            onPressed: _exitMlSession,
          ),
        ],
    ];
  }

  void _clearBacktestSession() {
    _backtestRun = null;
    _btSelectedSignalId = null;
    _btSelectedTradeId = null;
    _btHighlightIds = {};
    _btFocusBarIdx = null;
  }

  void _closeBacktestWorkbench() {
    setState(() => _backtestPanelOpen = false);
    _refreshKeepAlive();
  }

  BacktestStepHarnessResult _mainSessionHarnessForSearch() {
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    return BacktestStepHarnessResult.fromMainSession(
      bars: List<KlineBar>.from(_allBars),
      levels: _levels,
      mathFreeze: _stepFreeze.mathFreezeStore,
      chanEvents: _chanEventStore(),
      zsObjects: _stepFreeze.zsObjectStore,
      diverRelations: _stepFreeze.diverRelationStore,
      lineSeries: _chartLineStore(),
      chipPeaks: _stepFreeze.chipPeakStore,
      barFeatures: _barFeatures,
      maxKn: maxKn,
      mathConfig: _mathIndicatorConfig,
      chipBucketStep: _chipConfig.bucketStep,
      knClock: _stepFreeze.knClockTimeline,
    );
  }

  Future<void> _openIndicatorSearch({
    bool closeSettingsSheet = false,
    IndicatorSearchSessionSnapshot? restore,
  }) async {
    if (_mlSession.isActive) {
      _showSnack('请先退出机器学习');
      return;
    }
    final code = _selectedCode;
    if (code == null) {
      _showSnack('请先选择股票');
      return;
    }
    if (!_hasSession || _allBars.isEmpty) {
      _showSnack('请先加载 K 线');
      return;
    }
    if (_stepIdx < 0) {
      _showSnack('请先步进至少一根 K 线');
      return;
    }
    if (_stepIdx < _allBars.length - 1) {
      _showSnack(
        '寻优与策略回测共用主图冻结：请先步进到区间最后一根 K（可一键跳末）',
      );
      return;
    }
    // 恢复模式：主图会话必须还指着同一份数据，否则重开上一次的宽表没有意义
    // ——它跑的就是旧区间的结果，拿它对现在的图做判断会出错。
    if (restore != null) {
      final same = _selectedCode == restore.code &&
          _period == restore.period &&
          _fmtDateTime(_beginDate) == restore.beginText &&
          _fmtDateTime(_endDate) == restore.endText &&
          _allBars.length == restore.barCount;
      if (!same) {
        _lastSearchSession = null;
        _showSnack('主图会话已变更，缓存的寻优结果作废，请重新寻优');
        return;
      }
    }
    if (closeSettingsSheet && Navigator.canPop(context)) {
      Navigator.pop(context);
      _settingsSheetSetState = null;
    }
    setState(() => _indicatorSearchRunning = true);
    _msgHistory.append(
      restore != null
          ? '返回寻优结果：$code ${_periods[_period] ?? _period} '
              '${_fmtDateTime(_beginDate)}~${_fmtDateTime(_endDate)}'
          : '指标寻优：$code ${_periods[_period] ?? _period} '
              '${_fmtDateTime(_beginDate)}~${_fmtDateTime(_endDate)}',
    );
    await showDialog<void>(
      context: context,
      // 点非结果界面＝关闭；扫描中由弹窗内 PopScope 挡住（见 IndicatorSearchDialog）
      barrierDismissible: true,
      builder: (ctx) => IndicatorSearchDialog(
        code: code,
        period: _period,
        beginText: _fmtDateTime(_beginDate),
        endText: _fmtDateTime(_endDate),
        dataRoot: _dataRoot,
        tickSource: _tickSourceFor(code),
        mathConfig: _mathIndicatorConfig,
        chipConfig: _chipConfig,
        strategyConfig: _strategyConfig,
        featureLookup: _pipelineSession?.cache.lookup,
        truncationCheck: _truncationCheck,
        earlyDynamicUnit: _earlyDynamicUnit,
        mainSessionHarness: _mainSessionHarnessForSearch(),
        initialBars: List<KlineBar>.from(_allBars),
        // 「眼睛 → 在 K 线图查看」：把该行买卖条件投到主图，并把本次会话缓存下来，
        // 供回测台横幅上的「返回寻优结果」原样恢复（排序/展开都在，不重扫）。
        onApplyToChart: _applySearchBacktestToChart,
        onCacheSession: (snap) => _lastSearchSession = snap,
        restoreSnapshot: restore,
      ),
    );
    if (!mounted) return;
    setState(() => _indicatorSearchRunning = false);
    _msgHistory.append(restore != null ? '返回寻优结果结束' : '指标寻优结束');
  }

  /// 回测台横幅上的「返回寻优结果」：用缓存会话原样重开上次那张宽表，不重新扫描。
  Future<void> _returnToSearch() async {
    final s = _lastSearchSession;
    if (s == null) return;
    await _openIndicatorSearch(restore: s);
  }

  /// 计优：跑完的缠论/指标冻结账 → 各级别连线转折点的指标统计。
///
/// 前置条件与寻优一致：必须已步进到区间最后一根 K（全部指标跑完）。
/// **只读** 冻结账（`_pipelineSession.cache.lookup`），不写冻结仓、不改主图语义。
Future<void> _openKeyPointStats({bool closeSettingsSheet = false}) async {
    if (_mlSession.isActive) {
      _showSnack('请先退出机器学习');
      return;
    }
    final code = _selectedCode;
    if (code == null) {
      _showSnack('请先选择股票');
      return;
    }
    if (!_hasSession || _allBars.isEmpty) {
      _showSnack('请先加载 K 线');
      return;
    }
    if (_stepIdx < 0) {
      _showSnack('请先步进至少一根 K 线');
      return;
    }
    if (_stepIdx < _allBars.length - 1) {
      _showSnack('计优需要全部指标先跑完：请先步进到区间最后一根 K（可一键跳末）');
      return;
    }
    final lookup = _pipelineSession?.cache.lookup;
    if (lookup == null || lookup.byIdx.isEmpty) {
      _showSnack('主图冻结账为空：请先步进 K 线再点计优');
      return;
    }
    if (closeSettingsSheet && Navigator.canPop(context)) {
      Navigator.pop(context);
      _settingsSheetSetState = null;
    }
    setState(() => _keyPointStatRunning = true);
    _msgHistory.appendKeyPointStatsStart(code, _period);
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => KeyPointStatsDialog(
        code: code,
        period: _period,
        beginText: _fmtDateTime(_beginDate),
        endText: _fmtDateTime(_endDate),
        bars: List<KlineBar>.from(_allBars),
        levels: _levels,
        lookup: lookup,
        maxKn: maxKn,
        k0Confirms: _k0ConfirmSignals,
        k0Lines: _k0Lines,
        // 复现参数：截断开关会改转折点位置；数学指标/筹码参数决定每格的值
        truncationCheck: _truncationCheck,
        maxBsClass: _maxBsClass,
        mathConfig: _mathIndicatorConfig,
        chipBucketStep: _chipConfig.bucketStep,
        peakRankMode: _chipConfig.peakRankConfig.schemeId,
        // 计优找出的指标组合 → 寻优候选，直接开寻优验证「能不能赚钱、样本外稳不稳」。
        onSearchWithCombos: (cands) async {
          if (!mounted) return;
          await _openIndicatorSearchWithCandidates(cands);
        },
      ),
    );
    if (!mounted) return;
    setState(() => _keyPointStatRunning = false);
    _msgHistory.appendKeyPointStatsEnd();
  }

  /// 用计优桥生成的候选直接开寻优（跳过枚举，只跑这几条）。
  Future<void> _openIndicatorSearchWithCandidates(List<ComboCand> cands) async {
    if (_mlSession.isActive) {
      _showSnack('请先退出机器学习');
      return;
    }
    final code = _selectedCode;
    if (code == null) {
      _showSnack('请先选择股票');
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => IndicatorSearchDialog(
        code: code,
        period: _period,
        beginText: _fmtDateTime(_beginDate),
        endText: _fmtDateTime(_endDate),
        dataRoot: _dataRoot,
        tickSource: _tickSourceFor(code),
        mathConfig: _mathIndicatorConfig,
        chipConfig: _chipConfig,
        strategyConfig: _strategyConfig,
        featureLookup: _pipelineSession?.cache.lookup,
        truncationCheck: _truncationCheck,
        earlyDynamicUnit: _earlyDynamicUnit,
        mainSessionHarness: _mainSessionHarnessForSearch(),
        initialBars: List<KlineBar>.from(_allBars),
        candidateOverride: cands,
        // 计优选出来的候选只跑这些：不粗筛、不再拼组合。
        candidatesOnly: true,
        onApplyToChart: _applySearchBacktestToChart,
        onCacheSession: (snap) => _lastSearchSession = snap,
      ),
    );
  }

  /// 设置 · 上次寻优结果（读本地快照，与当次一致：同摘要/同排序/同头部）。
  /// 当前主图区间与快照一致时才支持眼睛预览与「在 K 线图查看」全套路径。
  Future<void> _showLastSearchResultDialog() async {
    await IndicatorSearchLastResultStore.load();
    final snap = IndicatorSearchLastResultStore.current;
    if (snap == null || snap.verdicts.isEmpty) {
      _showSnack('暂无已保存的寻优快照，请先完整跑完一次寻优');
      return;
    }
    if (_mlSession.isActive) {
      _showSnack('请先退出机器学习');
      return;
    }
    if (!_hasSession || _allBars.isEmpty) {
      _showSnack('请先加载 K 线');
      return;
    }
    if (_stepIdx < _allBars.length - 1) {
      _showSnack('寻优与策略回测共用主图冻结：请先步进到区间最后一根 K（可一键跳末）');
      return;
    }
    final matches = _selectedCode == snap.code &&
        _period == snap.period &&
        _fmtDateTime(_beginDate) == snap.beginText &&
        _fmtDateTime(_endDate) == snap.endText &&
        _allBars.length == snap.barCount;
    final session = IndicatorSearchSessionSnapshot(
      verdicts: snap.verdicts,
      compiled: snap.compiled,
      ran: snap.ran,
      splitX: snap.splitX,
      elapsed: snap.elapsed,
      code: snap.code,
      period: snap.period,
      beginText: snap.beginText,
      endText: snap.endText,
      barCount: snap.barCount,
      align: snap.align,
      maxKn: snap.maxKn,
      resultsFilePath: snap.resultsFilePath,
    );
    await showDialog<void>(
      context: context,
      // 点遮罩＝关闭；恢复态不扫描，同 PopScope 允许 pop
      barrierDismissible: true,
      builder: (ctx) => IndicatorSearchDialog(
        code: snap.code,
        period: snap.period,
        beginText: snap.beginText,
        endText: snap.endText,
        dataRoot: _dataRoot,
        tickSource: _tickSourceFor(snap.code),
        mathConfig: _mathIndicatorConfig,
        chipConfig: _chipConfig,
        strategyConfig: _strategyConfig,
        featureLookup: _pipelineSession?.cache.lookup,
        truncationCheck: _truncationCheck,
        earlyDynamicUnit: _earlyDynamicUnit,
        mainSessionHarness: matches ? _mainSessionHarnessForSearch() : null,
        initialBars: matches ? List<KlineBar>.from(_allBars) : null,
        onApplyToChart: matches ? _applySearchBacktestToChart : null,
        onCacheSession: (snap) => _lastSearchSession = snap,
        enablePreview: matches,
        restoreSnapshot: session,
      ),
    );
  }

  /// 眼睛覆盖层「在 K 线图查看」：把寻优该行跑出的回测投到主界面 K 线图。
  /// 复用既有上图逻辑（替换策略 + 写回测 + 并入指标 + 开面板），随后关掉寻优弹窗。
  void _applySearchBacktestToChart(BacktestRun run, StrategyConfig cfg) {
    if (!mounted) return;
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    setState(() {
      _strategyConfig = cfg;
      _backtestRun = run;
      _backtestPanelOpen = true;
      _btSelectedSignalId = null;
      _btSelectedTradeId = null;
      _btHighlightIds = {};
      _panelExpanded = false;
      // 投图显示口径（与策略回测入口同源）：完全按本行策略条件重设主/副图显示，
      // 不保留上一次投图或手工勾选的指标；并固定带上每个 K{n} 层的 K{n} 与 K{n}连线。
      final merged = strategyDisplayIndicators(
        cfg: cfg,
        maxKn: maxKn,
        truncationCheck: _truncationCheck,
        maxBsClass: _maxBsClass,
      );
      _mainIndicators = merged.main;
      _subIndicators = merged.sub;
      // 分窗开着时，投图也同步到分窗集合，否则主窗看不到策略标记。
      if (LevelWindowSettingsStore.enabled) {
        _splitMainIndicators = merged.main;
        _splitSubIndicators = merged.sub;
        _splitIndicatorsReady = true;
      }
    });
    if (run.error != null) {
      _showSnack(run.error!);
      _msgHistory.append('寻优策略投图未跑成：${run.error}');
    } else {
      final m = run.result!.metrics;
      _msgHistory.append(
        '寻优策略投图：${cfg.buyLabel} / ${cfg.sellLabel}；'
        '净利${m.netProfit.toStringAsFixed(2)} 胜率${m.winRate.display} '
        '最大回撤${m.maxDrawdown.toStringAsFixed(2)}（图上已画买卖标记）',
      );
      _showSnack('已在 K 线图显示该策略回测');
    }
    // 关掉寻优弹窗 → 露出主 K 线图，此时已画出该策略买卖标记。
    if (Navigator.canPop(context)) Navigator.pop(context);
  }
  void _openBacktestWorkbench({bool closeSettingsSheet = false}) {
    if (_mlSession.isActive) {
      _showSnack('请先退出机器学习');
      return;
    }
    if (closeSettingsSheet && Navigator.canPop(context)) {
      Navigator.pop(context);
      _settingsSheetSetState = null;
    }
    setState(() {
      _backtestPanelOpen = true;
      _panelExpanded = false;
    });
    _refreshKeepAlive();
  }

  void _onBacktestSplitDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _backtestSplitDragging = true;
    _backtestSplitDragStartY = _useAndroidInteraction
        ? e.localPosition.dy
        : e.localPosition.dx;
    _backtestSplitDragStartFraction = _backtestChartFraction;
  }

  void _onBacktestSplitMove(PointerMoveEvent e, double total) {
    if (!_backtestSplitDragging || total <= 0) return;
    final pos =
        _useAndroidInteraction ? e.localPosition.dy : e.localPosition.dx;
    final delta = pos - _backtestSplitDragStartY;
    setState(() {
      _backtestChartFraction =
          ((_backtestSplitDragStartFraction * total + delta) / total)
              .clamp(_minBacktestChartFraction, _maxBacktestChartFraction);
    });
  }

  void _onBacktestSplitUp(PointerUpEvent e) {
    _backtestSplitDragging = false;
  }

  Widget _buildBacktestSplitBar(double total, {required bool vertical}) {
    return MouseRegion(
      cursor: vertical
          ? SystemMouseCursors.resizeUpDown
          : SystemMouseCursors.resizeLeftRight,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onBacktestSplitDown,
        onPointerMove: (e) => _onBacktestSplitMove(e, total),
        onPointerUp: _onBacktestSplitUp,
        child: vertical
            ? SizedBox(
                height: 8,
                child: Center(
                  child: Container(
                    height: _backtestSplitDragging ? 3 : 2,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: _backtestSplitDragging
                          ? AppPalette.rgb(0xAA42A5F5)
                          : AppPalette.rgb(0x55FFFFFF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              )
            : SizedBox(
                width: 8,
                child: Center(
                  child: Container(
                    width: _backtestSplitDragging ? 3 : 2,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _backtestSplitDragging
                          ? AppPalette.rgb(0xAA42A5F5)
                          : AppPalette.rgb(0x55FFFFFF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildReplayBody() {
    final chart = _buildKlineChart();
    if (!_backtestPanelOpen) return _withTooltipDock(chart);
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    final workbench = BacktestWorkbench(
      config: _strategyConfig,
      maxKn: maxKn,
      onConfigChanged: (c) => setState(() => _strategyConfig = c),
      onRun: _runStrategyBacktest,
      onClose: _closeBacktestWorkbench,
      onHelp: _showBacktestHelp,
      run: _backtestRun,
      bars: _visibleBars,
      currentStepIdx: _stepIdx < 0 ? 0 : _stepIdx,
      tab: _btTab,
      onTab: (t) => setState(() => _btTab = t),
      selectedSignalId: _btSelectedSignalId,
      selectedTradeId: _btSelectedTradeId,
      onSelectTrade: _onBacktestSelectTrade,
      onSelectSignal: _onBacktestSelectSignal,
      onJumpX: _jumpBacktestBar,
      focusX: _btFocusBarIdx,
      levels: _levels,
      mathFreeze: _stepFreeze.mathFreezeStore,
      chanEvents: _chanEventStore(),
      zsObjects: _stepFreeze.zsObjectStore,
      diverRelations: _stepFreeze.diverRelationStore,
      lineSeries: _chartLineStore(),
      features: _pipelineSession?.cache.lookup,
      chipPeaks: _stepFreeze.chipPeakStore,
      bucketStep: _chipConfig.bucketStep,
      knClock: _stepFreeze.knClockTimeline,
      compactLayout: _useAndroidInteraction,
    );
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide = !_useAndroidInteraction;
        if (sideBySide) {
          final totalW = constraints.maxWidth;
          if (totalW <= 0) return chart;
          const splitW = 8.0;
          const minChartW = 240.0;
          const minBenchW = 300.0;
          final maxChartW = math.max(minChartW, totalW - minBenchW - splitW);
          final minFrac = minChartW / totalW;
          final maxFrac = maxChartW / totalW;
          final frac = _backtestChartFraction.clamp(minFrac, maxFrac);
          final chartW = frac * totalW;
          final benchW = totalW - chartW - splitW;
          return Row(
            children: [
              // 桌面并排：chart 仍要包 _withTooltipDock，否则左边 tooltip 停靠子窗口
              // 没有 _tooltipBridge 的消费者，十字线 tooltip 界面无法调出。
              // dock 只在 chart 区域内出现（关面板时不占宽），工作台宽度 benchW 不变，
              // split 拖动改 _backtestChartFraction 仍然生效。
              SizedBox(width: chartW, child: _withTooltipDock(chart)),
              _buildBacktestSplitBar(totalW, vertical: false),
              SizedBox(width: benchW, child: workbench),
            ],
          );
        }
        final totalH = constraints.maxHeight;
        if (totalH <= 0) return chart;
        const splitBarH = 8.0;
        const minChartH = 120.0;
        const minBacktestH = 160.0;
        final maxChartH = math.max(minChartH, totalH - minBacktestH - splitBarH);
        final minFrac = minChartH / totalH;
        final maxFrac = maxChartH / totalH;
        final frac = _backtestChartFraction.clamp(minFrac, maxFrac);
        final chartH = frac * totalH;
        final backtestH = totalH - chartH - splitBarH;
        return _withTooltipDock(
          Column(
            children: [
              SizedBox(height: chartH, child: chart),
              _buildBacktestSplitBar(totalH, vertical: true),
              SizedBox(height: backtestH, child: workbench),
            ],
          ),
        );
      },
    );

    // 回测台横幅：寻优某行点了「在 K 线图查看」之后常驻顶部，写清图上生效的买卖条件，
    // 右端一个「返回寻优结果」按钮，原样回到那张宽表（排序/展开都在，不重扫）。
    if (_lastSearchSession != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchReturnBanner(),
          Expanded(child: body),
        ],
      );
    }
    return body;
  }

  /// 寻优横幅：显示当前图上生效的买卖条件 + 「返回寻优结果」入口。
  ///
  /// 2026-11-11 工具条化后标题条独立成一行，不再叠在 body 之上，
  /// 横幅右侧无需再为窗控让宽（移动端同样不占）。
  /// 口径来源就是 `_strategyConfig`，与图上买卖标记、工作台条件页同源，不另存一份。
  Widget _searchReturnBanner() {
    const rightInset = 0.0;
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    final buyText = astConditionTextCn(_strategyConfig.buyAst, maxKn: maxKn)
        .replaceAll('\n', ' ');
    final sellText = astConditionTextCn(_strategyConfig.sellAst, maxKn: maxKn)
        .replaceAll('\n', ' ');
    Widget condLine(String tag, String text, Color color) => Row(
          children: [
            Text(
              '$tag ',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
            ),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
          ],
        );
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: EdgeInsets.fromLTRB(8, 4, 8 + rightInset, 4),
      child: Row(
        children: [
          const Icon(Icons.history, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                condLine('买', buyText, AppPalette.rgb(0xFFE53935)),
                condLine('卖', sellText, AppPalette.rgb(0xFF43A047)),
              ],
            ),
          ),
          Tooltip(
            message: '回到上次那张寻优结果表：排序与展开行已保留，不重新扫描',
            child: TextButton(
              onPressed: _indicatorSearchRunning ? null : () => _returnToSearch(),
              child: const Text('返回寻优结果'),
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面：把十字线 tooltip 停靠为左侧独立子窗口（chart 缩小到剩余宽），原悬浮态关闭。
  /// 移动端：KlineChart 用内部悬浮面板，这里直接返回 child。
  ///
  /// 关键：Row 结构必须**始终存在**（用 Offstage 控制左栏显隐），不能在
  /// 「直接返回 child」与「Row>Expanded 包裹 child」之间切换 —— 否则 KlineChart
  /// 在树中的位置/深度变化且无 GlobalKey，Element 连同 State 会被整体重建，
  /// 十字线坐标、视口缩放等内部状态全部丢失（表现为 tooltip 一出现十字线就消失）。
  Widget _withTooltipDock(Widget child) {
    if (_useAndroidInteraction) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        return ValueListenableBuilder<bool>(
          valueListenable: _tooltipBridge.shown,
          builder: (context, shown, _) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Offstage(
                  offstage: !shown,
                  child: SizedBox(
                    width: _tooltipPanelWidth,
                    child: _buildDockedTooltipPanel(h),
                  ),
                ),
                Offstage(offstage: !shown, child: _buildTooltipDragHandle()),
                Expanded(child: child),
              ],
            );
          },
        );
      },
    );
  }

  /// 左侧停靠的 tooltip 子窗口内容（随十字线移动刷新行）
  Widget _buildDockedTooltipPanel(double h) {
    return ValueListenableBuilder<List<CrosshairTooltipRow>>(
      valueListenable: _tooltipBridge.rows,
      builder: (context, rows, _) {
        return Container(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: AppPalette.rgb(0x33556677),
                width: 1,
              ),
            ),
          ),
          child: CrosshairTooltipPanel(
            rows: rows,
            scrollController: _tooltipBridge.scrollController!,
            maxWidth: _tooltipPanelWidth,
            maxHeight: h,
            // 面板自己先关：各窗注入的关闭回调互相覆盖，点下去可能打到
            // 一个并不持有十字线的窗口，回调什么都不做。这里直接关面板，
            // 再通知各窗把共用的信息开关关掉。
            onClose: () {
              _tooltipBridge.suppressTooltipUntilMs =
                  DateTime.now().millisecondsSinceEpoch + 600;
              _tooltipBridge.shown.value = false;
              _tooltipBridge.onRequestClose?.call();
            },
          ),
        );
      },
    );
  }

  /// 左侧子窗口与 K 线之间的可拖拽分隔条（调整面板宽度）
  Widget _buildTooltipDragHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => setState(() => _tooltipPanelDragging = true),
        onPointerMove: (e) {
          if (e.buttons == 0) return;
          setState(() {
            _tooltipPanelWidth = (_tooltipPanelWidth + e.delta.dx)
                .clamp(_minTooltipPanelWidth, _maxTooltipPanelWidth);
          });
        },
        onPointerUp: (e) => setState(() => _tooltipPanelDragging = false),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: _tooltipPanelDragging ? 3 : 2,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: _tooltipPanelDragging
                    ? AppPalette.rgb(0xAA42A5F5)
                    : AppPalette.rgb(0x55FFFFFF),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ChanEventStore _chanEventStore() {
    return ChanEventStore(
      buy1ByKn: _stepFreeze.buy1HistoryByKn,
      sell1ByKn: _stepFreeze.sell1HistoryByKn,
      buy2ByKn: _stepFreeze.buy2HistoryByKn,
      sell2ByKn: _stepFreeze.sell2HistoryByKn,
      buyNByKn: _stepFreeze.buyNHistoryByKn,
      sellNByKn: _stepFreeze.sellNHistoryByKn,
      zsConfirmByKn: _stepFreeze.zsConfirmHistoryByKn,
      zsJudgmentByKn: _stepFreeze.zsJudgmentHistoryByKn,
      fractalJudgmentByKn: _stepFreeze.judgmentHistoryByKn,
      k0FractalConfirms: _k0ConfirmSignals,
    );
  }

  ChartLineStore _chartLineStore() {
    return ChartLineStore(
      adjacentRatioByKn: _stepFreeze.adjacentRatioHistoryByKn,
      lineSlopeByKn: _stepFreeze.lineSlopeHistoryByKn,
      stepRhythmByKn: _stepFreeze.stepRhythmHistoryByKn,
    );
  }

  /// 只算不改界面：回测工作台与 Agent API 共用这条执行路径。
  ///
  /// 会话口径全部取自当前主图（可见前缀 / 冻结仓 / 采样钟），与手动回测等价。
  BacktestRun _computeStrategyBacktest(StrategyConfig cfg) {
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    final scope = BacktestDataScope(
      code: _selectedCode ?? '',
      period: _period,
      barCount: _visibleBars.length,
      asOfX: _stepIdx < 0 ? 0 : _stepIdx,
      beginText: _fmtDateTime(_beginDate),
      endText: _fmtDateTime(_endDate),
    );
    return executeStrategyBacktest(
      config: cfg,
      scope: scope,
      bars: _visibleBars,
      levels: _levels,
      mathFreeze: _stepFreeze.mathFreezeStore,
      chanEvents: _chanEventStore(),
      zsObjects: _stepFreeze.zsObjectStore,
      diverRelations: _stepFreeze.diverRelationStore,
      lineSeries: _chartLineStore(),
      features: _pipelineSession?.cache.lookup,
      chipPeaks: _stepFreeze.chipPeakStore,
      bucketStep: _chipConfig.bucketStep,
      bollN: _mathIndicatorConfig.bollN,
      donchianN: _mathIndicatorConfig.donchianN,
      maxKn: maxKn,
      regressK: _mathIndicatorConfig.regressK,
      barFeatures: _barFeatures,
      mathConfig: _mathIndicatorConfig,
      knClock: _stepFreeze.knClockTimeline,
    );
  }

  void _runStrategyBacktest(StrategyConfig cfg) {
    if (!_hasSession || _visibleBars.isEmpty) {
      _showSnack('请先加载 K 线并走到至少一根');
      return;
    }
    final maxKn = chartMaxKn(levels: _levels, k0Lines: _k0Lines);
    final run = _computeStrategyBacktest(cfg);
    final scope = run.sourceRange;
    setState(() {
      _strategyConfig = cfg;
      _backtestRun = run;
      _backtestPanelOpen = true;
      _btSelectedSignalId = null;
      _btSelectedTradeId = null;
      _btHighlightIds = {};
      _panelExpanded = false;
      // 投图显示口径：完全按本策略条件重设主/副图显示，不保留上一次投图或手工勾选的指标；
      // 并固定带上每个 K{n} 层的 K{n} 与 K{n}连线。
      final merged = strategyDisplayIndicators(
        cfg: cfg,
        maxKn: maxKn,
        truncationCheck: _truncationCheck,
        maxBsClass: _maxBsClass,
      );
      _mainIndicators = merged.main;
      _subIndicators = merged.sub;
      // 分窗开着时，投图也同步到分窗集合，否则主窗看不到策略标记。
      if (LevelWindowSettingsStore.enabled) {
        _splitMainIndicators = merged.main;
        _splitSubIndicators = merged.sub;
        _splitIndicatorsReady = true;
      }
    });
    if (run.error != null) {
      _showSnack(run.error!);
      _msgHistory.append('策略回测未跑成：${run.error}');
      return;
    }
    final m = run.result!.metrics;
    _msgHistory.append(
      '策略回测 ${run.runId} 引擎${run.engineVersion}：'
      '${cfg.buyLabel} / ${cfg.sellLabel}；'
      '已走到K${scope.asOfX}；'
      '净利${m.netProfit.toStringAsFixed(2)} 胜率${m.winRate.display} '
      '最大回撤${m.maxDrawdown.toStringAsFixed(2)}。'
      '图上买1/卖1、买2/卖2 按组合组显示在发现当根，被拒的不画。',
    );
    _showSnack('回测完成：闭合 ${m.totalTrades} 笔');
  }

  void _jumpBacktestBar(int x) {
    setState(() {
      _btFocusBarIdx = x;
      _btFocusEpoch++;
    });
  }

  void _onBacktestSelectTrade(TradeRecord t) {
    final same = _btSelectedTradeId == t.tradeId;
    setState(() {
      _btSelectedTradeId = t.tradeId;
      _btHighlightIds = {t.entrySignalId, t.exitSignalId};
      _btSelectedSignalId = same ? t.exitSignalId : t.entrySignalId;
      _btFocusBarIdx = same ? t.exitX : t.entryX;
      _btFocusEpoch++;
      _btTab = BacktestWorkbenchTab.trades;
    });
  }

  void _onBacktestSelectSignal(SignalEvent s) {
    _applySignalSelection(s, openChain: true);
  }

  void _onChartStrategySignalTap(SignalEvent s) {
    _applySignalSelection(s, openChain: true);
  }

  void _applySignalSelection(SignalEvent s, {required bool openChain}) {
    final result = _backtestRun?.result;
    final link = result == null ? null : BacktestLinkIndex(result);
    final trade = link?.tradeForSignal(s.signalId);
    setState(() {
      _backtestPanelOpen = true;
      _btSelectedSignalId = s.signalId;
      _btSelectedTradeId = trade?.tradeId;
      _btHighlightIds = trade != null
          ? {trade.entrySignalId, trade.exitSignalId}
          : {s.signalId};
      _btFocusBarIdx = s.discoveryX;
      _btFocusEpoch++;
      if (openChain) _btTab = BacktestWorkbenchTab.chain;
    });
  }

  void _showBacktestHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('策略回测说明'),
        content: const SingleChildScrollView(
          child: Text(
            '先加载股票并走到你要回测的那根 K，再打开策略回测。\n'
            '电脑上整块工作台在窗口最小/最大/关闭下面，避免挡住那三个键。'
            '点工作台右上角关闭（X）只关策略回测、K 线铺回整屏；设置里还能再打开。不是关软件窗口。\n\n'
            '买卖条件各自用积木搭：比较（> < >= <=）、上穿/下穿，'
            '多条之间用 AND / OR。左右可以是同一层的收开高低、布林三轨、'
            'MACD（DIF/DEA/柱）、RSI、KDJ，K0 还可以用成交量；右边也可以填常数。'
            '也可以选一类/二类买卖点、分型确认、中枢确认、背驰出现：这些是「出现一次」的事件，'
            '每颗点当根出一次信号，连着两颗确认不会把后面那颗吞掉。'
            '事件只能用 AND/OR 拼（须同一根 K 两边都刚发生），不能拿去比较或上穿下穿。'
            '买卖都选分型确认时，同一根先平后开：空仓只开，有仓先平再开。'
            '确认中枢的高/低/中轴是数值：先认定「当前这层最新一个已经确认的中枢」，再取当时能看见的高低，'
            '不是事后扩大后的末态。没有确认中枢就是不可用，不会当成 0。'
            '背驰是「哪一个结构对比哪一个结构、在哪根 K 被发现」的关系，不是一根 K 看起来像背驰。'
            '力度比可以拿去和数字比，方向只能选向上或向下，不能把整个背驰拿去比大小或上穿下穿。'
            '同一条比较必须同层同钟：K0 最低价不能去穿 K1 布林。'
            '但两层各自穿完自己的布林，再用 AND/OR 拼是可以的，AND 必须撞在同一根 K 上。'
            '成交量这一版只开放 K0，没有另造 Kn 成交量和均量。\n\n'
            '点运行后，图上按组合组显示「买1/卖1」「买2/卖2」（红买绿卖），画在发现当根，被拒的不画。'
            '买1/卖1 用三角，买2/卖2 用箭头，买3/卖3 再三角，按组号奇偶交替。'
            '默认按本周期收盘价成交；也可在设置里改次周期开盘价。这不是缠论的 1Ba/1Sa。'
            '报告里的净利润、胜率、盈亏比、回撤都来自这一次回测结果，界面不会再算一遍。'
            '左侧变量诊断只读图上已冻住的格子和计算钟样本，不会现场重算指标。\n\n'
            '点交易表格会跳到入场 K，再点同一笔会跳到出场 K。'
            '点图上的买1/卖1会打开对应的信号→订单→成交→交易。\n\n'
            '手续费、滑点先按你填的数字；默认 0。不做做空、加仓、多品种。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  /// 复盘 K 线（ML 期间主区不挂本组件）。
  ///
  /// 单图 / 层级分窗两条路径：
  /// - 总开关关闭（默认）→ 与原来完全一致的整图集成；
  /// - 总开关打开 → 按用户选定的层级切片，每窗只画自己那层。
  /// 安卓交互与「仅筹码」模式强制走单图（这两条路径没有多窗语义）。
  Widget _buildKlineChart() {
    final split = !_useAndroidInteraction &&
        !_chipOnlyMode &&
        LevelWindowSettingsStore.enabled;
    final fullscreen = split ? _splitFullscreenLevel : null;
    return RepaintBoundary(
      key: _chartRepaintKey,
      child: split
          ? (fullscreen != null
              ? _buildKlinePane(level: fullscreen, primary: true, split: true)
              : LevelChartGrid(
                  count: LevelWindowSettingsStore.count,
                  levels: LevelWindowSettingsStore.activeLevels,
                  maxKn: chartMaxKn(levels: _levels, k0Lines: _k0Lines),
                  paneBuilder: (context, slot, level, primary) =>
                      _buildKlinePane(
                    level: level,
                    primary: primary,
                    split: true,
                  ),
                ))
          : _buildKlinePane(level: 0, primary: true, split: false),
    );
  }

  /// 单窗：`split=true` 时只画 [level] 那一层，并接入联动控制器。
  ///
  /// 第二版：分窗里每一格都可交互（各自步进/缩放/平移/十字线）；
  /// [primary] 只决定「谁独占全局键盘、谁挂筹码/回测/tooltip 这些全局浮层」，
  /// 避免同一份全局资源在 N 个窗里各画一遍。
  Widget _buildKlinePane({
    required int level,
    required bool primary,
    required bool split,
  }) {
    final gesturesOn = _hasSession && !_busy;
    final chart = KlineChart(
      // 每窗独立 State：层级换槽位时不复用旧窗的十字线/静音状态。
      key: ValueKey<String>(split ? 'level-$level' : 'single'),
      // ── 分窗联动：每窗独立视口 / 主副比例共用 / 十字线接管 / as-of 缓存 ──
      interactive: true,
      ownsKeyboard: split ? primary : true,
      sync: split ? _chartSync : null,
      displayLevel: split ? level : null,
      // 副图恒定占位：各窗几何一致，十字横线才能对到同一行。
      forceSubPane: split,
      bars: _visibleBars,
      period: _period,
      combineFrames: _combineFrames,
      k0ConfirmSignals: _k0ConfirmSignals,
      barFeatures: _barFeatures,
      k0Lines: _k0Lines,
      k1BarViews: _k1BarViews,
      k1CombineFrames: _k1CombineFrames,
      k1Analysis: _k1Analysis,
      levels: _levels,
      zsK0Frames: _zsK0Frames,
      buy1K0Frames: _buy1K0Frames,
      sell1K0Frames: _sell1K0Frames,
      buy2K0Frames: _buy2K0Frames,
      sell2K0Frames: _sell2K0Frames,
      buyNK0Frames: _buyNK0Frames,
      sellNK0Frames: _sellNK0Frames,
      defaultK0Policy: _defaultK0Policy,
      stepIdx: _stepIdx,
      stepSerial: _stepSerial,
      resetViewSerial: _resetViewSerial,
      truncationCheck: _truncationCheck,
      earlyDynamicUnit: _earlyDynamicUnit,
      preFirstFractalMode: _preFirstFractalMode,
      showBuildingDash: _showBuildingDash,
      chipOnlyMode: _chipOnlyMode,
      // 筹码 / 笔数分布只在主窗生效：其余窗各自可操作，但不需要重复一份浮层。
      chipConfig: primary ? _sessionChipConfig : const ChipConfig(),
      tickDistConfig: primary ? _sessionTickDistConfig : const TickDistConfig(),
      mathIndicatorConfig: _mathIndicatorConfig,
      mathFreezeStore: _stepFreeze.mathFreezeStore,
      diverFreezeStore: _stepFreeze.diverFreezeStore,
      chipPeakStore: _stepFreeze.chipPeakStore,
      judgmentHistoryByKn: _stepFreeze.judgmentHistoryByKn,
      zsJudgmentHistoryByKn: _stepFreeze.zsJudgmentHistoryByKn,
      zsConfirmHistoryByKn: _stepFreeze.zsConfirmHistoryByKn,
      buy1HistoryByKn: _stepFreeze.buy1HistoryByKn,
      sell1HistoryByKn: _stepFreeze.sell1HistoryByKn,
      buy2HistoryByKn: _stepFreeze.buy2HistoryByKn,
      sell2HistoryByKn: _stepFreeze.sell2HistoryByKn,
      buyNHistoryByKn: _stepFreeze.buyNHistoryByKn,
      sellNHistoryByKn: _stepFreeze.sellNHistoryByKn,
      bsVerdictHistoryByKn: _stepFreeze.bsVerdictHistoryByKn,
      overlayBsVerdictWrong: _overlayBsVerdictWrong,
      adjacentRatioHistoryByKn: _stepFreeze.adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: _stepFreeze.stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: _stepFreeze.lineSlopeHistoryByKn,
      lookupEngine: _pipelineSession?.cache.lookupEngine,
      sessionAsOfBundle: (asOf) => _pipelineSession?.cache.snapshotAt(asOf),
      mainIndicators: split ? _splitMainIndicators : _mainIndicators,
      onMainIndicatorsChanged:
          split ? _applySplitMainIndicators : _applyMainIndicators,
      subIndicators: split ? _sessionSplitSubIndicators : _sessionSubIndicators,
      onSubIndicatorsChanged:
          split ? _applySplitSubIndicators : _applySubIndicators,
      indicatorsEnabled: _hasSession,
      autoFollowLatest: true,
      isPlaying: _playing,
      // 第二版：每窗都能步进/播放，颗粒度统一走 K0 的一根 K。
      onTapStepBack: gesturesOn ? _stepBack : null,
      onTapPlay: !_hasSession ? null : (_busy && !_playing ? null : _togglePlay),
      onTapStepForward: gesturesOn ? _stepForward : null,
      // 左边界长按（原首K重置）：按住步退、松开即停。
      onLongPressReset: gesturesOn ? _startStepBackHold : null,
      onLongPressResetStop: gesturesOn ? _stopStepBackHold : null,
      onLongPressReload: !_busy ? _loadKlines : null,
      // 右边界长按：按住播放、松开暂停（原「一次性走完」已迁到顶栏按钮）。
      onLongPressPlayStart: gesturesOn ? _startPlay : null,
      onLongPressPlayStop: gesturesOn ? _pausePlay : null,
      // 回测买卖点/高亮/聚焦只挂在主窗：其余窗只负责显示该层结构，
      // 否则同一批标记会在 N 个窗里各画一遍。
      strategySignals: primary && _backtestPanelOpen
          ? (_backtestRun?.result?.signals ?? const [])
          : const [],
      strategyFills: primary && _backtestPanelOpen
          ? (_backtestRun?.result?.fills ?? const [])
          : const [],
      strategyRoundBySignalId:
          (!primary || !_backtestPanelOpen || _backtestRun?.result == null)
              ? const {}
              : buildStrategyRoundIndex(_backtestRun!.result!).roundBySignalId,
      highlightedStrategyIds: primary ? _btHighlightIds : const <String>{},
      focusBarIdx: primary ? _btFocusBarIdx : null,
      focusBarEpoch: _btFocusEpoch,
      onStrategySignalTap: primary ? _onChartStrategySignalTap : null,
      // 分窗固定走桌面布局：安卓交互壳层（顶部手势/浮动按钮）只应出现在单图。
      mobileLayout: split ? false : _useAndroidInteraction,
      // tooltip 停靠面板只有一块，但每个窗都要能往里写：
      // 鼠标跨到哪个窗，信息就换成那个窗所在层级的内容。
      tooltipBridge: _tooltipBridge,
      dockTooltipPanel: !_useAndroidInteraction,
    );
    // 子窗口全屏按钮已迁到顶栏（下拉选目标子窗口）；窗格内不再放按钮，
    // K 标签统一贴格子右缘（由 LevelChartGrid 的 _PaneChrome 绘制）。
    return chart;
  }

  String _mlStatusLine() {
    final code = _selectedCode ?? '未选';
    final mode = _isXgbMode ? 'XGB' : 'LR';
    final r = _mlReport;
    if (r == null) {
      return '标的=$code 周期=$_period · $mode · ${_mlSplitConfig.summary} · '
          '时序三截 · 验证调参 · 测试只报一次';
    }
    final t = r.testStats;
    return '标的=$code · $mode · 测试经验胜率=${(t.experienceWinRate * 100).toStringAsFixed(1)}%'
        ' · 基准=${(t.alphaWinRate * 100).toStringAsFixed(1)}%';
  }

  void _onMlSplitConfigChanged(MlSplitConfig cfg) {
    if (_mlTestLocked) {
      _showSnack('测试已锁定：不可改切分。请退出机器学习后重新进入');
      return;
    }
    setState(() => _mlSplitConfig = cfg);
  }

  /// 进入 ML：只打开设置页（当前股票 + 训练/验证/测试比例）。
  void _enterMlSession() {
    if (_selectedCode == null) {
      _showSnack('请先在设置里选择股票代码');
      _showMlHelp();
      return;
    }
    if (_dataRoot.isEmpty) {
      _showSnack('数据根目录未就绪，请稍候或重新打开股票下拉框');
      return;
    }
    if (_playing) {
      _playTimer?.cancel();
      _playing = false;
    }
    _mlSampler.reset();
    setState(() {
      _mlSession.enter();
      _mlPhase = MlPreparePhase.setup;
      _mlSamples = [];
      _mlReport = null;
      _mlError = null;
      _mlProgressHint = '';
      _mlTestLocked = false;
      _panelExpanded = false;
    });
    _refreshKeepAlive();
    _msgHistory.append(
      '进入机器学习：当前股票=$_selectedCode · ${_mlLabelConfig.summary} · '
      '时序三截+验证调参+测试一次锁定'
      '（schema v${MlFeatureSchema.schemaVersion}）',
    );
  }

  /// 点「加载」：取数→采样→展望窗打标→时序三截→验证调参→测试只评估一次并锁定。
  Future<void> _loadMlRun() async {
    if (_selectedCode == null) {
      _showSnack('请先选择股票');
      return;
    }
    if (_mlTestLocked) {
      _showSnack('测试已锁定一次评估。请退出机器学习后重新进入再加载');
      _msgHistory.append('ML拒绝重跑：测试已锁定（防窥探）');
      return;
    }
    _mlSampler.reset();
    setState(() {
      _mlPhase = MlPreparePhase.loading;
      _mlSamples = [];
      _mlReport = null;
      _mlError = null;
      _mlProgressHint = '正在取 $_selectedCode 数据…';
    });
    _msgHistory.append(
      'ML加载：$_selectedCode $_period · ${_mlSplitConfig.summary} · '
      '${_mlLabelConfig.summary}',
    );
    try {
      await _loadKlines();
      if (!mounted) return;
      if (!_hasSession || _allBars.isEmpty) {
        throw Exception(_error ?? '取数后无 K 线，请检查代码/区间/周期');
      }

      setState(() {
        _mlPhase = MlPreparePhase.computing;
        _mlProgressHint =
            '逐K采集 + 展望窗${_mlLabelConfig.horizonBars}K打标…';
      });
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await _runToEnd(mlSampler: _mlSampler);
      if (!mounted) return;

      setState(() {
        _mlPhase = MlPreparePhase.labeling;
        _mlProgressHint = '检查展望窗标签完整性…';
      });
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final samples = List<MlBspSample>.from(_mlSampler.samples);
      if (samples.isEmpty) {
        throw Exception('未采到 K0 一类 BS 样本，可换区间/周期再试');
      }
      final unlabeled = samples.where((e) => e.isCorrect == null).length;
      if (unlabeled > 0) {
        throw Exception('仍有 $unlabeled 条未打标（展望窗未到期）');
      }

      setState(() {
        _mlPhase = MlPreparePhase.training;
        _mlProgressHint = _isXgbMode
            ? '导出 libsvm + 调用 XGB 训练…'
            : '时序切分训练/验证/测试…';
      });
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      MlDatasetSplit.apply(samples, _mlSplitConfig);

      late final MlRunReport report;
      if (_isXgbMode) {
        setState(() {
          _mlPhase = MlPreparePhase.tuning;
          _mlProgressHint = _forceXgbRetrain
              ? 'Python XGB 强制重训中…'
              : 'Python XGB 训练（可复用指纹）…';
        });
        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
        report = await MlXgbTrainer.exportTrainAndEvaluate(
          samples: samples,
          dataRoot: _dataRoot,
          code: _selectedCode ?? '',
          period: _period,
          stepIdx: _stepIdx < 0 ? 0 : _stepIdx,
          splitConfig: _mlSplitConfig,
          params: _xgbParams,
          forceRetrain: _forceXgbRetrain,
        );
        if (!mounted) return;
        setState(() {
          _mlPhase = MlPreparePhase.evaluating;
          _mlProgressHint = 'Rust 打分完成 · 测试只评估一次并锁定…';
        });
        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
      } else {
        setState(() {
          _mlPhase = MlPreparePhase.tuning;
          _mlProgressHint = '仅验证集网格调参（测试集不参与）…';
        });
        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;

        setState(() {
          _mlPhase = MlPreparePhase.evaluating;
          _mlProgressHint = '测试集只评估一次并锁定…';
        });
        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
        report = MlExperienceTrainer.fitTuneAndTest(samples: samples);
      }

      setState(() {
        _mlSamples = samples;
        _mlReport = report;
        _mlPhase = MlPreparePhase.ready;
        _mlProgressHint = '';
        _mlTestLocked = true;
      });
      final t = report.testStats;
      _msgHistory.append(
        'ML测试结果(已锁定·${report.trainerKind})：经验胜率=${(t.experienceWinRate * 100).toStringAsFixed(1)}% '
        '基准=${(t.alphaWinRate * 100).toStringAsFixed(1)}% '
        '采纳=${t.adopted}/${t.total} · ${report.tuneSummary} · '
        '${report.drift.labelRateSummary} · ${report.drift.driftSummary}',
      );
      _showSnack(
        report.drift.alert
            ? '${report.headline} · ⚠分布漂移告警'
            : report.headline,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mlPhase = MlPreparePhase.error;
        _mlError = '$e';
        _mlProgressHint = '';
        // 失败不锁定，可改参重试
      });
      _msgHistory.append('机器学习加载失败：$e');
      _showSnack('加载失败：$e');
    }
  }

  void _exitMlSession() {
    setState(() {
      _mlSession.exit();
      _mlPhase = MlPreparePhase.setup;
      _mlSamples = [];
      _mlReport = null;
      _mlError = null;
      _mlProgressHint = '';
      _mlTestLocked = false;
      _mlSampler.reset();
    });
    _refreshKeepAlive();
    _msgHistory.append('退出机器学习：解锁测试锁定，回到复盘界面');
    _showSnack('已退出机器学习');
  }

  void _showMlHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('机器学习说明（防未来/防窥探）'),
        content: const SingleChildScrollView(
          child: Text(
            '只基于当前股票；不展示 K 线图；本阶段不导出、不加载外部模型。\n\n'
            '1. 设训练/验证比例（测试=时序余量）与展望窗K数；\n'
            '2. 「加载」：逐K采特征；α=发现后固定展望窗内 live一类+asOf极值'
            '（禁止跳末末态回标）；\n'
            '3. 时序三截→仅验证集调参→测试只评估一次并锁定；\n'
            '4. 结果含标签√率与特征漂移；测试锁定后不可改比例重跑'
            '（须退出机器学习再进）。\n\n'
            '本结果仅供学习，不构成投资建议。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  /// 跳末逐步采样用：用当步 cache 增量 Lookup（与图表同源，禁止再 Full build）。
  BarFeatureLookup _buildMlLookupFor({
    required List<KlineBar> bars,
    required List<KlineCombineFrame> combineFrames,
    required List<K0ConfirmSignal> k0Confirms,
    required List<BarCrosshairFeature> barFeatures,
    required List<K0Line> k0Lines,
    required List<LevelBundle> levels,
    required List<KlineCombineFrame> k1CombineFrames,
    required K1AnalysisBundle k1Analysis,
    required List<ZSFrame> zsK0Frames,
  }) {
    final sess = _pipelineSession;
    if (sess != null && sess.isAlive && !sess.cache.lookupEngine.isEmpty) {
      return sess.cache.lookup;
    }
    if (bars.isEmpty) return BarFeatureLookup.empty();
    final maxKn = chartMaxKn(levels: levels, k0Lines: k0Lines);
    final allSubs = buildSubIndicatorCatalog(
      maxKn,
      truncationCheck: _truncationCheck,
    ).toSet();
    final asOf = bars.last.idx;
    return BarFeatureLookup.build(
      bars: bars,
      combineFrames: combineFrames,
      k0Confirms: k0Confirms,
      barFeatures: barFeatures,
      k0Lines: k0Lines,
      k1Analysis: k1Analysis,
      levels: levels,
      k1CombineFrames: k1CombineFrames,
      buy1HistoryByKn: _stepFreeze.buy1HistoryByKn,
      sell1HistoryByKn: _stepFreeze.sell1HistoryByKn,
      buy2HistoryByKn: _stepFreeze.buy2HistoryByKn,
      sell2HistoryByKn: _stepFreeze.sell2HistoryByKn,
      buyNHistoryByKn: _stepFreeze.buyNHistoryByKn,
      sellNHistoryByKn: _stepFreeze.sellNHistoryByKn,
      adjacentRatioHistoryByKn: _stepFreeze.adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: _stepFreeze.stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: _stepFreeze.lineSlopeHistoryByKn,
      buy1K0Frames: _stepFreeze.buy1HistoryByKn[0] ?? const [],
      sell1K0Frames: _stepFreeze.sell1HistoryByKn[0] ?? const [],
      buy2K0Frames: _stepFreeze.buy2HistoryByKn[0] ?? const [],
      sell2K0Frames: _stepFreeze.sell2HistoryByKn[0] ?? const [],
      buyNK0Frames: _stepFreeze.buyNHistoryByKn[0] ?? const [],
      sellNK0Frames: _stepFreeze.sellNHistoryByKn[0] ?? const [],
      subIndicators: allSubs,
      truncationCheck: _truncationCheck,
      judgmentHistoryByKn: _stepFreeze.judgmentHistoryByKn,
      zsJudgmentHistoryByKn: _stepFreeze.zsJudgmentHistoryByKn,
      zsConfirmHistoryByKn: _stepFreeze.zsConfirmHistoryByKn,
      asOf: asOf,
      mathIndicatorConfig: _mathIndicatorConfig,
      mathFreezeStore: _stepFreeze.mathFreezeStore,
      diverFreezeStore: _stepFreeze.diverFreezeStore,
      zsK0Frames: zsK0Frames,
      maxBsClass: _maxBsClass,
    );
  }

  Widget _datePickerField({
    required String label,
    required String value,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(value, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  /// 截断开关说明弹窗（操作逻辑 + 开关含义）。
  void _showTruncationHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('截断机制说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：控制 Kn 流水线是否启用「截断监察」。\n\n'
            '开启（默认）\n'
            '· 暴力反转单元命中截断条件时，左框当场确认分型，截断K强制断开成新组。\n'
            '· 确认带 truncated 标记，tooltip 显示「值(截断)」。\n'
            '· 副图「Kn截断」仅在本开关开启时可选；关闭后自动从已勾选里移除。\n'
            '· 与「下层确认后才能参与上层」同构：截断只对已冻结下层单元生效，'
            '进行中 K0连线不参与 K1合并/截断判定。\n'
            '· 触发截断后，触发K在合并引擎内改写为可作第三元素的形态'
            '（下降截断抬低点/上升截断压高点），便于后续双高双低接续；'
            '原始K0不变。\n\n'
            '关闭\n'
            '· 回到添加截断机制之前的旧行为：暴力反转K可被包含吸收，无截断确认。\n'
            '· 便于与旧口径对照排查。\n\n'
            '操作步骤\n'
            '1. 打开右上角设置；\n'
            '2. 拨动「截断机制」开关；\n'
            '3. 当前已喂入的步进会立刻按新开关重算并刷新主/副图。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  void _showPreFirstFractalModeHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('首分型前合并框说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：控制「首个分型之前」那一段合并框怎么画、tooltip 的 MG/MD 写多少。\n'
            '只作用于首分型前的框；GG/DD、动态 K 蜡烛、连线、枢、买卖点都不受影响。\n\n'
            '三个选项\n'
            '· 种子框：首分型前**不合并**，按引擎原框逐根画（第一根框就是种子框，'
            '后面的框各自独立，横向范围也只到各自右端）。\n'
            '· 高高（默认）：把首分型前的各框并成一个框，左端从第一根 K 起、右端到'
            '最后一个框；高点取各框最高 high，低点也取各框最高 low。\n'
            '· 低低：同样并成一个框，高点取各框最低 high，低点也取各框最低 low。\n\n'
            '子窗口（层级分窗）\n'
            '· 高高 / 低低 下仍走逐对判定：相邻两根双低直接判顶分型、双高判底分型，'
            '这两种情况**不合并**；只有两根存在包含关系时才并框，并框取值按所选口径。\n'
            '· 种子框下不跑逐对判定，保持原框不变。\n\n'
            'tooltip（十字线）\n'
            '· 合并框那一行的 MG/MD 与画出来的框同源：换口径后十字线上的 MG/MD 一起变。\n'
            '· 其它数值（GG/DD、原始 K 线高低等）一律不动。\n\n'
            '操作步骤\n'
            '1. 打开右上角设置；\n'
            '2. 在「首分型前合并框」右侧下拉里选 种子框 / 高高 / 低低；\n'
            '3. 主图与各子窗口立刻按新口径重画，十字线移动一次即可看到新的 MG/MD。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      )),
    );
  }

  void _showEarlyDynamicUnitHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('层级早生成动态单元说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：控制每层首个单元（K 蜡烛）在什么时候出现。\n\n'
            '开启（默认）\n'
            '· K0 第一根：K1 窗口就有 idx=0 的动态 K（尚未确认，随行情演化）。\n'
            '· K0 首个分型确认当根：K1 的 idx=0 冻结为确认态、idx=1 动态；'
            '同时 K2 窗口出现 idx=0 动态 K。\n'
            '· 递归：Kn 的 idx=0 确认当根，K(n+1) 的 idx=0 以动态态出现。\n'
            '· 动态单元只是该层首个自然段的“演化中形态”，不合成确认段、'
            '不重编号；该层自己首个分型确认时，由经典流程转正为同一个 idx=0。\n'
            '· 动态期高低取真实 OHLC：起点极点→当步 K，high 取最高 high，'
            'low 取最低 low；「高高 / 低低」只用于合并框。\n'
            '· 种子框、种子开口虚线、种子 ABC 不画；K0 首确认前保留一条'
            '预锚动态单元的构建中虚线。\n'
            '· 十字线可跨所有窗口移动：鼠标进到哪个窗口就在那个窗口定位，'
            '其余窗口跟着联动。滚轮单击第一次只开十字线，第二次才开十字信息；'
            '十字信息只显示光标所在窗口那一层（K0 窗只出 K0，K1 窗只出 K1）。\n'
            '· 参与全链路：主/副图、中枢/买卖点、采样钟、冻结仓与回测同一口径。\n\n'
            '关闭\n'
            '· 回到经典口径：必须等引擎自己攒够输入，才出现该层首个单元；'
            'K1/K2 窗口相应延后可用。\n'
            '· 种子框与经典 K0 早退逻辑照旧。\n\n'
            '说明\n'
            '· 动态期方向/高低允许随结构修正；确认当根以实际分型为准。\n'
            '· 切换开关会清空冻结历史并从当前可见前缀重放，采样钟同步重算。\n\n'
            '操作步骤\n'
            '1. 打开右上角设置；\n'
            '2. 拨动「层级早生成动态单元」开关；\n'
            '3. 当前步进会立刻按新口径重算并刷新所有窗口。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      )),
    );
  }

  void _showPeriodHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('周期说明'),
        content: const SingleChildScrollView(
          child: Text(
            '默认：分笔（逐笔 K0）\n'
            '· 每一行分笔 = 一根 K0，O=H=L=C=成交价（一字线）。\n'
            '· 同分钟多笔=分钟起点+序内毫秒（+i ms），time 含秒/毫秒语义。\n'
            '· 主图底图画「点」不画蜡烛；缠论内核公式不变（吃 high/low）。\n'
            '· 与同区间 1 分钟缠论结构不可直接对比；结构更碎属预期。\n'
            '· 长区间根数很大，建议收窄加载起止时间。\n\n'
            '聚合周期（1分钟…多年）\n'
            '· 仍先 ticks→1 分钟，再升到所选周期；主图恢复蜡烛。\n'
            '· 可选：1/5/15/30/60 分钟，2/4 小时，1/3 日，1 周，'
            '1/3/6/9/12 月，1/3/6 年。\n\n'
            '操作步骤\n'
            '1. 设置里选周期，立即自动按新周期重载（无需手动加载）；\n'
            '2. 也可改加载起止时间 / 长按中区重载；\n'
            '3. test+custom.ohlc.csv：分笔直读行即 K0，'
            '其余周期由这些分笔按规则聚合生成。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }


  void _showTestOhlcHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('自定义 OHLC 说明'),
        content: const SingleChildScrollView(
          child: Text(
            '操作步骤：\n'
            '1. 股票选择 test；\n'
            '2. 点「编辑/加载自定义 OHLC」，默认启用分笔模板：\n'
            '   填价格与量，时间按每 3 秒一笔自动生成，开高低收联动；\n'
            '3. 「仅保存」或「保存并加载」写入 a_Data/test/custom.ohlc.csv\n'
            '   （即分笔数据源；选其它周期时由这些分笔自动聚合）。\n\n'
            '口径：分笔(tick)周期一行一笔直读；聚合周期按规则生成。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  void _showTickDrawBoardHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(
        child: AlertDialog(
          title: const Text('分笔画板说明'),
          content: const SingleChildScrollView(
            child: Text(
              '操作步骤：\n'
              '1. 股票选择 test；\n'
              '2. 点「分笔画板」，在 K 线页面拉出画板；\n'
              '3. 选择窗口数量，窗口按 K0、K1、K2 依次显示；\n'
              '4. 每个窗口都是原分窗样式，K 线/指标/十字线/信息窗可直接使用；\n'
              '5. 放大、缩小、平移和十字线全窗同步；\n'
              '6. 只有点中圆点 K 线才选中并聚焦；选中后只能上下拖动改价格'
              '（按网格吸附），不能左右移动；\n'
              '7. 拖动中与相邻 K 线同价时短暂出现同价框提示，不限制继续上下移动；\n'
              '8. 复制、删除只作用于选中的 K 线；未选中时拖拽只移动十字线；\n'
              '9. K1 及以上窗口自动生成；\n'
              '10. 点「保存并加载」，写入 a_Data/test/custom.ohlc.csv 并重新加载。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTickDrawBoard() async {
    List<KlineBar> seed = _allBars;
    if (_hasTestOhlcCsv()) {
      try {
        seed = _bridge.loadKlines(
          dataRoot: _dataRoot,
          code: 'test',
          beginDate: '1990/01/01 00:00:00',
          endDate: '2100/12/31 23:59:59',
          period: 'tick',
        );
      } catch (_) {}
    }
    final model = TickDrawBoardModel.fromBars(seed);
    final bundle = _bridge.buildKlineCombineBundle(
      model.toTickBars(),
      earlyDynamicUnit: _earlyDynamicUnit,
      truncationCheck: _truncationCheck,
    );
    // 画板子窗沿用分窗指标集合：首次进入补默认 Kn/Kn连线，已选过的保留。
    _splitIndicatorsReady = true;
    _splitMainIndicators = <MainChartIndicator>{
      ..._splitMainIndicators,
      ...defaultLevelWindowMainIndicators([
        for (var i = 0; i < model.windowCount; i++) i,
      ]),
    };
    setState(() {
      _tickDrawBoard = model;
      _tickDrawBundle = bundle;
      _tickDrawBoardOpen = true;
    });
  }

  void _updateTickDrawBoard(TickDrawBoardModel model) {
    final bundle = _bridge.buildKlineCombineBundle(
      model.toTickBars(),
      earlyDynamicUnit: _earlyDynamicUnit,
      truncationCheck: _truncationCheck,
    );
    // 窗口数量变化时补新层的默认 K 线/连线指标，避免子窗口空白。
    _splitIndicatorsReady = true;
    _splitMainIndicators = <MainChartIndicator>{
      ..._splitMainIndicators,
      ...defaultLevelWindowMainIndicators([
        for (var i = 0; i < model.windowCount; i++) i,
      ]),
    };
    setState(() {
      _tickDrawBoard = model;
      _tickDrawBundle = bundle;
    });
  }

  /// 关闭画板：只关画板，返回主图界面（不动 App 生命周期）。
  void _closeTickDrawBoard() {
    setState(() => _tickDrawBoardOpen = false);
  }

  Future<void> _saveTickDrawBoard() async {
    final model = _tickDrawBoard;
    if (model == null) return;
    final bars = model.toTickBars();
    try {
      final saved = _bridge.saveTestOhlc(dataRoot: _dataRoot, bars: bars);
      _msgHistory.append('分笔画板：保存${saved.count}根 → ${saved.path}');
      if (bars.isNotEmpty) {
        final begin = _tryParseBarTime(bars.first.timeText);
        final end = _tryParseBarTime(bars.last.timeText);
        if (begin != null && end != null) {
          setState(() {
            _beginDate = begin;
            _endDate = end;
            _tickDrawBoardOpen = false;
          });
        }
      }
      await _loadKlines();
    } catch (e) {
      setState(() => _error = e.toString());
      _msgHistory.append('分笔画板保存失败：$e');
    }
  }

  Future<void> _openTestOhlcEditor() async {
    // 预填：优先 CSV 全量（用 tick 直读分笔原文，不用聚合周期）；
    // 否则当前图上 bars；再否则空表模板
    List<KlineBar> seed = _allBars;
    if (_hasTestOhlcCsv()) {
      try {
        seed = _bridge.loadKlines(
          dataRoot: _dataRoot,
          code: 'test',
          beginDate: '1990/01/01 00:00:00',
          endDate: '2100/12/31 23:59:59',
          period: 'tick',
        );
      } catch (_) {
        // 保持 seed=_allBars
      }
    }
    final result = await showTestOhlcEditorDialog(
      context: context,
      initialBars: seed,
      // 分笔模板默认启用：每 3 秒一笔 + 开高低收联动 + 时间自动生成。
      tickTemplate: true,
    );
    if (result == null || !mounted) return;
    try {
      final saved = _bridge.saveTestOhlc(
        dataRoot: _dataRoot,
        bars: result.bars,
      );
      _msgHistory.append(
        'test 自定义OHLC：保存${saved.count}根 → ${saved.path}',
      );
      // 保存后对齐区间到文件首末
      if (result.bars.isNotEmpty) {
        final b0 = _tryParseBarTime(result.bars.first.timeText);
        final b1 = _tryParseBarTime(result.bars.last.timeText);
        if (b0 != null && b1 != null) {
          setState(() {
            _beginDate = b0;
            _endDate = b1;
          });
        }
      }
      if (result.loadAfterSave) {
        await _loadKlines();
      }
    } catch (e) {
      setState(() => _error = e.toString());
      _msgHistory.append('test 自定义OHLC 保存失败：$e');
    }
  }

  /// 构建中/未确认虚线开关说明弹窗（操作逻辑 + 开关含义）。
  void _showBuildingDashHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('构建中/未确认虚线说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：统一控制主图所有「构建中 / 未确认」的画线是否用虚线区分（与已确认的实线区分）。\n\n'
            '覆盖范围（开=虚线，关=全部实线）\n'
            '· 主图 K0/K1/…/KN 每层的末组合并框：末组=进行中、可继续延伸的合并，画虚线；前组=已冻结，画实线；\n'
            '· K0/K1/…/KN 构建中连线：与动态KN合并同输入的未冻结虚拟单元，'
            '按确认段几何画虚线（动态KN当确认KN）；\n'
            '· 种子框 UNKNOWN 开口（全层同构）：首分型前对照动态末组 hn/ln 的 sit1/sit2 才画；'
            '动态末组=冻+下层进行中（与动态Kn合并同口径）；种子含末组不画；'
            '虚线=动态Kn/动态合并/分型判断，实线=确认Kn/确认合并/分型确认，确认优先；'
            '第一条虚线期内非leave严格包含至多截一次；确认后TruncGuard原样；\n'
            '· 分型确认优先：纠正虚线端点，或单元冻结后虚线改实线；不回写永久结构；\n'
            '· 尾端取区间内首次方向极值所在 K0（非 as-of 末根钉 X）；全层同构；\n'
            '· K0/K1/…/Kn中枢：确定态实线；不确定/单段雏形虚线；框内斜线填充（与合并框区分）。\n\n'
            '关闭\n'
            '· 上述所有元素一律实线，不区分构建中状态（合并框、各层构建中连线、中枢框均实线）。\n\n'
            '操作步骤\n'
            '1. 打开右上角设置；\n'
            '2. 拨动「构建中/未确认虚线」开关；\n'
            '3. 当前图表立刻按开关刷新（无需重算步进）。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  /// 层级分窗总开关落地（设置面板与分窗配置共用同一条路径）。
  Future<void> _setLevelWindowSplitEnabled(
    bool v, {
    StateSetter? sheetSetState,
  }) async {
    await LevelWindowSettingsStore.save(enabled: v);
    if (!mounted) return;
    // 首次开分窗：每窗默认 Kn + 连线，其余指标由用户自行勾选。
    if (v) _ensureSplitIndicators();
    // 重新开分窗时副图胶囊条从头量起，避免沿用上一次运行的高占位。
    _chartSync.resetSubChipBand();
    _panelUi(() {}, sheetSetState: sheetSetState);
    _msgHistory.append(
      v
          ? '层级分窗=开（${LevelWindowSettingsStore.count} 窗）'
          : '层级分窗=关（回到单图集成）',
    );
  }

  /// 打开「窗口数量 + 每窗层级」设置弹窗；应用后落盘并重建图表。
  Future<void> _editLevelWindowLayout({StateSetter? sheetSetState}) async {
    final cfg = await showDialog<LevelWindowConfig>(
      context: context,
      builder: (_) => LevelWindowSettingsDialog(
        initialCount: LevelWindowSettingsStore.count,
        initialSlots: LevelWindowSettingsStore.slots,
      ),
    );
    if (cfg == null) return;
    await LevelWindowSettingsStore.save(
      enabled: true,
      count: cfg.count,
      slots: cfg.slots,
    );
    if (!mounted) return;
    // 层级换了：分窗指标重新按新层级铺默认（每窗只有本层 Kn，副图不勾）。
    _resetSplitIndicators();
    // 槽位换了，旧的 as-of 仓与查找缓存立即作废（避免串层）。
    _chartSync.asOfCache.clear();
    _chartSync.zsAsOfKey = null;
    _chartSync.zsAsOfBundle = null;
    // 窗口数/层级换了：副图胶囊条占位重新量。
    _chartSync.resetSubChipBand();
    _panelUi(() {}, sheetSetState: sheetSetState);
    final names = cfg.slots.take(cfg.count).map((e) => 'K$e').join(' / ');
    _msgHistory.append('层级分窗：${cfg.count} 窗（$names）');
  }

  /// 层级分窗操作说明弹窗（按 AGENTS：新增设置必须有操作逻辑与步骤说明）。
  void _showLevelWindowSplitHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('层级分窗说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：把现在「各层级集成在同一张 K 线图」的显示方式，拆成多个窗口，'
            '每个窗口只画一个层级（K0 真 K 线、K1 虚拟 K 线、K2+ 该层单元 K 线）。\n'
            '默认每窗只显示本层 Kn 与本层连线；合并框、中枢、买卖点与副图'
            '一律不默认启用；要看就点该窗对应的指标面板自行勾选。\n\n'
            '布局规则\n'
            '· 2 窗：左右排布；\n'
            '· 4 窗：上 2 下 2；6 窗：上 3 下 3；8 窗：上 4 下 4；10 窗：上 5 下 5；\n'
            '· 窗口按「左→右、上→下」依次取用设置里的层级。\n\n'
            '每窗层级\n'
            '· 由你自己逐个指定（K0 到 K9），同一层级只能占用一个窗口；\n'
            '· 必须包含 K0：没有 K0 就弹窗警告并拒绝应用；\n'
            '· 缩窗时若会把 K0 挤出可见范围，会自动把 K0 换到第 1 窗并提示。\n\n'
            '每窗都能操作\n'
            '· 每一窗都支持步进/步退、播放、长按步退/重载/播放，操作热区与 K0 窗一致'
            '（左＝步退、中＝播放/暂停、右＝步进、双击切十字线；'
            '左边界按住连续步退、右边界按住连续播放，松开即停）；\n'
            '· 步进颗粒度永远是 K0 的一根 K，所有窗同步看到同一步；\n'
            '· 每窗各自缩放、各自平移，互不牵连；主副图分割比例仍全窗共用，'
            '拖任一窗分割线全窗一起变；\n'
            '· 指标面板只列本层指标（主图与副图都是），勾选只作用于本层；'
            '默认只勾本层 K 线，副图默认一项不勾。\n\n'
            '十字线\n'
            '· 任一窗都能开启；开启瞬间该窗成为主窗，其余窗立刻切到主窗同一段'
            '（同一根 K 同一列、同一价格同一行）；\n'
            '· 若某窗看不到十字线那根 K，该窗只平移把它带进可见区，不改缩放；\n'
            '· 关闭十字线后，其余窗恢复各自开启前的缩放与位置。\n\n'
            '副图小眼睛\n'
            '· 副图区最右侧的眼睛按钮：点一下收起整块副图、主图吃满，'
            '图标变「眼睛+斜线」；再点恢复；\n'
            '· 每窗独立控制，单图集成模式也有。\n\n'
            '操作步骤\n'
            '1. 打开右上角设置；\n'
            '2. 打开「层级分窗（每层一个窗口）」；\n'
            '3. 点「窗口数量与每窗层级」，选数量、逐窗选层级，点「应用」；\n'
            '4. 关掉总开关即回到原来的单图集成，指标与副图不受影响。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      )),
    );
  }

  void _showBsVerdictOverlayHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('BSP对错叠加X说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：在原 Kn类BS 副图标记处叠加在线对错结果。\n\n'
            '评判源\n'
            '· 只使用 Rust 输出的 bs_verdict（Pending/Correct/Wrong）；\n'
            '· Flutter 不重新判断对错，只接收、冻结、按十字 asOf 展示。\n\n'
            '覆盖范围\n'
            '· 当前项目全部 BSP 类别：1B/2B/…/nB 与 1S/2S/…/nS；\n'
            '· K0…KN 同一套 judge；原 BSP 的 x/价格/标签不被改写。\n\n'
            '叠加规则\n'
            '· 对（Correct）或尚未判定（Pending）：不叠加，保持原标记；\n'
            '· 错（Wrong）：在原标记圆心叠加一个 X。\n'
            '· 十字 asOf=X 时，只展示 verdict_x≤X 的终态；提前于评判步仍显示 Pending。\n\n'
            '与旧 ML α\n'
            '· 旧 isCorrect 仍是展望窗离线标签，不是本开关的事实源。\n\n'
            '操作步骤\n'
            '1. 打开右上角设置；\n'
            '2. 拨动「BSP对错叠加X」；\n'
            '3. 图表立刻刷新（无需重算步进）。须连续单步验收，一键跳末≠步进验收。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  /// 筹码分布说明弹窗。
  void _showChipHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('筹码分布说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：展示历史成交量在价格维度上的累积分布'
            '（上市/区间首根 → 当前步进/十字 as-of）。\n\n'
            '怎么看\n'
            '· 主图右侧水平柱：左绿=S（卖），右红=B（买）；\n'
            '· 筹码峰：局部量峰打点，虚线延长到主图左侧；'
            '按 ±档自动配色：+1/-1 同色、+2/-2 同色…，框内 INn 另色；\n'
            '· 由设置面板总开关控制，不参与主图指标勾选；仅 K0 分支。\n\n'
            '数据与当下性\n'
            '· 离线分笔写入 chip_tick_bins（价量直加）；tick 禁止三角；'
            '非一字且无 bins 时才 OHLC 三角估算；\n'
            '· 逐K只累加已喂入 K 线；十字悬停回滚到该日累积，不回写历史；\n'
            '· 仅 K0：cutoff=当前步进末根 / 十字 as-of 所在 K0。\n\n'
            '操作步骤\n'
            '1. 设置里打开「筹码分布」总开关；\n'
            '2. 主图右侧立即绘制 K0 筹码；\n'
            '3. 桶宽在「数学指标参数」里用输入框设置（最小 0.01，与笔数分布共用）；\n'
            '4. 可调「峰延长线（按 ±档配色）」（与笔数分布共享开关）；配置写入 .chan_chip_config.json。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }

  /// 数学指标说明弹窗。
  void _showMathIndicatorHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('数学指标参数'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：移植旧工程 Math——均线/通道/BOLL/回归通道/MACD/RSI/KDJ/Demark/背驰；\n'
            '另含筹码/笔数分布共用桶宽。\n'
            '口径（全层同构）\n'
            '· K0：原生 K 线 OHLC；Kn≥1：unitBars+active；\n'
            '· 回归通道：父层 K{n+1}连线最后一段绑定——段内最小二乘回归=中轨，上下轨=中轨±k×残差标准差，'
            '外推到 asOf（与布林不同源；不进冻结仓）；\n'
            '· Demark：主图标注；Countdown 宽松/严、完美9、反向打断可配；\n'
            '· 背驰：进出段力度比 + diver∈{1,-1,0}；无 turnrate（离线无换手）；\n'
            '· 桶宽：最小 0.01 元，筹码与笔数分布共用；\n'
            '· K0 颗粒度展开；无未来函数；十字 asOf 截断。\n\n'
            '操作步骤\n'
            '1. 主图勾选布林/回归通道/Demark；副图勾选 MACD/RSI/KDJ/背驰_*；\n'
            '2. 点本项或「?」编辑参数（回归通道 k、Demark/背驰率/桶宽）；\n'
            '3. Math 写入 .chan_trend_model_config.json；桶宽写入筹码配置。\n\n'
            '回归通道（详细说明）\n'
            '· 基准区间：父层 K{n+1}连线（K0回归通道看 K1连线、K1看 K2…）在 asOf 视图下的最后一段'
            '（倒数第二个极点 → 最后一个极点）；端点含分型判断与构建中开口尾端；\n'
            '· 父层一出现新段，整条通道换基准（旧的整条不留，不拼阶梯）；\n'
            '· 回归：以 K0 格点 x 为自变量最小二乘 → 中轨（带斜率）；上下轨 = 中轨 ± k×残差总体标准差（与本项目布林同口径）；\n'
            '· 平行外推到 asOf 截断（宽度恒定，非喇叭口），asOf 右侧不画；十字 asOf 回退不泄漏未来；\n'
            '· 已接入：回测变量 MAIN.Kn.REGRESS.MID/UP/DOWN + 十字读数 regress_mid/up/down（按 asOf 现算，不进冻结仓）；\n'
            '· 不参与任何信号计算的未来函数；父层未成形或样本不足 2 根 → 该层整条不出线；\n'
            '· 与布林区别：布林=滑窗均值（水平线）全图连续；回归通道=父层连线段内回归线（带斜率）只画最新一段。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _editMathIndicatorParams();
            },
            child: const Text('编辑参数'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    ));
  }


  /// 编辑数学指标参数。
  Future<void> _editMathIndicatorParams() async {
    final meanCtl = TextEditingController(
        text: _mathIndicatorConfig.meanPeriods.join(','));
    final chanCtl = TextEditingController(
        text: _mathIndicatorConfig.channelPeriods.join(','));
    final macdFastCtl =
        TextEditingController(text: '${_mathIndicatorConfig.macdFast}');
    final macdSlowCtl =
        TextEditingController(text: '${_mathIndicatorConfig.macdSlow}');
    final macdSigCtl =
        TextEditingController(text: '${_mathIndicatorConfig.macdSignal}');
    final bollCtl = TextEditingController(text: '${_mathIndicatorConfig.bollN}');
    final donchianCtl =
        TextEditingController(text: '${_mathIndicatorConfig.donchianN}');
    final regressKCtl = TextEditingController(
        text: _mathIndicatorConfig.regressK.toStringAsFixed(2));
    final rsiCtl =
        TextEditingController(text: '${_mathIndicatorConfig.rsiPeriod}');
    final kdjCtl =
        TextEditingController(text: '${_mathIndicatorConfig.kdjPeriod}');
    final demarkLenCtl =
        TextEditingController(text: '${_mathIndicatorConfig.demarkLen}');
    final demarkSetupCtl =
        TextEditingController(text: '${_mathIndicatorConfig.demarkSetupBias}');
    final demarkCdCtl = TextEditingController(
        text: '${_mathIndicatorConfig.demarkCountdownBias}');
    final demarkMaxCtl = TextEditingController(
        text: '${_mathIndicatorConfig.demarkMaxCountdown}');
    final diverRateCtl = TextEditingController(
        text: '${_mathIndicatorConfig.divergenceRate}');
    final bucketCtl = TextEditingController(
        text: _chipConfig.bucketStep.toStringAsFixed(2));
    final peakRankNctl = TextEditingController(
        text: '${_chipConfig.chipPeakPureRank}');
    var peakLineMode = _chipConfig.peakLineMode;
    var demarkCdMode = _mathIndicatorConfig.demarkCountdownMode;
    var demarkPerfect9 = _mathIndicatorConfig.demarkPerfect9;
    var demarkInterruptCd =
        _mathIndicatorConfig.demarkInterruptCountdownOnReverse;
    int parseInt(String s, int fb) => int.tryParse(s.trim()) ?? fb;
    double parseDouble(String s, double fb) =>
        double.tryParse(s.trim()) ?? fb;
    /// 桶宽：最小 0.01；非法回落当前值
    double parseBucket(String s) {
      final v = double.tryParse(s.trim());
      if (v == null || !v.isFinite) return _chipConfig.bucketStep;
      if (v < 0.01) return 0.01;
      return (v * 100).round() / 100.0;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => SelectionArea(child: AlertDialog(
        title: const Text('设置数学指标参数'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: meanCtl,
                  decoration: const InputDecoration(
                    labelText: '均线周期',
                    hintText: '如 5,10,20',
                  ),
                ),
                TextField(
                  controller: chanCtl,
                  decoration: const InputDecoration(
                    labelText: '通道周期',
                    hintText: '如 20,60',
                  ),
                ),
                TextField(
                  controller: macdFastCtl,
                  decoration: const InputDecoration(labelText: 'MACD 快线'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: macdSlowCtl,
                  decoration: const InputDecoration(labelText: 'MACD 慢线'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: macdSigCtl,
                  decoration: const InputDecoration(labelText: 'MACD 信号线'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: bollCtl,
                  decoration: const InputDecoration(labelText: 'BOLL N'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: donchianCtl,
                  decoration: const InputDecoration(
                    labelText: '唐奇安 N',
                    hintText: '窗口根数，默认 20',
                  ),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: regressKCtl,
                  decoration: const InputDecoration(
                    labelText: '回归通道 k',
                    hintText: '上下轨倍数，默认 2.00',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                TextField(
                  controller: rsiCtl,
                  decoration: const InputDecoration(labelText: 'RSI 周期'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: kdjCtl,
                  decoration: const InputDecoration(labelText: 'KDJ 周期'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Demark',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                TextField(
                  controller: demarkLenCtl,
                  decoration:
                      const InputDecoration(labelText: 'Demark setup 长度'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: demarkSetupCtl,
                  decoration:
                      const InputDecoration(labelText: 'Demark setup bias'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: demarkCdCtl,
                  decoration: const InputDecoration(
                      labelText: 'Demark countdown bias'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: demarkMaxCtl,
                  decoration: const InputDecoration(
                      labelText: 'Demark max countdown'),
                  keyboardType: TextInputType.number,
                ),
                DropdownButtonFormField<DemarkCountdownMode>(
                  value: demarkCdMode,
                  decoration: const InputDecoration(
                    labelText: 'Countdown 比较',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: DemarkCountdownMode.looseClose,
                      child: Text('宽松：买close<close[i-2] / 卖close>close[i-2]'),
                    ),
                    DropdownMenuItem(
                      value: DemarkCountdownMode.strictExtreme,
                      child: Text('原版严：买close≤low[i-2] / 卖close≥high[i-2]'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setLocal(() => demarkCdMode = v);
                  },
                ),
                DropdownButtonFormField<bool>(
                  value: demarkPerfect9,
                  decoration: const InputDecoration(
                    labelText: '完美 9（Perfected）',
                  ),
                  items: const [
                    DropdownMenuItem(value: false, child: Text('不启用（默认）')),
                    DropdownMenuItem(value: true, child: Text('启用')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setLocal(() => demarkPerfect9 = v);
                  },
                ),
                DropdownButtonFormField<bool>(
                  value: demarkInterruptCd,
                  decoration: const InputDecoration(
                    labelText: '反向 Setup 打断 Countdown',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: false,
                      child: Text('宽松：不打断（仅 TDST/数满13）'),
                    ),
                    DropdownMenuItem(
                      value: true,
                      child: Text('严：反向 Setup 即废倒计时（默认）'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setLocal(() => demarkInterruptCd = v);
                  },
                ),
                TextField(
                  controller: diverRateCtl,
                  decoration: const InputDecoration(
                    labelText: '背驰率 divergence_rate',
                    hintText: '>100 保送；默认 1.0；如 0.8',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('筹码 / 笔数分布',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                TextField(
                  controller: bucketCtl,
                  decoration: const InputDecoration(
                    labelText: '筹码桶宽（元，笔数分布共用）',
                    hintText: '最小 0.01；如 0.01 / 0.05 / 0.10',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                TextField(
                  controller: peakRankNctl,
                  decoration: const InputDecoration(
                    labelText: '筹码峰数量 N（纯量级取前 N 个峰）',
                    hintText: '1..12，默认 7',
                  ),
                  keyboardType: TextInputType.number,
                ),
                DropdownButtonFormField<PeakLineMode>(
                  value: peakLineMode,
                  decoration: const InputDecoration(
                    labelText: '峰线型（筹码峰延长线）',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: PeakLineMode.solid,
                      child: Text('全实线'),
                    ),
                    DropdownMenuItem(
                      value: PeakLineMode.dashed,
                      child: Text('全虚线'),
                    ),
                    DropdownMenuItem(
                      value: PeakLineMode.bySign,
                      child: Text('按符号（默认）'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setLocal(() => peakLineMode = v);
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    ));
    if (ok != true || !mounted) {
      for (final c in [
        meanCtl,
        chanCtl,
        macdFastCtl,
        macdSlowCtl,
        macdSigCtl,
        bollCtl,
        donchianCtl,
        regressKCtl,
        rsiCtl,
        kdjCtl,
        demarkLenCtl,
        demarkSetupCtl,
        demarkCdCtl,
        demarkMaxCtl,
        diverRateCtl,
        bucketCtl,
      ]) {
        c.dispose();
      }
      return;
    }
    final bucketStep = parseBucket(bucketCtl.text);
    final cfg = MathIndicatorConfig(
      meanPeriods: TrendModelConfig.parsePeriodsText(
        meanCtl.text,
        TrendModelConfig.defaultMeanPeriods,
      ),
      channelPeriods: TrendModelConfig.parsePeriodsText(
        chanCtl.text,
        TrendModelConfig.defaultChannelPeriods,
      ),
      macdFast: parseInt(macdFastCtl.text, 12),
      macdSlow: parseInt(macdSlowCtl.text, 26),
      macdSignal: parseInt(macdSigCtl.text, 9),
      bollN: parseInt(bollCtl.text, 20),
      donchianN: parseInt(donchianCtl.text, 20),
      regressK: parseDouble(regressKCtl.text, 2.0),
      rsiPeriod: parseInt(rsiCtl.text, 14),
      kdjPeriod: parseInt(kdjCtl.text, 9),
      demarkLen: parseInt(demarkLenCtl.text, 9),
      demarkSetupBias: parseInt(demarkSetupCtl.text, 4),
      demarkCountdownBias: parseInt(demarkCdCtl.text, 2),
      demarkMaxCountdown: parseInt(demarkMaxCtl.text, 13),
      demarkCountdownMode: demarkCdMode,
      demarkPerfect9: demarkPerfect9,
      demarkInterruptCountdownOnReverse: demarkInterruptCd,
      divergenceRate: parseDouble(diverRateCtl.text, 1.0),
    );
    for (final c in [
      meanCtl,
      chanCtl,
      macdFastCtl,
      macdSlowCtl,
      macdSigCtl,
      bollCtl,
      donchianCtl,
      rsiCtl,
      kdjCtl,
      demarkLenCtl,
      demarkSetupCtl,
      demarkCdCtl,
      demarkMaxCtl,
      diverRateCtl,
      bucketCtl,
      peakRankNctl,
    ]) {
      c.dispose();
    }
    // Math 参数未变则不重冻；桶宽单独落盘筹码配置
    if (cfg != _mathIndicatorConfig) {
      await _updateMathIndicatorConfig(cfg);
    }
    if ((bucketStep - _chipConfig.bucketStep).abs() > 1e-12) {
      await _updateChipConfig(_chipConfig.copyWith(bucketStep: bucketStep));
      await _updateTickDistConfig(
          _tickDistConfig.copyWith(bucketStep: bucketStep));
    }
    final peakN = parseInt(peakRankNctl.text, _chipConfig.chipPeakPureRank)
        .clamp(1, 12);
    if (peakN != _chipConfig.chipPeakPureRank ||
        peakLineMode != _chipConfig.peakLineMode) {
      await _updateChipConfig(_chipConfig.copyWith(
        chipPeakPureRank: peakN,
        peakLineMode: peakLineMode,
      ));
      _msgHistory.append(
        '筹码峰参数：数量N=$peakN；线型=${peakLineMode.name}',
      );
    }
    _msgHistory.append(
      '数学指标：均线=${cfg.meanPeriods.join(",")}；通道=${cfg.channelPeriods.join(",")}；'
      'MACD=${cfg.macdFast}/${cfg.macdSlow}/${cfg.macdSignal}；BOLL=${cfg.bollN}；'
      '唐奇安N=${cfg.donchianN}；'
      'RSI=${cfg.rsiPeriod}；KDJ=${cfg.kdjPeriod}；Demark=${cfg.demarkLen}'
      '/${cfg.demarkCountdownMode.name}'
      '/完美9=${cfg.demarkPerfect9}'
      '/反向打断=${cfg.demarkInterruptCountdownOnReverse}；'
      '背驰率=${cfg.divergenceRate}；桶宽=$bucketStep',
    );
  }
}

/// 标题条紧凑按钮：严格 28×28（= kDesktopCaptionBarHeight），自绘 hover 底色。
///
/// 不用 Material `IconButton`——它内部强制 48px 最小命中区，在 28px 工具条里
/// 会与相邻按钮的命中区叠在一起（用户反馈的重叠根因）；也不用
/// `WindowCaptionButton`——它强制 minWidth 46 / minHeight 32，必然溢出工具条。
class _CaptionBarButton extends StatefulWidget {
  const _CaptionBarButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_CaptionBarButton> createState() => _CaptionBarButtonState();
}

class _CaptionBarButtonState extends State<_CaptionBarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: kDesktopCaptionBarHeight,
            height: kDesktopCaptionBarHeight,
            alignment: Alignment.center,
            color: _hovered && enabled
                ? AppPalette.rgb(0x33FFFFFF)
                : const Color(0x00000000),
            child: Opacity(
              opacity: enabled ? 1.0 : 0.4,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏「子窗口全屏」下拉弹层：`PopupMenuItem<int>` 列出各分窗层级。
class _SplitFullscreenPopupRoute extends PopupRoute<int> {
  _SplitFullscreenPopupRoute({
    required this.items,
    required this.position,
  });

  final List<PopupMenuEntry<int>> items;
  final RelativeRect position;

  @override
  Color? get barrierColor => const Color(0x00000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '子窗口全屏';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondary) {
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: CustomSingleChildLayout(
        delegate: _SplitFullscreenLayoutDelegate(position),
        child: Material(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
          child: IntrinsicWidth(
            child: Container(
              constraints: const BoxConstraints(minWidth: 96),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: items,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitFullscreenLayoutDelegate extends SingleChildLayoutDelegate {
  _SplitFullscreenLayoutDelegate(this.position);

  final RelativeRect position;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return Offset(
      position.right > 0
          ? math.max(8.0, size.width - childSize.width - position.right)
          : math.max(8.0, size.width - childSize.width - 8),
      position.top > 0 ? position.top : kDesktopCaptionBarHeight + 2,
    );
  }

  @override
  bool shouldRelayout(covariant _SplitFullscreenLayoutDelegate old) =>
      old.position != position;
}
