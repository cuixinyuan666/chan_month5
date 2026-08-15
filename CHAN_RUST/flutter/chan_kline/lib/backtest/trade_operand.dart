import 'signal_data_catalog.dart';
import 'trade_clock.dart';

/// 表达式操作数身份。比较 / 穿越只认 displayKn + clockFamily。
class TradeOperand {
  final String variableId;
  final String displayName;
  final int displayKn;
  final TradeClockFamily clockFamily;
  final TradeEvalClock evalClock;
  final TradePlotClock plotClock;

  const TradeOperand._({
    required this.variableId,
    required this.displayName,
    required this.displayKn,
    required this.clockFamily,
    required this.evalClock,
    required this.plotClock,
  });

  /// 未登记、只盘点、缺钟字段 → 不能当操作数。
  static TradeOperand? tryBind(String variableId, {int maxKn = 8}) {
    final def = lookupTradeVariable(variableId, maxKn: maxKn);
    if (def == null || !def.expressionReady) return null;
    final kn = def.displayKn;
    final eval = def.evalClock;
    final plot = def.plotClock;
    if (kn == null || eval == null || plot == null) return null;
    return TradeOperand._(
      variableId: def.variableId,
      displayName: def.displayName,
      displayKn: kn,
      clockFamily: def.clockFamily,
      evalClock: eval,
      plotClock: plot,
    );
  }
}

/// 比较只编译、不求值；穿越 [crossAbove]/[crossBelow] 由 evalCross 求值。
enum TradeBinaryOp {
  gt,
  lt,
  ge,
  le,
  eq,
  crossAbove,
  crossBelow,
  /// 事件出现一次（发现边沿），不是数值比较
  eventExists,
}

/// 表达式操作数：变量 或 常数。比较/穿越至少一侧必须是变量。
sealed class TradeValueRef {
  const TradeValueRef();
}

/// 目录里的可交易变量，例如 RAW.K1.CLOSE
class TradeVarRef extends TradeValueRef {
  final String variableId;
  const TradeVarRef(this.variableId);
}

/// 字面量，例如 CLOSE > 10 里的 10。钟跟着对面那根变量走。
class TradeConstRef extends TradeValueRef {
  final double value;
  const TradeConstRef(this.value);
}

/// 枚举常量，例如背驰方向 UP / DOWN。不是 double。
class TradeEnumRef extends TradeValueRef {
  final String token;
  const TradeEnumRef(this.token);
}

/// 同层同钟对：外部组不出来，只能 [compileBinaryOp] 成功才有。
class SameClockPair {
  final TradeOperand left;
  final TradeOperand right;

  const SameClockPair._(this.left, this.right);
}

/// 编译结果：合法同钟对，或非法表达式（混层/混钟在编译阶段就灭掉）。
sealed class TradeExprCompile {
  const TradeExprCompile();
}

final class TradeExprOk extends TradeExprCompile {
  final SameClockPair pair;
  final TradeBinaryOp op;

  const TradeExprOk({required this.pair, required this.op});
}

/// 编译失败分类：不要所有错误都叫 invalid。
enum TradeCompileErrorKind {
  type,
  clock,
  unavailable,
  other,
}

final class TradeExprIllegal extends TradeExprCompile {
  /// 白话原因，给以后策略搭积木报错用
  final String reason;
  final TradeCompileErrorKind kind;

  const TradeExprIllegal(
    this.reason, {
    this.kind = TradeCompileErrorKind.other,
  });
}

/// 变量或常数比较/穿越：钟由变量一侧决定；两常数非法。
final class TradeValueExprOk extends TradeExprCompile {
  /// 这对操作数共用的层号/钟
  final TradeOperand clock;
  final TradeOperand? leftOp;
  final TradeOperand? rightOp;
  final TradeValueRef left;
  final TradeValueRef right;
  final TradeBinaryOp op;

  const TradeValueExprOk({
    required this.clock,
    required this.leftOp,
    required this.rightOp,
    required this.left,
    required this.right,
    required this.op,
  });
}

/// 比较 / CROSS 的唯一入口：过不了同钟门禁就是非法表达式，不会进入求值。
TradeExprCompile compileBinaryOp({
  required String leftId,
  required String rightId,
  required TradeBinaryOp op,
  int maxKn = 8,
}) {
  final a = TradeOperand.tryBind(leftId, maxKn: maxKn);
  final b = TradeOperand.tryBind(rightId, maxKn: maxKn);
  if (a == null || b == null) {
    return _unboundExpr(leftId, rightId, maxKn);
  }
  if (_isEventOperand(a, maxKn) || _isEventOperand(b, maxKn)) {
    return const TradeExprIllegal(
      '事件不能比较或穿越，请用「出现」条件（EVENT_EXISTS）',
      kind: TradeCompileErrorKind.type,
    );
  }
  if (_isEnumOperand(a, maxKn) || _isEnumOperand(b, maxKn)) {
    if (op != TradeBinaryOp.eq) {
      return const TradeExprIllegal(
        '方向这类枚举只能用等于，不能比大小或上穿下穿',
        kind: TradeCompileErrorKind.type,
      );
    }
    if (!_isEnumOperand(a, maxKn) || !_isEnumOperand(b, maxKn)) {
      return const TradeExprIllegal(
        '方向只能和方向常量或同类枚举比较，不能和数字混比',
        kind: TradeCompileErrorKind.type,
      );
    }
  }
  if (a.displayKn != b.displayKn || a.clockFamily != b.clockFamily) {
    return TradeExprIllegal(
      '${a.displayName} 和 ${b.displayName} 不是同一层同一套钟，'
      '不能直接比较或穿越（禁止用铺平后的K0格子混钟）',
      kind: TradeCompileErrorKind.clock,
    );
  }
  if (a.evalClock != b.evalClock) {
    return TradeExprIllegal(
      '${a.displayName} 和 ${b.displayName} 计算钟不同，'
      '条件只能在各自 evalClock 上算',
      kind: TradeCompileErrorKind.clock,
    );
  }
  return TradeExprOk(pair: SameClockPair._(a, b), op: op);
}

/// 兼容：能否组成比较/穿越（内部走编译门禁，不是运行时再判）。
bool canCombineInExpression(String idA, String idB, {int maxKn = 8}) {
  return compileBinaryOp(
    leftId: idA,
    rightId: idB,
    op: TradeBinaryOp.gt,
    maxKn: maxKn,
  ) is TradeExprOk;
}

/// 变量 vs 变量走同层同钟；变量 vs 常数继承变量的钟；常数 vs 常数非法。
TradeExprCompile compileValuePair({
  required TradeValueRef left,
  required TradeValueRef right,
  required TradeBinaryOp op,
  int maxKn = 8,
}) {
  final leftVar = left is TradeVarRef;
  final rightVar = right is TradeVarRef;
  final leftEnum = left is TradeEnumRef;
  final rightEnum = right is TradeEnumRef;
  if (leftEnum || rightEnum) {
    if (op != TradeBinaryOp.eq) {
      return const TradeExprIllegal(
        '方向这类枚举只能用等于，不能比大小或上穿下穿',
        kind: TradeCompileErrorKind.type,
      );
    }
    if (!leftVar && !rightVar) {
      return const TradeExprIllegal(
        '两个方向常量不能比较，至少一侧必须是变量',
        kind: TradeCompileErrorKind.type,
      );
    }
    final varRef = leftVar ? left as TradeVarRef : right as TradeVarRef;
    final bound = TradeOperand.tryBind(varRef.variableId, maxKn: maxKn);
    if (bound == null) {
      return _unboundOne(varRef.variableId, maxKn);
    }
    if (!_isEnumOperand(bound, maxKn)) {
      return const TradeExprIllegal(
        '只有背驰方向这类枚举才能和方向常量比较',
        kind: TradeCompileErrorKind.type,
      );
    }
    return TradeValueExprOk(
      clock: bound,
      leftOp: leftVar ? bound : null,
      rightOp: rightVar ? bound : null,
      left: left,
      right: right,
      op: op,
    );
  }
  if (!leftVar && !rightVar) {
    return const TradeExprIllegal(
      '常数和常数不能比较，至少一侧必须是变量',
      kind: TradeCompileErrorKind.type,
    );
  }
  if (leftVar && rightVar) {
    final bin = compileBinaryOp(
      leftId: (left as TradeVarRef).variableId,
      rightId: (right as TradeVarRef).variableId,
      op: op,
      maxKn: maxKn,
    );
    if (bin is TradeExprIllegal) return bin;
    final ok = bin as TradeExprOk;
    return TradeValueExprOk(
      clock: ok.pair.left,
      leftOp: ok.pair.left,
      rightOp: ok.pair.right,
      left: left,
      right: right,
      op: op,
    );
  }
  final varRef = leftVar ? left as TradeVarRef : right as TradeVarRef;
  final bound = TradeOperand.tryBind(varRef.variableId, maxKn: maxKn);
  if (bound == null) {
    return _unboundOne(varRef.variableId, maxKn);
  }
  if (_isEventOperand(bound, maxKn)) {
    return const TradeExprIllegal(
      '事件不能和常数比较，请用「出现」条件（EVENT_EXISTS）',
      kind: TradeCompileErrorKind.type,
    );
  }
  if (_isEnumOperand(bound, maxKn)) {
    return const TradeExprIllegal(
      '方向只能和「向上/向下」比较，不能和数字比',
      kind: TradeCompileErrorKind.type,
    );
  }
  return TradeValueExprOk(
      clock: bound,
      leftOp: leftVar ? bound : null,
      rightOp: rightVar ? bound : null,
      left: left,
      right: right,
      op: op,
    );
}

bool _isEventOperand(TradeOperand op, int maxKn) {
  final def = lookupTradeVariable(op.variableId, maxKn: maxKn);
  return def != null && def.valueType == TradeValueType.event;
}

bool _isEnumOperand(TradeOperand op, int maxKn) {
  final def = lookupTradeVariable(op.variableId, maxKn: maxKn);
  return def != null && def.valueType == TradeValueType.enumeration;
}

TradeExprIllegal _unboundExpr(String leftId, String rightId, int maxKn) {
  final da = lookupTradeVariable(leftId, maxKn: maxKn);
  final db = lookupTradeVariable(rightId, maxKn: maxKn);
  if (da?.readiness == TradeReadiness.inventoryOnly ||
      db?.readiness == TradeReadiness.inventoryOnly) {
    return const TradeExprIllegal(
      '只盘点还不能当条件（整个对象/关系请用投影字段，例如中枢低、背驰力度比）',
      kind: TradeCompileErrorKind.unavailable,
    );
  }
  return const TradeExprIllegal(
    '未登记进交易目录，或只盘点还不能当条件',
    kind: TradeCompileErrorKind.unavailable,
  );
}

TradeExprIllegal _unboundOne(String variableId, int maxKn) {
  final d = lookupTradeVariable(variableId, maxKn: maxKn);
  if (d?.readiness == TradeReadiness.inventoryOnly) {
    return const TradeExprIllegal(
      '只盘点还不能当条件（整个对象/关系请用投影字段，例如中枢低、背驰力度比）',
      kind: TradeCompileErrorKind.unavailable,
    );
  }
  return const TradeExprIllegal(
    '未登记进交易目录，或只盘点还不能当条件',
    kind: TradeCompileErrorKind.unavailable,
  );
}
