import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge/chan_bridge.dart';
import 'compute/bi_virtual_bar_view_compute.dart';
import 'debug/app_debug_snapshot.dart';
import 'debug/msg_history.dart';
import 'models/kline_bar.dart';
import 'models/bi_confirm_signal.dart';
import 'models/bar_crosshair_feature.dart';
import 'models/bi_segment.dart';
import 'models/bi_virtual_bar_view.dart';
import 'models/kline_combine_frame.dart';
import 'models/level_models.dart';
import 'models/seg_analysis.dart';
import 'widgets/datetime_picker_dialog.dart';
import 'widgets/kline_chart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChanKlineApp());
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
    MainChartIndicator.kline,
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

  static const _defaultCode = '002003';
  static const _testCode = 'test';
  static final _standardBeginDate = DateTime(2004, 7, 19, 10, 47, 0);
  static final _standardEndDate = DateTime(2004, 7, 20, 13, 9, 0);
  static final _testBeginDate = DateTime(2026, 7, 10, 9, 30, 0);
  static final _testEndDate = DateTime(2026, 7, 10, 9, 33, 59);

  /// 切换股票时对齐各自默认加载区间。
  void _syncDateRangeForCode(String code) {
    if (code == _testCode) {
      _beginDate = _testBeginDate;
      _endDate = _testEndDate;
      _period = '1m';
    } else if (code == _defaultCode) {
      _beginDate = _standardBeginDate;
      _endDate = _standardEndDate;
      _period = '1m';
    }
  }

  String _preferredCode(List<String> codes) {
    if (codes.contains(_testCode)) return _testCode;
    if (codes.contains(_defaultCode)) return _defaultCode;
    return codes.first;
  }

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

  String _fmtDateTime(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

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
    // 选定加载区间后立即按时间从 a_Data 重载，而非仅改参数等手动点「加载」
    await _loadKlines();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _error = null;
    });
    try {
      _bridge.ensureInitialized();
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
      _msgHistory.append('初始化完成：代码=$_selectedCode 周期=$_period 根目录=$_dataRoot');
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
        '加载K线：$code ${_fmtDateTime(_beginDate)}~${_fmtDateTime(_endDate)} '
        '${_periods[_period] ?? _period} 共${bars.length}根',
      );
      _rebuildCombine();
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
      _msgHistory.append('加载K线失败：$e');
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
      final bundle = _bridge.buildKlineCombineBundle(_visibleBars);
      if (bundle.defaultBiPolicy == 'purged') {
        _defaultBiPurged = true;
      }
      var virtualBars = bundle.biVirtualBars;
      // 会话级 purge：审判 FAIL 出现过后，步退回首笔确认前也不再展示默认笔
      // （bar_features 的 bi_* 由 Rust 固定 purged 口径，首笔确认前本就为空）
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
      _msgHistory.append('合并计算失败：$e');
    }
  }

  void _logCombineSummary({String prefix = '逐K汇总'}) {
    if (_visibleBars.isEmpty) return;
    final tail = _visibleBars.last;
    final levelCount = _levels.length;
    final segCount = _levels.isNotEmpty ? _levels.last.segments.length : _biSegments.length;
    _msgHistory.append(
      '$prefix @${_visibleCount}/${_allBars.length} idx=${tail.idx} '
      '层数=$levelCount 末层段=$segCount 1段=${_biSegments.length} '
      'policy=$_defaultBiPolicy',
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

  Future<void> _copyDebugSnapshot() async {
    final text = _buildDebugSnapshotText();
    if (text.trim().isEmpty) {
      _showSnack('没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _msgHistory.append(
      '已复制页面调试快照（step=$_stepIdx 可见=$_visibleCount 层=${_levels.length}）',
    );
    _showSnack('页面调试信息已复制，可粘贴给调试方');
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
      appBar: AppBar(
        title: const Text('CHAN_RUST · K线图（Rust 计算）'),
        actions: [
          IconButton(
            tooltip: '复制页面调试信息',
            onPressed: _copyDebugSnapshot,
            icon: const Icon(Icons.content_copy),
          ),
          IconButton(
            tooltip: '历史记录',
            onPressed: () => _msgHistory.showDialog(context),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: '刷新股票列表',
            onPressed: _busy ? null : _bootstrap,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(_error!, style: const TextStyle(color: Colors.orange)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              '数据目录: $_dataRoot\n'
              '加载区间: ${_fmtDateTime(_beginDate)} ~ ${_fmtDateTime(_endDate)}  |  逐K: ${_visibleCount}/${_allBars.length}',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
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
                      mainIndicators: _mainIndicators,
                      onMainIndicatorsChanged: (v) =>
                          setState(() => _mainIndicators = v),
                      subIndicators: _subIndicators,
                      onSubIndicatorsChanged: (v) =>
                          setState(() => _subIndicators = v),
                      autoFollowLatest: true,
                    ),
                  ),
                ),
                if (_loadingChart)
                  const Positioned(
                    top: 16,
                    right: 16,
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
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
            ),
            SizedBox(
              width: 152,
              child: DropdownButtonFormField<String>(
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
            ),
            _datePickerField(
              label: '加载起始时间',
              value: _fmtDateTime(_beginDate),
              onTap: _busy ? null : () => _pickDateTime(isBegin: true),
            ),
            _datePickerField(
              label: '加载截止时间',
              value: _fmtDateTime(_endDate),
              onTap: _busy ? null : () => _pickDateTime(isBegin: false),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _loadKlines,
              icon: const Icon(Icons.candlestick_chart),
              label: const Text('重新加载'),
            ),
            const SizedBox(width: 8, height: 1),
            IconButton.filledTonal(
              tooltip: '逐K后退',
              onPressed: _hasSession && !_busy ? _stepBack : null,
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton.filledTonal(
              tooltip: _playing ? '暂停逐K' : '逐K播放',
              onPressed: _hasSession && !_busy ? _togglePlay : null,
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton.filledTonal(
              tooltip: '逐K前进',
              onPressed: _hasSession && !_busy ? _stepForward : null,
              icon: const Icon(Icons.skip_next),
            ),
            OutlinedButton.icon(
              onPressed: _hasSession && !_busy ? _resetStep : null,
              icon: const Icon(Icons.first_page, size: 18),
              label: const Text('首K'),
            ),
            OutlinedButton.icon(
              onPressed: _hasSession && !_busy ? _runToEnd : null,
              icon: const Icon(Icons.last_page, size: 18),
              label: const Text('一次性走完'),
            ),
            OutlinedButton.icon(
              onPressed: _copyDebugSnapshot,
              icon: const Icon(Icons.copy_all, size: 18),
              label: const Text('复制页面信息'),
            ),
            OutlinedButton.icon(
              onPressed: () => _msgHistory.showDialog(context),
              icon: const Icon(Icons.history, size: 18),
              label: const Text('历史记录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _datePickerField({
    required String label,
    required String value,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      width: 220,
      child: InkWell(
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
      ),
    );
  }
}
