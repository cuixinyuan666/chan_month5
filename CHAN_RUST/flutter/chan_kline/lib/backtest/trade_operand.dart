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

final class TradeExprIllegal extends TradeExprCompile {
  /// 白话原因，给以后策略搭积木报错用
  final String reason;

  const TradeExprIllegal(this.reason);
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
    return const TradeExprIllegal('未登记进交易目录，或只盘点还不能当条件');
  }
  if (a.displayKn != b.displayKn || a.clockFamily != b.clockFamily) {
    return TradeExprIllegal(
      '${a.displayName} 和 ${b.displayName} 不是同一层同一套钟，'
      '不能直接比较或穿越（禁止用铺平后的K0格子混钟）',
    );
  }
  if (a.evalClock != b.evalClock) {
    return TradeExprIllegal(
      '${a.displayName} 和 ${b.displayName} 计算钟不同，'
      '条件只能在各自 evalClock 上算',
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
