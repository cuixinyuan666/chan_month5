import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'catalog_lookup.dart';
import 'condition_ast.dart';
import 'signal_event.dart';
import 'trade_clock.dart';
import 'trade_operand.dart';

/// 编译后的钟身份：AND/OR 两边必须同一层同一套钟同一计算钟。
class CompiledClock {
  final int displayKn;
  final TradeClockFamily family;
  final TradeEvalClock evalClock;

  const CompiledClock({
    required this.displayKn,
    required this.family,
    required this.evalClock,
  });

  bool sameAs(CompiledClock o) =>
      displayKn == o.displayKn &&
      family == o.family &&
      evalClock == o.evalClock;
}

sealed class CondCompileResult {
  const CondCompileResult();
}

final class CondCompileOk extends CondCompileResult {
  final CompiledCond root;
  const CondCompileOk(this.root);
}

final class CondCompileIllegal extends CondCompileResult {
  final String reason;
  const CondCompileIllegal(this.reason);
}

sealed class CompiledCond {
  CompiledClock get clock;
  String get label;
  const CompiledCond();
}

final class CompiledCmp extends CompiledCond {
  final TradeValueRef left;
  final TradeValueRef right;
  final TradeBinaryOp op;
  final TradeOperand clockOp;
  final TradeOperand? leftOp;
  final TradeOperand? rightOp;

  const CompiledCmp({
    required this.left,
    required this.right,
    required this.op,
    required this.clockOp,
    required this.leftOp,
    required this.rightOp,
  });

  @override
  CompiledClock get clock => CompiledClock(
        displayKn: clockOp.displayKn,
        family: clockOp.clockFamily,
        evalClock: clockOp.evalClock,
      );

  @override
  String get label => astConditionText(TradeCmpAst(left: left, right: right, op: op));
}

final class CompiledAnd extends CompiledCond {
  final CompiledCond left;
  final CompiledCond right;

  const CompiledAnd(this.left, this.right);

  @override
  CompiledClock get clock => left.clock;

  @override
  String get label => astConditionText(TradeAndAst(
        _astFromCompiled(left),
        _astFromCompiled(right),
      ));
}

final class CompiledOr extends CompiledCond {
  final CompiledCond left;
  final CompiledCond right;

  const CompiledOr(this.left, this.right);

  @override
  CompiledClock get clock => left.clock;

  @override
  String get label => astConditionText(TradeOrAst(
        _astFromCompiled(left),
        _astFromCompiled(right),
      ));
}

/// 编译一棵条件树：混层/混钟/两常数在这里就非法，不会进求值。
CondCompileResult compileConditionAst(TradeAst ast, {int maxKn = 8}) {
  final kn = maxKnInAst(ast);
  if (kn != null && kn > maxKn) {
    return CondCompileIllegal('所选层超出当前图上最大层 K$maxKn，请改选更低的层');
  }
  return _compile(ast, maxKn: maxKn);
}

CondCompileResult _compile(TradeAst ast, {required int maxKn}) {
  switch (ast) {
    case TradeCmpAst(:final left, :final right, :final op):
      final r = compileValuePair(
        left: left,
        right: right,
        op: op,
        maxKn: maxKn,
      );
      if (r is TradeExprIllegal) return CondCompileIllegal(r.reason);
      final ok = r as TradeValueExprOk;
      return CondCompileOk(CompiledCmp(
        left: ok.left,
        right: ok.right,
        op: ok.op,
        clockOp: ok.clock,
        leftOp: ok.leftOp,
        rightOp: ok.rightOp,
      ));
    case TradeAndAst(:final left, :final right):
      return _compileJoin(left, right, maxKn: maxKn, and: true);
    case TradeOrAst(:final left, :final right):
      return _compileJoin(left, right, maxKn: maxKn, and: false);
  }
}

CondCompileResult _compileJoin(
  TradeAst left,
  TradeAst right, {
  required int maxKn,
  required bool and,
}) {
  final la = _compile(left, maxKn: maxKn);
  if (la is CondCompileIllegal) return la;
  final ra = _compile(right, maxKn: maxKn);
  if (ra is CondCompileIllegal) return ra;
  final l = (la as CondCompileOk).root;
  final r = (ra as CondCompileOk).root;
  if (!l.clock.sameAs(r.clock)) {
    return CondCompileIllegal(
      '条件里混了不同层或不同钟，不能 ${and ? 'AND' : 'OR'} 在一起'
      '（禁止 K0 和 K1 拼在同一棵树上）',
    );
  }
  return CondCompileOk(and ? CompiledAnd(l, r) : CompiledOr(l, r));
}

class CondEvalCtx {
  final int asOf;
  final List<KlineBar> bars;
  final List<LevelBundle> levels;
  final MathSeriesFreezeStore? mathFreeze;
  final int bollN;
  final int maxKn;

  const CondEvalCtx({
    required this.asOf,
    required this.bars,
    this.levels = const [],
    this.mathFreeze,
    this.bollN = 20,
    this.maxKn = 8,
  });
}

class _BoolPt {
  final int evalIndex;
  final int availableAt;
  final bool flag;
  final double signalPrice;
  final double leftValue;
  final double rightValue;
  final String leftId;
  final String rightId;
  final TradeBinaryOp op;
  final List<SignalSnapshot> snapshots;

  const _BoolPt({
    required this.evalIndex,
    required this.availableAt,
    required this.flag,
    required this.signalPrice,
    required this.leftValue,
    required this.rightValue,
    required this.leftId,
    required this.rightId,
    required this.op,
    required this.snapshots,
  });
}

/// 在 evalClock 上求值 → 布尔序列 → 假变真出信号。界面不再算一遍。
List<SignalEvent> evalCompiledCond({
  required CompiledCond cond,
  required TradeSide side,
  required String ruleId,
  required CondEvalCtx ctx,
}) {
  final series = _eval(cond, ctx);
  if (series.isEmpty) return const [];
  final text = cond.label;
  final out = <SignalEvent>[];
  for (var i = 0; i < series.length; i++) {
    final prev = i == 0 ? false : series[i - 1].flag;
    final curr = series[i];
    if (prev || !curr.flag) continue;
    out.add(SignalEvent(
      signalId: 'sig-${side.name}-${curr.availableAt}-${curr.evalIndex}',
      ruleId: ruleId,
      side: side,
      op: curr.op,
      displayKn: cond.clock.displayKn,
      clockFamily: cond.clock.family,
      evalIndex: curr.evalIndex,
      discoveryX: curr.availableAt,
      availableAt: curr.availableAt,
      signalPrice: curr.signalPrice,
      source: '$ruleId|$text',
      leftValue: curr.leftValue,
      rightValue: curr.rightValue,
      leftId: curr.leftId,
      rightId: curr.rightId,
      conditionText: text,
      snapshots: curr.snapshots,
    ));
  }
  return out;
}

List<_BoolPt> _eval(CompiledCond cond, CondEvalCtx ctx) {
  switch (cond) {
    case CompiledCmp():
      return _evalCmp(cond, ctx);
    case CompiledAnd():
      return _combine(_eval(cond.left, ctx), _eval(cond.right, ctx), and: true);
    case CompiledOr():
      return _combine(_eval(cond.left, ctx), _eval(cond.right, ctx), and: false);
  }
}

List<_BoolPt> _evalCmp(CompiledCmp cond, CondEvalCtx ctx) {
  final left = _readRef(cond.left, cond.clockOp, ctx);
  final right = _readRef(cond.right, cond.clockOp, ctx);
  final rightByAt = <int, EvalClockPoint>{
    for (final p in right) p.availableAt: p,
  };
  final aligned = <({EvalClockPoint a, EvalClockPoint b})>[];
  for (final a in left) {
    final b = rightByAt[a.availableAt];
    if (b == null) continue;
    aligned.add((a: a, b: b));
  }
  aligned.sort((x, y) => x.a.availableAt.compareTo(y.a.availableAt));
  if (aligned.isEmpty) return const [];

  final leftId = cond.left is TradeVarRef
      ? (cond.left as TradeVarRef).variableId
      : '';
  final rightId = cond.right is TradeVarRef
      ? (cond.right as TradeVarRef).variableId
      : '';

  final out = <_BoolPt>[];
  for (var i = 0; i < aligned.length; i++) {
    final a = aligned[i].a;
    final b = aligned[i].b;
    final flag = _cmpAt(cond.op, aligned, i);
    out.add(_BoolPt(
      evalIndex: a.evalIndex,
      availableAt: a.availableAt,
      flag: flag,
      signalPrice: a.value,
      leftValue: a.value,
      rightValue: b.value,
      leftId: leftId,
      rightId: rightId,
      op: cond.op,
      snapshots: _leafSnapshots(cond, a.value, b.value),
    ));
  }
  return out;
}

bool _cmpAt(
  TradeBinaryOp op,
  List<({EvalClockPoint a, EvalClockPoint b})> aligned,
  int i,
) {
  final a = aligned[i].a.value;
  final b = aligned[i].b.value;
  switch (op) {
    case TradeBinaryOp.gt:
      return a > b;
    case TradeBinaryOp.lt:
      return a < b;
    case TradeBinaryOp.ge:
      return a >= b;
    case TradeBinaryOp.le:
      return a <= b;
    case TradeBinaryOp.eq:
      return a == b;
    case TradeBinaryOp.crossAbove:
      if (i == 0) return false;
      final pa = aligned[i - 1].a.value;
      final pb = aligned[i - 1].b.value;
      return pa <= pb && a > b;
    case TradeBinaryOp.crossBelow:
      if (i == 0) return false;
      final pa = aligned[i - 1].a.value;
      final pb = aligned[i - 1].b.value;
      return pa >= pb && a < b;
  }
}

List<SignalSnapshot> _leafSnapshots(
  CompiledCmp cond,
  double leftVal,
  double rightVal,
) {
  final out = <SignalSnapshot>[];
  if (cond.left is TradeVarRef) {
    out.add(SignalSnapshot(
      label: snapshotVarLabel((cond.left as TradeVarRef).variableId),
      value: leftVal,
    ));
  } else if (cond.left is TradeConstRef) {
    out.add(SignalSnapshot(
      label: '常数 ${tradeValueLabel(cond.left)}',
      value: leftVal,
    ));
  }
  if (cond.right is TradeVarRef) {
    out.add(SignalSnapshot(
      label: snapshotVarLabel((cond.right as TradeVarRef).variableId),
      value: rightVal,
    ));
  } else if (cond.right is TradeConstRef) {
    out.add(SignalSnapshot(
      label: '常数 ${tradeValueLabel(cond.right)}',
      value: rightVal,
    ));
  }
  return out;
}

List<_BoolPt> _combine(List<_BoolPt> left, List<_BoolPt> right, {required bool and}) {
  if (left.isEmpty || right.isEmpty) return const [];
  final rightByAt = <int, _BoolPt>{for (final p in right) p.availableAt: p};
  final out = <_BoolPt>[];
  for (final a in left) {
    final b = rightByAt[a.availableAt];
    if (b == null) continue;
    final flag = and ? (a.flag && b.flag) : (a.flag || b.flag);
    out.add(_BoolPt(
      evalIndex: a.evalIndex,
      availableAt: a.availableAt,
      flag: flag,
      signalPrice: a.signalPrice,
      leftValue: a.leftValue,
      rightValue: a.rightValue,
      leftId: a.leftId,
      rightId: a.rightId,
      op: _preferCrossOp(a, b),
      snapshots: _mergeSnaps(a.snapshots, b.snapshots),
    ));
  }
  out.sort((x, y) => x.availableAt.compareTo(y.availableAt));
  return out;
}

TradeBinaryOp _preferCrossOp(_BoolPt a, _BoolPt b) {
  bool isCross(TradeBinaryOp op) =>
      op == TradeBinaryOp.crossAbove || op == TradeBinaryOp.crossBelow;
  if (a.flag && isCross(a.op)) return a.op;
  if (b.flag && isCross(b.op)) return b.op;
  return a.op;
}

List<SignalSnapshot> _mergeSnaps(
  List<SignalSnapshot> a,
  List<SignalSnapshot> b,
) {
  final seen = <String>{};
  final out = <SignalSnapshot>[];
  for (final s in [...a, ...b]) {
    if (seen.add(s.label)) out.add(s);
  }
  return out;
}

List<EvalClockPoint> _readRef(
  TradeValueRef ref,
  TradeOperand clockOp,
  CondEvalCtx ctx,
) {
  if (ref is TradeConstRef) {
    final grid = readEvalClockSeries(
      variableId: clockOp.variableId,
      asOf: ctx.asOf,
      bars: ctx.bars,
      levels: ctx.levels,
      mathFreeze: ctx.mathFreeze,
      bollN: ctx.bollN,
    );
    return [
      for (final p in grid)
        EvalClockPoint(
          evalIndex: p.evalIndex,
          availableAt: p.availableAt,
          value: ref.value,
        ),
    ];
  }
  final id = (ref as TradeVarRef).variableId;
  return readEvalClockSeries(
    variableId: id,
    asOf: ctx.asOf,
    bars: ctx.bars,
    levels: ctx.levels,
    mathFreeze: ctx.mathFreeze,
    bollN: ctx.bollN,
  );
}

TradeAst _astFromCompiled(CompiledCond c) {
  switch (c) {
    case CompiledCmp(:final left, :final right, :final op):
      return TradeCmpAst(left: left, right: right, op: op);
    case CompiledAnd(:final left, :final right):
      return TradeAndAst(_astFromCompiled(left), _astFromCompiled(right));
    case CompiledOr(:final left, :final right):
      return TradeOrAst(_astFromCompiled(left), _astFromCompiled(right));
  }
}
