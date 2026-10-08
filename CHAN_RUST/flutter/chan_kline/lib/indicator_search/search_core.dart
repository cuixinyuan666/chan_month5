import 'dart:io';

import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/models/kline_bar.dart';

/// 寻优公共部件：候选枚举、样本内外切分、结果落盘。
class ComboCand {
  final String name;
  final TradeAst buyAst;
  final TradeAst sellAst;

  const ComboCand(this.name, this.buyAst, this.sellAst);
}

class ComboVerdict {
  final String name;
  final String buyText;
  final String sellText;
  final SegmentMetrics inSample;
  final SegmentMetrics outSample;
  final TradeAst? buyAst;
  final TradeAst? sellAst;
  final int splitX;

  const ComboVerdict({
    required this.name,
    required this.buyText,
    required this.sellText,
    required this.inSample,
    required this.outSample,
    this.buyAst,
    this.sellAst,
    required this.splitX,
  });

  /// 展示用短标签（「事件｜…」→「事件」）。
  String get categoryLabel {
    final i = name.indexOf('｜');
    if (i <= 0) return name;
    return name.substring(0, i);
  }

  /// 快照是否带可导入的买卖 AST（旧版快照没有 → 禁用导入并提示重新寻优）。
  bool get hasAst => buyAst != null && sellAst != null;

  Map<String, dynamic> toJson() => {
    'name': name,
    'buyText': buyText,
    'sellText': sellText,
    'inSample': _segmentToJson(inSample),
    'outSample': _segmentToJson(outSample),
    if (buyAst != null) 'buyAst': buyAst!.toJson(),
    if (sellAst != null) 'sellAst': sellAst!.toJson(),
    'splitX': splitX,
  };

  static ComboVerdict fromJson(Map<String, dynamic> m) {
    final inM = m['inSample'] as Map?;
    final outM = m['outSample'] as Map?;
    return ComboVerdict(
      name: m['name'] as String? ?? '',
      buyText: m['buyText'] as String? ?? '',
      sellText: m['sellText'] as String? ?? '',
      inSample: inM == null
          ? SegmentMetrics.empty
          : _segmentFromJson(inM as Map<String, dynamic>),
      outSample: outM == null
          ? SegmentMetrics.empty
          : _segmentFromJson(outM as Map<String, dynamic>),
      buyAst: m['buyAst'] is Map
          ? tradeAstFromJson(m['buyAst'] as Map<String, dynamic>)
          : null,
      sellAst: m['sellAst'] is Map
          ? tradeAstFromJson(m['sellAst'] as Map<String, dynamic>)
          : null,
      splitX: (m['splitX'] as num?)?.toInt() ?? 0,
    );
  }
}

Object? _mn(MetricNum m) =>
    m.isInfinity ? 'inf' : (m.isFinite ? m.value : null);

MetricNum _mnBack(Object? v) {
  if (v == null) return const MetricNum.unavailable();
  if (v == 'inf') return const MetricNum.infinity();
  if (v is num) return MetricNum.finite(v.toDouble());
  return const MetricNum.unavailable();
}

Map<String, dynamic> _segmentToJson(SegmentMetrics s) => {
  'trades': s.trades,
  'winning': s.winning,
  'losing': s.losing,
  'flat': s.flat,
  'winRate': _mn(s.winRate),
  'grossProfit': s.grossProfit,
  'grossLoss': s.grossLoss,
  'netProfit': s.netProfit,
  'returnPct': _mn(s.returnPct),
  'payoffRatio': _mn(s.payoffRatio),
  'profitFactor': _mn(s.profitFactor),
  'expectancy': _mn(s.expectancy),
  'averageWin': _mn(s.averageWin),
  'averageLoss': _mn(s.averageLoss),
  'largestWin': _mn(s.largestWin),
  'largestLoss': _mn(s.largestLoss),
  'maxConsecutiveWins': s.maxConsecutiveWins,
  'maxConsecutiveLosses': s.maxConsecutiveLosses,
  'maxDrawdown': s.maxDrawdown,
  'maxDrawdownPct': s.maxDrawdownPct,
  'maxDrawdownStartX': s.maxDrawdownStartX,
  'maxDrawdownEndX': s.maxDrawdownEndX,
  'recoveryX': s.recoveryX,
  'avgHoldBars': _mn(s.avgHoldBars),
  'medianHoldBars': _mn(s.medianHoldBars),
  'maxHoldBars': _mn(s.maxHoldBars),
  'holdTimeRatio': _mn(s.holdTimeRatio),
  'annualReturn': _mn(s.annualReturn),
  'annualVol': _mn(s.annualVol),
  'sharpe': _mn(s.sharpe),
  'sortino': _mn(s.sortino),
  'calmar': _mn(s.calmar),
};

SegmentMetrics _segmentFromJson(Map<String, dynamic> m) => SegmentMetrics(
  trades: (m['trades'] as num?)?.toInt() ?? 0,
  winning: (m['winning'] as num?)?.toInt() ?? 0,
  losing: (m['losing'] as num?)?.toInt() ?? 0,
  flat: (m['flat'] as num?)?.toInt() ?? 0,
  winRate: _mnBack(m['winRate']),
  grossProfit: (m['grossProfit'] as num?)?.toDouble() ?? 0,
  grossLoss: (m['grossLoss'] as num?)?.toDouble() ?? 0,
  netProfit: (m['netProfit'] as num?)?.toDouble() ?? 0,
  returnPct: _mnBack(m['returnPct']),
  payoffRatio: _mnBack(m['payoffRatio']),
  profitFactor: _mnBack(m['profitFactor']),
  expectancy: _mnBack(m['expectancy']),
  averageWin: _mnBack(m['averageWin']),
  averageLoss: _mnBack(m['averageLoss']),
  largestWin: _mnBack(m['largestWin']),
  largestLoss: _mnBack(m['largestLoss']),
  maxConsecutiveWins: (m['maxConsecutiveWins'] as num?)?.toInt() ?? 0,
  maxConsecutiveLosses: (m['maxConsecutiveLosses'] as num?)?.toInt() ?? 0,
  maxDrawdown: (m['maxDrawdown'] as num?)?.toDouble() ?? 0,
  maxDrawdownPct: (m['maxDrawdownPct'] as num?)?.toDouble() ?? 0,
  maxDrawdownStartX: (m['maxDrawdownStartX'] as num?)?.toInt(),
  maxDrawdownEndX: (m['maxDrawdownEndX'] as num?)?.toInt(),
  recoveryX: (m['recoveryX'] as num?)?.toInt(),
  avgHoldBars: _mnBack(m['avgHoldBars']),
  medianHoldBars: _mnBack(m['medianHoldBars']),
  maxHoldBars: _mnBack(m['maxHoldBars']),
  holdTimeRatio: _mnBack(m['holdTimeRatio']),
  annualReturn: _mnBack(m['annualReturn']),
  annualVol: _mnBack(m['annualVol']),
  sharpe: _mnBack(m['sharpe']),
  sortino: _mnBack(m['sortino']),
  calmar: _mnBack(m['calmar']),
);

int splitIndexOf(int total, {double inRatio = 0.7}) {
  if (total <= 0) return 0;
  if (total == 1) return 0;
  final cut = (total * inRatio).round();
  return cut.clamp(1, total - 1);
}

/// 与 [splitIndexOf] 对应切点 K 的 `idx`（用于 asOfX 与 entryX 比较）。
int splitBarIdx(List<KlineBar> bars, {double inRatio = 0.7}) {
  if (bars.isEmpty) return 0;
  if (bars.length == 1) return bars.first.idx;
  final cut = splitIndexOf(bars.length, inRatio: inRatio);
  final ix = cut.clamp(0, bars.length - 1);
  assert(() {
    final base = bars.first.idx;
    for (var i = 0; i < bars.length; i++) {
      if (bars[i].idx != base + i) return false;
    }
    return true;
  }());
  return bars[ix].idx;
}

class VerdictSink {
  VerdictSink(this.path, {this.writeHeader = true});

  final String path;
  final bool writeHeader;
  final StringBuffer _pending = StringBuffer();
  bool _headerWritten = false;

  void add(ComboVerdict v) {
    if (writeHeader && !_headerWritten) {
      _pending.writeln(
        'name\tin_t\tin_wr\tin_po\tin_pf\tin_net\tin_sh\tin_calmar'
        '\tout_t\tout_wr\tout_po\tout_pf\tout_net\tout_sh\tout_calmar',
      );
      _headerWritten = true;
    }
    final i = v.inSample, o = v.outSample;
    _pending.writeln(
      '${_tsvCell(v.name)}\t${i.trades}\t${_numCell(i.winRate, pct: true)}'
      '\t${_numCell(i.payoffRatio)}\t${_numCell(i.profitFactor)}\t'
      '${i.netProfit.toStringAsFixed(0)}\t${_numCell(i.sharpe)}\t'
      '${_numCell(i.calmar)}\t'
      '${o.trades}\t${_numCell(o.winRate, pct: true)}'
      '\t${_numCell(o.payoffRatio)}\t${_numCell(o.profitFactor)}\t'
      '${o.netProfit.toStringAsFixed(0)}\t${_numCell(o.sharpe)}\t'
      '${_numCell(o.calmar)}',
    );
  }

  /// 将缓冲追加落盘（不用长期 [IOSink]，避免 Windows 上 flush 报 StreamSink bound）。
  void flush() {
    if (_pending.isEmpty) return;
    try {
      File(path).writeAsStringSync(
        _pending.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
    _pending.clear();
  }

  void close() {
    if (writeHeader && !_headerWritten) {
      _pending.writeln(
        'name\tin_t\tin_wr\tin_po\tin_pf\tin_net\tin_sh\tin_calmar'
        '\tout_t\tout_wr\tout_po\tout_pf\tout_net\tout_sh\tout_calmar',
      );
      _headerWritten = true;
    }
    flush();
  }

  static String _tsvCell(String s) =>
      s.replaceAll('\t', ' ').replaceAll('\r', ' ').replaceAll('\n', ' ');

  static String _numCell(MetricNum m, {bool pct = false}) {
    if (m.isUnavailable) return '—';
    if (m.isInfinity) return 'inf';
    final v = m.value!;
    return pct ? '${(v * 100).toStringAsFixed(1)}' : v.toStringAsFixed(3);
  }
}
