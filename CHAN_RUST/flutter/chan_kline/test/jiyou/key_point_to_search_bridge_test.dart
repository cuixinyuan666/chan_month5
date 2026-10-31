import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/key_point_stats/key_point_combo_contrast.dart';
import 'package:chan_kline/key_point_stats/key_point_to_search_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优到寻优的键名桥回归。
///
/// 钉死两件事：冻结账的键能翻译成交易变量；翻译出的候选买卖方向正确
/// （顶上更高的指标，买入取低于分界、卖出取高于分界）。
void main() {
  test('冻结账键翻译成交易变量', () {
    expect(tradeVarIdOf('sub.rsi_1'), 'SUB.K1.RSI.VALUE');
    expect(tradeVarIdOf('sub.macd_dif_2'), 'SUB.K2.MACD.DIF');
    expect(tradeVarIdOf('sub.kdj_k_0'), 'SUB.K0.KDJ.K');
    expect(tradeVarIdOf('sub.unknown_1'), isNull);
    expect(tradeVarIdOf('rsi_1'), isNull);
  });

  test('组合翻译成寻优候选，方向正确', () {
    final combo = KeyPointComboContrast(
      metricKeys: ['sub.rsi_1', 'sub.kdj_k_1'],
      labelCns: ['RSI', 'KDJ K'],
      topHigher: [true, false],
      contrast: 1.8,
      lift: 0.2,
      level: 1,
    );
    final cand = searchCandidateFromCombo(combo, {
      'sub.rsi_1': 50,
      'sub.kdj_k_1': 40,
    });
    expect(cand, isNotNull);
    expect(cand!.name, startsWith('计优组合｜'));

    // 买侧：RSI 顶更高 → 低于 50；KDJ 底更高 → 高于 40。两者用并且连接。
    final buy = cand.buyAst as TradeAndAst;
    final buyRsi = buy.left as TradeCmpAst;
    expect((buyRsi.left as TradeVarRef).variableId, 'SUB.K1.RSI.VALUE');
    expect(buyRsi.op, TradeBinaryOp.lt);
    final buyKdj = buy.right as TradeCmpAst;
    expect(buyKdj.op, TradeBinaryOp.gt);

    // 卖侧方向相反。
    final sell = cand.sellAst as TradeAndAst;
    expect((sell.left as TradeCmpAst).op, TradeBinaryOp.gt);
    expect((sell.right as TradeCmpAst).op, TradeBinaryOp.lt);
  });

  test('有指标翻译不了时整条不产出', () {
    final combo = KeyPointComboContrast(
      metricKeys: ['sub.rsi_1', 'metrics.chip.something'],
      labelCns: ['RSI', '筹码'],
      topHigher: [true, true],
      contrast: 1,
      lift: 0,
      level: 1,
    );
    expect(
      searchCandidateFromCombo(combo, {'sub.rsi_1': 50}),
      isNull,
    );
  });
}
