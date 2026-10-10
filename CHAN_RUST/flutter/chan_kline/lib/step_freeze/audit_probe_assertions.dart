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
    // ref 在循环里被赋值，Dart 不会对其做空值提升；取一份非空局部变量再往下用
    final anchor = ref;

    // 锚点区间取「该标签的实际存活段」，而不是硬写死 [holdFromX, holdToX]。
    //
    // 2026-10-10 修：原来写死「77~114 每根都必须是 0-0」，于是本条从建起来
    // 就一直红。查实原因 —— 标签规则是 `'$roundRef-${roundCurrent - roundRef}'`，
    // `roundCurrent` 从 0 推进到 1 时，`0-0` **按设计就该消失**（002003 分笔
    // 实测在 x=110 推进，此处起变成 `0-1` + `1-0`）。硬区间等于要求
    // 「拿上一轮的结构继续冒充当下」，与当下性相悖。
    // 同时下面新增 `superseded` 断言：**消失必须有结构性理由**，
    // 不是「比放宽判据」——是比原来多验了一条。
    var aliveTo = holdFromX - 1;
    for (final p in hist) {
      if (p.label != holdLabel) continue;
      if (p.x < holdFromX || p.x > toX) continue;
      if (p.x > aliveTo) aliveTo = p.x;
    }
    if (aliveTo < holdFromX) {
      return {
        'ok': false,
        'reason': 'anchor_label_absent_in_hold_window',
        'holdFromX': holdFromX,
        'holdToX': toX,
      };
    }

    var miss = 0;
    var mismatch = 0;
    for (var x = holdFromX; x <= aliveTo; x++) {
      final at = hist.where((e) => e.x == x && e.label == holdLabel).toList();
      if (at.isEmpty) {
        miss++; // 存活段中间断档 —— 这才是真正的「持值断了」
        continue;
      }
      final p = at.first;
      if (p.key != anchor.key || (p.value - anchor.value).abs() > 1e-9) {
        mismatch++; // 持值期间 key/值漂移
      }
    }

    // 消失必须由「结构推进」解释：下一根上该组已切到新一轮/新组。
    var superseded = true;
    final after = hist.where((e) => e.x == aliveTo + 1).toList();
    if (after.isEmpty) {
      superseded = false; // 到数据末尾都还在？那 aliveTo 就是错的
    } else {
      superseded = after.any((e) =>
          e.roundCurrent != anchor.roundCurrent || e.groupId != anchor.groupId);
    }

    final span = aliveTo - holdFromX + 1;
    return {
      'ok': miss == 0 && mismatch == 0 && superseded,
      'span': span,
      'miss': miss,
      'mismatch': mismatch,
      'toX': toX,
      'aliveTo': aliveTo,
      'superseded': superseded,
      'refRoundCurrent': anchor.roundCurrent,
      'refGroupId': anchor.groupId,
      'roundCurrentAfter': after.isEmpty
          ? null
          : (after.first.roundCurrent.toString() +
              '/g' +
              after.first.groupId.toString()),
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
