import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/chan_bridge.dart';
import 'compute/bi_virtual_bar_view_compute.dart';
import 'history/app_debug_snapshot.dart';
import 'history/msg_history.dart';
import 'models/kline_bar.dart';
import 'models/bi_confirm_signal.dart';
import 'models/bar_crosshair_feature.dart';
import 'models/bi_segment.dart';
import 'models/bi_virtual_bar_view.dart';
import 'models/kline_combine_frame.dart';
import 'models/level_models.dart';
import 'models/seg_analysis.dart';
import 'widgets/datetime_picker_dialog.dart';
import 'widgets/edge_control_panel.dart';
import 'widgets/kline_chart.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      // 隐藏系统标题文字与白底标题栏，自绘右上角三键
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFF121212),
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setTitle('');
      // 先显示再最大化，避免 show 把最大化冲掉
      await windowManager.show();
      await windowManager.maximize();
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
  DateTime _beginDate = _standardBeginDate;
  DateTime _endDate = _standardEndDate;

  List<String> _codes = [];
  String? _selectedCode;
  String _period = '1m';
  String _dataRoot = '';
  List<KlineBar> _allBars = [];
  List<KlineCombineFrame> _combineFrames = [];
  List<BiConfirmSignal> _biConfirmSignals = [];
  List<BarCrosshairFeature> _barFeatures = [];
  List<BiSegment> _biSegments = [];
  List<BiVirtualBarView> _biVirtualBarViews = [];
  List<KlineCombineFrame> _biCombineFrames = [];
  SegAnalysisBundle _segAnalysis = SegAnalysisBundle.empty();
  List<LevelBundle> _levels = [];
  Set<MainChartIndicator> _mainIndicators = {
    MainChartIndicator.klineCombine,
    MainChartIndicator.biLine,
    MainChartIndicator.segLine,
    MainChartIndicator.biKlineCombine,
  };
  Set<SubChartIndicator> _subIndicators = {SubChartIndicator.biConfirm};
  int _stepIdx = -1; // -1 表示尚未步进
  bool _playing = false;
  Timer? _playTimer;
  String? _error;
  bool _defaultBiPurged = false;
  String _defaultBiPolicy = 'pending';
  bool _bootstrapping = false;
  bool _loadingChart = false;
  bool _panelExpanded = false;
  int _panelEdge = 1; // 默认右贴边（设置按钮在右上）
  /// 截断监察：开=当前口径；关=添加截断前旧行为（暴力反转被吸收）
  bool _truncationCheck = true;

  bool get _busy => _bootstrapping || _loadingChart;
  bool get _hasSession => _allBars.isNotEmpty;
  int get _visibleCount => _stepIdx < 0 ? 0 : math.min(_stepIdx + 1, _allBars.length);
  List<KlineBar> get _visibleBars =>
      _visibleCount <= 0 ? const [] : _allBars.sublist(0, _visibleCount);

  static const _periods = <String, String>{
    '1m': 'TICK-1MIN',
    '5m': '5分钟',
    '15m': '15分钟',
    '60m': '60分钟',
    'day': '日线',
    'week': '周线',
    'month': '月线',
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
    _bootstrap();
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  /// 切换股票时对齐各自默认加载区间。
  void _syncDateRangeForCode(String code) {
    final range = _codeDefaultRanges[code];
    if (range != null) {
      _beginDate = range.$1;
      _endDate = range.$2;
    } else {
      _beginDate = _standardBeginDate;
      _endDate = _standardEndDate;
    }
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
        '根目录=$_dataRoot；口径=K0原始K/K1笔/K2线段/Kn第n层；'
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
        _defaultBiPurged = false;
      });
      _msgHistory.append(
        '加载K0：$code ${_fmtDateTime(_beginDate)}~${_fmtDateTime(_endDate)} '
        '${_periods[_period] ?? _period} 共${bars.length}根',
      );
      _rebuildCombine();
      _logCombineSummary(prefix: '加载后汇总');
    } catch (e) {
      setState(() {
        _error = e.toString();
        _allBars = [];
        _combineFrames = [];
        _biConfirmSignals = [];
        _barFeatures = [];
        _biSegments = [];
        _biVirtualBarViews = [];
        _biCombineFrames = [];
        _segAnalysis = SegAnalysisBundle.empty();
        _levels = [];
        _stepIdx = -1;
      });
      _msgHistory.append('加载K0失败：$e');
    } finally {
      if (mounted) setState(() => _loadingChart = false);
    }
  }

  void _rebuildCombine() {
    if (_visibleBars.isEmpty) {
      setState(() {
        _combineFrames = [];
        _biConfirmSignals = [];
        _barFeatures = [];
        _biSegments = [];
        _biVirtualBarViews = [];
        _biCombineFrames = [];
        _segAnalysis = SegAnalysisBundle.empty();
        _levels = [];
      });
      return;
    }
    try {
      final bundle = _bridge.buildKlineCombineBundle(
        _visibleBars,
        truncationCheck: _truncationCheck,
      );
      if (bundle.defaultBiPolicy == 'purged') {
        _defaultBiPurged = true;
      }
      var virtualBars = bundle.biVirtualBars;
      // 会话级 purge：审判 FAIL 出现过后，步退回首笔确认前也不再展示默认笔
      if (_defaultBiPurged &&
          bundle.defaultBiPolicy == 'pending' &&
          bundle.biSegments.isEmpty) {
        virtualBars = const [];
      }
      final biViews = buildBiVirtualBarViews(virtualBars);
      setState(() {
        _combineFrames = bundle.frames;
        _biConfirmSignals = bundle.biConfirms;
        _barFeatures = bundle.barFeatures;
        _biSegments = bundle.biSegments;
        _biVirtualBarViews = biViews;
        _biCombineFrames = bundle.biCombineFrames;
        _segAnalysis = bundle.segAnalysis;
        _defaultBiPolicy = bundle.defaultBiPolicy;
        _levels = bundle.levels;
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
        _levels.isNotEmpty ? _levels.last.segments.length : _biSegments.length;
    _msgHistory.append(
      '$prefix @$_visibleCount/${_allBars.length} idx=${tail.idx} '
      '层数=$levelCount 末层Kn段=$lastLevelSegs K1段=${_biSegments.length} '
      'policy=$_defaultBiPolicy 截断=${_truncationCheck ? "开" : "关"}',
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
      defaultBiPolicy: _defaultBiPolicy,
      truncationCheck: _truncationCheck,
      subIndicatorLabels: _subIndicators.map((e) => e.label).toSet(),
      mainIndicatorLabels: _mainIndicators.map((e) => e.label).toSet(),
      visibleBars: _visibleBars,
      combineFrames: _combineFrames,
      biConfirms: _biConfirmSignals,
      barFeatures: _barFeatures,
      biSegments: _biSegments,
      biCombineFrames: _biCombineFrames,
      segAnalysis: _segAnalysis,
      levels: _levels,
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
    _playTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      if (_stepIdx >= _allBars.length - 1) {
        _stopPlay();
        setState(() {});
        return;
      }
      setState(() => _stepIdx += 1);
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
    setState(() => _stepIdx = _allBars.length - 1);
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
                  combineFrames: _combineFrames,
                  biConfirmSignals: _biConfirmSignals,
                  barFeatures: _barFeatures,
                  biSegments: _biSegments,
                  biVirtualBarViews: _biVirtualBarViews,
                  biCombineFrames: _biCombineFrames,
                  segAnalysis: _segAnalysis,
                  levels: _levels,
                  defaultBiPolicy: _defaultBiPolicy,
                  truncationCheck: _truncationCheck,
                  mainIndicators: _mainIndicators,
                  onMainIndicatorsChanged: (v) =>
                      setState(() => _mainIndicators = v),
                  subIndicators: _subIndicators,
                  onSubIndicatorsChanged: (v) =>
                      setState(() => _subIndicators = v),
                  autoFollowLatest: true,
                  onTapStepBack: _hasSession && !_busy ? _stepBack : null,
                  onTapPlay: _hasSession && !_busy ? _togglePlay : null,
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

  /// 透明标题条：中部拖动；右侧设置紧贴最小化。
  /// 左侧开孔穿透，避免挡住 K 线区主图指标入口（↓+已选名）。
  Widget _buildCaptionBar() {
    return Row(
      children: [
        // 与主图指标 chip 最大宽度对齐，点击穿透到下层
        const IgnorePointer(
          child: SizedBox(width: 280, height: 36),
        ),
        Expanded(
          child: DragToMoveArea(
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
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
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
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          isExpanded: true,
          value: _period,
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
          onChanged: _bootstrapping ? null : (v) => setState(() => _period = v ?? '1m'),
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
                    _defaultBiPurged = false;
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
            '· 与「下层确认后才能参与上层」同构：截断只对已冻结下层单元生效，'
            '进行中笔不参与 K1合并/截断判定。\n'
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
}
