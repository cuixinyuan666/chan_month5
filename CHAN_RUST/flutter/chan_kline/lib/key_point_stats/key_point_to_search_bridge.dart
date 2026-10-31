import '../backtest/condition_ast.dart';
import '../backtest/signal_data_catalog.dart';
import '../backtest/trade_operand.dart';
import '../indicator_search/search_core.dart';

import 'key_point_combo_contrast.dart';

/// 计优到寻优的桥：把「哪几个指标一起看顶底分得最开」翻译成可回测的买卖条件。
///
/// 两套命名对不上：计优读冻结账的键（`sub.rsi_1`），寻优用交易变量
/// （`SUB.K1.RSI.VALUE`）。这里做翻译，并按顶底方向给出条件：
/// 顶上更高的指标，用「高于中位」当卖出、用「低于中位」当买入，反过来同理。
/// 这样计优找出的组合能直接丢进寻优验证「能不能赚钱、样本外稳不稳」。

/// 一个计优键翻译出的交易变量。翻译不了返回 null。
String? tradeVarIdOf(String statKey) {
  final m = RegExp(r'^sub\.(rsi|macd_dif|macd_dea|macd_hist|kdj_k|kdj_d|kdj_j)_(\d+)$')
      .firstMatch(statKey);
  if (m == null) return null;
  final kind = m.group(1)!;
  final kn = int.parse(m.group(2)!);
  switch (kind) {
    case 'rsi':
      return rsiValueId(kn);
    case 'macd_dif':
      return macdFieldId(kn, 'DIF');
    case 'macd_dea':
      return macdFieldId(kn, 'DEA');
    case 'macd_hist':
      return macdFieldId(kn, 'HIST');
    case 'kdj_k':
      return kdjFieldId(kn, 'K');
    case 'kdj_d':
      return kdjFieldId(kn, 'D');
    case 'kdj_j':
      return kdjFieldId(kn, 'J');
  }
  return null;
}

/// 把一个组合区分度结果翻译成一条寻优候选。
///
/// [midpoints] 给出每个指标的分界值（通常取顶底两组均值的中点）。
/// 组合里任何一个指标翻译不了或没有分界值，整条返回 null，不产出半截条件。
ComboCand? searchCandidateFromCombo(
  KeyPointComboContrast combo,
  Map<String, double> midpoints,
) {
  TradeAst? buy;
  TradeAst? sell;
  for (var i = 0; i < combo.metricKeys.length; i++) {
    final key = combo.metricKeys[i];
    final varId = tradeVarIdOf(key);
    final mid = midpoints[key];
    if (varId == null || mid == null) return null;
    final higherOnTop = combo.topHigher[i];
    // 买入站在「偏向底」的一侧，卖出站在「偏向顶」的一侧。
    final buyOp = higherOnTop ? TradeBinaryOp.lt : TradeBinaryOp.gt;
    final sellOp = higherOnTop ? TradeBinaryOp.gt : TradeBinaryOp.lt;
    buy = _and(buy, _cmp(varId, mid, buyOp));
    sell = _and(sell, _cmp(varId, mid, sellOp));
  }
  if (buy == null || sell == null) return null;
  return ComboCand('计优组合｜${combo.ruleText}', buy, sell);
}

TradeAst _cmp(String varId, double mid, TradeBinaryOp op) => TradeCmpAst(
      left: TradeVarRef(varId),
      right: TradeConstRef(mid),
      op: op,
    );

TradeAst _and(TradeAst? acc, TradeAst next) =>
    acc == null ? next : TradeAndAst(acc, next);
