import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/key_point_stats/key_point_combo_contrast.dart';
import 'package:chan_kline/key_point_stats/key_point_contrast.dart';
import 'package:chan_kline/key_point_stats/key_point_to_search_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优到寻优的键名桥回归。
///
/// 钉死三件事：冻结账的键能翻译成交易变量；翻译出的候选买卖方向正确
/// （顶上更高的指标，买入取低于分界、卖出取高于分界）；分界按组合所在
/// 级别取，不能拿别的级别的中点。
void main() {
  KeyPointContrast contrast({
    required int level,
    required String key,
    required double topMean,
    required double bottomMean,
  }) =>
      KeyPointContrast(
        level: level,
        metricKey: key,
        labelCn: 'RSI',
        topMean: topMean,
        bottomMean: bottomMean,
        deltaMean: topMean - bottomMean,
        pooledSigma: 1,
        contrast: (topMean - bottomMean).abs(),
        topPoints: 4,
        bottomPoints: 4,
      );

  double? constOf(TradeAst ast, String variableId) {
    if (ast is TradeAndAst) {
      return constOf(ast.left, variableId) ?? constOf(ast.right, variableId);
    }
    if (ast is TradeCmpAst) {
      final left = ast.left;
      if (left is TradeVarRef && left.variableId == variableId) {
        final right = ast.right;
        if (right is TradeConstRef) return right.value;
      }
    }
    return null;
  }

  test('冻结账键翻译成交易变量', () {
    expect(tradeVarIdOf('sub.rsi_1'), 'SUB.K1.RSI.VALUE');
    expect(tradeVarIdOf('sub.macd_dif_2'), 'SUB.K2.MACD.DIF');
    expect(tradeVarIdOf('sub.kdj_k_0'), 'SUB.K0.KDJ.K');
    expect(tradeVarIdOf('sub.volume_0'), 'RAW.K0.VOLUME');
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
      1: {
        'sub.rsi_1': 50,
        'sub.kdj_k_1': 40,
      },
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

  test('同一指标在不同级别各取各的中点', () {
    final k1 = KeyPointComboContrast(
      metricKeys: ['sub.rsi_1'],
      labelCns: ['K1 RSI'],
      topHigher: [true],
      contrast: 1,
      lift: 0,
      level: 1,
    );
    final k2 = KeyPointComboContrast(
      metricKeys: ['sub.rsi_1'],
      labelCns: ['K1 RSI'],
      topHigher: [true],
      contrast: 1,
      lift: 0,
      level: 2,
    );
    final midpoints = midpointsByLevelOf([
      contrast(level: 1, key: 'sub.rsi_1', topMean: 60, bottomMean: 40),
      contrast(level: 2, key: 'sub.rsi_1', topMean: 80, bottomMean: 40),
    ]);

    expect(constOf(searchCandidateFromCombo(k1, midpoints)!.buyAst,
        'SUB.K1.RSI.VALUE'), 50);
    expect(constOf(searchCandidateFromCombo(k2, midpoints)!.buyAst,
        'SUB.K1.RSI.VALUE'), 60);
  });

  test('翻译不了的指标单独跳过，剩下的照常产出', () {
    final combo = KeyPointComboContrast(
      metricKeys: ['sub.rsi_1', 'metrics.chip.something'],
      labelCns: ['RSI', '筹码'],
      topHigher: [true, true],
      contrast: 1,
      lift: 0,
      level: 1,
    );
    final cand = searchCandidateFromCombo(combo, {
      1: {'sub.rsi_1': 50},
    });
    expect(cand, isNotNull);
    // 只剩一个条件，不再包一层「并且」。
    expect(cand!.buyAst, isA<TradeCmpAst>());
    // 名字只列真正进了条件的指标，不能把没翻译的筹码写进去。
    expect(cand.name, contains('RSI'));
    expect(cand.name, isNot(contains('筹码')));
  });

  test('一个都翻译不了才返回 null', () {
    final combo = KeyPointComboContrast(
      metricKeys: ['metrics.chip.something'],
      labelCns: ['筹码'],
      topHigher: [true],
      contrast: 1,
      lift: 0,
      level: 1,
    );
    expect(searchCandidateFromCombo(combo, const {}), isNull);
  });
}
