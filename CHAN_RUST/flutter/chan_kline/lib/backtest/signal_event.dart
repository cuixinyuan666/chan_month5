import 'trade_clock.dart';
import 'trade_operand.dart';
import 'condition_ast.dart';

/// 策略方向（归一化后的买卖，不是缠论 1Ba）。
enum TradeSide { buy, sell }

/// 触发时变量取值，给「买点/触发时/发现」解释用。
class SignalSnapshot {
  final String label;
  final double? value;

  const SignalSnapshot({required this.label, this.value});
}

/// 穿越边沿 / 条件上升沿 → 归一化后的可交易信号。
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
  /// 整棵条件树文案（界面只展示，不再算一遍）
  final String conditionText;
  /// 触发当步各变量取值
  final List<SignalSnapshot> snapshots;

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
    this.conditionText = '',
    this.snapshots = const [],
  });

  bool get isTradable => side != null && ruleId.isNotEmpty;

  String get explainBlock {
    final sideCn = switch (side) {
      TradeSide.buy => '买点',
      TradeSide.sell => '卖点',
      null => '信号',
    };
    final cond = conditionText.isNotEmpty
        ? conditionText
        : '${compactVarId(leftId)} ${tradeOpToken(op)} ${compactVarId(rightId)}';
    final snapLines = snapshots.isEmpty
        ? <String>[
            '${snapshotVarLabel(leftId)} = ${_fmtNum(leftValue)}',
            if (rightId.isNotEmpty)
              '${snapshotVarLabel(rightId)} = ${_fmtNum(rightValue)}',
          ]
        : [
            for (final s in snapshots)
              '${s.label} = ${s.value == null ? '不可用' : _fmtNum(s.value!)}',
          ];
    return '$sideCn：\n$cond\n\n触发时：\n${snapLines.join('\n')}\n\n发现：\nK0 #$discoveryX';
  }

  SignalEvent copyWith({
    String? signalId,
    String? ruleId,
    TradeSide? side,
    String? source,
    String? conditionText,
    List<SignalSnapshot>? snapshots,
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
      conditionText: conditionText ?? this.conditionText,
      snapshots: snapshots ?? this.snapshots,
    );
  }
}

String _fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  final s = v.toStringAsFixed(4);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
