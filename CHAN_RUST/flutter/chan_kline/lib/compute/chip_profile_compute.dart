import '../bridge/chan_bridge.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../widgets/kline_chip.dart';

/// 筹码 profile 计算：优先 Rust FFI；失败时 Dart 直加/三角兜底（保渲染可用）。
class ChipProfileCompute {
  /// Kn as-of：K0 直接用 cutoff；Kn≥1 用该层已确认/动态单元覆盖到的最大 K0 idx。
  static int cutoffForKn({
    required int kn,
    required int asOfK0,
    required List<LevelBundle> levels,
  }) {
    if (kn <= 0) return asOfK0;
    LevelBundle? lv;
    for (final e in levels) {
      if (e.level == kn) {
        lv = e;
        break;
      }
    }
    if (lv == null) return asOfK0;
    var maxX = -1;
    for (final u in lv.unitBars) {
      final x2 = u.x2;
      if (x2 <= asOfK0 && x2 > maxX) maxX = x2;
    }
    // 动态未确认单元：纳入当前 asOf（当下性）
    final active = lv.activeUnit;
    if (active != null) {
      if (active.x2 <= asOfK0 && active.x2 > maxX) {
        maxX = active.x2;
      }
      if (asOfK0 > maxX) maxX = asOfK0;
    }
    return maxX < 0 ? asOfK0 : maxX;
  }

  static ChipProfileData compute({
    required List<KlineBar> bars,
    required int cutoffX,
    double bucketStep = 0.1,
  }) {
    try {
      return ChanBridge.instance.chipProfile(
        bars: bars,
        cutoffX: cutoffX,
        bucketStep: bucketStep,
      );
    } catch (_) {
      return _dartFallback(bars, cutoffX, bucketStep);
    }
  }

  static ChipProfileData _dartFallback(
    List<KlineBar> bars,
    int cutoffX,
    double bucketStep,
  ) {
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    final bucketsS = <int, double>{};
    final bucketsB = <int, double>{};
    for (final bar in bars) {
      if (bar.idx > cutoffX) continue;
      final raw = bar.metrics['chip_tick_bins'];
      if (raw is Map) {
        final p = (raw['p'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const <double>[];
        final s = (raw['s'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const <double>[];
        final b = (raw['b'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const <double>[];
        final w = (raw['w'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const <double>[];
        if (p.isEmpty) {
          // 空 chip_tick_bins → 三角分摊兜底（对齐 Rust 行为）
          _triangle(bar, step, bucketsB);
        } else {
          for (var i = 0; i < p.length; i++) {
            final price = p[i];
            if (!price.isFinite) continue;
            final key = (price / step).floor();
            final sv = i < s.length ? s[i] : 0.0;
            var bv = i < b.length ? b[i] : 0.0;
            if (b.isEmpty && i < w.length) bv = w[i];
            if (sv > 0) bucketsS[key] = (bucketsS[key] ?? 0) + sv;
            if (bv > 0) bucketsB[key] = (bucketsB[key] ?? 0) + bv;
          }
        }
      } else {
        _triangle(bar, step, bucketsB);
      }
    }
    final keys = {...bucketsS.keys, ...bucketsB.keys}.toList()..sort();
    final prices = <double>[];
    final sVals = <double>[];
    final bVals = <double>[];
    final totals = <double>[];
    var maxTotal = 0.0;
    for (final k in keys) {
      final sv = bucketsS[k] ?? 0.0;
      final bv = bucketsB[k] ?? 0.0;
      final t = sv + bv;
      if (t > maxTotal) maxTotal = t;
      prices.add(k * step);
      sVals.add(sv);
      bVals.add(bv);
      totals.add(t);
    }
    return ChipProfileData(
      profileId: 'dart:$cutoffX:$step',
      cutoffX: cutoffX,
      bucketStep: step,
      prices: prices,
      s: sVals,
      b: bVals,
      total: totals,
      maxTotal: maxTotal,
      source: 'dart',
    );
  }

  static void _triangle(KlineBar bar, double step, Map<int, double> bucketsB) {
    final low = bar.low < bar.high ? bar.low : bar.high;
    final high = bar.low > bar.high ? bar.low : bar.high;
    final mode = bar.close.clamp(low, high);
    final vol = bar.volume < 0 ? 0.0 : bar.volume;
    if (high < low || vol <= 0) return;
    final i0 = (low / step).floor();
    final i1 = (high / step).ceil();
    if (i1 < i0) return;
    if ((high - low).abs() < 1e-12) {
      bucketsB[i0] = (bucketsB[i0] ?? 0) + vol;
      return;
    }
    final weights = <MapEntry<int, double>>[];
    var totalW = 0.0;
    for (var key = i0; key <= i1; key++) {
      final price = key * step;
      double w;
      if ((mode - low).abs() < 1e-12) {
        w = (high - price) / (high - low);
      } else if ((high - mode).abs() < 1e-12) {
        w = (price - low) / (high - low);
      } else if (price <= mode) {
        w = (price - low) / (mode - low);
      } else {
        w = (high - price) / (high - mode);
      }
      if (w < 0) w = 0;
      weights.add(MapEntry(key, w));
      totalW += w;
    }
    if (totalW <= 1e-12) return;
    for (final e in weights) {
      if (e.value > 0) {
        bucketsB[e.key] = (bucketsB[e.key] ?? 0) + e.value / totalW * vol;
      }
    }
  }
}
