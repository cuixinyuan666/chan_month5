import 'dart:io';
import 'dart:math' as math;

import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/models/kline_bar.dart';

/// 全胜无亏损时 payoff=∞ 仍过门槛；排序时用有限 cap，避免压过样本更多的有限组合。
const double kRankScoreInfinitePayoffCap = 8.0;

/// 指标组合寻优的公共部件：候选枚举、样本内外切分、稳健评分、结果落盘。
class ComboCand {
  final String name;
  final TradeAst buyAst;
  final TradeAst sellAst;

  const ComboCand(this.name, this.buyAst, this.sellAst);
}

class RawScore {
  final int trades;
  final double? winRate;
  final double? payoff;
  final double? profitFactor;
  final double netProfit;

  const RawScore({
    required this.trades,
    required this.winRate,
    required this.payoff,
    required this.profitFactor,
    required this.netProfit,
  });

  static const empty = RawScore(
    trades: 0,
    winRate: null,
    payoff: null,
    profitFactor: null,
    netProfit: 0,
  );

  Map<String, dynamic> toJson() => {
    'trades': trades,
    'winRate': winRate,
    'payoff': _encodeOptionalDouble(payoff),
    'profitFactor': _encodeOptionalDouble(profitFactor),
    'netProfit': netProfit,
  };

  static RawScore fromJson(Map<String, dynamic> m) => RawScore(
    trades: (m['trades'] as num?)?.toInt() ?? 0,
    winRate: (m['winRate'] as num?)?.toDouble(),
    payoff: _decodeOptionalDouble(m['payoff']),
    profitFactor: _decodeOptionalDouble(m['profitFactor']),
    netProfit: (m['netProfit'] as num?)?.toDouble() ?? 0,
  );
}

Object? _encodeOptionalDouble(double? v) {
  if (v == null) return null;
  if (v.isInfinite) return 'inf';
  return v;
}

double? _decodeOptionalDouble(Object? v) {
  if (v == null) return null;
  if (v == 'inf') return double.infinity;
  if (v is num) return v.toDouble();
  return null;
}

class ComboVerdict {
  final String name;
  final String buyText;
  final String sellText;
  final RawScore inSample;
  final RawScore outSample;
  final double inRankScore;
  final bool passed;
  final int splitX;

  /// 内段不过关时外段不参与双达标（内外仍各回测一次；与「外段 0 笔」区分）。
  final bool outSampleSkipped;

  const ComboVerdict({
    required this.name,
    required this.buyText,
    required this.sellText,
    required this.inSample,
    required this.outSample,
    required this.inRankScore,
    required this.passed,
    required this.splitX,
    this.outSampleSkipped = false,
  });

  /// 展示用短标签（「事件｜…」→「事件」）。
  String get categoryLabel {
    final i = name.indexOf('｜');
    if (i <= 0) return name;
    return name.substring(0, i);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'buyText': buyText,
    'sellText': sellText,
    'inSample': inSample.toJson(),
    'outSample': outSample.toJson(),
    'inRankScore': inRankScore,
    'passed': passed,
    'splitX': splitX,
    'outSampleSkipped': outSampleSkipped,
  };

  static ComboVerdict fromJson(Map<String, dynamic> m) => ComboVerdict(
    name: m['name'] as String? ?? '',
    buyText: m['buyText'] as String? ?? '',
    sellText: m['sellText'] as String? ?? '',
    inSample: RawScore.fromJson(
      Map<String, dynamic>.from(m['inSample'] as Map? ?? {}),
    ),
    outSample: RawScore.fromJson(
      Map<String, dynamic>.from(m['outSample'] as Map? ?? {}),
    ),
    inRankScore: (m['inRankScore'] as num?)?.toDouble() ?? 0,
    passed: m['passed'] == true,
    splitX: (m['splitX'] as num?)?.toInt() ?? 0,
    outSampleSkipped: m['outSampleSkipped'] == true,
  );
}

class PassGate {
  final double minWinRate;
  final double minPayoff;
  final int minTrades;

  const PassGate({
    this.minWinRate = 0.60,
    this.minPayoff = 1.5,
    this.minTrades = 5,
  });

  bool okSegment(RawScore s) =>
      s.trades >= minTrades &&
      (s.winRate ?? 0) >= minWinRate &&
      _payoffMeetsGate(s.payoff, minPayoff);

  static bool _payoffMeetsGate(double? payoff, double minPayoff) {
    if (payoff != null && payoff.isInfinite) return true;
    return (payoff ?? 0) >= minPayoff;
  }

  bool ok(ComboVerdict v) => okSegment(v.inSample) && okSegment(v.outSample);
}

double rankScoreOf(RawScore s, {required int minTrades}) {
  final n = s.trades;
  if (n < minTrades) return 0;
  final wr = s.winRate;
  final po = s.payoff;
  if (wr == null || po == null) return 0;
  final poFinite = po.isInfinite ? kRankScoreInfinitePayoffCap : po;
  final shrink = n / (n + 6.0);
  final wrAdj = 0.5 + (wr - 0.5) * shrink;
  final conf = math.log(1 + n / 5.0) / math.log(1 + 50 / 5.0);
  return wrAdj * poFinite * (0.35 + 0.65 * conf);
}

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

/// 寻优「全胜小样本」体检（只读诊断，不改任何判定）。
///
/// 背景：`rankScoreOf` 对 `payoff=∞` 用 [kRankScoreInfinitePayoffCap]=8.0 封顶，
/// 而小样本惩罚 `shrink=n/(n+6)` 在 n=5 时仅 0.455、`conf` 因子有 0.35 兜底，
/// 导致「5 笔全胜」得分(≈3.13)压过「50 笔胜率60%盈亏比2.0」(≈1.18)。
/// 叠加上万候选无多重比较校正，榜首容易被小样本噪声占据。
/// 本统计只把事实摆出来，供人工判断是否需要收紧门槛或 cap。
class SearchInfPayoffDiagnostics {
  /// 进入统计的候选总数（跑通并产出 verdict）。
  final int total;

  /// 样本内 `payoff` 为 ∞ 的候选数。
  final int infCount;

  /// 保守分前 [topN] 名中样本内 `payoff` 为 ∞ 的个数。
  final int infInTop;

  /// 保守分前 [topN] 名中的最小样本内笔数（小样本噪声的直接证据）。
  final int topMinTrades;

  /// 双达标组合中的最小样本内笔数。
  final int passedMinTrades;

  /// 双达标组合中样本内 `payoff` 为 ∞ 的个数。
  final int passedInfCount;

  /// 双达标组合数。
  final int passedCount;

  const SearchInfPayoffDiagnostics({
    required this.total,
    required this.infCount,
    required this.infInTop,
    required this.topMinTrades,
    required this.passedMinTrades,
    required this.passedInfCount,
    required this.passedCount,
  });

  static const empty = SearchInfPayoffDiagnostics(
    total: 0,
    infCount: 0,
    infInTop: 0,
    topMinTrades: 0,
    passedMinTrades: 0,
    passedInfCount: 0,
    passedCount: 0,
  );

  static bool _isInf(RawScore s) => s.payoff != null && s.payoff!.isInfinite;

  factory SearchInfPayoffDiagnostics.of(
    List<ComboVerdict> verdicts, {
    int topN = 20,
  }) {
    if (verdicts.isEmpty) return empty;
    final byRank = [...verdicts]
      ..sort((a, b) => b.inRankScore.compareTo(a.inRankScore));
    final top = byRank.take(topN).toList();
    final passed = verdicts.where((e) => e.passed).toList();
    return SearchInfPayoffDiagnostics(
      total: verdicts.length,
      infCount: verdicts.where((e) => _isInf(e.inSample)).length,
      infInTop: top.where((e) => _isInf(e.inSample)).length,
      topMinTrades: top.isEmpty
          ? 0
          : top.map((e) => e.inSample.trades).reduce((a, b) => a < b ? a : b),
      passedMinTrades: passed.isEmpty
          ? 0
          : passed
                .map((e) => e.inSample.trades)
                .reduce((a, b) => a < b ? a : b),
      passedInfCount: passed.where((e) => _isInf(e.inSample)).length,
      passedCount: passed.length,
    );
  }

  /// 供报告头/结果面板展示的一行体检结论（无数据时返回 null）。
  String? toDisplayLine({int topN = 20}) {
    if (total == 0) return null;
    final buf = StringBuffer()
      ..write('全胜体检：样本内盈亏比∞ $infCount/$total')
      ..write(' · 前$topN名中∞ $infInTop 个、最小笔数 $topMinTrades');
    if (passedCount > 0) {
      buf.write(
        ' · 双达标 $passedCount 个中最小笔数 $passedMinTrades、∞ $passedInfCount 个',
      );
    } else {
      buf.write(' · 双达标 0 个');
    }
    // 榜首被小样本占据时给出明确告警（这是最值得警惕的形态）。
    if (infInTop > 0 && topMinTrades > 0 && topMinTrades < 10) {
      buf.write(' ⚠ 榜首含盈亏比∞的小样本组合，请核对笔数后再看排名');
    }
    return buf.toString();
  }
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
        'name\tin_trades\tin_winrate\tin_payoff\tout_trades\tout_winrate'
        '\tout_payoff\trank\tpassed\tout_skipped',
      );
      _headerWritten = true;
    }
    _pending.writeln(
      '${_tsvCell(v.name)}\t${v.inSample.trades}\t${_f(v.inSample.winRate)}'
      '\t${_f(v.inSample.payoff)}\t${v.outSample.trades}'
      '\t${_f(v.outSample.winRate)}\t${_f(v.outSample.payoff)}'
      '\t${v.inRankScore.toStringAsFixed(4)}\t${v.passed}\t${v.outSampleSkipped}',
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
        'name\tin_trades\tin_winrate\tin_payoff\tout_trades\tout_winrate'
        '\tout_payoff\trank\tpassed\tout_skipped',
      );
      _headerWritten = true;
    }
    flush();
  }

  static String _tsvCell(String s) =>
      s.replaceAll('\t', ' ').replaceAll('\r', ' ').replaceAll('\n', ' ');

  static String _f(double? x) {
    if (x == null) return '-';
    if (x.isInfinite) return 'inf';
    return x.toStringAsFixed(4);
  }
}
