import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/models/kline_bar.dart';

import 'search_core.dart';
import 'search_env.dart';

class IndicatorSearchProgress {
  final String phase;
  final int done;
  final int total;
  final int compiled;
  final int ran;
  final int passed;
  final double? phaseFraction;
  final Duration? elapsed;
  final Duration? eta;
  final List<ComboVerdict> recentPassed;

  const IndicatorSearchProgress({
    required this.phase,
    required this.done,
    required this.total,
    required this.compiled,
    required this.ran,
    required this.passed,
    this.phaseFraction,
    this.elapsed,
    this.eta,
    this.recentPassed = const [],
  });
}

class IndicatorSearchRunStats {
  final int compiled;
  final int ran;
  final int passed;
  final int splitX;
  final List<ComboVerdict> verdicts;
  final Duration elapsed;
  final bool cancelled;

  const IndicatorSearchRunStats({
    required this.compiled,
    required this.ran,
    required this.passed,
    required this.splitX,
    required this.verdicts,
    required this.elapsed,
    this.cancelled = false,
  });
}

class IndicatorSearchRunner {
  final Map<String, StrategyCompileResult> _compileCache = {};
  bool _cancelRequested = false;

  /// 仅供机器人验证的 Widget 测试注入：取消信号回调（生产为 null）。
  /// 对话框点「取消扫描」时与 [requestCancel] 一并触发，便于测试观测。
  final void Function()? onCancelRequested;

  IndicatorSearchRunner({this.onCancelRequested});

  void requestCancel() {
    _cancelRequested = true;
    onCancelRequested?.call();
  }

  String _compileKey(TradeAst buy, TradeAst sell, int maxKn) =>
      '$maxKn||${astConditionCacheKey(buy)}||${astConditionCacheKey(sell)}';

  StrategyCompileOk? compileOk(ComboCand c, int maxKn) {
    final key = _compileKey(c.buyAst, c.sellAst, maxKn);
    final cached = _compileCache[key];
    if (cached != null) {
      return cached is StrategyCompileOk ? cached : null;
    }
    final comp = compileStrategyConfig(
      StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst),
      maxKn: maxKn,
    );
    _compileCache[key] = comp;
    return comp is StrategyCompileOk ? comp : null;
  }

  bool tryCompile(ComboCand c, int maxKn) => compileOk(c, maxKn) != null;

  ComboVerdict? evaluateCandidate({
    required ComboCand c,
    required SearchEnv env,
    required int splitX,
    required PassGate gate,
    required int maxKn,
    bool skipOosEarly = false,
  }) {
    final okCompile = compileOk(c, maxKn);
    if (okCompile == null) return null;
    // 内外段各回测一次；skipOosEarly 仅影响外段是否参与双达标门槛（不省算力）。
    final seg = env.runInOutFromSingleFull(
      okCompile,
      c.buyAst,
      c.sellAst,
      splitX,
    );
    if (seg == null) return null;
    final rIn = seg.inSample;
    final rOut = seg.outSample;
    final rank = rankScoreOf(rIn, minTrades: gate.minTrades);
    final skipOos = skipOosEarly &&
        (rank == 0 || !gate.okSegment(rIn));
    final passed = gate.okSegment(rIn) &&
        !skipOos &&
        gate.okSegment(rOut);
    return ComboVerdict(
      name: c.name,
      buyText: astConditionTextCn(c.buyAst, maxKn: maxKn),
      sellText: astConditionTextCn(c.sellAst, maxKn: maxKn),
      inSample: rIn,
      outSample: rOut,
      inRankScore: rank,
      passed: passed,
      splitX: splitX,
      outSampleSkipped: skipOos,
    );
  }

  Future<IndicatorSearchRunStats> runAll({
    required List<KlineBar> bars,
    required SearchEnv env,
    required List<ComboCand> cands,
    required PassGate gate,
    required int maxKn,
    bool skipOosEarly = true,
    void Function(IndicatorSearchProgress p)? onProgress,
    int yieldEvery = 25,
    VerdictSink? sink,
    int sinkFlushEvery = 80,
  }) async {
    _cancelRequested = false;
    final splitX = splitBarIdx(bars);
    var compiled = 0, ran = 0, passed = 0;
    var cancelled = false;
    final all = <ComboVerdict>[];
    final recentPassed = <ComboVerdict>[];
    final started = DateTime.now();
    var sinkPending = 0;

    void flushSink() {
      sink?.flush();
      sinkPending = 0;
    }

    for (var i = 0; i < cands.length; i++) {
      if (_cancelRequested) {
        cancelled = true;
        break;
      }
      final c = cands[i];
      if (tryCompile(c, maxKn)) {
        compiled++;
      } else {
        continue;
      }
      final v = evaluateCandidate(
        c: c,
        env: env,
        splitX: splitX,
        gate: gate,
        maxKn: maxKn,
        skipOosEarly: skipOosEarly,
      );
      if (v == null) continue;
      ran++;
      if (v.passed) {
        passed++;
        recentPassed.insert(0, v);
        if (recentPassed.length > 5) recentPassed.removeLast();
      }
      all.add(v);
      sink?.add(v);
      sinkPending++;
      if (sinkPending >= sinkFlushEvery) flushSink();

      if (onProgress != null &&
          (i == 0 ||
              i == cands.length - 1 ||
              (yieldEvery > 0 && i % yieldEvery == 0))) {
        final elapsed = DateTime.now().difference(started);
        Duration? eta;
        if (i > 0) {
          final msPer = elapsed.inMilliseconds / (i + 1);
          eta = Duration(
            milliseconds: (msPer * (cands.length - i - 1)).round(),
          );
        }
        onProgress(IndicatorSearchProgress(
          phase: '回测扫描',
          done: i + 1,
          total: cands.length,
          compiled: compiled,
          ran: ran,
          passed: passed,
          phaseFraction: (i + 1) / cands.length,
          elapsed: elapsed,
          eta: eta,
          recentPassed: List<ComboVerdict>.from(recentPassed),
        ));
      }
      if (yieldEvery > 0 && i % yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    flushSink();

    return IndicatorSearchRunStats(
      compiled: compiled,
      ran: ran,
      passed: passed,
      splitX: splitX,
      verdicts: all,
      elapsed: DateTime.now().difference(started),
      cancelled: cancelled,
    );
  }

  static List<ComboVerdict> sortForDisplay(List<ComboVerdict> all) {
    final passedList = [...all]..sort((a, b) {
        if (a.passed != b.passed) return a.passed ? -1 : 1;
        return b.inRankScore.compareTo(a.inRankScore);
      });
    return passedList;
  }

  static List<ComboVerdict> topByRank(List<ComboVerdict> all) {
    final byScore = [...all]..sort((a, b) => b.inRankScore.compareTo(a.inRankScore));
    return byScore;
  }
}
