import '../models/kline_bar.dart';
import '../widgets/kline_chip.dart';

/// K0 笔数分布：与筹码同构分桶，读 `chip_tick_count_bins`（Rust 第4列按价累加）。
/// 无 bins 时回退 metrics.tick_count / buy/sell 落在收盘价；
/// tick_count=0（分笔显式写 0）不落桶 → 全无柱。
class TickDistProfileCompute {
  static ChipProfileData? _cached;
  static String? _cachedKey;

  static void clearCache() {
    _cached = null;
    _cachedKey = null;
  }

  static String _cacheKey(List<KlineBar> bars, int cutoffX, double step) {
    if (bars.isEmpty) return '0|$cutoffX|$step';
    final a = bars.first;
    final b = bars.last;
    return 'tickdist|${bars.length}|${a.idx}|${a.timeMs}|${b.idx}|${b.timeMs}|$cutoffX|$step';
  }

  static ChipProfileData compute({
    required List<KlineBar> bars,
    required int cutoffX,
    double bucketStep = 0.1,
  }) {
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    final key = _cacheKey(bars, cutoffX, step);
    if (_cached != null && _cachedKey == key) return _cached!;

    final runS = <int, double>{};
    final runB = <int, double>{};
    final runW = <int, double>{};
    for (final bar in bars) {
      if (bar.idx > cutoffX) break;
      _accumulateBar(bar, step, runS, runB, runW);
    }
    final out = _mapsToProfile(cutoffX, step, runS, runB, runW);
    _cached = out;
    _cachedKey = key;
    return out;
  }

  static void _accumulateBar(
    KlineBar bar,
    double step,
    Map<int, double> runS,
    Map<int, double> runB,
    Map<int, double> runW,
  ) {
    final bins = bar.metrics['chip_tick_count_bins'];
    if (bins is Map) {
      final p = (bins['p'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final sv = (bins['s'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final bv = (bins['b'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final wv = (bins['w'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      if (p.isNotEmpty) {
        for (var i = 0; i < p.length; i++) {
          final price = p[i];
          if (!price.isFinite) continue;
          final key = (price / step).floor();
          final ss = i < sv.length ? sv[i] : 0.0;
          final bb = i < bv.length ? bv[i] : 0.0;
          final ww = i < wv.length ? wv[i] : 0.0;
          if (ss > 0) runS[key] = (runS[key] ?? 0) + ss;
          if (bb > 0) runB[key] = (runB[key] ?? 0) + bb;
          if (ww > 0) runW[key] = (runW[key] ?? 0) + ww;
        }
        return;
      }
    }
    // 回退：整根笔数落在收盘价（B/S/G 拆 metrics）
    final total = (bar.metrics['tick_count'] as num?)?.toDouble() ?? 0.0;
    if (total <= 0 || !bar.close.isFinite) return;
    final buy = (bar.metrics['buy_tick_count'] as num?)?.toDouble() ?? 0.0;
    final sell = (bar.metrics['sell_tick_count'] as num?)?.toDouble() ?? 0.0;
    var gray = total - buy - sell;
    if (gray < 0) gray = 0;
    final key = (bar.close / step).floor();
    if (sell > 0) runS[key] = (runS[key] ?? 0) + sell;
    if (buy > 0) runB[key] = (runB[key] ?? 0) + buy;
    if (gray > 0) runW[key] = (runW[key] ?? 0) + gray;
  }

  static ChipProfileData _mapsToProfile(
    int cutoffX,
    double step,
    Map<int, double> bucketsS,
    Map<int, double> bucketsB,
    Map<int, double> bucketsW,
  ) {
    final keys = {...bucketsS.keys, ...bucketsB.keys, ...bucketsW.keys}.toList()
      ..sort();
    final prices = <double>[];
    final sVals = <double>[];
    final bVals = <double>[];
    final wVals = <double>[];
    final totals = <double>[];
    var maxTotal = 0.0;
    for (final k in keys) {
      final sv = bucketsS[k] ?? 0.0;
      final bv = bucketsB[k] ?? 0.0;
      final wv = bucketsW[k] ?? 0.0;
      final t = sv + bv + wv;
      if (t > maxTotal) maxTotal = t;
      prices.add(k * step);
      sVals.add(sv);
      bVals.add(bv);
      wVals.add(wv);
      totals.add(t);
    }
    return ChipProfileData(
      profileId: 'tickdist:$cutoffX:$step',
      cutoffX: cutoffX,
      bucketStep: step,
      prices: prices,
      s: sVals,
      b: bVals,
      w: wVals,
      total: totals,
      maxTotal: maxTotal,
      source: 'tickdist',
    );
  }
}
