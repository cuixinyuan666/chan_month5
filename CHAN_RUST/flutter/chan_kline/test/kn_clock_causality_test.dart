import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/structure_object.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/demark_compute.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
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

  test('按层同构：K2 的采样点/取值取自 level1，不是 level0（V1 回归）', () {
    final clock = h.knClock!;
    // 时间线必须每一层都记了轨（此前只记 level0，K2 全靠 K1 的格）
    expect(clock.levels, containsAll(<int>[0, 1]),
        reason: '采样钟必须按层分轨；只有 level0 会让 K2 拿到 K1 的虚拟K');
    expect(clock.levels.length, greaterThan(1),
        reason: '实际数据存在 K2 及以上，只记一层即违反全层同构');

    // K2 的采样点集合 == level1 的采样点集合，且与 level0 不同
    final k2Ends = collectKnOhlcSamplesAt(displayKn: 2, timeline: clock, asOf: null)
        .map((e) => e.endX)
        .toList();
    expect(k2Ends, clock.sampleEnds(1, null),
        reason: 'displayKn=2 的采样父层必须是 level1');
    expect(k2Ends, isNot(equals(clock.sampleEnds(0, null))),
        reason: 'K2 的采样点若与 K1 完全相同，说明仍在用 level0（V1 未修）');

    // RAW.K2.HIGH 必须取自 level1 的动态段，而不是 level0 的。
    // （close 用不了：正在生长的虚拟K收盘都等于当根 K0 收盘，两层天然相同；
    //   high/low 才带出聚合区间的差异，是判层的有效探针。）
    final rawK2 = readEvalClockSeries(
      variableId: 'RAW.K2.HIGH',
      asOf: bars.last.idx,
      bars: bars,
      levels: h.levels,
      knClock: clock,
    );
    final rawK1 = readEvalClockSeries(
      variableId: 'RAW.K1.HIGH',
      asOf: bars.last.idx,
      bars: bars,
      levels: h.levels,
      knClock: clock,
    );
    expect(rawK2, isNotEmpty, reason: 'K2 最高价应有样本');
    final k1ByX = {for (final e in rawK1) e.availableAt: e.value};
    final differing =
        rawK2.where((e) => k1ByX[e.availableAt] != e.value).length;
    expect(differing, greaterThan(0),
        reason: 'K2 最高价与 K1 最高价在所有公共采样根上都相同 = 取错层（V1 未修）');
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

  test('背驰力度比/方向接了采样钟（V2 回归）', () {
    List<double> _ratio({required bool withClock}) => readEvalClockSeries(
          variableId: 'STRUCTURE.K1.DIVERGENCE.RATIO',
          asOf: bars.last.idx,
          bars: bars,
          levels: h.levels,
          diverRelations: h.diverRelations,
          knClock: withClock ? h.knClock : null,
        ).map((e) => e.value).toList();
    final withClock = _ratio(withClock: true);
    final noClock = _ratio(withClock: false);
    expect(withClock, isNotEmpty, reason: 'K1 背驰力度比应有样本');
    expect(withClock, isNot(equals(noClock)),
        reason: '接/不接采样钟结果必须不同（相同 = 采样钟根本没起作用，V2 未修）');
    expect(withClock.length, greaterThan(noClock.length * 3),
        reason: '接采样钟后应逐根在场（远多于段尾制的一层一点）');
  });

  test('Demark 事件读冻结仓而非现算最终态（V3 回归）', () {
    // 造一份只含「K1 在 K0#3 完成买」的冻结仓；现算路径在这份数据上不出该标记。
    final store = MathSeriesFreezeStore();
    store.demarkByKn[1] = DemarkK0Series([
      for (var i = 0; i <= 3; i++)
        i == 3
            ? [const DemarkMark(type: 'complete', dir: -1, idx: 3)]
            : null,
    ]);
    final viaStore = listTradeChanEvents(
      variableId: 'MAIN.K1.DEMARK.COMPLETE_BUY',
      asOf: 3,
      store: h.chanEvents,
      levels: h.levels,
      mathFreeze: store,
      bars: bars,
      maxKn: h.maxKn,
    );
    expect(viaStore.map((e) => e.availableAt), contains(3),
        reason: 'Demark 完成标记必须从冻结仓读出（逐根当步算好的那份）');
    final viaLive = listTradeChanEvents(
      variableId: 'MAIN.K1.DEMARK.COMPLETE_BUY',
      asOf: 3,
      store: h.chanEvents,
      levels: h.levels,
      bars: bars,
      maxKn: h.maxKn,
    );
    expect(viaLive.map((e) => e.availableAt), isNot(contains(3)),
        reason: '现算（最终态段尾制）本就不该给出这格——否则本测试无法区分两条路');
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