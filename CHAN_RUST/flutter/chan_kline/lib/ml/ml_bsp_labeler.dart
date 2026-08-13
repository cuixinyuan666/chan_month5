import 'dart:math' as math;

import '../models/buy1_frame.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/sell1_frame.dart';
import 'ml_bsp_sample.dart';
import 'ml_label_config.dart';

/// α label：发现后固定展望窗内，用**当时** live 一类帧 + asOf 截断极值判定。
/// 禁止用全样本跳末末态回标。
/// 这是旧离线 ML 标签路径，不是 Rust 在线 `BsVerdict`（Pending/Correct/Wrong）事实源。
class MlBspLabeler {
  MlBspLabeler._();

  static const double _priceEps = 1e-6;

  /// 在步进过程中：对已到期（x+horizon 或数据末）且未打标的样本打标。
  static void labelDueSamples({
    required List<MlBspSample> samples,
    required int asOfIdx,
    required int horizonBars,
    required bool isLastBar,
    required List<Buy1Frame> liveBuy1,
    required List<Sell1Frame> liveSell1,
    required List<K0Line> k0LinesAsOf,
    required List<KlineBar> barsAsOf,
  }) {
    for (final s in samples) {
      if (s.isCorrect != null) continue;
      final dueAt = s.x + horizonBars;
      final due = asOfIdx >= dueAt || isLastBar;
      if (!due) continue;
      final truncated = isLastBar && asOfIdx < dueAt;
      applyOneAtAsOf(
        sample: s,
        asOfIdx: asOfIdx,
        liveBuy1: liveBuy1,
        liveSell1: liveSell1,
        k0LinesAsOf: k0LinesAsOf,
        barsAsOf: barsAsOf,
        truncated: truncated,
        horizonBars: horizonBars,
      );
    }
  }

  /// 单条：仅用 asOf 已可见数据（live 帧 + 截断连线极值）。
  static void applyOneAtAsOf({
    required MlBspSample sample,
    required int asOfIdx,
    required List<Buy1Frame> liveBuy1,
    required List<Sell1Frame> liveSell1,
    required List<K0Line> k0LinesAsOf,
    required List<KlineBar> barsAsOf,
    required bool truncated,
    required int horizonBars,
  }) {
    final buyKeys = {
      for (final b in liveBuy1) 'B|${b.x}|${b.label}|${b.segIdx}',
    };
    final sellKeys = {
      for (final s in liveSell1) 'S|${s.x}|${s.label}|${s.segIdx}',
    };
    final buyXs = {for (final b in liveBuy1) b.x};
    final sellXs = {for (final s in liveSell1) s.x};

    final inSetStrict = sample.side == 'B'
        ? buyKeys.contains(sample.sampleKey)
        : sellKeys.contains(sample.sampleKey);
    final inSetLoose = sample.side == 'B'
        ? buyXs.contains(sample.x)
        : sellXs.contains(sample.x);
    final inSet = inSetStrict || inSetLoose;
    final truncNote = truncated ? '·窗截断至数据末' : '';

    if (!inSet) {
      sample.isCorrect = false;
      sample.labelReason =
          '展望窗${horizonBars}K内 live一类已不在（α=×）$truncNote';
      return;
    }

    final extremeOk = matchesK0LineExtremeAsOf(
      side: sample.side,
      x: sample.x,
      price: sample.price,
      asOfIdx: asOfIdx,
      k0Lines: k0LinesAsOf,
      bars: barsAsOf,
    );
    if (!extremeOk) {
      sample.isCorrect = false;
      sample.labelReason = sample.side == 'B'
          ? '展望窗内非K0连线最低（α=×）$truncNote'
          : '展望窗内非K0连线最高（α=×）$truncNote';
      return;
    }

    sample.isCorrect = true;
    sample.labelReason = inSetStrict
        ? '展望窗内live命中且为asOf极值（α=√）$truncNote'
        : '展望窗内同x命中且为asOf极值（α=√）$truncNote';
  }

  /// 兼容旧测试：asOf=末根、live=传入列表（仍走展望窗截断路径）。
  static void applyLabels({
    required List<MlBspSample> samples,
    required List<Buy1Frame> finalBuy1K0,
    required List<Sell1Frame> finalSell1K0,
    required List<K0Line> k0Lines,
    required List<KlineBar> bars,
    int? horizonBars,
  }) {
    if (bars.isEmpty) return;
    final asOf = bars.last.idx;
    final h = horizonBars ?? MlLabelConfig().horizonBars;
    labelDueSamples(
      samples: samples,
      asOfIdx: asOf,
      horizonBars: h,
      isLastBar: true,
      liveBuy1: finalBuy1K0,
      liveSell1: finalSell1K0,
      k0LinesAsOf: k0Lines,
      barsAsOf: bars,
    );
  }

  /// Ba/Sa 极值只在 [lineX1, min(lineX2, asOf)] 内比，禁止看 asOf 右侧。
  static bool matchesK0LineExtremeAsOf({
    required String side,
    required int x,
    required double price,
    required int asOfIdx,
    required List<K0Line> k0Lines,
    required List<KlineBar> bars,
  }) {
    if (bars.isEmpty || k0Lines.isEmpty) return false;
    if (x > asOfIdx) return false;
    final barByIdx = {for (final b in bars) b.idx: b};

    for (final line in k0Lines) {
      final x1 = _lineX1(line);
      final x2Raw = _lineX2(line);
      final x2 = math.min(x2Raw, asOfIdx);
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
        if (x == minX &&
            (price - minLow).abs() <= _priceEps + 1e-4 * minLow.abs()) {
          return true;
        }
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

  /// 旧名转发（极值 asOf=bars末）
  static bool matchesK0LineExtreme({
    required String side,
    required int x,
    required double price,
    required List<K0Line> k0Lines,
    required List<KlineBar> bars,
  }) {
    if (bars.isEmpty) return false;
    return matchesK0LineExtremeAsOf(
      side: side,
      x: x,
      price: price,
      asOfIdx: bars.last.idx,
      k0Lines: k0Lines,
      bars: bars,
    );
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
