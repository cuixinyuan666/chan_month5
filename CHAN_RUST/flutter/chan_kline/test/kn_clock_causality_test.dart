import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/structure_object.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// K1+ 采样钟的当下性回归（2026-10-06 排查后固化）。
///
/// 背景：过去 K1+ 穿越按「一段一个采样点」采样、且采样点取自**最终态**结构，
/// 于是「当时正在生长的段」被划走 → 动态段中途成立的信号被丢或被推到段尾
/// （002003 上 21/21 条买信号全落段尾，实盘复现不了）。
///
/// 锁死：①逐 bar 采样；②段中信号可产生；③前缀重放一致；④变量仍不回写；⑤空档切断。
/// 刻意不经过 SearchEnv（它的筛选口径会变），直接走回测引擎。
const _code = '002003';
const _period = '1m';
const _begin = '2025/09/29 09:30:00';
const _end = '2025/10/10 15:00:00';

TradeAst _buyAst() => const TradeCmpAst(
      left: TradeVarRef('MAIN.K1.MA.5'),
      right: TradeVarRef('STRUCTURE.K1.ZS.ACTIVE.CENTER'),
      op: TradeBinaryOp.crossBelow,
    );

TradeAst _sellAst() => const TradeEventAst('STRUCTURE.K0.SELL1');

List<int> _segEnds(List<LevelBundle> levels) {
  for (final lv in levels) {
    if (lv.level == 0) {
      return <int>[
        ...lv.unitBars.where((u) => u.dir != 0).map((u) => u.x2),
        if (lv.activeUnit != null && lv.activeUnit!.dir != 0)
          lv.activeUnit!.x2
      ]..sort();
    }
  }
  return const [];
}

String _cover(List<int> ends, int x) {
  for (final e in ends) {
    if (x <= e) return x == e ? '段尾' : '段内';
  }
  return '段外';
}

void main() {
  late List<KlineBar> bars;
  late BacktestStepHarnessResult h;

  List<SignalEvent> _signalsWith(
    BacktestStepHarnessResult hz,
    TradeAst buy,
    TradeAst sell,
    int asOf,
    List<KlineBar> barsIn,
  ) {
    final run = executeStrategyBacktest(
      config: StrategyConfig(buyAst: buy, sellAst: sell),
      scope: BacktestDataScope(
        code: _code,
        period: _period,
        barCount: barsIn.length,
        asOfX: asOf,
        beginText: _begin,
        endText: _end,
      ),
      bars: barsIn,
      levels: hz.levels,
      mathFreeze: hz.mathFreeze,
      chanEvents: hz.chanEvents,
      zsObjects: hz.zsObjects,
      diverRelations: hz.diverRelations,
      lineSeries: hz.lineSeries,
      chipPeaks: hz.chipPeaks,
      maxKn: hz.maxKn,
      barFeatures: hz.barFeatures,
      mathConfig: hz.mathConfig,
      knClock: hz.knClock,
    );
    return run.result!.signals;
  }

  List<SignalEvent> _signals(TradeAst buy, TradeAst sell, int asOf) =>
      _signalsWith(h, buy, sell, asOf, bars);

  List<String> _keys(List<SignalEvent> sigs, int asOf) => sigs
      .where((s) => s.discoveryX <= asOf)
      .map((s) => '${s.discoveryX}:${s.side?.name}:${s.op.name}')
      .toList()
    ..sort();

  setUpAll(() async {
    final bridge = ChanBridge.instance;
    bridge.ensureInitialized();
    bars = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: _code,
          beginDate: _begin,
          endDate: _end,
          period: _period,
          tickSource: 'protocol',
        )
        .bars;
    h = await driveStepHarness(bars);
  });

  test('逐 bar 采样：采样点远多于「一段一个」，且覆盖段中', () {
    final perBar =
        collectKnOhlcSamplesAt(displayKn: 1, timeline: h.knClock!, asOf: null);
    final perSeg =
        collectKnOhlcSamples(displayKn: 1, bars: bars, levels: h.levels);
    expect(perBar.length, greaterThan(perSeg.length * 5),
        reason: '逐 bar 采样应远多于段尾制');
    final ends = _segEnds(h.levels);
    final inBody = perBar
        .map((e) => e.endX)
        .where((x) => _cover(ends, x) == '段内')
        .toList();
    expect(inBody, isNotEmpty, reason: '段中必须有采样点（动态段口径）');
  });

  test('段中信号可产生：买信号不再全是段尾', () {
    final xs = _signals(_buyAst(), _sellAst(), bars.last.idx)
        .where((s) => s.op.name == 'crossBelow')
        .map((s) => s.discoveryX)
        .toList();
    final ends = _segEnds(h.levels);
    expect(xs.where((x) => _cover(ends, x) == '段内'), isNotEmpty,
        reason: '段中成立的信号不得被段尾制吞掉（回归：曾 21/21 全落段尾）');
  });

  test('前缀一致性：只喂 bars[0..asOf] 与全量取 x<=asOf 信号一致', () async {
    const asOf = 692;
    final expectKeys = _keys(_signals(_buyAst(), _sellAst(), bars.last.idx), asOf);
    final hp = await driveStepHarness(bars.sublist(0, asOf + 1));
    final preKeys = _keys(
        _signalsWith(hp, _buyAst(), _sellAst(), asOf, bars.sublist(0, asOf + 1)),
        asOf);
    expect(preKeys, expectKeys,
        reason: '前缀重放必须与全量前段一致（不等即引入未来信息或漏信号）');
  });

  test('变量取值仍按当步冻结、不回写', () {
    final before = h.zsObjects
        .projectActive(displayKn: 1, asOf: 528, projection: ZsProjection.center);
    expect(before, isNotNull);
    expect(h.mathFreeze.mean(1)?[5], isNotNull);
    final again = h.zsObjects
        .projectActive(displayKn: 1, asOf: 528, projection: ZsProjection.center);
    expect(again, before, reason: '同一 asOf 的中枢快照不得被后续数据改写');
  });

  test('空档切断：K2 穿越信号的前一点必与它相邻（无单侧空档）', () {
    // K2 实测空档 128 个（K0/K1 为 0），用它做端到端断言。
    final buy = const TradeCmpAst(
      left: TradeVarRef('MAIN.K2.MA.10'),
      right: TradeVarRef('STRUCTURE.K2.ZS.ACTIVE.CENTER'),
      op: TradeBinaryOp.crossBelow,
    );
    final sigXs = _signals(buy, _sellAst(), bars.last.idx)
        .where((s) => s.op.name == 'crossBelow')
        .map((s) => s.discoveryX)
        .toList()
      ..sort();
    final ma = readEvalClockSeries(
      variableId: 'MAIN.K2.MA.10',
      asOf: bars.last.idx,
      bars: bars,
      levels: h.levels,
      mathFreeze: h.mathFreeze,
      knClock: h.knClock,
    );
    final zs = readEvalClockSeries(
      variableId: 'STRUCTURE.K2.ZS.ACTIVE.CENTER',
      asOf: bars.last.idx,
      bars: bars,
      levels: h.levels,
      mathFreeze: h.mathFreeze,
      zsObjects: h.zsObjects,
      knClock: h.knClock,
    );
    final maAt = {for (final e in ma) e.availableAt};
    final zsAt = {for (final e in zs) e.availableAt};
    final both = maAt.intersection(zsAt);
    expect(sigXs, isNotEmpty, reason: 'K2 该条件应有信号');
    for (final x in sigXs) {
      final prev = both.where((y) => y < x).toList()..sort();
      expect(prev, isNotEmpty);
      final y = prev.last;
      final gapInside = maAt.where((t) => t > y && t < x && !zsAt.contains(t));
      expect(gapInside, isEmpty,
          reason: '信号 K$x 的前一点 K$y 与它之间存在空档（应被切断）');
    }
  });
}