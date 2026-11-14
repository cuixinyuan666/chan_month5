import '../models/kline_bar.dart';
import 'equity_curve.dart';
import 'order_models.dart';
import 'signal_event.dart';

/// 按成交顺序在每根 K0 应用 Fill（executeX），收盘记净值（含浮盈）。
List<EquityPoint> buildEquityCurve({
  required List<KlineBar> bars,
  required List<Fill> fills,
  required double initialCash,
}) {
  if (bars.isEmpty) return const [];
  // T3：bars 在寻优/回测里由 pipeline 或 harness 产出，idx 严格连续升序。
  // 先做一次 O(N) 的「是否已升序」判定，是则直接用原 list（省掉每候选一次
  // 全量拷贝 + O(N log N) 排序）；否则退回原有的拷贝+排序。
  // 判定是纯比较，浮点运算与结果一字未动。
  var orderedIsSorted = true;
  for (var i = 1; i < bars.length; i++) {
    if (bars[i].idx < bars[i - 1].idx) {
      orderedIsSorted = false;
      break;
    }
  }
  final ordered = orderedIsSorted ? bars : ([...bars]..sort((a, b) => a.idx.compareTo(b.idx)));
  final byX = <int, List<Fill>>{};
  for (final f in fills) {
    byX.putIfAbsent(f.executeX, () => []).add(f);
  }

  var cash = initialCash;
  var qty = 0;
  var avgCost = 0.0;
  var realized = 0.0;
  final out = <EquityPoint>[];

  for (final bar in ordered) {
    final fs = byX[bar.idx];
    if (fs != null) {
      for (final f in fs) {
        if (f.side == TradeSide.buy) {
          cash -= f.price * f.quantity + f.commission;
          qty = f.quantity;
          avgCost = f.price;
          // 进场手续费当时已付，记入已实现，避免「现金少了但已实现仍为 0」
          realized -= f.commission;
        } else {
          cash += f.price * f.quantity - f.commission;
          realized += (f.price - avgCost) * f.quantity - f.commission;
          qty = 0;
          avgCost = 0;
        }
      }
    }
    final posVal = qty * bar.close;
    final unreal = qty == 0 ? 0.0 : (bar.close - avgCost) * qty;
    out.add(EquityPoint(
      x: bar.idx,
      cash: cash,
      positionQty: qty,
      positionValue: posVal,
      equity: cash + posVal,
      realizedPnL: realized,
      unrealizedPnL: unreal,
    ));
  }
  return out;
}
