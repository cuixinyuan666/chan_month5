import '../compute/step_rhythm_compute.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bar_feature_lookup.dart';
import '../models/k1_analysis.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// 本次任务验收探针（设置「复制调试信息」）。
/// 只含：T1 K1节奏关窗持值（默认分笔·77–114 续上个 0-0）；T2 tip 与主图历史同源。
/// 常驻按钮；内容随当前验收项更新（勿删按钮）。
class AuditProbeSnapshot {
  static const int _holdFromX = 77;
  static const int _holdToX = 114;
  static const int _displayKn = 1;
  static const String _holdLabel = '0-0';

  static String build({
    required String code,
    required String period,
    required String periodLabel,
    required String beginDate,
    required String endDate,
    required int stepIdx,
    required List<KlineBar> bars,
    required List<LevelBundle> sessionLevels,
    required List<BarCrosshairFeature> barFeatures,
    Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn = const {},
  }) {
    final now = DateTime.now();
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    final buf = StringBuffer();
    buf.writeln(
      'CHAN_RUST 验收调试信息（本批：T1 K1节奏关窗持值·T2 tip同源）',
    );
    buf.writeln('时间=$ts');
    buf.writeln(
      '代码=$code 周期=$period($periodLabel) 区间=$beginDate ~ $endDate',
    );
    buf.writeln('stepIdx=$stepIdx bars=${bars.length}');
    buf.writeln(
      '期望锚点：分笔·K$_displayKn节奏·K0 $_holdFromX–$_holdToX 续上个 $_holdLabel；'
      '全层同构；tip 与主图历史同源。',
    );
    buf.writeln('用法：跳末后点本按钮，全文粘贴给助手。');
    buf.writeln();

    if (bars.isEmpty || stepIdx < 0) {
      buf.writeln('【中止】尚无已步进数据。');
      return buf.toString();
    }

    final lastIdx = bars[stepIdx.clamp(0, bars.length - 1)].idx;
    final hist = stepRhythmHistoryByKn[_displayKn] ?? const <StepRhythmLinePoint>[];

    buf.writeln(
      '======== T1：K$_displayKn 节奏关窗持值（$_holdFromX–$_holdToX 续 $_holdLabel） ========',
    );
    _writeHoldContinuity(
      buf,
      hist: hist,
      lastIdx: lastIdx,
      period: period,
    );
    buf.writeln();

    buf.writeln('======== T2：tooltip 与主图节奏历史同源 ========');
    _writeTipHistorySync(
      buf,
      bars: bars,
      sessionLevels: sessionLevels,
      barFeatures: barFeatures,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
      hist: hist,
      lastIdx: lastIdx,
    );
    buf.writeln();

    buf.writeln('======== 结束 ========');
    return buf.toString();
  }

  static void _writeHoldContinuity(
    StringBuffer buf, {
    required List<StepRhythmLinePoint> hist,
    required int lastIdx,
    required String period,
  }) {
    buf.writeln('period=$period histN=${hist.length} lastIdx=$lastIdx');
    if (lastIdx < _holdFromX) {
      buf.writeln('判定=SKIP_数据未到$_holdFromX（请跳末或换默认样本）');
      return;
    }

    final toX = lastIdx < _holdToX ? lastIdx : _holdToX;
    // 持值参照：区间起点前最近一根同 label
    StepRhythmLinePoint? ref;
    for (final p in hist) {
      if (p.label != _holdLabel) continue;
      if (p.x >= _holdFromX) continue;
      if (ref == null || p.x > ref.x) ref = p;
    }
    if (ref == null) {
      buf.writeln('判定=BUG_HOLD_无参照（$_holdFromX 前无 $_holdLabel）');
      return;
    }
    buf.writeln(
      '参照 x=${ref.x} label=${ref.label} value=${ref.value.toStringAsFixed(6)} '
      'key=${ref.key}',
    );

    var miss = 0;
    var mismatch = 0;
    var okN = 0;
    final missXs = <int>[];
    final badXs = <int>[];
    for (var x = _holdFromX; x <= toX; x++) {
      final at = hist.where((e) => e.x == x && e.label == _holdLabel).toList();
      if (at.isEmpty) {
        miss++;
        if (missXs.length < 8) missXs.add(x);
        continue;
      }
      final p = at.first;
      final sameKey = p.key == ref.key;
      final sameVal = (p.value - ref.value).abs() <= 1e-9;
      if (!sameKey || !sameVal) {
        mismatch++;
        if (badXs.length < 8) badXs.add(x);
        continue;
      }
      okN++;
    }
    final span = toX - _holdFromX + 1;
    buf.writeln(
      '扫 x=$_holdFromX..$toX span=$span ok=$okN miss=$miss mismatch=$mismatch',
    );
    if (missXs.isNotEmpty) {
      buf.writeln('缺点样例 x=$missXs');
    }
    if (badXs.isNotEmpty) {
      buf.writeln('异值样例 x=$badXs');
    }
    if (toX < _holdToX) {
      buf.writeln('注意：数据仅到 $toX，未满 $_holdToX（部分验收）');
    }
    if (miss == 0 && mismatch == 0 && okN == span) {
      buf.writeln('判定=OK_FIXED K$_displayKn节奏关窗持值');
    } else if (miss > 0) {
      buf.writeln('判定=BUG_HOLD_缺续写（关窗区间应持上个 $_holdLabel）');
    } else {
      buf.writeln('判定=BUG_HOLD_值或key漂移');
    }
  }

  static void _writeTipHistorySync(
    StringBuffer buf, {
    required List<KlineBar> bars,
    required List<LevelBundle> sessionLevels,
    required List<BarCrosshairFeature> barFeatures,
    required Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn,
    required List<StepRhythmLinePoint> hist,
    required int lastIdx,
  }) {
    // 优先在持值区内取样；不足则用最后一根有 0-0 的柱
    var focusX = _holdFromX;
    if (focusX > lastIdx) focusX = lastIdx;
    if (focusX < _holdFromX && lastIdx >= _holdFromX) {
      focusX = _holdFromX;
    }
    final inHold = hist
        .where((e) =>
            e.label == _holdLabel &&
            e.x >= _holdFromX &&
            e.x <= (lastIdx < _holdToX ? lastIdx : _holdToX))
        .toList();
    if (inHold.isNotEmpty) {
      focusX = inHold[inHold.length ~/ 2].x;
    } else {
      final any = hist.where((e) => e.label == _holdLabel).toList();
      if (any.isNotEmpty) focusX = any.last.x;
    }

    final atHist =
        hist.where((e) => e.x == focusX && e.label == _holdLabel).toList();
    buf.writeln('取样 x=$focusX hist有$_holdLabel=${atHist.isNotEmpty}');
    if (atHist.isEmpty) {
      buf.writeln('判定=BUG_TIP_历史无点（无法对同源）');
      return;
    }
    final expectVal = atHist.first.value;
    // tip 与 bar_feature_lookup 同口径：toStringAsFixed(3) 后再装箱
    final expectTipText = expectVal.toStringAsFixed(3);

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
    final tipLabel = 'K$_displayKn节奏$_holdLabel';
    CrosshairTooltipRow? tipRow;
    for (final r in rows) {
      if (r.label == tipLabel) {
        tipRow = r;
        break;
      }
    }
    buf.writeln('tip行=$tipLabel 存在=${tipRow != null}');
    if (tipRow == null) {
      buf.writeln('判定=BUG_TIP_缺节奏行');
      return;
    }
    // tip 值格式 【价】；与历史同 3 位小数口径比对（勿用全精度 vs 四舍五入）
    final tipText = tipRow.value;
    final m = RegExp(r'[-+]?\d+(?:\.\d+)?').firstMatch(tipText);
    if (m == null) {
      buf.writeln('tip原文=$tipText 判定=BUG_TIP_无数值');
      return;
    }
    final tipNumText = m.group(0)!;
    buf.writeln(
      'hist=${expectVal.toStringAsFixed(6)} hist3=$expectTipText '
      'tip原文=$tipText tipNum=$tipNumText',
    );
    if (tipNumText == expectTipText) {
      buf.writeln('判定=OK_FIXED tip与主图节奏历史同源');
    } else {
      buf.writeln('判定=BUG_TIP_与历史不同源');
    }
  }
}
