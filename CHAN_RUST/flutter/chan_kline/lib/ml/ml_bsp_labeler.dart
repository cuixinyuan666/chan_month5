import 'dart:math' as math;

import '../models/buy1_frame.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/sell1_frame.dart';
import 'ml_bsp_sample.dart';

/// α label：末态一类集合 + K0连线极值核对（Ba=连线最低 / Sa=连线最高）。
class MlBspLabeler {
  MlBspLabeler._();

  static const double _priceEps = 1e-6;

  static void applyLabels({
    required List<MlBspSample> samples,
    required List<Buy1Frame> finalBuy1K0,
    required List<Sell1Frame> finalSell1K0,
    required List<K0Line> k0Lines,
    required List<KlineBar> bars,
  }) {
    final buyKeys = {
      for (final b in finalBuy1K0) 'B|${b.x}|${b.label}|${b.segIdx}',
    };
    final sellKeys = {
      for (final s in finalSell1K0) 'S|${s.x}|${s.label}|${s.segIdx}',
    };
    // 宽松：同 side+x 也算仍在集合（字母复位时 label 可能变）
    final buyXs = {for (final b in finalBuy1K0) b.x};
    final sellXs = {for (final s in finalSell1K0) s.x};

    for (final s in samples) {
      final inSetStrict = s.side == 'B'
          ? buyKeys.contains(s.sampleKey)
          : sellKeys.contains(s.sampleKey);
      final inSetLoose = s.side == 'B' ? buyXs.contains(s.x) : sellXs.contains(s.x);
      final inSet = inSetStrict || inSetLoose;

      if (!inSet) {
        s.isCorrect = false;
        s.labelReason = '末态一类集合中已不存在（α=×）';
        continue;
      }

      final extremeOk = matchesK0LineExtreme(
        side: s.side,
        x: s.x,
        price: s.price,
        k0Lines: k0Lines,
        bars: bars,
      );
      if (!extremeOk) {
        s.isCorrect = false;
        s.labelReason = s.side == 'B'
            ? '非对应K0连线最低点（α=×）'
            : '非对应K0连线最高点（α=×）';
        continue;
      }

      s.isCorrect = true;
      s.labelReason = inSetStrict
          ? '末态集合命中且为K0连线极值（α=√）'
          : '末态同x命中且为K0连线极值（α=√）';
    }
  }

  /// Ba ↔ 覆盖该 x 的 K0连线区间最低；Sa ↔ 最高。
  static bool matchesK0LineExtreme({
    required String side,
    required int x,
    required double price,
    required List<K0Line> k0Lines,
    required List<KlineBar> bars,
  }) {
    if (bars.isEmpty || k0Lines.isEmpty) return false;
    final barByIdx = {for (final b in bars) b.idx: b};

    for (final line in k0Lines) {
      final x1 = _lineX1(line);
      final x2 = _lineX2(line);
      if (x < x1 || x > x2) continue;

      var minLow = double.infinity;
      var maxHigh = double.negativeInfinity;
      var minX = x1;
      var maxX = x1;
      for (var i = x1; i <= x2; i++) {
        final b = barByIdx[i];
        if (b == null) continue;
        if (b.low < minLow) {
          minLow = b.low;
          minX = b.idx;
        }
        if (b.high > maxHigh) {
          maxHigh = b.high;
          maxX = b.idx;
        }
      }
      if (minLow.isInfinite || maxHigh.isInfinite) continue;

      if (side == 'B') {
        if (x == minX && (price - minLow).abs() <= _priceEps + 1e-4 * minLow.abs()) {
          return true;
        }
        // 价格贴近最低且 x 在极值邻域（合并K）
        if ((price - minLow).abs() <= _priceEps + 1e-4 * minLow.abs() &&
            (x - minX).abs() <= 2) {
          return true;
        }
      } else if (side == 'S') {
        if (x == maxX &&
            (price - maxHigh).abs() <= _priceEps + 1e-4 * maxHigh.abs()) {
          return true;
        }
        if ((price - maxHigh).abs() <= _priceEps + 1e-4 * maxHigh.abs() &&
            (x - maxX).abs() <= 2) {
          return true;
        }
      }
    }
    return false;
  }

  static int _lineX1(K0Line line) {
    final xs = [
      line.beginConfirmX,
      line.beginFractalX1,
      line.beginFractalX2,
    ].where((e) => e >= 0);
    return xs.isEmpty ? 0 : xs.reduce(math.min);
  }

  static int _lineX2(K0Line line) {
    final xs = [
      line.endConfirmX,
      line.endFractalX1,
      line.endFractalX2,
    ].where((e) => e >= 0);
    return xs.isEmpty ? 0 : xs.reduce(math.max);
  }
}
