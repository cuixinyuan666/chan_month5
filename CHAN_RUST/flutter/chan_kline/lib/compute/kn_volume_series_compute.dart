import '../models/bar_crosshair_feature.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// K0 volume: native bars[].volume.
List<double> computeK0VolumeSeries(List<KlineBar> bars) {
  return [for (final b in bars) b.volume];
}

/// All Kn volume series (key = display kn: 0=K0, 1=K1, ...).
///
/// Full-layer isomorphic; aligns with Rust confirm ��λ:
/// - Confirmed Kn endpoint settles at end_pole (unit.x2), confirm at confirmX.
/// - Shared K0 between confirmed and next dynamic = prev.x2 (end_pole);
///   next dynamic sum starts at prev.x2+1 (does NOT include shared vol).
/// - Display: unit writes through confirmX-1 (building may pass pole);
///   next unit display starts at prev.confirmX (no look-ahead before confirm).
Map<int, List<double>> computeAllKnVolumeSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  final n = bars.length;
  final out = <int, List<double>>{};
  if (n == 0) return out;

  var increments = computeK0VolumeSeries(bars);
  out[0] = List<double>.from(increments);

  final sorted = [...levels]..sort((a, b) => a.level.compareTo(b.level));
  for (final bundle in sorted) {
    final kn = bundle.level;
    if (kn < 1) continue;
    final series = _accumulateConfirmGated(
      lowerIncrements: increments,
      bundle: bundle,
      bars: bars,
    );
    out[kn] = series;
    increments = _cumulativeToIncrements(series);
  }
  return out;
}

List<double> computeKnVolumeSeries({
  required List<KlineBar> bars,
  required LevelBundle bundle,
  List<double>? lowerIncrements,
}) {
  return _accumulateConfirmGated(
    lowerIncrements: lowerIncrements ?? computeK0VolumeSeries(bars),
    bundle: bundle,
    bars: bars,
  );
}

List<double> _accumulateConfirmGated({
  required List<double> lowerIncrements,
  required LevelBundle bundle,
  required List<KlineBar> bars,
}) {
  final n = bars.length;
  final out = List<double>.filled(n, 0.0);
  if (n == 0) return out;
  final idxToI = <int, int>{for (var i = 0; i < n; i++) bars[i].idx: i};
  final lastIdx = bars.last.idx;

  final units = <LevelUnitBar>[
    ...bundle.unitBars,
    if (bundle.activeUnit != null) bundle.activeUnit!,
  ];
  if (units.isEmpty) return out;

  LevelUnitBar? prev;
  for (final u in units) {
    final isActiveTail =
        bundle.activeUnit != null && identical(u, bundle.activeUnit);

    late final int sumStart;
    late final int displayStart;
    if (prev == null) {
      sumStart = u.x1 >= 0 ? u.x1 : 0;
      displayStart = sumStart;
    } else {
      // ���� K0 = ȷ�Ϻ���λ�յ� end_pole(prev.x2)����̬�β�������
      sumStart = prev.x2 + 1;
      // �������һȷ�ϲ��𣬱���ȷ��ǰ��δ���ж�
      displayStart =
          prev.confirmX >= 0 ? prev.confirmX : (prev.x2 + 1);
    }

    final int endX;
    if (isActiveTail) {
      endX = lastIdx;
    } else if (u.confirmX >= 0) {
      // ȷ��ǰ��̬��Խ�����㻭�� confirmX-1
      endX = u.confirmX - 1;
    } else {
      endX = u.x2;
    }
    if (endX < sumStart) {
      prev = u;
      continue;
    }

    var run = 0.0;
    for (var x = sumStart; x <= endX; x++) {
      final i = idxToI[x];
      if (i == null) continue;
      run += lowerIncrements[i];
      if (x >= displayStart) {
        out[i] = run;
      }
    }
    prev = u;
  }
  return out;
}

List<double> _cumulativeToIncrements(List<double> series) {
  final n = series.length;
  if (n == 0) return const [];
  final incr = List<double>.filled(n, 0.0);
  incr[0] = series[0];
  for (var i = 1; i < n; i++) {
    final v = series[i];
    if (v == 0) {
      incr[i] = 0;
      continue;
    }
    final prev = series[i - 1];
    if (prev == 0 || v < prev) {
      incr[i] = v;
    } else {
      incr[i] = v - prev;
    }
  }
  return incr;
}
