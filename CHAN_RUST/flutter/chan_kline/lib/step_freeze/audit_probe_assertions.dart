import '../models/bar_crosshair_feature.dart';
import '../models/bar_feature_lookup.dart' show BarFeatureLookup, CrosshairTooltipRow;
import '../models/k1_analysis.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../compute/step_rhythm_compute.dart';

/// 验收探针 T1/T2 数据断言（与 `audit_probe_snapshot.dart` 同口径）。
class AuditProbeAssertions {
  static const int holdFromX = 77;
  static const int holdToX = 114;
  static const int displayKn = 1;
  static const String holdLabel = '0-0';

  static Map<String, Object?> evaluate({
    required List<KlineBar> bars,
    required int stepIdx,
    required List<LevelBundle> sessionLevels,
    required List<BarCrosshairFeature> barFeatures,
    required Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn,
  }) {
    final checks = <Map<String, Object?>>[];
    var ok = true;

    final t1 = _t1HoldContinuity(
      hist: stepRhythmHistoryByKn[displayKn] ?? const [],
      lastIdx: bars[stepIdx.clamp(0, bars.length - 1)].idx,
    );
    checks.add({'id': 'T1_rhythm_hold', ...t1});
    if (t1['ok'] != true) ok = false;

    final t2 = _t2TipSync(
      bars: bars,
      sessionLevels: sessionLevels,
      barFeatures: barFeatures,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
      hist: stepRhythmHistoryByKn[displayKn] ?? const [],
      lastIdx: bars[stepIdx.clamp(0, bars.length - 1)].idx,
    );
    checks.add({'id': 'T2_tip_sync', ...t2});
    if (t2['ok'] != true) ok = false;

    return {'ok': ok, 'checks': checks};
  }

  static Map<String, Object?> _t1HoldContinuity({
    required List<StepRhythmLinePoint> hist,
    required int lastIdx,
  }) {
    if (lastIdx < holdFromX) {
      return {'ok': true, 'skipped': true, 'reason': 'data_before_hold_from'};
    }
    final toX = lastIdx < holdToX ? lastIdx : holdToX;
    StepRhythmLinePoint? ref;
    for (final p in hist) {
      if (p.label != holdLabel) continue;
      if (p.x >= holdFromX) continue;
      if (ref == null || p.x > ref.x) ref = p;
    }
    if (ref == null) {
      return {'ok': false, 'reason': 'no_ref_before_hold'};
    }
    var miss = 0;
    var mismatch = 0;
    for (var x = holdFromX; x <= toX; x++) {
      final at = hist.where((e) => e.x == x && e.label == holdLabel).toList();
      if (at.isEmpty) {
        miss++;
        continue;
      }
      final p = at.first;
      if (p.key != ref.key || (p.value - ref.value).abs() > 1e-9) {
        mismatch++;
      }
    }
    final span = toX - holdFromX + 1;
    return {
      'ok': miss == 0 && mismatch == 0,
      'span': span,
      'miss': miss,
      'mismatch': mismatch,
      'toX': toX,
    };
  }

  static Map<String, Object?> _t2TipSync({
    required List<KlineBar> bars,
    required List<LevelBundle> sessionLevels,
    required List<BarCrosshairFeature> barFeatures,
    required Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn,
    required List<StepRhythmLinePoint> hist,
    required int lastIdx,
  }) {
    var focusX = holdFromX;
    if (focusX > lastIdx) focusX = lastIdx;
    final inHold = hist
        .where((e) =>
            e.label == holdLabel &&
            e.x >= holdFromX &&
            e.x <= (lastIdx < holdToX ? lastIdx : holdToX))
        .toList();
    if (inHold.isNotEmpty) {
      focusX = inHold[inHold.length ~/ 2].x;
    } else {
      final any = hist.where((e) => e.label == holdLabel).toList();
      if (any.isNotEmpty) focusX = any.last.x;
    }
    final atHist =
        hist.where((e) => e.x == focusX && e.label == holdLabel).toList();
    if (atHist.isEmpty) {
      return {'ok': false, 'reason': 'hist_missing_at_focus', 'focusX': focusX};
    }
    final expectTipText = atHist.first.value.toStringAsFixed(3);
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: barFeatures,
      k0Lines: const [],
      k1Analysis: const K1AnalysisBundle(),
      levels: sessionLevels,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
    );
    final rows = lookup.crosshairTooltipRows(focusX, timePart: 'probe');
    final tipLabel = 'K$displayKn节奏$holdLabel';
    CrosshairTooltipRow? tipRow;
    for (final r in rows) {
      if (r.label == tipLabel) {
        tipRow = r;
        break;
      }
    }
    if (tipRow == null) {
      return {'ok': false, 'reason': 'tip_row_missing', 'focusX': focusX};
    }
    final m = RegExp(r'[-+]?\d+(?:\.\d+)?').firstMatch(tipRow.value);
    if (m == null) {
      return {'ok': false, 'reason': 'tip_no_number', 'tip': tipRow.value};
    }
    return {
      'ok': m.group(0) == expectTipText,
      'focusX': focusX,
      'expect': expectTipText,
      'tipNum': m.group(0),
    };
  }
}
