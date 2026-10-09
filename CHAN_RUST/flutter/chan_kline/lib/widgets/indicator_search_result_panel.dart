import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../backtest/condition_ast.dart';
import '../backtest/backtest_metrics.dart';
import '../backtest/equity_curve.dart';
import '../indicator_search/candidate_builder.dart';
import '../indicator_search/search_core.dart';
import '../indicator_search/search_env.dart';
import '../indicator_search/search_verdict_views.dart';

/// 把两个 ScrollController 的偏移互相同步（冻结列 / 主体共用一份纵向滚动）。
class _SyncedScroll {
  final List<ScrollController> _controllers = [];
  bool _syncing = false;

  ScrollController create() {
    final c = ScrollController();
    _controllers.add(c);
    c.addListener(() => _onScroll(c));
    return c;
  }

  void _onScroll(ScrollController src) {
    if (_syncing) return;
    _syncing = true;
    for (final c in _controllers) {
      if (c == src || !c.hasClients) continue;
      if ((c.offset - src.offset).abs() > 0.5) {
        c.jumpTo(src.offset);
      }
    }
    _syncing = false;
  }

  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _controllers.clear();
  }
}

/// 三态指标格式化：不可用→「—」，∞→「∞」，否则定点小数 / 百分比。
String _mn(MetricNum m, {bool pct = false, int digits = 2}) {
  if (m.isUnavailable) return '—';
  if (m.isInfinity) return '∞';
  final v = m.value!;
  return pct ? '${(v * 100).toStringAsFixed(1)}%' : v.toStringAsFixed(digits);
}

const List<String> _circled = [
  '①',
  '②',
  '③',
  '④',
  '⑤',
  '⑥',
  '⑦',
  '⑧',
  '⑨',
];

String _badge(int priority) =>
    priority < _circled.length ? _circled[priority] : '${priority + 1}';

/// 寻优结果：单张宽表 + 眼睛 sticky 列 + 点击行展开详细指标 + 横向滚动。
///
/// 排序状态（sort / expanded）由上层（对话框）持有，本面板只负责渲染与交互回调，
/// 便于「返回寻优结果」原样恢复排序与展开。
class IndicatorSearchResultPanel extends StatefulWidget {
  const IndicatorSearchResultPanel({
    super.key,
    required this.verdicts,
    required this.resultsFilePath,
    required this.elapsed,
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.splitX,
    required this.sort,
    required this.onSort,
    required this.onRemoveSort,
    required this.onClearSort,
    required this.expanded,
    required this.onToggleExpand,
    this.align,
    this.maxKn = 16,
    this.buildSummary,
    this.onPreviewBacktest,
    this.previewHint,
  });

  final List<ComboVerdict> verdicts;
  final String resultsFilePath;
  final Duration elapsed;
  final String code;
  final String period;
  final String beginText;
  final String endText;
  final int splitX;

  final VerdictSortState sort;
  final ValueChanged<VerdictSortColumn> onSort;
  final ValueChanged<VerdictSortColumn> onRemoveSort;
  final VoidCallback onClearSort;
  final int? expanded;
  final ValueChanged<int> onToggleExpand;

  final IndicatorSearchAlignSnapshot? align;
  final int maxKn;
  final CandidateBuildSummary? buildSummary;

  /// 眼睛按钮回调：以该行买卖 AST 替换当前策略并打开回测台。
  /// 传 null 表示当前界面无法即时回测（如快照与当前主图区间不一致）。
  final void Function(ComboVerdict)? onPreviewBacktest;

  /// onPreviewBacktest 为 null 时，眼睛置灰并展示的提示文案。
  final String? previewHint;

  @override
  State<IndicatorSearchResultPanel> createState() =>
      _IndicatorSearchResultPanelState();
}

class _IndicatorSearchResultPanelState extends State<IndicatorSearchResultPanel> {
  late final _SyncedScroll _synced;
  late final ScrollController _vFrozen;
  late final ScrollController _vBody;
  late final ScrollController _hBody;

  // 布局常量
  static const double _eyeW = 34;
  static const double _typeW = 72;
  static const double _frozenW = _eyeW + _typeW;
  static const double _buyW = 150;
  static const double _sellW = 150;
  static const double _headerH = 44;
  static const double _mainRowH = 44;
  static const double _detailH = 184;

  // 主体可排序数值列宽（加宽避免「内盈利因子」等中文截断）
  static const double _colTrades = 56;
  static const double _colRate = 64;
  static const double _colRatio = 64;
  static const double _colPf = 62;
  static const double _colNet = 78;
  static const double _colScore = 74;

  @override
  void initState() {
    super.initState();
    _synced = _SyncedScroll();
    _vFrozen = _synced.create();
    _vBody = _synced.create();
    _hBody = ScrollController();
  }

  @override
  void dispose() {
    _synced.dispose();
    _hBody.dispose();
    super.dispose();
  }

  /// 排序/清除/移除时回到首行（纵向），让「排序生效」即时可见。
  void _jumpTop() {
    if (_vFrozen.hasClients) _vFrozen.jumpTo(0);
    if (_vBody.hasClients) _vBody.jumpTo(0);
  }

  void _onSort(VerdictSortColumn col) {
    _jumpTop();
    widget.onSort(col);
  }

  void _onRemove(VerdictSortColumn col) {
    _jumpTop();
    widget.onRemoveSort(col);
  }

  void _onClear() {
    _jumpTop();
    widget.onClearSort();
  }

  /// 鼠标滚轮（无 Shift）在表头区 → 横向滚动；Shift+纵滚任意处 → 横向滚动。
  /// 触控板横向双指由 SingleChildScrollView 原生处理（scrollDelta.dx）。
  void _scrollH(double delta) {
    if (!_hBody.hasClients) return;
    final max = _hBody.position.maxScrollExtent;
    final next = (_hBody.offset + delta).clamp(0.0, max);
    _hBody.jumpTo(next);
  }

  List<ComboVerdict> get _sorted => sortVerdicts(widget.verdicts, widget.sort);

  /// 主体总宽（用于横向滚动容器）。
  double get _bodyW =>
      _buyW +
      _sellW +
      (_colTrades + _colRate + _colRatio + _colPf + _colNet + _colScore + _colScore) *
          2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summaryBg = theme.colorScheme.surfaceContainerHighest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部精简摘要：标的 / 周期 / 区间 / 切点 / 候选数 / 成交费用参数
        Container(
          color: summaryBg,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 2,
                children: [
                  Text(
                    '${widget.code} ${widget.period} · '
                    '${widget.beginText}~${widget.endText} · '
                    '内外切点 K0#${widget.splitX} · 候选${widget.verdicts.length} · '
                    '耗时 ${widget.elapsed.inMinutes}分${widget.elapsed.inSeconds % 60}秒',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.sort.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 24),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _onClear,
                      child: const Text('清除排序', style: TextStyle(fontSize: 11)),
                    ),
                ],
              ),
              if (widget.align != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    widget.align!.replayParamLine,
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '完整 TSV：${widget.resultsFilePath}',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ),
              if (widget.buildSummary != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    widget.buildSummary!.toDisplayLine(),
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '任意文字可拖选复制；点行展开明细；鼠标右键点某一行＝复制该行整行（制表符分列，与 TSV 同列序）',
                  style:
                      TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final availH = constraints.maxHeight;
              return Listener(
                onPointerSignal: (n) {
                  if (n is PointerScrollEvent &&
                      n.kind == PointerDeviceKind.mouse &&
                      HardwareKeyboard.instance.isShiftPressed) {
                    _scrollH(n.scrollDelta.dy + n.scrollDelta.dx);
                  }
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 冻结列：眼睛 + 类型
                    SizedBox(
                      width: _frozenW,
                      height: availH,
                      child: Column(
                        children: [
                          _frozenHeader(),
                          Expanded(
                            child: ListView.builder(
                              controller: _vFrozen,
                              itemCount: _sorted.length,
                              itemBuilder: (_, i) => _frozenCell(_sorted[i], i),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 主体：可横向滚动的指标宽表
                    Expanded(
                      child: Scrollbar(
                        controller: _hBody,
                        thumbVisibility: true,
                        trackVisibility: true,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          controller: _hBody,
                          child: SizedBox(
                            width: _bodyW,
                            height: availH,
                            child: Column(
                              children: [
                                _bodyHeader(),
                                Expanded(
                                  child: ListView.builder(
                                    controller: _vBody,
                                    itemCount: _sorted.length,
                                    itemBuilder: (_, i) =>
                                        _bodyRow(_sorted[i], i),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _frozenHeader() => Container(
        height: _headerH,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: _eyeW,
              child: Center(
                child: Icon(
                  Icons.visibility,
                  size: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
            Expanded(
              child: _sortableHeaderCell(
                '类型',
                VerdictSortColumn.type,
                tooltip: '类型：这行买卖条件取自哪一类信号族\n'
                    '（事件／阈值／数值／结构等）\n(type)',
              ),
            ),
          ],
        ),
      );

  Widget _sortableHeaderCell(
    String label,
    VerdictSortColumn col, {
    String? tooltip,
  }) {
    final key = widget.sort.keyFor(col);
    final priority = widget.sort.priorityOf(col);
    final active = key != null;
    final arrow = key == null ? '' : (key.ascending ? ' ↑' : ' ↓');
    final badge = priority >= 0 ? _badge(priority) : '';
    return Tooltip(
      message: tooltip ?? label,
      waitDuration: const Duration(milliseconds: 300),
      child: InkWell(
        onTap: () => _onSort(col),
        onLongPress: active ? () => _onRemove(col) : null,
        child: Center(
          child: Text(
            '$badge$label$arrow',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? Colors.blue.shade700 : null,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _frozenCell(ComboVerdict v, int index) {
    final expanded = index == widget.expanded;
    return Column(
      children: [
        SizedBox(
          height: _mainRowH,
          child: GestureDetector(
            onSecondaryTapUp: (_) => _copyRow(v),
            child: InkWell(
              onTap: () => widget.onToggleExpand(index),
              child: Row(
                children: [
                  SizedBox(
                    width: _eyeW,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.visibility,
                        size: 18,
                        color: _eyeEnabled(v)
                            ? Colors.blue.shade600
                            : Colors.grey.shade400,
                      ),
                      tooltip: _eyeTooltip(v),
                      onPressed: _eyeEnabled(v)
                          ? () => widget.onPreviewBacktest?.call(v)
                          : null,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      v.categoryLabel,
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded) const SizedBox(height: _detailH),
      ],
    );
  }

  bool _eyeEnabled(ComboVerdict v) =>
      widget.onPreviewBacktest != null && v.hasAst;

  /// 该行整行的 TSV 文本（列序与表头一致，买/卖条件用面板同一套中文口径）。
  String _rowTsv(ComboVerdict v) {
    final i = v.inSample;
    final o = v.outSample;
    final maxKn = widget.maxKn;
    return [
      conditionDisplayText(v.buyText, maxKn: maxKn).replaceAll('\t', ' '),
      conditionDisplayText(v.sellText, maxKn: maxKn).replaceAll('\t', ' '),
      i.trades,
      _mn(i.winRate, pct: true),
      _mn(i.payoffRatio),
      _mn(i.profitFactor),
      i.netProfit.toStringAsFixed(0),
      _mn(i.sharpe),
      _mn(i.calmar),
      o.trades,
      _mn(o.winRate, pct: true),
      _mn(o.payoffRatio),
      _mn(o.profitFactor),
      o.netProfit.toStringAsFixed(0),
      _mn(o.sharpe),
      _mn(o.calmar),
    ].join('\t');
  }

  /// 右键整行复制：写入剪贴板并给一条短提示。
  void _copyRow(ComboVerdict v) {
    Clipboard.setData(ClipboardData(text: _rowTsv(v)));
    final msg = ScaffoldMessenger.maybeOf(context);
    if (msg != null) {
      msg
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已复制该行（${v.categoryLabel}）整行文本'),
          duration: const Duration(milliseconds: 1200),
        ));
    }
  }

  String _eyeTooltip(ComboVerdict v) {
    if (widget.onPreviewBacktest == null) {
      return widget.previewHint ??
          '该界面无法即时回测（请重新寻优后预览）';
    }
    if (!v.hasAst) return '旧快照无买卖 AST，需重新寻优导入';
    return '以该行买卖条件替换当前策略并打开回测台';
  }

  /// 表头列名 tooltip：白话口径 + 英文列键（寻优结果宽表列说明的唯一落点）。
  ///
  /// [scope] 取「样本内 / 样本外」；[plain] 是该指标的白话算法；[note] 补三态说明。
  static String _colTip(
    String label,
    String key,
    String scope,
    String plain, [
    String? note,
  ]) =>
      note == null
          ? '$label：$plain（$scope）\n$key'
          : '$label：$plain（$scope）\n$key（$note）';

  Widget _bodyHeader() => Listener(
        onPointerSignal: (n) {
          if (n is PointerScrollEvent && n.kind == PointerDeviceKind.mouse) {
            // 表头区无纵向内容：鼠标纵滚转为横向滚动（触控板横向 dx 由 ScrollView 原生处理）
            _scrollH(n.scrollDelta.dy != 0 ? n.scrollDelta.dy : n.scrollDelta.dx);
          }
        },
        child: Container(
          height: _headerH,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _plainHeader(
                '买入条件',
                _buyW,
                tooltip: '买入条件：该组合的开仓触发条件\n'
                    '点本行可展开看全文\n(buy)',
              ),
              _plainHeader(
                '卖出条件',
                _sellW,
                tooltip: '卖出条件：该组合的平仓触发条件\n'
                    '点本行可展开看全文\n(sell)',
              ),
              _sortableHeaderCell(
                '内笔数',
                VerdictSortColumn.inTrades,
                tooltip: _colTip('内笔数', 'in_trades', '样本内',
                    '已平仓笔数（盈利＋亏损＋持平）'),
              ).w(_colTrades),
              _sortableHeaderCell(
                '内胜率',
                VerdictSortColumn.inWinRate,
                tooltip: _colTip('内胜率', 'in_win_rate', '样本内',
                    '盈利笔数 ÷ 已平仓总笔数'),
              ).w(_colRate),
              _sortableHeaderCell(
                '内盈亏比',
                VerdictSortColumn.inPayoff,
                tooltip: _colTip(
                    '内盈亏比', 'in_payoff_ratio', '样本内', '单笔平均盈利 ÷ 单笔平均亏损',
                    '全胜无亏显示 ∞'),
              ).w(_colRatio),
              _sortableHeaderCell(
                '内盈利因子',
                VerdictSortColumn.inPf,
                tooltip: _colTip(
                    '内盈利因子', 'in_profit_factor', '样本内', '毛利 ÷ 毛亏',
                    '无亏损显示 ∞，0 成交显示 —'),
              ).w(_colPf),
              _sortableHeaderCell(
                '内净利',
                VerdictSortColumn.inNet,
                tooltip: _colTip('内净利', 'in_net_profit', '样本内',
                    '末净值 − 初始本金（已扣费用与滑点）'),
              ).w(_colNet),
              _sortableHeaderCell(
                '内夏普',
                VerdictSortColumn.inSharpe,
                tooltip: _colTip(
                    '内夏普', 'in_sharpe', '样本内', '每笔收益均值 ÷ 每笔收益标准差，按 252 根 K 年化',
                    '标准差为 0 显示 —'),
              ).w(_colScore),
              _sortableHeaderCell(
                '内卡玛',
                VerdictSortColumn.inCalmar,
                tooltip: _colTip(
                    '内卡玛', 'in_calmar', '样本内', '年化收益 ÷ 最大回撤幅度',
                    '回撤为 0 显示 —'),
              ).w(_colScore),
              _sortableHeaderCell(
                '外笔数',
                VerdictSortColumn.outTrades,
                tooltip: _colTip('外笔数', 'out_trades', '样本外',
                    '已平仓笔数（盈利＋亏损＋持平）'),
              ).w(_colTrades),
              _sortableHeaderCell(
                '外胜率',
                VerdictSortColumn.outWinRate,
                tooltip: _colTip('外胜率', 'out_win_rate', '样本外',
                    '盈利笔数 ÷ 已平仓总笔数'),
              ).w(_colRate),
              _sortableHeaderCell(
                '外盈亏比',
                VerdictSortColumn.outPayoff,
                tooltip: _colTip(
                    '外盈亏比', 'out_payoff_ratio', '样本外', '单笔平均盈利 ÷ 单笔平均亏损',
                    '全胜无亏显示 ∞'),
              ).w(_colRatio),
              _sortableHeaderCell(
                '外盈利因子',
                VerdictSortColumn.outPf,
                tooltip: _colTip(
                    '外盈利因子', 'out_profit_factor', '样本外', '毛利 ÷ 毛亏',
                    '无亏损显示 ∞，0 成交显示 —'),
              ).w(_colPf),
              _sortableHeaderCell(
                '外净利',
                VerdictSortColumn.outNet,
                tooltip: _colTip('外净利', 'out_net_profit', '样本外',
                    '末净值 − 初始本金（已扣费用与滑点）'),
              ).w(_colNet),
              _sortableHeaderCell(
                '外夏普',
                VerdictSortColumn.outSharpe,
                tooltip: _colTip(
                    '外夏普', 'out_sharpe', '样本外', '每笔收益均值 ÷ 每笔收益标准差，按 252 根 K 年化',
                    '标准差为 0 显示 —'),
              ).w(_colScore),
              _sortableHeaderCell(
                '外卡玛',
                VerdictSortColumn.outCalmar,
                tooltip: _colTip(
                    '外卡玛', 'out_calmar', '样本外', '年化收益 ÷ 最大回撤幅度',
                    '回撤为 0 显示 —'),
              ).w(_colScore),
            ],
          ),
        ),
      );

  Widget _plainHeader(String label, double w, {String? tooltip}) => SizedBox(
        width: w,
        child: Tooltip(
          message: tooltip ?? label,
          waitDuration: const Duration(milliseconds: 300),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );

  Widget _bodyRow(ComboVerdict v, int index) {
    final expanded = index == widget.expanded;
    final i = v.inSample;
    final o = v.outSample;
    return Column(
      children: [
        SizedBox(
          height: _mainRowH,
          child: GestureDetector(
            onSecondaryTapUp: (_) => _copyRow(v),
            child: InkWell(
              onTap: () => widget.onToggleExpand(index),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _ruleCell(v.buyText),
                  _ruleCell(v.sellText),
                  _numCell('${i.trades}', _colTrades),
                  _numCell(_mn(i.winRate, pct: true), _colRate),
                  _numCell(_mn(i.payoffRatio), _colRatio),
                  _numCell(_mn(i.profitFactor), _colPf),
                  _numCell(i.netProfit.toStringAsFixed(0), _colNet),
                  _numCell(_mn(i.sharpe), _colScore),
                  _numCell(_mn(i.calmar), _colScore),
                  _numCell('${o.trades}', _colTrades),
                  _numCell(_mn(o.winRate, pct: true), _colRate),
                  _numCell(_mn(o.payoffRatio), _colRatio),
                  _numCell(_mn(o.profitFactor), _colPf),
                  _numCell(o.netProfit.toStringAsFixed(0), _colNet),
                  _numCell(_mn(o.sharpe), _colScore),
                  _numCell(_mn(o.calmar), _colScore),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          SizedBox(height: _detailH, child: _detailContent(v)),
      ],
    );
  }

  Widget _ruleCell(String text) {
    final t = conditionDisplayText(text, maxKn: widget.maxKn);
    return SizedBox(
      width: _buyW,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          t,
          style: const TextStyle(fontSize: 10, height: 1.3),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _numCell(String t, double w) => SizedBox(
        width: w,
        child: Center(
          child: Text(t, style: const TextStyle(fontSize: 11, height: 1.25)),
        ),
      );

  /// 行展开后的其余详细指标（内外段并列）。
  Widget _detailContent(ComboVerdict v) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _detailCard('样本内', v.inSample)),
          const SizedBox(width: 10),
          Expanded(child: _detailCard('样本外', v.outSample)),
        ],
      ),
    );
  }

  Widget _detailCard(String title, SegmentMetrics s) {
    final chips = <String>[
      '胜/亏/平：${s.winning}/${s.losing}/${s.flat}',
      '毛利：${s.grossProfit.toStringAsFixed(0)}',
      '毛亏：${s.grossLoss.toStringAsFixed(0)}',
      '期望：${_mn(s.expectancy)}',
      '平均盈：${_mn(s.averageWin)}',
      '平均亏：${_mn(s.averageLoss)}',
      '最大盈：${_mn(s.largestWin)}',
      '最大亏：${_mn(s.largestLoss)}',
      '连胜/连亏：${s.maxConsecutiveWins}/${s.maxConsecutiveLosses}',
      '平均持仓：${_mn(s.avgHoldBars, digits: 1)}K',
      '中位持仓：${_mn(s.medianHoldBars, digits: 1)}K',
      '最长持仓：${_mn(s.maxHoldBars, digits: 1)}K',
      '持仓占比：${_mn(s.holdTimeRatio, pct: true)}',
      '回撤额：${s.maxDrawdown.toStringAsFixed(0)}',
      '回撤比例：${(s.maxDrawdownPct * 100).toStringAsFixed(1)}%',
      '年化收益：${_mn(s.annualReturn, pct: true)}',
      '年化波动：${_mn(s.annualVol, pct: true)}',
      '索提诺：${_mn(s.sortino)}',
      '收益%：${_mn(s.returnPct, pct: true)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: chips
              .map(
                (c) => Text(
                  c,
                  style: const TextStyle(fontSize: 10, height: 1.3),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

extension _WBox on Widget {
  Widget w(double width) => SizedBox(width: width, child: this);
}
