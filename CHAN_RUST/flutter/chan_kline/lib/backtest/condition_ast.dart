import 'divergence_relation.dart';
import 'signal_data_catalog.dart';
import 'trade_operand.dart';

/// 策略条件 AST。真假只由引擎按这棵树求值，界面只负责搭树。
sealed class TradeAst {
  const TradeAst();
}

/// 叶子：A 比较/穿越 B
class TradeCmpAst extends TradeAst {
  final TradeValueRef left;
  final TradeValueRef right;
  final TradeBinaryOp op;

  const TradeCmpAst({
    required this.left,
    required this.right,
    required this.op,
  });
}

/// 叶子：某事件在当根首次出现（EVENT_EXISTS）
class TradeEventAst extends TradeAst {
  final String variableId;
  const TradeEventAst(this.variableId);
}

/// 并且：左右都真才真（按计算钟对齐后的样本）
class TradeAndAst extends TradeAst {
  final TradeAst left;
  final TradeAst right;
  const TradeAndAst(this.left, this.right);
}

/// 或者：左右有一个真就真
class TradeOrAst extends TradeAst {
  final TradeAst left;
  final TradeAst right;
  const TradeOrAst(this.left, this.right);
}

/// 界面两条叶子之间的连接词（左结合链：((c1 AND c2) OR c3)）
enum CondJoin { and, or }

/// 第一批可进公式的变量（先证明契约→UI→AST→回测，不塞 MACD/RSI/买卖点）
class StrategyVarSpec {
  /// CLOSE / OPEN / HIGH / LOW / BOLL.MID / BOLL.UP / BOLL.DOWN
  final String key;
  final String label;
  final bool isBoll;

  const StrategyVarSpec({
    required this.key,
    required this.label,
    required this.isBoll,
  });

  String idOf(int kn) =>
      isBoll ? bollBandId(kn, key.split('.').last) : rawOhlcId(kn, key);
}

const List<StrategyVarSpec> kStrategyFirstBatch = [
  StrategyVarSpec(key: 'CLOSE', label: '收盘', isBoll: false),
  StrategyVarSpec(key: 'OPEN', label: '开盘', isBoll: false),
  StrategyVarSpec(key: 'HIGH', label: '最高', isBoll: false),
  StrategyVarSpec(key: 'LOW', label: '最低', isBoll: false),
  StrategyVarSpec(key: 'BOLL.MID', label: '布林中轨', isBoll: true),
  StrategyVarSpec(key: 'BOLL.UP', label: '布林上轨', isBoll: true),
  StrategyVarSpec(key: 'BOLL.DOWN', label: '布林下轨', isBoll: true),
];

const TradeCmpAst kDefaultBollBuyAst = TradeCmpAst(
  left: TradeVarRef('RAW.K0.CLOSE'),
  right: TradeVarRef('MAIN.K0.BOLL.DOWN'),
  op: TradeBinaryOp.crossBelow,
);

const TradeCmpAst kDefaultBollSellAst = TradeCmpAst(
  left: TradeVarRef('RAW.K0.CLOSE'),
  right: TradeVarRef('MAIN.K0.BOLL.UP'),
  op: TradeBinaryOp.crossAbove,
);

/// 该层收盘下穿该层布林下轨
TradeCmpAst bollBuyAst(int kn) => TradeCmpAst(
      left: TradeVarRef(rawOhlcId(kn, 'CLOSE')),
      right: TradeVarRef(bollBandId(kn, 'DOWN')),
      op: TradeBinaryOp.crossBelow,
    );

/// 该层收盘上穿该层布林上轨
TradeCmpAst bollSellAst(int kn) => TradeCmpAst(
      left: TradeVarRef(rawOhlcId(kn, 'CLOSE')),
      right: TradeVarRef(bollBandId(kn, 'UP')),
      op: TradeBinaryOp.crossAbove,
    );

/// 综合策略买：K1 收下穿下轨 并且 收盘低于中轨
TradeAst k1CompositeBuyAst() => TradeAndAst(
      bollBuyAst(1),
      TradeCmpAst(
        left: const TradeVarRef('RAW.K1.CLOSE'),
        right: const TradeVarRef('MAIN.K1.BOLL.MID'),
        op: TradeBinaryOp.lt,
      ),
    );

/// 综合策略卖：K1 收上穿上轨 或者 收盘高于中轨
TradeAst k1CompositeSellAst() => TradeOrAst(
      bollSellAst(1),
      TradeCmpAst(
        left: const TradeVarRef('RAW.K1.CLOSE'),
        right: const TradeVarRef('MAIN.K1.BOLL.MID'),
        op: TradeBinaryOp.gt,
      ),
    );

/// 综合策略买：K1 MACD DIF 上穿 DEA 并且 RSI < 50
TradeAst k1MacdRsiBuyAst() => TradeAndAst(
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.MACD.DIF'),
        right: TradeVarRef('SUB.K1.MACD.DEA'),
        op: TradeBinaryOp.crossAbove,
      ),
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.RSI.VALUE'),
        right: TradeConstRef(50),
        op: TradeBinaryOp.lt,
      ),
    );

/// 综合策略卖：K1 MACD DIF 下穿 DEA 或者 RSI > 70
TradeAst k1MacdRsiSellAst() => TradeOrAst(
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.MACD.DIF'),
        right: TradeVarRef('SUB.K1.MACD.DEA'),
        op: TradeBinaryOp.crossBelow,
      ),
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.RSI.VALUE'),
        right: TradeConstRef(70),
        op: TradeBinaryOp.gt,
      ),
    );

/// 成交量 vs 常数（K1 成交量本阶段不登记，只用 K0）
TradeCmpAst k0VolumeGtAst(double threshold) => TradeCmpAst(
      left: const TradeVarRef('RAW.K0.VOLUME'),
      right: TradeConstRef(threshold),
      op: TradeBinaryOp.gt,
    );

/// K1 一类买点出现
const TradeEventAst k1Buy1EventAst = TradeEventAst('STRUCTURE.K1.BUY1');

/// K1 一类卖点出现
const TradeEventAst k1Sell1EventAst = TradeEventAst('STRUCTURE.K1.SELL1');

/// 买：K1 一类买点 并且 RSI < 50
TradeAst k1Buy1AndRsiAst() => TradeAndAst(
      k1Buy1EventAst,
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.RSI.VALUE'),
        right: TradeConstRef(50),
        op: TradeBinaryOp.lt,
      ),
    );

/// 卖：K1 一类卖点 或者 MACD DIF 下穿 DEA
TradeAst k1Sell1OrMacdAst() => TradeOrAst(
      k1Sell1EventAst,
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.MACD.DIF'),
        right: TradeVarRef('SUB.K1.MACD.DEA'),
        op: TradeBinaryOp.crossBelow,
      ),
    );

/// 买：K1 一类买点 并且 该层确认背驰出现
TradeAst k1Buy1AndDiverAst() => TradeAndAst(
      k1Buy1EventAst,
      TradeEventAst(diverExistsId(1)),
    );

/// 买：K1 背驰力度比 < 0.8 并且 RSI < 50
TradeAst k1DiverRatioAndRsiAst() => TradeAndAst(
      TradeCmpAst(
        left: TradeVarRef(diverRatioId(1)),
        right: const TradeConstRef(0.8),
        op: TradeBinaryOp.lt,
      ),
      const TradeCmpAst(
        left: TradeVarRef('SUB.K1.RSI.VALUE'),
        right: TradeConstRef(50),
        op: TradeBinaryOp.lt,
      ),
    );

/// 买：K1 一类买点 并且 收盘低于当前确认中枢低
TradeAst k1Buy1AndZsLowAst() => const TradeAndAst(
      k1Buy1EventAst,
      TradeCmpAst(
        left: TradeVarRef('RAW.K1.CLOSE'),
        right: TradeVarRef('STRUCTURE.K1.ZS.CURRENT.LOW'),
        op: TradeBinaryOp.lt,
      ),
    );

/// 卖：K1 一类卖点 或者 收盘上穿当前确认中枢高
TradeAst k1Sell1OrZsHighAst() => const TradeOrAst(
      k1Sell1EventAst,
      TradeCmpAst(
        left: TradeVarRef('RAW.K1.CLOSE'),
        right: TradeVarRef('STRUCTURE.K1.ZS.CURRENT.HIGH'),
        op: TradeBinaryOp.crossAbove,
      ),
    );

/// 给人看的操作符：比较用符号，穿越用 CROSS_ABOVE / CROSS_BELOW
String tradeOpToken(TradeBinaryOp op) {
  return switch (op) {
    TradeBinaryOp.gt => '>',
    TradeBinaryOp.lt => '<',
    TradeBinaryOp.ge => '>=',
    TradeBinaryOp.le => '<=',
    TradeBinaryOp.eq => '==',
    TradeBinaryOp.crossAbove => 'CROSS_ABOVE',
    TradeBinaryOp.crossBelow => 'CROSS_BELOW',
    TradeBinaryOp.eventExists => 'EVENT_EXISTS',
  };
}

String tradeOpLabelCn(TradeBinaryOp op) {
  return switch (op) {
    TradeBinaryOp.gt => '>',
    TradeBinaryOp.lt => '<',
    TradeBinaryOp.ge => '>=',
    TradeBinaryOp.le => '<=',
    TradeBinaryOp.eq => '==',
    TradeBinaryOp.crossAbove => '上穿',
    TradeBinaryOp.crossBelow => '下穿',
    TradeBinaryOp.eventExists => '出现',
  };
}

/// RAW.K1.CLOSE → K1.CLOSE；MAIN.K1.BOLL.DOWN → K1.BOLL.DOWN
String compactVarId(String variableId) {
  final parts = variableId.split('.');
  if (parts.length >= 3 && parts[1].startsWith('K')) {
    return parts.sublist(1).join('.');
  }
  return variableId;
}

String tradeValueLabel(TradeValueRef ref) {
  if (ref is TradeConstRef) {
    final v = ref.value;
    if (v == v.roundToDouble()) return '${v.toInt()}';
    return '$v';
  }
  if (ref is TradeEnumRef) {
    final d = divergenceDirectionFromToken(ref.token);
    return d == null ? ref.token : divergenceDirectionCn(d);
  }
  if (ref is TradeVarRef) return compactVarId(ref.variableId);
  return '?';
}

/// 触发时快照标签：K1 CLOSE / K1 BOLL.DOWN
String snapshotVarLabel(String variableId) {
  final parts = variableId.split('.');
  if (parts.length >= 3 && parts[1].startsWith('K')) {
    return '${parts[1]} ${parts.sublist(2).join('.')}';
  }
  return variableId;
}

/// 多行条件文案（AND/OR 单独一行），给信号解释用
String astConditionText(TradeAst ast, {String? parentKind}) {
  switch (ast) {
    case TradeCmpAst(:final left, :final right, :final op):
      return '${tradeValueLabel(left)} ${tradeOpToken(op)} ${tradeValueLabel(right)}';
    case TradeEventAst(:final variableId):
      return '${compactVarId(variableId)} EVENT_EXISTS';
    case TradeAndAst(:final left, :final right):
      final inner =
          '${astConditionText(left, parentKind: 'and')}\nAND\n${astConditionText(right, parentKind: 'and')}';
      return parentKind != null && parentKind != 'and' ? '($inner)' : inner;
    case TradeOrAst(:final left, :final right):
      final inner =
          '${astConditionText(left, parentKind: 'or')}\nOR\n${astConditionText(right, parentKind: 'or')}';
      return parentKind != null && parentKind != 'or' ? '($inner)' : inner;
  }
}

void collectAstVarIds(TradeAst ast, List<String> out) {
  switch (ast) {
    case TradeCmpAst(:final left, :final right):
      if (left is TradeVarRef) out.add(left.variableId);
      if (right is TradeVarRef) out.add(right.variableId);
    case TradeEventAst(:final variableId):
      out.add(variableId);
    case TradeAndAst(:final left, :final right):
      collectAstVarIds(left, out);
      collectAstVarIds(right, out);
    case TradeOrAst(:final left, :final right):
      collectAstVarIds(left, out);
      collectAstVarIds(right, out);
  }
}

int? maxKnInAst(TradeAst ast) {
  final ids = <String>[];
  collectAstVarIds(ast, ids);
  var max = -1;
  for (final id in ids) {
    final parts = id.split('.');
    if (parts.length < 2 || !parts[1].startsWith('K')) continue;
    final kn = int.tryParse(parts[1].substring(1));
    if (kn != null && kn > max) max = kn;
  }
  return max < 0 ? null : max;
}

({int kn, String key})? parseFirstBatchId(String variableId) {
  final parts = variableId.split('.');
  if (parts.length < 3 || !parts[1].startsWith('K')) return null;
  final kn = int.tryParse(parts[1].substring(1));
  if (kn == null) return null;
  if (parts[0] == 'RAW' && parts.length == 3) {
    final key = parts[2];
    const ohlc = {'CLOSE', 'OPEN', 'HIGH', 'LOW'};
    if (ohlc.contains(key)) return (kn: kn, key: key);
  }
  if (parts[0] == 'MAIN' &&
      parts.length == 4 &&
      parts[2] == 'BOLL') {
    return (kn: kn, key: 'BOLL.${parts[3]}');
  }
  return null;
}

StrategyVarSpec? specByKey(String key) {
  for (final s in kStrategyFirstBatch) {
    if (s.key == key) return s;
  }
  return null;
}

/// 把 AST 摊成左结合叶子链，给界面编辑用（求值仍走原树）
({List<TradeAst> leaves, List<CondJoin> joins}) flattenAstChain(
  TradeAst ast,
) {
  if (ast is TradeCmpAst || ast is TradeEventAst) {
    return (leaves: [ast], joins: <CondJoin>[]);
  }
  if (ast is TradeAndAst) {
    final l = flattenAstChain(ast.left);
    final r = flattenAstChain(ast.right);
    return (
      leaves: [...l.leaves, ...r.leaves],
      joins: [...l.joins, CondJoin.and, ...r.joins],
    );
  }
  if (ast is TradeOrAst) {
    final l = flattenAstChain(ast.left);
    final r = flattenAstChain(ast.right);
    return (
      leaves: [...l.leaves, ...r.leaves],
      joins: [...l.joins, CondJoin.or, ...r.joins],
    );
  }
  return (leaves: const <TradeAst>[], joins: <CondJoin>[]);
}

/// 叶子链折回 AST（左结合）
TradeAst foldAstChain(List<TradeAst> leaves, List<CondJoin> joins) {
  if (leaves.isEmpty) return kDefaultBollBuyAst;
  TradeAst acc = leaves.first;
  for (var i = 0; i < joins.length && i + 1 < leaves.length; i++) {
    final next = leaves[i + 1];
    acc = joins[i] == CondJoin.and
        ? TradeAndAst(acc, next)
        : TradeOrAst(acc, next);
  }
  return acc;
}
