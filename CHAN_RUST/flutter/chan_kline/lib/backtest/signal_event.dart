import 'trade_clock.dart';
import 'trade_operand.dart';

/// 穿越边沿事件（本阶段只有 CROSS，不是策略买卖/订单）。
class SignalEvent {
  final TradeBinaryOp op;
  final int displayKn;
  final TradeClockFamily clockFamily;
  /// 边沿发生在 evalClock 的第几根样本（当前这根，不是上一根）
  final int evalIndex;
  /// 当时能知道这根样本的 K0 索引；成交以后也用这根轴
  final int availableAt;
  final double leftValue;
  final double rightValue;
  final String leftId;
  final String rightId;

  const SignalEvent({
    required this.op,
    required this.displayKn,
    required this.clockFamily,
    required this.evalIndex,
    required this.availableAt,
    required this.leftValue,
    required this.rightValue,
    required this.leftId,
    required this.rightId,
  });
}
