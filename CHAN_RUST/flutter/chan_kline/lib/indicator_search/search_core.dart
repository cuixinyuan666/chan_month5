import 'dart:io';
import 'dart:math' as math;

import 'package:chan_kline/backtest/condition_ast.dart';

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
        'payoff': payoff,
        'profitFactor': profitFactor,
        'netProfit': netProfit,
      };

  static RawScore fromJson(Map<String, dynamic> m) => RawScore(
        trades: (m['trades'] as num?)?.toInt() ?? 0,
        winRate: (m['winRate'] as num?)?.toDouble(),
        payoff: (m['payoff'] as num?)?.toDouble(),
        profitFactor: (m['profitFactor'] as num?)?.toDouble(),
        netProfit: (m['netProfit'] as num?)?.toDouble() ?? 0,
      );
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

  const ComboVerdict({
    required this.name,
    required this.buyText,
    required this.sellText,
    required this.inSample,
    required this.outSample,
    required this.inRankScore,
    required this.passed,
    required this.splitX,
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
      (s.payoff ?? 0) >= minPayoff;

  bool ok(ComboVerdict v) => okSegment(v.inSample) && okSegment(v.outSample);
}

double rankScoreOf(RawScore s, {required int minTrades}) {
  final n = s.trades;
  if (n < minTrades) return 0;
  final wr = s.winRate;
  final po = s.payoff;
  if (wr == null || po == null) return 0;
  final shrink = n / (n + 6.0);
  final wrAdj = 0.5 + (wr - 0.5) * shrink;
  final conf = math.log(1 + n / 5.0) / math.log(1 + 50 / 5.0);
  return wrAdj * po * (0.35 + 0.65 * conf);
}

int splitIndexOf(int total, {double inRatio = 0.7}) {
  if (total <= 0) return 0;
  final cut = (total * inRatio).round();
  return cut.clamp(1, math.max(1, total - 1));
}

class VerdictSink {
  VerdictSink(this.path);

  final String path;
  final StringBuffer _pending = StringBuffer();

  void add(ComboVerdict v) {
    _pending.writeln(
      '${v.name}\t${v.inSample.trades}\t${_f(v.inSample.winRate)}'
      '\t${_f(v.inSample.payoff)}\t${v.outSample.trades}'
      '\t${_f(v.outSample.winRate)}\t${_f(v.outSample.payoff)}'
      '\t${v.inRankScore.toStringAsFixed(4)}\t${v.passed}',
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

  void close() => flush();

  static String _f(double? x) => x == null ? '-' : x.toStringAsFixed(4);
}
