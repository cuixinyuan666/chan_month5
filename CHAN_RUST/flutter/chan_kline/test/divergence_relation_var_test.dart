import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/divergence_relation.dart';
import 'package:chan_kline/backtest/divergence_relation_store.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/backtest/trade_value.dart';
import 'package:chan_kline/backtest/trade_var_diagnose.dart';
import 'package:chan_kline/compute/divergence_compute.dart';
import 'package:chan_kline/compute/divergence_freeze_store.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/zs_frame.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close, {double? open}) {
  final o = open ?? close;
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: o,
    high: (close > o ? close : o) + 1,
    low: (close < o ? close : o) - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

BacktestDataScope _scope(int asOf) => BacktestDataScope(
      code: 'test',
      period: '1m',
      barCount: asOf + 1,
      asOfX: asOf,
      beginText: '',
      endText: '',
    );

List<LevelBundle> _k1Levels() => [
      const LevelBundle(
        level: 0,
        unitBars: [
          LevelUnitBar(
            idx: 0,
            dir: 1,
            x1: 0,
            x2: 6,
            open: 10,
            high: 11,
            low: 8,
            close: 9,
          ),
          LevelUnitBar(
            idx: 1,
            dir: -1,
            x1: 6,
            x2: 12,
            open: 9,
            high: 13,
            low: 9,
            close: 12.5,
          ),
        ],
      ),
    ];

DivergenceCompareSpan _span({
  int inSeg = 1,
  int outSeg = 2,
  int inLo = 2,
  int inHi = 5,
  int outLo = 5,
  int outHi = 8,
  int outDir = -1,
  String mode = 'broke',
}) {
  return DivergenceCompareSpan(
    inSegIdx: inSeg,
    outSegIdx: outSeg,
    inLoX: inLo,
    inHiX: inHi,
    outLoX: outLo,
    outHiX: outHi,
    inBeginX: inLo,
    inEndX: inHi,
    outBeginX: outLo,
    outEndX: outHi,
    inDir: -outDir,
    outDir: outDir,
    mode: mode,
  );
}

DivergenceRelation _rel({
  required String id,
  required int kn,
  required int at,
  int? discovery,
  DivergenceDirection dir = DivergenceDirection.down,
  String src = 'SEG|1|2',
  String ref = 'SEG|1|1',
  double? ratio = 0.5,
  bool confirmed = true,
}) {
  return DivergenceRelation(
    relationId: id,
    displayKn: kn,
    availableAt: at,
    discoveryX: discovery ?? at,
    direction: dir,
    sourceObjectId: src,
    referenceObjectId: ref,
    sourceSegment: 2,
    referenceSegment: 1,
    ratio: ratio,
    confirmed: confirmed,
    source: 'test',
  );
}

void _seedArea(
  DivergenceFreezeStore freeze, {
  required int kn,
  required int n,
  required int at,
  required DivergenceCompareSpan span,
  required double ratio,
  double outMetric = 1,
}) {
  final diverAt = List<int>.filled(n, 0);
  diverAt[at] = 1;
  final ratioAt = List<double?>.filled(n, null);
  ratioAt[at] = ratio;
  final outAt = List<double?>.filled(n, null);
  outAt[at] = outMetric;
  freeze.mergeLevel(
    displayKn: kn,
    fresh: {
      DivergenceAlgo.area: DivergenceAlgoK0Series(
        inAt: List<double?>.filled(n, null),
        outAt: outAt,
        ratioAt: ratioAt,
        diverAt: diverAt,
      ),
    },
  );
  final spans = List<DivergenceCompareSpan?>.filled(n, null);
  spans[at] = span;
  freeze.mergeSpan(displayKn: kn, fresh: spans);
}

void main() {
  group('登记与类型门禁', () {
    test('K0..K2 背驰出现/力度比/方向进公式；整对象不能当 double', () {
      for (final kn in [0, 1, 2]) {
        final exists = lookupTradeVariable(
          'STRUCTURE.K$kn.DIVERGENCE.EXISTS',
          maxKn: 2,
        )!;
        expect(exists.expressionReady, isTrue, reason: 'EXISTS K$kn');
        expect(exists.valueType, TradeValueType.event);
        expect(exists.evalClock, TradeEvalClock.k0Bar);
        expect(exists.clockFamily, TradeClockFamily.zsMath);

        final ratio = lookupTradeVariable(
          'STRUCTURE.K$kn.DIVERGENCE.RATIO',
          maxKn: 2,
        )!;
        expect(ratio.expressionReady, isTrue, reason: 'RATIO K$kn');
        expect(ratio.valueType, TradeValueType.relationProjection);

        final dir = lookupTradeVariable(
          'STRUCTURE.K$kn.DIVERGENCE.DIRECTION',
          maxKn: 2,
        )!;
        expect(dir.expressionReady, isTrue, reason: 'DIRECTION K$kn');
        expect(dir.valueType, TradeValueType.enumeration);
      }
      expect(lookupTradeVariable('STRUCTURE.K0.DIVERGENCE.RATIO')!.evalClock,
          TradeEvalClock.k0Bar);
      expect(lookupTradeVariable('STRUCTURE.K1.DIVERGENCE.RATIO')!.evalClock,
          TradeEvalClock.knSample);
      final whole = lookupTradeVariable('STRUCTURE.K1.DIVERGENCE', maxKn: 2);
      expect(whole, isNotNull);
      expect(whole!.expressionReady, isFalse);
    });

    test('EXISTS 不能比较/穿越；DIRECTION 只能等于；混层混钟非法', () {
      expect(
        compileValuePair(
          left: const TradeVarRef('STRUCTURE.K1.DIVERGENCE.EXISTS'),
          right: const TradeConstRef(0),
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'STRUCTURE.K1.DIVERGENCE.EXISTS',
          rightId: 'SUB.K1.RSI.VALUE',
          op: TradeBinaryOp.crossAbove,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileValuePair(
          left: const TradeVarRef('STRUCTURE.K1.DIVERGENCE.DIRECTION'),
          right: const TradeEnumRef('DOWN'),
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileValuePair(
          left: const TradeVarRef('STRUCTURE.K1.DIVERGENCE.DIRECTION'),
          right: const TradeEnumRef('DOWN'),
          op: TradeBinaryOp.eq,
          maxKn: 2,
        ),
        isA<TradeValueExprOk>(),
      );
      expect(
        compileValuePair(
          left: const TradeVarRef('STRUCTURE.K1.DIVERGENCE.DIRECTION'),
          right: const TradeConstRef(-1),
          op: TradeBinaryOp.eq,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'STRUCTURE.K0.DIVERGENCE.RATIO',
          rightId: 'SUB.K1.RSI.VALUE',
          op: TradeBinaryOp.lt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileConditionAst(
          const TradeAndAst(
            TradeEventAst('STRUCTURE.K0.DIVERGENCE.EXISTS'),
            TradeCmpAst(
              left: TradeVarRef('SUB.K1.RSI.VALUE'),
              right: TradeConstRef(50),
              op: TradeBinaryOp.lt,
            ),
          ),
          maxKn: 2,
        ),
        isA<CondCompileIllegal>(),
      );
      expect(
        compileConditionAst(k1Buy1AndDiverAst(), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(k1DiverRatioAndRsiAst(), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(
          const TradeAndAst(
            TradeEventAst('STRUCTURE.K1.DIVERGENCE.EXISTS'),
            TradeCmpAst(
              left: TradeVarRef('SUB.K1.RSI.VALUE'),
              right: TradeConstRef(40),
              op: TradeBinaryOp.lt,
            ),
          ),
          maxKn: 2,
        ),
        isA<CondCompileOk>(),
      );
    });
  });

  group('对象身份与历史冻结', () {
    test('冻结仓喂入绑定中枢对象，动态延伸 relationId 不变', () {
      final freeze = DivergenceFreezeStore();
      final span = _span();
      _seedArea(freeze, kn: 1, n: 12, at: 6, span: span, ratio: 0.6);
      final zs = [
        const ZSFrame(
          x1: 2,
          x2: 5,
          high: 12,
          low: 10,
          level: 0,
          endIdx: 1,
        ),
        const ZSFrame(
          x1: 5,
          x2: 8,
          high: 11,
          low: 9,
          level: 0,
          endIdx: 2,
        ),
      ];
      final store = DivergenceRelationStore();
      store.ingestFromFreeze(
        displayKn: 1,
        asOf: 6,
        freeze: freeze,
        zsFrames: zs,
      );
      final a = store.resolveCurrent(displayKn: 1, asOf: 6)!;
      expect(a.referenceObjectId, 'ZS|1|2');
      expect(a.sourceObjectId, 'ZS|1|5');
      expect(a.ratio, closeTo(0.6, 1e-12));
      expect(a.direction, DivergenceDirection.down);
      expect(a.discoveryX, 6);

      store.ingestRelation(a);
      store.ingestRelation(_rel(
        id: a.relationId,
        kn: 1,
        at: 10,
        discovery: 6,
        src: a.sourceObjectId,
        ref: a.referenceObjectId,
        ratio: 0.4,
      ));
      final b = store.resolveCurrent(displayKn: 1, asOf: 10)!;
      expect(b.relationId, a.relationId);
      expect(b.ratio, closeTo(0.4, 1e-12));
      expect(store.snapshotOf(a.relationId, 6)!.ratio, closeTo(0.6, 1e-12));
      expect(
        store.listExistsEvents(displayKn: 1, asOf: 10).map((e) => e.availableAt),
        [6],
      );
    });

    test('同一 asOf 不回写；确认翻转追加新事件', () {
      final store = DivergenceRelationStore();
      const id = 'DIVER|1|area|SEG|1|1|SEG|1|2|1|2|broke';
      store.ingestRelation(_rel(id: id, kn: 1, at: 6, ratio: 0.5));
      store.ingestRelation(_rel(id: id, kn: 1, at: 6, ratio: 0.9));
      expect(store.snapshotOf(id, 6)!.ratio, closeTo(0.5, 1e-12));

      store.ingestRelation(
        _rel(id: id, kn: 1, at: 8, ratio: 0.5, confirmed: false),
      );
      store.ingestRelation(_rel(id: id, kn: 1, at: 10, ratio: 0.45));
      expect(
        store.listExistsEvents(displayKn: 1, asOf: 10).map((e) => e.availableAt),
        [6, 10],
      );
      expect(store.snapshotOf(id, 6)!.confirmed, isTrue);
      expect(store.snapshotOf(id, 8)!.confirmed, isFalse);
    });

    test('没有当时可见关系 → 不可用，不是 0', () {
      final bars = [_bar(6, 10)];
      final empty = lookupTradeNumeric(
        variableId: 'STRUCTURE.K1.DIVERGENCE.RATIO',
        asOf: 6,
        bars: bars,
      );
      expect(empty.isUnavailable, isTrue);

      final store = DivergenceRelationStore();
      store.ingestRelation(_rel(id: 'r1', kn: 1, at: 8, ratio: 0.3));
      final tooEarly = lookupTradeNumeric(
        variableId: 'STRUCTURE.K1.DIVERGENCE.RATIO',
        asOf: 6,
        bars: [_bar(6, 10), _bar(8, 10)],
        diverRelations: store,
      );
      expect(tooEarly.isUnavailable, isTrue);
      final later = lookupTradeNumeric(
        variableId: 'STRUCTURE.K1.DIVERGENCE.RATIO',
        asOf: 8,
        bars: [_bar(6, 10), _bar(8, 10)],
        diverRelations: store,
      );
      expect(later.value, closeTo(0.3, 1e-12));
    });

    test('无比较对象时退回段身份，仍是稳定引用', () {
      final freeze = DivergenceFreezeStore();
      _seedArea(freeze, kn: 0, n: 9, at: 4, span: _span(), ratio: 0.7);
      final store = DivergenceRelationStore();
      store.ingestFromFreeze(
        displayKn: 0,
        asOf: 4,
        freeze: freeze,
        zsFrames: const [],
      );
      final rel = store.resolveCurrent(displayKn: 0, asOf: 4)!;
      expect(rel.referenceObjectId, 'SEG|0|1');
      expect(rel.sourceObjectId, 'SEG|0|2');
    });
  });

  group('诊断', () {
    test('能看到 relationId、比较对象、发现时刻、力度比和方向', () {
      final store = DivergenceRelationStore();
      store.ingestRelation(_rel(
        id: 'DIVER|1|area|ZS|1|2|ZS|1|5|1|2|broke',
        kn: 1,
        at: 6,
        src: 'ZS|1|5',
        ref: 'ZS|1|2',
        ratio: 0.55,
      ));
      final d = diagnoseTradeVariable(
        variableId: 'STRUCTURE.K1.DIVERGENCE.RATIO',
        asOf: 6,
        bars: [_bar(6, 10)],
        diverRelations: store,
        maxKn: 2,
      );
      expect(d.currentDiver, isNotNull);
      expect(d.text, contains('DIVER|1|area'));
      expect(d.text, contains('ZS|1|2'));
      expect(d.text, contains('ZS|1|5'));
      expect(d.text, contains('向下'));
      expect(d.text, contains('K0 #6'));
    });
  });

  group('综合回测', () {
    test('策略A：K1.BUY1 AND K1.DIVERGENCE.EXISTS → 下一根开盘', () {
      final bars = [
        for (var i = 0; i <= 12; i++) _bar(i, 10.0, open: 10.0 + i * 0.1),
      ];
      final store = DivergenceRelationStore();
      store.ingestRelation(_rel(id: 'r-a', kn: 1, at: 6, ratio: 0.5));
      final events = ChanEventStore(
        buy1ByKn: {
          1: [
            const Buy1Frame(
              x: 6,
              price: 9,
              label: '1Ba',
              segIdx: 3,
              level: 0,
            ),
          ],
        },
      );
      final run = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k1Buy1AndDiverAst(),
          sellAst: const TradeCmpAst(
            left: TradeVarRef('SUB.K1.RSI.VALUE'),
            right: TradeConstRef(90),
            op: TradeBinaryOp.gt,
          ),
          initialCapital: 100000,
          quantity: 100,
        ),
        scope: _scope(12),
        bars: bars,
        levels: _k1Levels(),
        mathFreeze: MathSeriesFreezeStore()
          ..rsiByKn[1] = [for (var i = 0; i <= 12; i++) 40.0],
        chanEvents: events,
        diverRelations: store,
        maxKn: 2,
      );
      expect(run.ok, isTrue, reason: run.error);
      expect(run.engineVersion, kBacktestEngineVersion);
      final buys =
          run.result!.signals.where((s) => s.side == TradeSide.buy).toList();
      expect(buys.map((s) => s.discoveryX).toList(), [6]);
      expect(buys.first.conditionText, contains('BUY1'));
      expect(buys.first.conditionText, contains('DIVERGENCE.EXISTS'));
      final buyFill =
          run.result!.fills.firstWhere((f) => f.side == TradeSide.buy);
      expect(buyFill.executeX, 7);
      expect(run.result!.equityCurve, isNotEmpty);
      expect(run.result!.metrics.netProfit, isA<double>());
      for (final f in run.result!.fills) {
        final sig =
            run.result!.signals.firstWhere((s) => s.signalId == f.signalId);
        expect(f.executeX, sig.discoveryX + 1);
      }
    });

    test('策略B：K1.DIVERGENCE.RATIO<0.8 AND RSI<50 → 下一根开盘', () {
      final bars = [
        for (var i = 0; i <= 12; i++) _bar(i, 10.0, open: 10.0 + i * 0.1),
      ];
      final store = DivergenceRelationStore();
      store.ingestRelation(_rel(id: 'r-b', kn: 1, at: 6, ratio: 0.5));
      final freeze = MathSeriesFreezeStore();
      freeze.rsiByKn[1] = [for (var i = 0; i <= 12; i++) 40.0];
      freeze.macdByKn[1] = MacdK0Series(
        dif: [for (var i = 0; i <= 12; i++) 0.0],
        dea: [for (var i = 0; i <= 12; i++) 0.0],
        macd: [for (var i = 0; i <= 12; i++) 0.0],
      );
      expect(
        compileStrategyConfig(
          StrategyConfig(
            buyAst: k1DiverRatioAndRsiAst(),
            sellAst: const TradeCmpAst(
              left: TradeVarRef('SUB.K1.RSI.VALUE'),
              right: TradeConstRef(90),
              op: TradeBinaryOp.gt,
            ),
          ),
          maxKn: 2,
        ),
        isA<StrategyCompileOk>(),
      );
      final run = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k1DiverRatioAndRsiAst(),
          sellAst: const TradeCmpAst(
            left: TradeVarRef('SUB.K1.RSI.VALUE'),
            right: TradeConstRef(90),
            op: TradeBinaryOp.gt,
          ),
          initialCapital: 100000,
          quantity: 100,
        ),
        scope: _scope(12),
        bars: bars,
        levels: _k1Levels(),
        mathFreeze: freeze,
        diverRelations: store,
        maxKn: 2,
      );
      expect(run.ok, isTrue, reason: run.error);
      final buys =
          run.result!.signals.where((s) => s.side == TradeSide.buy).toList();
      expect(buys, isNotEmpty);
      expect(buys.first.discoveryX, 6);
      expect(buys.first.conditionText, contains('DIVERGENCE.RATIO'));
      expect(buys.first.conditionText, contains('RSI'));
      final buyFill =
          run.result!.fills.firstWhere((f) => f.side == TradeSide.buy);
      expect(buyFill.executeX, 7);
      expect(run.result!.equityCurve, isNotEmpty);
      expect(run.result!.metrics.netProfit, isA<double>());
    });

    test('方向等于向下能出信号；无关系不出', () {
      final bars = [
        for (var i = 0; i <= 12; i++) _bar(i, 10.0),
      ];
      final store = DivergenceRelationStore();
      store.ingestRelation(_rel(id: 'r-d', kn: 1, at: 6, ratio: 0.5));
      final ast = TradeCmpAst(
        left: TradeVarRef(diverDirectionId(1)),
        right: const TradeEnumRef('DOWN'),
        op: TradeBinaryOp.eq,
      );
      final ok = compileConditionAst(ast, maxKn: 2) as CondCompileOk;
      final withRel = evalCompiledCond(
        cond: ok.root,
        side: TradeSide.buy,
        ruleId: 'dir',
        ctx: CondEvalCtx(
          asOf: 12,
          bars: bars,
          levels: _k1Levels(),
          diverRelations: store,
          maxKn: 2,
        ),
      );
      expect(withRel.map((s) => s.discoveryX).toList(), [6]);

      final none = evalCompiledCond(
        cond: ok.root,
        side: TradeSide.buy,
        ruleId: 'dir',
        ctx: CondEvalCtx(
          asOf: 12,
          bars: bars,
          levels: _k1Levels(),
          maxKn: 2,
        ),
      );
      expect(none, isEmpty);
    });
  });
}
