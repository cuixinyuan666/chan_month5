import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/key_point_to_search_bridge.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优→寻优的无前视回归。
///
/// 组合、方向、分界都只能用寻优切点之前的已确认关键点拟合；
/// 切点之后才确认的顶底不能参与，否则样本外指标会被前视污染。
void main() {
  List<KlineBar> bars(int n) => [
        for (var i = 0; i < n; i++)
          KlineBar(
            idx: i,
            timeMs: i * 60000,
            timeText: '2004/07/19 09:30:00',
            open: 100,
            high: 100,
            low: 100,
            close: 100,
            volume: 1000,
            amount: 2000,
          ),
      ];

  K0ConfirmSignal sig(int pole, String fx) => K0ConfirmSignal(
        x: pole + 1,
        fx: fx,
        value: fx == 'TOP' ? 1 : -1,
        fractalX1: pole,
        fractalX2: pole,
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

  test('拿去寻优只用切点前的关键点拟合，切点后的顶底不参与', () {
    final bs = bars(25);
    final signals = <K0ConfirmSignal>[
      for (final p in [1, 3, 5, 7]) sig(p, 'TOP'),
      for (final p in [2, 4, 6, 8]) sig(p, 'BOTTOM'),
      // 切点后（confirm > 18）才确认的顶底：MACD 在这里才明显分开。
      for (final p in [19, 21, 23]) sig(p, 'TOP'),
      for (final p in [18, 20, 22]) sig(p, 'BOTTOM'),
    ];

    const rsi = <int, double>{
      1: 70, 3: 71, 5: 69, 7: 70,
      2: 30, 4: 29, 6: 31, 8: 30,
      19: 100, 21: 101, 23: 99,
      18: 50, 20: 49, 22: 51,
    };
    const kdj = <int, double>{
      1: 60, 3: 62, 5: 58, 7: 60,
      2: 40, 4: 38, 6: 42, 8: 40,
      19: 60, 21: 62, 23: 58,
      18: 40, 20: 38, 22: 42,
    };
    const macd = <int, double>{
      1: 50, 3: 51, 5: 49, 7: 50,
      2: 50, 4: 49, 6: 51, 8: 50,
      19: 90, 21: 91, 23: 89,
      18: 10, 20: 9, 22: 11,
    };
    final byIdx = <int, Map<String, dynamic>>{
      for (final p in rsi.keys)
        p: {
          'idx': p,
          'sub': {
            'rsi_0': rsi[p],
            'kdj_k_0': kdj[p],
            'macd_hist_0': macd[p],
          },
        },
    };
    final lookup = BarFeatureLookup.fromCached(byIdx: byIdx);

    final full = KeyPointStatRunner.run(
      lookup: lookup,
      collect: collectKeyPoints(
        bars: bs,
        levels: const [],
        k0Confirms: signals,
        asOf: 24,
      ),
      settings: const KeyPointStatSettings(),
      code: 'TEST',
      period: '1m',
      barCount: 25,
      maxKn: 1,
    );
    // 全样本里 MACD 在切点后才分开，会被贪心选进组合 —— 这正是旧口径的污染源。
    expect(
      full.comboContrasts.any((c) => c.metricKeys.contains('sub.macd_hist_0')),
      isTrue,
      reason: '测试数据应让全样本组合包含切点后才分开的 MACD',
    );

    final splitX = splitBarIdx(bs);
    final cands = bridgeCandidatesAsOf(
      bars: bs,
      levels: const [],
      k0Confirms: signals,
      lookup: lookup,
      settings: const KeyPointStatSettings(),
      asOf: splitX,
      code: 'TEST',
      period: '1m',
      maxKn: 1,
    );

    expect(cands, isNotEmpty, reason: '切点前有足够顶底，应能拟合出组合');
    for (final c in cands) {
      expect(c.name, isNot(contains('MACD')),
          reason: '切点前 MACD 不分开，不能进组合：${c.name}');
      expect(
        constOf(c.buyAst, 'SUB.K0.RSI.VALUE'),
        closeTo(50, 1e-9),
        reason: '分界必须是切点前顶底均值的中点，不能混入切点后的 100/50',
      );
    }

    // 对照：全样本候选会用到切点后的数据（RSI 中点被拉到 60.7 左右）。
    final fullCands = candidatesFromResult(full);
    final withMacd =
        fullCands.firstWhere((c) => c.name.contains('MACD'), orElse: () {
      throw StateError('全样本候选应包含 MACD 组合');
    });
    final fullRsi = full.contrasts.firstWhere(
      (c) => c.level == 0 && c.metricKey == 'sub.rsi_0',
    );
    expect(
      constOf(withMacd.buyAst, 'SUB.K0.RSI.VALUE'),
      closeTo((fullRsi.topMean + fullRsi.bottomMean) / 2, 1e-9),
    );
    expect(constOf(withMacd.buyAst, 'SUB.K0.RSI.VALUE'), isNot(closeTo(50, 0.1)));
  });
}
