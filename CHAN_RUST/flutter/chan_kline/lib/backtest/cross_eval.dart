import 'catalog_lookup.dart';
import 'signal_event.dart';
import 'trade_operand.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../compute/math_series_freeze_store.dart';

/// CROSS 求值结果：混钟在编译阶段非法，不会产出事件。
sealed class CrossEvalResult {
  const CrossEvalResult();
}

final class CrossEvalOk extends CrossEvalResult {
  final List<SignalEvent> events;

  const CrossEvalOk(this.events);
}

final class CrossEvalIllegal extends CrossEvalResult {
  final String reason;

  const CrossEvalIllegal(this.reason);
}

/// 在已对齐的 evalClock 样本上做边沿穿越。
/// 只看相邻两根样本；持续在上/下侧不重复触发。
/// 禁止传入 K0 铺平格子（那是 plotClock，不是计算钟）。
List<SignalEvent> detectCrossOnEvalSeries({
  required List<EvalClockPoint> left,
  required List<EvalClockPoint> right,
  required TradeBinaryOp op,
  required TradeOperand leftOp,
  required TradeOperand rightOp,
}) {
  if (op != TradeBinaryOp.crossAbove && op != TradeBinaryOp.crossBelow) {
    return const [];
  }
  final rightByAt = <int, EvalClockPoint>{};
  for (final p in right) {
    rightByAt[p.availableAt] = p;
  }
  final aligned = <({EvalClockPoint a, EvalClockPoint b})>[];
  for (final a in left) {
    final b = rightByAt[a.availableAt];
    if (b == null) continue;
    aligned.add((a: a, b: b));
  }
  aligned.sort((x, y) => x.a.availableAt.compareTo(y.a.availableAt));
  if (aligned.length < 2) return const [];

  final out = <SignalEvent>[];
  for (var i = 1; i < aligned.length; i++) {
    final prev = aligned[i - 1];
    final curr = aligned[i];
    final hit = switch (op) {
      TradeBinaryOp.crossAbove =>
        prev.a.value <= prev.b.value && curr.a.value > curr.b.value,
      TradeBinaryOp.crossBelow =>
        prev.a.value >= prev.b.value && curr.a.value < curr.b.value,
      _ => false,
    };
    if (!hit) continue;
    out.add(SignalEvent(
      signalId: 'sig-${curr.a.availableAt}-${curr.a.evalIndex}-${op.name}',
      ruleId: '',
      side: null,
      op: op,
      displayKn: leftOp.displayKn,
      clockFamily: leftOp.clockFamily,
      evalIndex: curr.a.evalIndex,
      discoveryX: curr.a.availableAt,
      availableAt: curr.a.availableAt,
      signalPrice: curr.a.value,
      source: '${op.name}|${leftOp.variableId}|${rightOp.variableId}',
      leftValue: curr.a.value,
      rightValue: curr.b.value,
      leftId: leftOp.variableId,
      rightId: rightOp.variableId,
    ));
  }
  return out;
}

/// 同层同钟 → 读双方 evalClock → 相邻样本判断穿越 → 边沿出一次事件。
/// 绝对不走 [lookupTradeNumeric] 的 K0 铺平值。
CrossEvalResult evalCross({
  required String leftId,
  required String rightId,
  required TradeBinaryOp op,
  required int asOf,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathSeriesFreezeStore? mathFreeze,
  int bollN = 20,
  int maxKn = 8,
}) {
  if (op != TradeBinaryOp.crossAbove && op != TradeBinaryOp.crossBelow) {
    return const CrossEvalIllegal('本阶段只求值 CROSS_ABOVE / CROSS_BELOW');
  }
  final compiled = compileBinaryOp(
    leftId: leftId,
    rightId: rightId,
    op: op,
    maxKn: maxKn,
  );
  if (compiled is TradeExprIllegal) {
    return CrossEvalIllegal(compiled.reason);
  }
  final ok = compiled as TradeExprOk;
  final left = readEvalClockSeries(
    variableId: leftId,
    asOf: asOf,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    bollN: bollN,
  );
  final right = readEvalClockSeries(
    variableId: rightId,
    asOf: asOf,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    bollN: bollN,
  );
  return CrossEvalOk(detectCrossOnEvalSeries(
    left: left,
    right: right,
    op: op,
    leftOp: ok.pair.left,
    rightOp: ok.pair.right,
  ));
}
