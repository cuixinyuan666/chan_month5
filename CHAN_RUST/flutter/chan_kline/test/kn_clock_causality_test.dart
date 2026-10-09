import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/chart_line_store.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/structure_object.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/demark_compute.dart';
import 'package:chan_kline/compute/kn_clock_timeline.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/compute/line_slope_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/compute/step_rhythm_compute.dart';
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

  test('对弦平移 / 顶极贴合 / 底极贴合不再恒无样本（V4 回归）', () {
    // 白名单补齐后至少 K0 三族都有样本；K1 对弦平移同样可读。
    // （顶/底极贴合依赖「父段内极点拟合」，父层无数据时本就为空——那是数据属性，
    //   与本次白名单缺失是两回事。）
    const ids = [
      'MAIN.K0.FX_CHORD_TRANSLATED.PRICE',
      'MAIN.K0.FX_BOTTOM_SNUG.PRICE',
      'MAIN.K0.FX_TOP_SNUG.PRICE',
      'MAIN.K1.FX_CHORD_TRANSLATED.PRICE',
    ];
    for (final id in ids) {
      final s = readEvalClockSeries(
        variableId: id,
        asOf: bars.last.idx,
        bars: bars,
        levels: h.levels,
        k0Confirms: h.chanEvents.k0FractalConfirms,
        knClock: h.knClock,
      );
      expect(s, isNotEmpty,
          reason: '$id 在目录里已登记，此前求值白名单漏了它 → 恒无样本、'
              '引用它的策略永远不出信号且不报错（V4）');
    }
  });

  test('采样钟退场会被计数，不许静默退回冻段（S6）', () {
    KnClockDiagnostics.reset();
    _signals(_buyAst(), _sellAst(), bars.last.idx);
    expect(KnClockDiagnostics.totalFallbacks, 0,
        reason: '走采样钟时不得有任何一次退回最终态段划分；'
            '此前这条兜底无声发生，正是「信号被推到段尾且测试全绿」的成因');

    // 反向验证探针本身有效：拿掉采样钟必须被计上。
    final run = executeStrategyBacktest(
      config: StrategyConfig(buyAst: _buyAst(), sellAst: _sellAst()),
      scope: BacktestDataScope(
        code: _code,
        period: _period,
        barCount: bars.length,
        asOfX: bars.last.idx,
        beginText: _begin,
        endText: _end,
      ),
      bars: bars,
      levels: h.levels,
      mathFreeze: h.mathFreeze,
      chanEvents: h.chanEvents,
      zsObjects: h.zsObjects,
      diverRelations: h.diverRelations,
      lineSeries: h.lineSeries,
      chipPeaks: h.chipPeaks,
      maxKn: h.maxKn,
      barFeatures: h.barFeatures,
      mathConfig: h.mathConfig,
    );
    expect(run.result!.signals, isNotEmpty);
    expect(KnClockDiagnostics.missingTimelineFallbacks, greaterThan(0),
        reason: '探针无效：没传采样钟却没计数，说明这条断言测不到东西');
    KnClockDiagnostics.reset();
  });

  test('空档切断：K2 穿越信号的前一点必与它相邻（无单侧空档）', () {
    // K2 实测空档 128 个（K0/K1 为 0），用它做端到端断言。
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
    final maAt = {for (final e in ma) e.availableAt: e.value};
    final zsAt = {for (final e in zs) e.availableAt: e.value};
    final both = maAt.keys.toSet().intersection(zsAt.keys.toSet()).toList()
      ..sort();
    final allAt = <int>{...maAt.keys, ...zsAt.keys};

    // 参照答案（oracle）：按两侧都有值的采样点顺序，相邻两点**真相邻**才允许穿越。
    bool gapBetween(int y, int x) => allAt.any(
        (t) => t > y && t < x && (!maAt.containsKey(t) || !zsAt.containsKey(t)));
    final expected = <int>{};
    for (var i = 1; i < both.length; i++) {
      final y = both[i - 1];
      final x = both[i];
      if (gapBetween(y, x)) continue;
      if (maAt[y]! >= zsAt[y]! && maAt[x]! < zsAt[x]!) expected.add(x);
    }
    expect(both.length, greaterThan(100), reason: 'K2 两侧都应有样本');

    // 「MA 下穿中枢」与「中枢上穿 MA」是**同一个条件**的两种写法，空档切断必须对称生效。
    for (final e in <String, TradeCmpAst>{
      'MA下穿中枢': const TradeCmpAst(
        left: TradeVarRef('MAIN.K2.MA.10'),
        right: TradeVarRef('STRUCTURE.K2.ZS.ACTIVE.CENTER'),
        op: TradeBinaryOp.crossBelow,
      ),
      '中枢上穿MA': const TradeCmpAst(
        left: TradeVarRef('STRUCTURE.K2.ZS.ACTIVE.CENTER'),
        right: TradeVarRef('MAIN.K2.MA.10'),
        op: TradeBinaryOp.crossAbove,
      ),
    }.entries) {
      final sigXs = _signals(e.value, _sellAst(), bars.last.idx)
          .where((s) => s.op.name == e.value.op.name)
          .map((s) => s.discoveryX)
          .toSet();
      expect(sigXs, expected,
          reason: '${e.key}写法的信号集合必须等于「真相邻且发生穿越」的参照答案；'
              '多出来的就是跨空档的假信号（V5）');
    }
  });

  test('空档切断左右对称：同一条件两种写法结果一致（V5 · 合成数据）', () {
    // 真实数据上 K2 的空档恰好没落在任何一次穿越之前，端到端测不出不对称；
    // 这里用可控的稀疏/稠密两列把单侧空档钉死在一次「本该发生」的穿越之前。
    // 斜率列在 K0#1/3/5（稀疏），节奏列在 K0#1..5（稠密）；K0#3 本该上穿。
    final lines = ChartLineStore(
      lineSlopeByKn: {
        0: const [
          LineSlopePoint(x: 1, displayKn: 0, slope: 0, dir: 'up', childIdx: 1),
          LineSlopePoint(x: 3, displayKn: 0, slope: 5, dir: 'up', childIdx: 3),
          LineSlopePoint(x: 5, displayKn: 0, slope: 0, dir: 'down', childIdx: 5),
        ],
      },
      stepRhythmByKn: {
        0: [
          for (var x = 1; x <= 5; x++)
            StepRhythmLinePoint(
              x: x,
              displayKn: 0,
              key: 'r$x',
              value: 2,
              ratio: 1,
              dir: 'up',
              roundCurrent: 0,
              roundRef: 0,
              layer: 0,
              label: '$x',
              currentBiIdx: x,
              refBiIdx: x,
              retraceBiIdx: x,
            ),
        ],
      },
    );
    Set<int> _sig(TradeAst ast) {
      final run = executeStrategyBacktest(
        config: StrategyConfig(buyAst: ast, sellAst: _sellAst()),
        scope: BacktestDataScope(
          code: _code,
          period: _period,
          barCount: 6,
          asOfX: 5,
          beginText: _begin,
          endText: _end,
        ),
        bars: bars,
        levels: h.levels,
        mathFreeze: h.mathFreeze,
        lineSeries: lines,
        maxKn: h.maxKn,
      );
      return run.result!.signals
          .where((s) => s.side?.name == 'buy')
          .map((s) => s.discoveryX)
          .toSet();
    }

    const slopeUp = TradeCmpAst(
      left: TradeVarRef('SUB.K0.LINE_SLOPE'),
      right: TradeVarRef('MAIN.K0.STEP_RHYTHM'),
      op: TradeBinaryOp.crossAbove,
    );
    const rhythmDown = TradeCmpAst(
      left: TradeVarRef('MAIN.K0.STEP_RHYTHM'),
      right: TradeVarRef('SUB.K0.LINE_SLOPE'),
      op: TradeBinaryOp.crossBelow,
    );
    expect(_sig(slopeUp), _sig(rhythmDown),
        reason: '同一条件的两种写法必须同结果；旧实现只看 left 侧，'
            '把「稠密在右」的空档全漏了（V5）');
    expect(_sig(slopeUp), isEmpty,
        reason: 'K0#1 与 K0#3 之间，节奏列在 K0#2 有值而斜率列没有 → 中间不可知，'
            '这次上穿必须被切断，不许出信号');
  });
}