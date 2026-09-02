import '../compute/math_series_freeze_store.dart';
import '../models/bar_feature_lookup.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'buy_n_var.dart';
import 'catalog_lookup.dart';
import 'chan_event_store.dart';
import 'chart_line_store.dart';
import 'chip_peak_store.dart';
import 'condition_ast.dart';
import 'condition_trace.dart';
import 'divergence_relation.dart';
import 'divergence_relation_store.dart';
import 'signal_data_catalog.dart';
import 'signal_event.dart';
import 'trade_clock.dart';
import 'trade_operand.dart';
import 'trade_value.dart';
import 'zhongshu_object_store.dart';

/// 编译后的钟身份：比较/RSI 等 AND/OR 仍须同一层同一套钟。
/// K0 当根事件（一类/二类/N类、分型确认/判断、中枢确认/判断、背驰出现、Demark完成）
/// 可以跨层 AND/OR；拼过之后不能再跟某一层的 RSI/收盘混。
class CompiledClock {
  final int displayKn;
  final TradeClockFamily family;
  final TradeEvalClock evalClock;
  /// 这棵子树已经把不同层或不同钟族的 K0 当根事件拼在一起。
  final bool crossKnBs;

  const CompiledClock({
    required this.displayKn,
    required this.family,
    required this.evalClock,
    this.crossKnBs = false,
  });

  bool sameAs(CompiledClock o) =>
      displayKn == o.displayKn &&
      family == o.family &&
      evalClock == o.evalClock &&
      crossKnBs == o.crossKnBs;
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
  final TradeCompileErrorKind kind;
  const CondCompileIllegal(
    this.reason, {
    this.kind = TradeCompileErrorKind.other,
  });
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
  final CompiledClock _clock;

  const CompiledAnd(this.left, this.right, this._clock);

  @override
  CompiledClock get clock => _clock;

  @override
  String get label => astConditionText(TradeAndAst(
        _astFromCompiled(left),
        _astFromCompiled(right),
      ));
}

final class CompiledOr extends CompiledCond {
  final CompiledCond left;
  final CompiledCond right;
  final CompiledClock _clock;

  const CompiledOr(this.left, this.right, this._clock);

  @override
  CompiledClock get clock => _clock;

  @override
  String get label => astConditionText(TradeOrAst(
        _astFromCompiled(left),
        _astFromCompiled(right),
      ));
}

final class CompiledEvent extends CompiledCond {
  final String variableId;
  final TradeOperand clockOp;

  const CompiledEvent({required this.variableId, required this.clockOp});

  @override
  CompiledClock get clock => CompiledClock(
        displayKn: clockOp.displayKn,
        family: clockOp.clockFamily,
        evalClock: clockOp.evalClock,
      );

  @override
  String get label => astConditionText(TradeEventAst(variableId));
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
      if (r is TradeExprIllegal) {
        return CondCompileIllegal(r.reason, kind: r.kind);
      }
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
    case TradeEventAst(:final variableId):
      return _compileEvent(variableId, maxKn: maxKn);
  }
}

CondCompileResult _compileEvent(String variableId, {required int maxKn}) {
  if (!isRegisteredEventVar(variableId, maxKn: maxKn)) {
    final def = lookupTradeVariable(variableId, maxKn: maxKn);
    if (def?.readiness == TradeReadiness.inventoryOnly) {
      return const CondCompileIllegal(
        '只盘点还不能当条件',
        kind: TradeCompileErrorKind.unavailable,
      );
    }
    return const CondCompileIllegal(
      '未登记的事件变量，或还不能当条件',
      kind: TradeCompileErrorKind.unavailable,
    );
  }
  final bound = TradeOperand.tryBind(variableId, maxKn: maxKn);
  if (bound == null) {
    return const CondCompileIllegal(
      '未登记进交易目录，或只盘点还不能当条件',
      kind: TradeCompileErrorKind.unavailable,
    );
  }
  return CondCompileOk(CompiledEvent(variableId: variableId, clockOp: bound));
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
  if (!_clocksJoinable(l, r)) {
    return CondCompileIllegal(
      '条件里混了不同层或不同钟，不能 ${and ? 'AND' : 'OR'} 在一起'
      '（一类/二类/N类、分型确认/判断、中枢确认/判断、背驰出现、Demark完成'
      '可以跨层拼；收盘/RSI/布林仍须同层同钟；分型确认不能和 RSI 直接拼）',
      kind: TradeCompileErrorKind.clock,
    );
  }
  final clock = _joinClock(l, r);
  return CondCompileOk(
    and ? CompiledAnd(l, r, clock) : CompiledOr(l, r, clock),
  );
}

bool _involvesEvent(CompiledCond c) {
  return switch (c) {
    CompiledEvent() => true,
    CompiledAnd(:final left, :final right) =>
      _involvesEvent(left) || _involvesEvent(right),
    CompiledOr(:final left, :final right) =>
      _involvesEvent(left) || _involvesEvent(right),
    CompiledCmp() => false,
  };
}

/// 整棵子树都是「K0 当根出现」的事件（可含它们之间的 AND/OR）。
bool _isPureK0BarEventTree(CompiledCond c) {
  return switch (c) {
    CompiledEvent(:final clockOp) =>
      clockOp.evalClock == TradeEvalClock.k0Bar,
    CompiledAnd(:final left, :final right) =>
      _isPureK0BarEventTree(left) && _isPureK0BarEventTree(right),
    CompiledOr(:final left, :final right) =>
      _isPureK0BarEventTree(left) && _isPureK0BarEventTree(right),
    CompiledCmp() => false,
  };
}

bool _clocksJoinable(CompiledCond a, CompiledCond b) {
  // 发现都钉在 K0 当根：层号/钟族只标明哪一层打出来的，允许跨层 AND/OR。
  if (_isPureK0BarEventTree(a) && _isPureK0BarEventTree(b)) return true;
  // 已经跨层或跨钟族拼过的事件树，不能再跟某一层 RSI/收盘混。
  if (a.clock.crossKnBs || b.clock.crossKnBs) return false;
  if (a.clock.sameAs(b.clock)) return true;
  if (a.clock.displayKn != b.clock.displayKn) return false;
  if (a.clock.family != b.clock.family) return false;
  return _involvesEvent(a) || _involvesEvent(b);
}

CompiledClock _joinClock(CompiledCond a, CompiledCond b) {
  if (_isPureK0BarEventTree(a) && _isPureK0BarEventTree(b)) {
    final cross = a.clock.displayKn != b.clock.displayKn ||
        a.clock.family != b.clock.family ||
        a.clock.crossKnBs ||
        b.clock.crossKnBs;
    return CompiledClock(
      displayKn: a.clock.displayKn,
      family: a.clock.family,
      evalClock: TradeEvalClock.k0Bar,
      crossKnBs: cross,
    );
  }
  if (_involvesEvent(a) && a.clock.evalClock == TradeEvalClock.k0Bar) {
    return a.clock;
  }
  if (_involvesEvent(b) && b.clock.evalClock == TradeEvalClock.k0Bar) {
    return b.clock;
  }
  return a.clock;
}

class CondEvalCtx {
  final int asOf;
  final List<KlineBar> bars;
  final List<LevelBundle> levels;
  final MathSeriesFreezeStore? mathFreeze;
  final ChanEventStore chanEvents;
  final ZhongshuObjectStore? zsObjects;
  final DivergenceRelationStore? diverRelations;
  final ChartLineStore? lineSeries;
  final BarFeatureLookup? features;
  final ChipPeakFreezeStore? chipPeaks;
  final double bucketStep;
  final int bollN;
  final int maxKn;

  const CondEvalCtx({
    required this.asOf,
    required this.bars,
    this.levels = const [],
    this.mathFreeze,
    this.chanEvents = ChanEventStore.empty,
    this.zsObjects,
    this.diverRelations,
    this.lineSeries,
    this.features,
    this.chipPeaks,
    this.bucketStep = 0.1,
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
  final ConditionTrace trace;

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
    required this.trace,
  });
}

/// 在 evalClock 上求值 → 布尔序列 → 出信号。界面不再算一遍。
/// 状态比较（收盘>均线）：假变真，连着真只打第一次。
/// 分型确认等事件：当根脉冲，连着两颗各打一次（对齐金字塔 CROSS）。
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
    if (!curr.flag) continue;
    // 事件当根各打一次；比较/穿越仍假变真
    if (curr.op != TradeBinaryOp.eventExists && prev) continue;
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
      trace: curr.trace,
    ));
  }
  return out;
}

List<_BoolPt> _eval(CompiledCond cond, CondEvalCtx ctx) {
  switch (cond) {
    case CompiledCmp():
      return _evalCmp(cond, ctx);
    case CompiledEvent():
      return _evalEvent(cond, ctx);
    case CompiledAnd():
      return _combine(
        _eval(cond.left, ctx),
        _eval(cond.right, ctx),
        and: true,
        ctx: ctx,
      );
    case CompiledOr():
      return _combine(
        _eval(cond.left, ctx),
        _eval(cond.right, ctx),
        and: false,
        ctx: ctx,
      );
  }
}

List<_BoolPt> _evalEvent(CompiledEvent cond, CondEvalCtx ctx) {
  final events = listTradeChanEvents(
    variableId: cond.variableId,
    asOf: ctx.asOf,
    store: ctx.chanEvents,
    levels: ctx.levels,
    diverRelations: ctx.diverRelations,
    mathFreeze: ctx.mathFreeze,
    maxKn: ctx.maxKn,
  );
  final at = <int, TradeChanEvent>{
    for (final e in events) e.availableAt: e,
  };
  final out = <_BoolPt>[];
  var i = 0;
  for (final b in ctx.bars) {
    if (b.idx > ctx.asOf) continue;
    final ev = at[b.idx];
    final flag = ev != null;
    out.add(_BoolPt(
      evalIndex: i,
      availableAt: b.idx,
      flag: flag,
      signalPrice: ev?.price ?? b.close,
      leftValue: ev?.price ?? 0,
      rightValue: flag ? 1 : 0,
      leftId: cond.variableId,
      rightId: '',
      op: TradeBinaryOp.eventExists,
      snapshots: [
        SignalSnapshot(
          label: snapshotVarLabel(cond.variableId),
          value: flag ? (ev?.price ?? 1) : null,
        ),
      ],
      trace: ConditionTrace(
        op: 'EXISTS',
        flag: flag,
        label: snapshotVarLabel(cond.variableId),
        variableId: cond.variableId,
        value: flag ? 1 : 0,
        objectId: ev?.objectId,
        relationId: ev?.relationId,
      ),
    ));
    i++;
  }
  return out;
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
      trace: _cmpTrace(cond, ctx, a.availableAt, a.value, b.value, flag),
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
    case TradeBinaryOp.eventExists:
      return false;
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
  } else if (cond.left is TradeEnumRef) {
    out.add(SignalSnapshot(
      label: '方向 ${tradeValueLabel(cond.left)}',
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
  } else if (cond.right is TradeEnumRef) {
    out.add(SignalSnapshot(
      label: '方向 ${tradeValueLabel(cond.right)}',
      value: rightVal,
    ));
  }
  return out;
}

List<_BoolPt> _combine(
  List<_BoolPt> left,
  List<_BoolPt> right, {
  required bool and,
  required CondEvalCtx ctx,
}) {
  final eventful = left.any((p) => p.op == TradeBinaryOp.eventExists) ||
      right.any((p) => p.op == TradeBinaryOp.eventExists);
  if (!eventful) {
    return _combineExact(left, right, and: and);
  }
  if (and && (left.isEmpty || right.isEmpty)) return const [];
  if (!and && left.isEmpty) return right;
  if (!and && right.isEmpty) return left;
  return _combineAsOf(left, right, and: and, ctx: ctx);
}

List<_BoolPt> _combineExact(
  List<_BoolPt> left,
  List<_BoolPt> right, {
  required bool and,
}) {
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
      rightValue: b.rightValue,
      leftId: a.leftId,
      rightId: b.rightId,
      op: _preferCrossOp(a, b),
      snapshots: _mergeSnaps(a.snapshots, b.snapshots),
      trace: ConditionTrace(
        op: and ? 'AND' : 'OR',
        flag: flag,
        label: and ? 'AND' : 'OR',
        children: [a.trace, b.trace],
      ),
    ));
  }
  out.sort((x, y) => x.availableAt.compareTo(y.availableAt));
  return out;
}

bool _isPulseOp(TradeBinaryOp op) =>
    op == TradeBinaryOp.eventExists ||
    op == TradeBinaryOp.crossAbove ||
    op == TradeBinaryOp.crossBelow;

bool _flagAt(List<_BoolPt> series, int x) {
  _BoolPt? exact;
  _BoolPt? last;
  for (final p in series) {
    if (p.availableAt > x) continue;
    last = p;
    if (p.availableAt == x) exact = p;
  }
  if (exact != null) return exact.flag;
  if (last == null) return false;
  if (_isPulseOp(last.op)) return false;
  return last.flag;
}

_BoolPt? _ptAt(List<_BoolPt> series, int x) {
  _BoolPt? exact;
  _BoolPt? last;
  for (final p in series) {
    if (p.availableAt > x) continue;
    last = p;
    if (p.availableAt == x) exact = p;
  }
  return exact ?? last;
}

List<_BoolPt> _combineAsOf(
  List<_BoolPt> left,
  List<_BoolPt> right, {
  required bool and,
  required CondEvalCtx ctx,
}) {
  final out = <_BoolPt>[];
  var i = 0;
  for (final b in ctx.bars) {
    if (b.idx > ctx.asOf) continue;
    final x = b.idx;
    final lf = _flagAt(left, x);
    final rf = _flagAt(right, x);
    final flag = and ? (lf && rf) : (lf || rf);
    final a = _ptAt(left, x);
    final bpt = _ptAt(right, x);
    final preferLeftEvent =
        a != null && a.op == TradeBinaryOp.eventExists && lf;
    final src = preferLeftEvent
        ? a
        : (bpt != null && bpt.op == TradeBinaryOp.eventExists && rf)
            ? bpt
            : (lf ? a : (rf ? bpt : a));
    out.add(_BoolPt(
      evalIndex: i,
      availableAt: x,
      flag: flag,
      signalPrice: src?.signalPrice ?? b.close,
      leftValue: a?.leftValue ?? 0,
      rightValue: bpt?.rightValue ?? 0,
      leftId: a?.leftId ?? '',
      rightId: (bpt != null && bpt.leftId.isNotEmpty)
          ? bpt.leftId
          : (bpt?.rightId ?? ''),
      op: a != null && bpt != null
          ? _preferCrossOp(a, bpt)
          : (src?.op ?? TradeBinaryOp.eventExists),
      snapshots: _mergeSnaps(
        a?.snapshots ?? const [],
        bpt?.snapshots ?? const [],
      ),
      trace: ConditionTrace(
        op: and ? 'AND' : 'OR',
        flag: flag,
        label: and ? 'AND' : 'OR',
        children: [
          if (a != null) a.trace,
          if (bpt != null) bpt.trace,
        ],
      ),
    ));
    i++;
  }
  return out;
}

TradeBinaryOp _preferCrossOp(_BoolPt a, _BoolPt b) {
  if (a.flag && a.op == TradeBinaryOp.eventExists) return a.op;
  if (b.flag && b.op == TradeBinaryOp.eventExists) return b.op;
  if (a.flag && _isPulseOp(a.op)) return a.op;
  if (b.flag && _isPulseOp(b.op)) return b.op;
  // 真值来自状态比较时，不要把事件/穿越的 op 粘到整段 true 上
  if (a.flag) return a.op;
  if (b.flag) return b.op;
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

ConditionTrace _cmpTrace(
  CompiledCmp cond,
  CondEvalCtx ctx,
  int asOf,
  double leftVal,
  double rightVal,
  bool flag,
) {
  final leftId = cond.left is TradeVarRef
      ? (cond.left as TradeVarRef).variableId
      : null;
  final rightId = cond.right is TradeVarRef
      ? (cond.right as TradeVarRef).variableId
      : null;
  final leftIds = leftId == null
      ? (objectId: null, relationId: null)
      : _structIds(leftId, asOf, ctx);
  final rightIds = rightId == null
      ? (objectId: null, relationId: null)
      : _structIds(rightId, asOf, ctx);
  return ConditionTrace(
    op: tradeOpToken(cond.op),
    flag: flag,
    label: cond.label,
    children: [
      ConditionTrace(
        op: 'VALUE',
        label: tradeValueLabel(cond.left),
        variableId: leftId,
        value: leftVal,
        objectId: leftIds.objectId,
        relationId: leftIds.relationId,
      ),
      ConditionTrace(
        op: 'VALUE',
        label: tradeValueLabel(cond.right),
        variableId: rightId,
        value: rightVal,
        objectId: rightIds.objectId,
        relationId: rightIds.relationId,
      ),
    ],
  );
}

({String? objectId, String? relationId}) _structIds(
  String variableId,
  int asOf,
  CondEvalCtx ctx,
) {
  final id = canonicalizeTradeVarId(variableId);
  final kn = knFromVariableId(id);
  if (kn == null) return (objectId: null, relationId: null);
  if (id.contains('.ZS.CURRENT') && ctx.zsObjects != null) {
    final zs = ctx.zsObjects!.resolveCurrentConfirmedZs(
      displayKn: kn,
      asOf: asOf,
    );
    return (objectId: zs?.objectId, relationId: null);
  }
  if (id.contains('.ZS.ACTIVE') && ctx.zsObjects != null) {
    final zs = ctx.zsObjects!.resolveCurrentActiveZs(
      displayKn: kn,
      asOf: asOf,
    );
    return (objectId: zs?.objectId, relationId: null);
  }
  if (id.contains('.DIVERGENCE') && ctx.diverRelations != null) {
    final rel = ctx.diverRelations!.resolveCurrent(displayKn: kn, asOf: asOf);
    return (objectId: null, relationId: rel?.relationId);
  }
  return (objectId: null, relationId: null);
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
      zsObjects: ctx.zsObjects,
      diverRelations: ctx.diverRelations,
      lineSeries: ctx.lineSeries,
      features: ctx.features,
      chipPeaks: ctx.chipPeaks,
      bucketStep: ctx.bucketStep,
      k0Confirms: ctx.chanEvents.k0FractalConfirms,
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
  if (ref is TradeEnumRef) {
    final dir = divergenceDirectionFromToken(ref.token);
    final code = dir == null ? 0.0 : divergenceDirectionCode(dir);
    final grid = readEvalClockSeries(
      variableId: clockOp.variableId,
      asOf: ctx.asOf,
      bars: ctx.bars,
      levels: ctx.levels,
      mathFreeze: ctx.mathFreeze,
      zsObjects: ctx.zsObjects,
      diverRelations: ctx.diverRelations,
      lineSeries: ctx.lineSeries,
      features: ctx.features,
      chipPeaks: ctx.chipPeaks,
      bucketStep: ctx.bucketStep,
      k0Confirms: ctx.chanEvents.k0FractalConfirms,
      bollN: ctx.bollN,
    );
    return [
      for (final p in grid)
        EvalClockPoint(
          evalIndex: p.evalIndex,
          availableAt: p.availableAt,
          value: code,
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
    zsObjects: ctx.zsObjects,
    diverRelations: ctx.diverRelations,
    lineSeries: ctx.lineSeries,
    features: ctx.features,
    chipPeaks: ctx.chipPeaks,
    bucketStep: ctx.bucketStep,
    k0Confirms: ctx.chanEvents.k0FractalConfirms,
    bollN: ctx.bollN,
  );
}

TradeAst _astFromCompiled(CompiledCond c) {
  switch (c) {
    case CompiledCmp(:final left, :final right, :final op):
      return TradeCmpAst(left: left, right: right, op: op);
    case CompiledEvent(:final variableId):
      return TradeEventAst(variableId);
    case CompiledAnd(:final left, :final right):
      return TradeAndAst(_astFromCompiled(left), _astFromCompiled(right));
    case CompiledOr(:final left, :final right):
      return TradeOrAst(_astFromCompiled(left), _astFromCompiled(right));
  }
}
