import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/chan_bridge.dart';
import 'compute/adjacent_ratio_compute.dart';
import 'compute/chip_profile_compute.dart';
import 'compute/tick_dist_profile_compute.dart';
import 'compute/class1_bs_compute.dart';
import 'compute/class2_bs_compute.dart';
import 'compute/class_n_bs_compute.dart';
import 'compute/fractal_judgment_compute.dart';
import 'compute/k1_bar_view_compute.dart';
import 'compute/step_rhythm_compute.dart';
import 'history/app_debug_snapshot.dart';
import 'history/msg_history.dart';
import 'models/zs_frame.dart';
import 'models/buy1_frame.dart';
import 'models/sell1_frame.dart';
import 'models/buy2_frame.dart';
import 'models/sell2_frame.dart';
import 'models/buy_n_frame.dart';
import 'models/sell_n_frame.dart';
import 'models/kline_bar.dart';
import 'models/k0_confirm_signal.dart';
import 'models/bar_crosshair_feature.dart';
import 'models/k0_line.dart';
import 'models/k1_bar_view.dart';
import 'models/chart_indicator.dart';
import 'models/chip_config.dart';
import 'models/tick_dist_config.dart';
import 'models/kline_combine_frame.dart';
import 'models/level_models.dart';
import 'models/k1_analysis.dart';
import 'models/kline_combine_bundle.dart';
import 'settings/chip_settings_store.dart';
import 'widgets/datetime_picker_dialog.dart';
import 'widgets/edge_control_panel.dart';
import 'widgets/kline_chart.dart';
import 'widgets/test_ohlc_editor_dialog.dart';
import 'window_work_area.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  // Kn相邻比例 + Kn步进节奏副图
  MsgHistory.instance.appendAdjacentRatioAndStepRhythm();
  MsgHistory.instance.appendTickK0NativePeriod();
  // 展示轨：动态KN当确认段画虚线；确认优先纠正/改实线
  MsgHistory.instance.appendDisplayTrackDynamicKnBuildingLines();
  // 种子框 / 第一条虚线限制 / 种子包含截断（全层同构，常驻历史）
  MsgHistory.instance.appendSeedBoxFirstSeg();
  MsgHistory.instance.appendSeedFirstDashRules();
  MsgHistory.instance.appendSeedContainTruncation();
  // test 自定义 OHLC：前端编辑 → custom.ohlc.csv 直读上图
  MsgHistory.instance.appendTestCustomOhlc();
  // 桌面：工作区全屏不盖任务栏；tooltip 分隔线贴边框
  MsgHistory.instance.appendDesktopWorkAreaAndTooltipSep();
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
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      // 隐藏系统标题文字与白底标题栏，自绘右上角三键
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFF121212),
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

class ChanKlineApp extends StatelessWidget {
  const ChanKlineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CHAN_RUST K线',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF42A5F5),
          brightness: Brightness.dark,
        ),
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

class _KlineHomePageState extends State<KlineHomePage> {
  final _bridge = ChanBridge.instance;
  final _msgHistory = MsgHistory.instance;
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
  int _stepIdx = -1; // -1 表示尚未步进
  bool _playing = false;
  Timer? _playTimer;
  String? _error;
  bool _defaultK0Purged = false;
  String _defaultK0Policy = 'pending';
  bool _bootstrapping = false;
  bool _loadingChart = false;
  bool _panelExpanded = false;
  int _panelEdge = 1; // 默认右贴边（设置按钮在右上）
  /// 截断监察：开=当前口径；关=添加截断前旧行为（暴力反转被吸收）
  bool _truncationCheck = true;
  /// 构建中合并框（虚线）开关：开=末组合并画虚线；关=全部实线（默认开）
  bool _showBuildingDash = true;
  /// 筹码分布配置（落盘 .chan_chip_config.json）
  ChipConfig _chipConfig = const ChipConfig();
  /// 笔数分布配置（主图左侧；同 JSON 嵌套 tickDist）
  TickDistConfig _tickDistConfig = const TickDistConfig();
  /// chip 分支：仅显示筹码分布，关闭所有缠论渲染（关=正常缠论+筹码可并存）
  final bool _chipOnlyMode = false;

  /// 分型判断步进事件日志：kn → 追加式历史（换股/重载才清空；不因重算丢点）
  Map<int, List<FractalJudgmentEvent>> _judgmentHistoryByKn = {};

  /// 一类BS 会话历史：对齐分型判断（K0 步进颗粒度 + 动态 Kn）；换股/重载清空。
  /// 踩坑：禁止只用「层|段|标签」去重——同动态 active 延伸时下一步会无新 x。
  Map<int, List<Buy1Frame>> _buy1HistoryByKn = {};
  Map<int, List<Sell1Frame>> _sell1HistoryByKn = {};

  /// 二类BS 会话历史（与一类同框同构冻结）。
  Map<int, List<Buy2Frame>> _buy2HistoryByKn = {};
  Map<int, List<Sell2Frame>> _sell2HistoryByKn = {};

  /// 三类+BS 会话历史（链升类；双键冻结同构）。
  Map<int, List<BuyNFrame>> _buyNHistoryByKn = {};
  Map<int, List<SellNFrame>> _sellNHistoryByKn = {};

  /// Kn相邻比例会话历史（按显示层；换股/重载清空）。
  Map<int, List<AdjacentRatioPoint>> _adjacentRatioHistoryByKn = {};

  /// Kn步进节奏会话历史 + 每层方向状态。
  Map<int, List<StepRhythmLinePoint>> _stepRhythmHistoryByKn = {};
  final Map<int, StepRhythmState> _stepRhythmStateByKn = {};

  /// catalog 三类..N 类上限（至少 9；随会话观察到的更高类扩大）
  int get _maxBsClass => math.max(
        9,
        maxBuyNClassObserved(
          buyNHistoryByKn: _buyNHistoryByKn,
          sellNHistoryByKn: _sellNHistoryByKn,
        ),
      );

  bool get _busy => _bootstrapping || _loadingChart;
  bool get _hasSession => _allBars.isNotEmpty;
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
    _loadChipConfig();
    _bootstrap();
  }

  Future<void> _loadChipConfig() async {
    final both = await ChipSettingsStore.loadBoth();
    if (!mounted) return;
    setState(() {
      _chipConfig = both.$1;
      _tickDistConfig = both.$2;
    });
  }

  Future<void> _updateChipConfig(ChipConfig cfg) async {
    setState(() => _chipConfig = cfg);
    await ChipSettingsStore.save(cfg, tickDist: _tickDistConfig);
  }

  Future<void> _updateTickDistConfig(TickDistConfig cfg) async {
    setState(() => _tickDistConfig = cfg);
    await ChipSettingsStore.save(_chipConfig, tickDist: cfg);
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  /// 切换股票时对齐各自默认加载区间。
  void _syncDateRangeForCode(String code) {
    // test + 已有 custom.ohlc.csv：用文件首末时间填区间
    if (code == 'test' && _hasTestOhlcCsv()) {
      try {
        final bars = _bridge.loadKlines(
          dataRoot: _dataRoot,
          code: 'test',
          beginDate: '1990/01/01 00:00:00',
          endDate: '2100/12/31 23:59:59',
          period: _period,
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

  String? _preferredCode(List<String> codes) {
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

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _error = null;
    });
    try {
      final root = _bridge.defaultDataRoot();
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
      setState(() => _error = e.toString());
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
    });
    try {
      final bars = _bridge.loadKlines(
        dataRoot: _dataRoot,
        code: code,
        beginDate: _fmtDateTime(_beginDate),
        endDate: _fmtDateTime(_endDate),
        period: _period,
      );
      setState(() {
        _allBars = bars;
        _stepIdx = bars.isEmpty ? -1 : 0;
        _defaultK0Purged = false;
        _judgmentHistoryByKn.clear();
        _buy1HistoryByKn.clear();
        _sell1HistoryByKn.clear();
        _buy2HistoryByKn.clear();
        _sell2HistoryByKn.clear();
        _buyNHistoryByKn.clear();
        _sellNHistoryByKn.clear();
        _adjacentRatioHistoryByKn.clear();
        _stepRhythmHistoryByKn.clear();
        for (final s in _stepRhythmStateByKn.values) {
          s.reset();
        }
        _stepRhythmStateByKn.clear();
      });
      final directOhlc = code == 'test' && _hasTestOhlcCsv();
      _msgHistory.append(
        '加载K0：$code ${_fmtDateTime(_beginDate)}~${_fmtDateTime(_endDate)} '
        '${_periods[_period] ?? _period} 共${bars.length}根'
        '${directOhlc ? "（直读custom.ohlc.csv，忽略周期聚合）" : ""}',
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
        _judgmentHistoryByKn.clear();
        _buy1HistoryByKn.clear();
        _sell1HistoryByKn.clear();
        _buy2HistoryByKn.clear();
        _sell2HistoryByKn.clear();
        _buyNHistoryByKn.clear();
        _sellNHistoryByKn.clear();
        _adjacentRatioHistoryByKn.clear();
        _stepRhythmHistoryByKn.clear();
        for (final s in _stepRhythmStateByKn.values) {
          s.reset();
        }
        _stepRhythmStateByKn.clear();
      });
      _msgHistory.append('加载K0失败：$e');
    } finally {
      if (mounted) setState(() => _loadingChart = false);
    }
  }

  /// 把当前可见窗口的展示轨分型判断并入会话日志（追加去重，不删旧点）。
  void _mergeJudgmentHistory({
    required List<KlineBar> bars,
    required List<LevelBundle> levels,
    required List<BarCrosshairFeature> barFeatures,
    required List<K0Line> k0Lines,
  }) {
    if (bars.isEmpty) return;
    final maxKnProbe = chartMaxKn(levels: levels, k0Lines: k0Lines);
    final knHi = maxKnProbe < 1 ? 1 : maxKnProbe;
    final nextHistory = <int, List<FractalJudgmentEvent>>{
      for (final e in _judgmentHistoryByKn.entries)
        e.key: List<FractalJudgmentEvent>.from(e.value),
    };
    for (var kn = 1; kn <= knHi; kn++) {
      final log = nextHistory.putIfAbsent(kn, () => <FractalJudgmentEvent>[]);
      mergeFractalJudgmentEventLog(
        log,
        collectFractalJudgmentEvents(
          kn: kn,
          bars: bars,
          levels: levels,
          barFeatures: barFeatures,
          truncationCheck: _truncationCheck,
        ),
      );
    }
    _judgmentHistoryByKn = nextHistory;
  }

  /// Kn≥1：本步动态 active 段 idx；K0 无 active（分钟K段不延伸）。
  int? _activeSegIdxForKn(KlineCombineBundle bundle, int kn) {
    if (kn <= 0) return null;
    for (final lv in bundle.levels) {
      if (lv.level == kn) return lv.activeUnit?.idx;
    }
    return null;
  }

  /// 把本步 Rust 一类/二类/三类+BS 并入会话历史。
  /// 对齐分型判断：K0 步进颗粒度；传 activeSegIdx 使动态 Kn 延伸步仍追加本步 x。
  void _mergeBsHistory(KlineCombineBundle bundle) {
    final discoveryX = _stepIdx < 0 ? 0 : _stepIdx;
    final nextBuy = <int, List<Buy1Frame>>{
      for (final e in _buy1HistoryByKn.entries)
        e.key: List<Buy1Frame>.from(e.value),
    };
    final nextSell = <int, List<Sell1Frame>>{
      for (final e in _sell1HistoryByKn.entries)
        e.key: List<Sell1Frame>.from(e.value),
    };
    final nextBuy2 = <int, List<Buy2Frame>>{
      for (final e in _buy2HistoryByKn.entries)
        e.key: List<Buy2Frame>.from(e.value),
    };
    final nextSell2 = <int, List<Sell2Frame>>{
      for (final e in _sell2HistoryByKn.entries)
        e.key: List<Sell2Frame>.from(e.value),
    };
    final nextBuyN = <int, List<BuyNFrame>>{
      for (final e in _buyNHistoryByKn.entries)
        e.key: List<BuyNFrame>.from(e.value),
    };
    final nextSellN = <int, List<SellNFrame>>{
      for (final e in _sellNHistoryByKn.entries)
        e.key: List<SellNFrame>.from(e.value),
    };
    for (final e in collectBuy1EventsByKn(bundle).entries) {
      final log = nextBuy.putIfAbsent(e.key, () => <Buy1Frame>[]);
      mergeBuy1EventLog(
        log,
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: _activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectSell1EventsByKn(bundle).entries) {
      final log = nextSell.putIfAbsent(e.key, () => <Sell1Frame>[]);
      mergeSell1EventLog(
        log,
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: _activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectBuy2EventsByKn(bundle).entries) {
      final log = nextBuy2.putIfAbsent(e.key, () => <Buy2Frame>[]);
      mergeBuy2EventLog(
        log,
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: _activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectSell2EventsByKn(bundle).entries) {
      final log = nextSell2.putIfAbsent(e.key, () => <Sell2Frame>[]);
      mergeSell2EventLog(
        log,
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: _activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectBuyNEventsByKn(bundle).entries) {
      final log = nextBuyN.putIfAbsent(e.key, () => <BuyNFrame>[]);
      mergeBuyNEventLog(
        log,
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: _activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectSellNEventsByKn(bundle).entries) {
      final log = nextSellN.putIfAbsent(e.key, () => <SellNFrame>[]);
      mergeSellNEventLog(
        log,
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: _activeSegIdxForKn(bundle, e.key),
      );
    }
    _buy1HistoryByKn = nextBuy;
    _sell1HistoryByKn = nextSell;
    _buy2HistoryByKn = nextBuy2;
    _sell2HistoryByKn = nextSell2;
    _buyNHistoryByKn = nextBuyN;
    _sellNHistoryByKn = nextSellN;
  }

  /// 本步相邻比例 + 步进节奏并入会话（全层；禁止整表覆盖消点）。
  /// 指标遵循动态计算：传入 bars/barFeatures，子线含展示轨虚线。
  void _mergeRatioAndRhythm(KlineCombineBundle bundle) {
    final displayX = _stepIdx < 0 ? 0 : _stepIdx;
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    // 连线显示层 0..maxKn-1
    final maxDisplayKn = maxKn <= 0 ? -1 : maxKn - 1;
    if (maxDisplayKn < 0) return;
    mergeAdjacentRatioForStep(
      historyByKn: _adjacentRatioHistoryByKn,
      levels: bundle.levels,
      displayX: displayX,
      maxDisplayKn: maxDisplayKn,
      bars: _visibleBars,
      barFeatures: bundle.barFeatures,
      truncationCheck: _truncationCheck,
    );
    mergeStepRhythmForStep(
      historyByKn: _stepRhythmHistoryByKn,
      stateByKn: _stepRhythmStateByKn,
      levels: bundle.levels,
      displayX: displayX,
      maxDisplayKn: maxDisplayKn,
      bars: _visibleBars,
      barFeatures: bundle.barFeatures,
      truncationCheck: _truncationCheck,
    );
    // 新 Map 引用，便于 painter shouldRepaint 感知
    _adjacentRatioHistoryByKn = {
      for (final e in _adjacentRatioHistoryByKn.entries)
        e.key: List<AdjacentRatioPoint>.from(e.value),
    };
    _stepRhythmHistoryByKn = {
      for (final e in _stepRhythmHistoryByKn.entries)
        e.key: List<StepRhythmLinePoint>.from(e.value),
    };
  }

  List<LevelBundle> _levelsWithFrozenBs(List<LevelBundle> levels) {
    final with1 = levelsWithFrozenClass1Bs(
      levels,
      buy1HistoryByKn: _buy1HistoryByKn,
      sell1HistoryByKn: _sell1HistoryByKn,
    );
    final with2 = levelsWithFrozenClass2Bs(
      with1,
      buy2HistoryByKn: _buy2HistoryByKn,
      sell2HistoryByKn: _sell2HistoryByKn,
    );
    return levelsWithFrozenClassNBs(
      with2,
      buyNHistoryByKn: _buyNHistoryByKn,
      sellNHistoryByKn: _sellNHistoryByKn,
    );
  }

  void _rebuildCombine() {
    if (_chipOnlyMode) return;
    if (_visibleBars.isEmpty) {
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
        _judgmentHistoryByKn.clear();
        _buy1HistoryByKn.clear();
        _sell1HistoryByKn.clear();
        _buy2HistoryByKn.clear();
        _sell2HistoryByKn.clear();
        _buyNHistoryByKn.clear();
        _sellNHistoryByKn.clear();
        _adjacentRatioHistoryByKn.clear();
        _stepRhythmHistoryByKn.clear();
        for (final s in _stepRhythmStateByKn.values) {
          s.reset();
        }
        _stepRhythmStateByKn.clear();
      });
      return;
    }
    try {
      final bundle = _bridge.buildKlineCombineBundle(
        _visibleBars,
        truncationCheck: _truncationCheck,
      );
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
      // 本步展示轨判断事件 → 追加进会话日志
      _mergeJudgmentHistory(
        bars: _visibleBars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
        k0Lines: bundle.k0Lines,
      );
      // 会话冻结：并入本步一类BS，禁止下一步整表覆盖消掉上步显示
      _mergeBsHistory(bundle);
      _mergeRatioAndRhythm(bundle);
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
        _buy1K0Frames = _buy1HistoryByKn[0] ?? const [];
        _sell1K0Frames = _sell1HistoryByKn[0] ?? const [];
        _buy2K0Frames = _buy2HistoryByKn[0] ?? const [];
        _sell2K0Frames = _sell2HistoryByKn[0] ?? const [];
        _buyNK0Frames = _buyNHistoryByKn[0] ?? const [];
        _sellNK0Frames = _sellNHistoryByKn[0] ?? const [];
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

  Future<void> _copyHistoryRecords() async {
    final ok = await _msgHistory.copyToClipboard(
      context: mounted ? context : null,
      okMsg: '历史记录已复制',
    );
    if (ok) {
      _msgHistory.append('已一键复制历史记录（共${_msgHistory.rows.length}条）');
    }
  }

  Future<void> _copyDebugSnapshot() async {
    final text = _buildDebugSnapshotText();
    if (text.trim().isEmpty) {
      _showSnack('没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _msgHistory.append(
      '已复制页面快照（step=$_stepIdx 可见K0=$_visibleCount Kn层=${_levels.length}）',
    );
    _showSnack('页面快照已复制，可粘贴排查');
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
  }

  void _togglePlay() {
    if (!_hasSession || _stepIdx >= _allBars.length - 1) return;
    if (_playing) {
      _stopPlay();
      setState(() {});
      return;
    }
    setState(() => _playing = true);
    // 异步步进：先让出事件循环，优先消化左/中/右点击（尤其暂停），再做重算
    _playTimer = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (!mounted || !_playing) return;
      if (_stepIdx >= _allBars.length - 1) {
        _stopPlay();
        setState(() {});
        return;
      }
      setState(() => _stepIdx += 1);
      await Future<void>.delayed(Duration.zero);
      if (!mounted || !_playing) return;
      _rebuildCombine();
    });
  }

  void _stepForward() {
    if (!_hasSession || _stepIdx >= _allBars.length - 1) return;
    _stopPlay();
    setState(() => _stepIdx += 1);
    _rebuildCombine();
  }

  void _stepBack() {
    if (!_hasSession || _stepIdx <= 0) return;
    _stopPlay();
    setState(() => _stepIdx -= 1);
    _rebuildCombine();
  }

  void _resetStep() {
    if (!_hasSession) return;
    _stopPlay();
    setState(() => _stepIdx = 0);
    _rebuildCombine();
  }

  void _runToEnd() {
    if (!_hasSession) return;
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
    for (var i = start; i <= end; i++) {
      _stepIdx = i;
      final visible = _allBars.sublist(0, i + 1);
      try {
        final bundle = _bridge.buildKlineCombineBundle(
          visible,
          truncationCheck: _truncationCheck,
        );
        if (bundle.defaultK0Policy == 'purged') {
          _defaultK0Purged = true;
        }
        _mergeJudgmentHistory(
          bars: visible,
          levels: bundle.levels,
          barFeatures: bundle.barFeatures,
          k0Lines: bundle.k0Lines,
        );
        // 一类/二类BS 也逐K并入会话冻结，避免一次性走完只剩末态
        _mergeBsHistory(bundle);
        _mergeRatioAndRhythm(bundle);
      } catch (e) {
        _msgHistory.append('一次性走完@step=$i 失败：$e');
        break;
      }
    }
    // 末态刷新图面（merge 幂等，不会删旧点）
    _rebuildCombine();
    _logCombineSummary(prefix: '一次性走完');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      // 图表铺满；标题按钮叠在右上角之上，可点且不挡视觉延伸
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF121212),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0x33FFFFFF)),
                ),
                child: KlineChart(
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
                  truncationCheck: _truncationCheck,
                  showBuildingDash: _showBuildingDash,
                  chipOnlyMode: _chipOnlyMode,
                  chipConfig: _chipConfig,
                  tickDistConfig: _tickDistConfig,
                  judgmentHistoryByKn: _judgmentHistoryByKn,
                  buy1HistoryByKn: _buy1HistoryByKn,
                  sell1HistoryByKn: _sell1HistoryByKn,
                  buy2HistoryByKn: _buy2HistoryByKn,
                  sell2HistoryByKn: _sell2HistoryByKn,
                  buyNHistoryByKn: _buyNHistoryByKn,
                  sellNHistoryByKn: _sellNHistoryByKn,
                  adjacentRatioHistoryByKn: _adjacentRatioHistoryByKn,
                  stepRhythmHistoryByKn: _stepRhythmHistoryByKn,
                  mainIndicators: _mainIndicators,
                  onMainIndicatorsChanged: (v) =>
                      setState(() => _mainIndicators = v),
                  subIndicators: _subIndicators,
                  onSubIndicatorsChanged: (v) =>
                      setState(() => _subIndicators = v),
                  indicatorsEnabled: _hasSession,
                  autoFollowLatest: true,
                  isPlaying: _playing,
                  // 左中右热区：会话内始终可点（尤其播放中暂停优先）；加载中才屏蔽
                  onTapStepBack: _hasSession && !_busy ? _stepBack : null,
                  onTapPlay: _hasSession
                      ? (_busy && !_playing ? null : _togglePlay)
                      : null,
                  onTapStepForward:
                      _hasSession && !_busy ? _stepForward : null,
                  onLongPressReset:
                      _hasSession && !_busy ? _resetStep : null,
                  onLongPressReload: _busy ? null : _loadKlines,
                  onLongPressRunToEnd:
                      _hasSession && !_busy ? _runToEnd : null,
                ),
              ),
            ),
          ),
          if (_error != null)
            Positioned(
              left: 12,
              right: 120,
              top: 40,
              child: Text(_error!, style: const TextStyle(color: Colors.orange)),
            ),
          // 设置打开时：点非面板区域关闭，不穿透到 K 线播放手势
          if (_panelExpanded)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _panelExpanded = false),
                child: const ColoredBox(color: Color(0x33000000)),
              ),
            ),
          if (_panelExpanded)
            EdgeControlPanel(
              edge: _panelEdge,
              onClose: () => setState(() => _panelExpanded = false),
              onCycleEdge: () => setState(() => _panelEdge = 1 - _panelEdge),
              child: _buildPanelBody(),
            ),
          // 最上层：拖动区 + 设置 + 最小/最大/关闭
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 36,
            child: _buildCaptionBar(),
          ),
          if (_loadingChart)
            const Positioned(
              top: 44,
              right: 16,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }

  /// 透明标题条：左侧穿透点击主图指标；窗控前窄条拖窗；右侧设置/最小化/最大化/关闭。
  /// 踩坑：勿用「屏宽-140 固定开孔 + Expanded」——窗控实际约 174px，会 RIGHT OVERFLOW。
  Widget _buildCaptionBar() {
    const dragGripW = 28.0;
    return Row(
      children: [
        const Expanded(
          child: IgnorePointer(
            child: SizedBox(height: 36),
          ),
        ),
        DragToMoveArea(
          child: SizedBox(
            width: dragGripW,
            height: 36,
            child: Container(color: Colors.transparent),
          ),
        ),
        Tooltip(
          message: '设置',
          child: IconButton(
            onPressed: () => setState(() => _panelExpanded = !_panelExpanded),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: Icon(
              _panelExpanded ? Icons.close : Icons.settings,
              size: 18,
              color: const Color(0xFFE2E8F0),
            ),
          ),
        ),
        WindowCaptionButton.minimize(
          brightness: Brightness.dark,
          onPressed: () => windowManager.minimize(),
        ),
        WindowCaptionButton.maximize(
          brightness: Brightness.dark,
          onPressed: () async {
            // 铺满工作区 ↔ 还原；不走原生 maximize（会盖任务栏）
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
          },
        ),
        WindowCaptionButton.close(
          brightness: Brightness.dark,
          onPressed: () => windowManager.close(),
        ),
      ],
    );
  }

  Widget _buildPanelBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
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
                  setState(() {
                    _selectedCode = v;
                    _syncDateRangeForCode(v);
                  });
                  _loadKlines();
                },
        ),
        if (_selectedCode == 'test') ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _openTestOhlcEditor,
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('编辑/加载自定义 OHLC'),
                ),
              ),
              IconButton(
                tooltip: '自定义 OHLC 说明',
                icon: const Icon(Icons.help_outline, size: 18),
                onPressed: _showTestOhlcHelp,
              ),
            ],
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
                        setState(() => _period = next);
                        // 切周期立即按新周期重载：否则图表用「新周期蜡烛画法」重绘
                        // 仍停留在内存的 tick 数据（每根 O=H=L=C），会全部显示成一字线
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
              : (v) {
                  setState(() {
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
                  });
                  _msgHistory.append('截断机制=${v ? "开" : "关"}，重算当前步进');
                  _rebuildCombine();
                  _logCombineSummary(prefix: '截断开关后汇总');
                },
          secondary: IconButton(
            tooltip: '截断机制说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showTruncationHelp,
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
                  setState(() {
                    _showBuildingDash = v;
                  });
                  _msgHistory.append('构建中虚线=${v ? "开" : "关"}');
                },
          secondary: IconButton(
            tooltip: '构建中/未确认虚线说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showBuildingDashHelp,
          ),
        ),
        const SizedBox(height: 8),
        // 筹码分布：总开关 + 峰线；桶宽/拉伸见说明弹窗（已迁设置·仅K0，不参与主图指标勾选）
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('筹码分布', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _chipConfig.enabled
                ? '已开启（主图右侧绘制 K0筹码）'
                : '已关闭（主图右侧不绘制）',
            style: const TextStyle(fontSize: 11),
          ),
          value: _chipConfig.enabled,
          onChanged: _busy
              ? null
              : (v) {
                  _updateChipConfig(_chipConfig.copyWith(enabled: v));
                  _msgHistory.append('筹码分布总开关=${v ? "开" : "关"}');
                },
          secondary: IconButton(
            tooltip: '筹码分布说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showChipHelp,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('筹码峰延长线', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _chipConfig.peakLineEnabled ? '已开启' : '已关闭',
            style: const TextStyle(fontSize: 11),
          ),
          value: _chipConfig.peakLineEnabled,
          onChanged: !_chipConfig.enabled || _busy
              ? null
              : (v) {
                  _updateChipConfig(_chipConfig.copyWith(peakLineEnabled: v));
                  _msgHistory.append('筹码峰延长线=${v ? "开" : "关"}');
                },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('筹码桶宽（元）', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            '${_chipConfig.bucketStep.toStringAsFixed(2)}（笔数分布共用）',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: SizedBox(
            width: 120,
            child: Slider(
              min: 0.01,
              max: 1.0,
              divisions: 99,
              value: _chipConfig.bucketStep.clamp(0.01, 1.0),
              onChanged: (!_chipConfig.enabled && !_tickDistConfig.enabled) ||
                      _busy
                  ? null
                  : (v) {
                      final step = (v * 100).round() / 100.0;
                      _updateChipConfig(_chipConfig.copyWith(bucketStep: step));
                      _updateTickDistConfig(
                          _tickDistConfig.copyWith(bucketStep: step));
                    },
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('笔数分布', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _tickDistConfig.enabled
                ? '已开启（主图左侧绘制 K0笔数分布）'
                : '已关闭（主图左侧不绘制）',
            style: const TextStyle(fontSize: 11),
          ),
          value: _tickDistConfig.enabled,
          onChanged: _busy
              ? null
              : (v) {
                  _updateTickDistConfig(_tickDistConfig.copyWith(enabled: v));
                  _msgHistory.append('笔数分布总开关=${v ? "开" : "关"}');
                },
          secondary: IconButton(
            tooltip: '笔数分布说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: _showTickDistHelp,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('笔数峰延长线', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            _tickDistConfig.peakLineEnabled ? '已开启' : '已关闭',
            style: const TextStyle(fontSize: 11),
          ),
          value: _tickDistConfig.peakLineEnabled,
          onChanged: !_tickDistConfig.enabled || _busy
              ? null
              : (v) {
                  _updateTickDistConfig(
                      _tickDistConfig.copyWith(peakLineEnabled: v));
                  _msgHistory.append('笔数峰延长线=${v ? "开" : "关"}');
                },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _bootstrap,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新股票列表'),
        ),
        const SizedBox(height: 10),
        // 常驻：一键复制历史记录（合并到 main / 清理 UI 时不得删除）
        OutlinedButton.icon(
          onPressed: _copyHistoryRecords,
          icon: const Icon(Icons.copy_all, size: 18),
          label: const Text('一键复制历史记录'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _msgHistory.showDialog(context),
          icon: const Icon(Icons.history, size: 18),
          label: const Text('查看历史记录'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _copyDebugSnapshot,
          icon: const Icon(Icons.content_copy, size: 18),
          label: const Text('复制页面快照'),
        ),
      ],
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
      builder: (ctx) => AlertDialog(
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
    );
  }

  void _showPeriodHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
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
            '3. test+custom.ohlc.csv 仍直读行即 K，忽略周期。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showTestOhlcHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义 OHLC 说明'),
        content: const SingleChildScrollView(
          child: Text(
            '操作步骤：\n'
            '1. 股票选择 test；\n'
            '2. 点「编辑/加载自定义 OHLC」填写时间与开高低收；\n'
            '3. 「仅保存」或「保存并加载」写入 a_Data/test/custom.ohlc.csv。\n\n'
            '口径：行即最终 K 线（忽略周期聚合）；有 CSV 优先直读，无则回退分笔。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _openTestOhlcEditor() async {
    // 预填：优先 CSV 全量；否则当前图上 bars；再否则空表模板
    List<KlineBar> seed = _allBars;
    if (_hasTestOhlcCsv()) {
      try {
        seed = _bridge.loadKlines(
          dataRoot: _dataRoot,
          code: 'test',
          beginDate: '1990/01/01 00:00:00',
          endDate: '2100/12/31 23:59:59',
          period: _period,
        );
      } catch (_) {
        // 保持 seed=_allBars
      }
    }
    final result = await showTestOhlcEditorDialog(
      context: context,
      initialBars: seed,
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
      builder: (ctx) => AlertDialog(
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
    );
  }

  /// 筹码分布说明弹窗。
  void _showChipHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('筹码分布说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：展示历史成交量在价格维度上的累积分布'
            '（上市/区间首根 → 当前步进/十字 as-of）。\n\n'
            '怎么看\n'
            '· 主图右侧水平柱：左绿=S（卖），右红=B（买）；\n'
            '· 筹码峰：局部量峰打点，虚线延长到主图左侧；\n'
            '· 由设置面板总开关控制，不参与主图指标勾选；仅 K0 分支。\n\n'
            '数据与当下性\n'
            '· 离线分笔写入 chip_tick_bins（价量直加）；tick 禁止三角；'
            '非一字且无 bins 时才 OHLC 三角估算；\n'
            '· 逐K只累加已喂入 K 线；十字悬停回滚到该日累积，不回写历史；\n'
            '· 仅 K0：cutoff=当前步进末根 / 十字 as-of 所在 K0。\n\n'
            '操作步骤\n'
            '1. 设置里打开「筹码分布」总开关；\n'
            '2. 主图右侧立即绘制 K0 筹码；\n'
            '3. 可调「筹码桶宽」「筹码峰延长线」；\n'
            '4. 配置写入 .chan_chip_config.json，下次启动恢复。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showTickDistHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('笔数分布说明'),
        content: const SingleChildScrollView(
          child: Text(
            '作用：与筹码分布同构，按价格累计分笔笔数（第4列），'
            '画在主图左侧；价签画在笔数分布右侧。\n\n'
            '怎么看\n'
            '· 水平柱 B/S/G 着色同筹码；\n'
            '· 笔数峰：局部笔数峰打点，虚线延长进主图；\n'
            '· 十字 tooltip：K0笔数峰-/+n（编号规则同筹码峰）。\n\n'
            '数据\n'
            '· Rust 写入 chip_tick_count_bins（按价累加 ticks）；'
            '桶宽与筹码共用。\n\n'
            '操作步骤\n'
            '1. 设置打开「笔数分布」；\n'
            '2. 主图左侧绘制；可开「笔数峰延长线」；\n'
            '3. 重编 DLL 后冷启以载入笔数桶（旧数据无 bins 时回退收盘价落笔数）。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
