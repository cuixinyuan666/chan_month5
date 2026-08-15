import 'trade_clock.dart';
import 'trade_operand.dart';

/// 策略方向（归一化后的买卖，不是缠论 1Ba）。
enum TradeSide { buy, sell }

/// 穿越边沿 → 归一化后的可交易信号。
/// availableAt / discoveryX = 系统当时知道的 K0，不是结构对象的理论位置。
class SignalEvent {
  final String signalId;
  final String ruleId;
  /// 归一化后才有；CROSS 检出时可为 null
  final TradeSide? side;
  final TradeBinaryOp op;
  final int displayKn;
  final TradeClockFamily clockFamily;
  final int evalIndex;
  /// 发现当根 K0（与 availableAt 同义；成交用 discoveryX+1）
  final int discoveryX;
  /// 当时能知道这根样本的 K0
  final int availableAt;
  final double signalPrice;
  final String source;
  final double leftValue;
  final double rightValue;
  final String leftId;
  final String rightId;

  const SignalEvent({
    required this.signalId,
    required this.ruleId,
    required this.side,
    required this.op,
    required this.displayKn,
    required this.clockFamily,
    required this.evalIndex,
    required this.discoveryX,
    required this.availableAt,
    required this.signalPrice,
    required this.source,
    required this.leftValue,
    required this.rightValue,
    required this.leftId,
    required this.rightId,
  });

  bool get isTradable => side != null && ruleId.isNotEmpty;

  SignalEvent copyWith({
    String? signalId,
    String? ruleId,
    TradeSide? side,
    String? source,
  }) {
    return SignalEvent(
      signalId: signalId ?? this.signalId,
      ruleId: ruleId ?? this.ruleId,
      side: side ?? this.side,
      op: op,
      displayKn: displayKn,
      clockFamily: clockFamily,
      evalIndex: evalIndex,
      discoveryX: discoveryX,
      availableAt: availableAt,
      signalPrice: signalPrice,
      source: source ?? this.source,
      leftValue: leftValue,
      rightValue: rightValue,
      leftId: leftId,
      rightId: rightId,
    );
  }
}
