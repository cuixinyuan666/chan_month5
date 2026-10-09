import 'package:chan_kline/models/kline_bar.dart';

/// 合成 K0：交替等长腿折线。每腿 [legLen] 根，腿幅 [step]×[legLen]。
/// 相邻 K 无包含关系（high/low 随 close 单调平移）。
List<KlineBar> synthZigzag({
  int legs = 16,
  int legLen = 6,
  double step = 0.5,
  double base = 10.0,
}) {
  final bars = <KlineBar>[];
  var idx = 0;
  var price = base;
  for (var l = 0; l < legs; l++) {
    final dir = l.isEven ? 1 : -1;
    for (var i = 0; i < legLen; i++) {
      final o = price;
      final c = price + dir * step;
      bars.add(
        KlineBar(
          idx: idx,
          timeMs: idx * 60000,
          timeText: 't$idx',
          open: o,
          high: (o > c ? o : c) + 0.3,
          low: (o < c ? o : c) - 0.3,
          close: c,
          volume: 100,
          amount: 1000,
        ),
      );
      price = c;
      idx++;
    }
  }
  return bars;
}
