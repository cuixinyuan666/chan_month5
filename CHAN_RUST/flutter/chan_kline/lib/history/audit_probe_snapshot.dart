import '../compute/step_rhythm_compute.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chart_indicator.dart';
import '../models/k1_analysis.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// 本次任务验收探针（设置「复制调试信息」）。
/// 只含：T1 tip三类分桶（背驰 / 比例+节奏 / 其它指标）；T2 Kn节奏主图归属。
/// 常驻按钮；内容随当前验收项更新（勿删按钮）。
class AuditProbeSnapshot {
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
      'CHAN_RUST 验收调试信息（本批：T1 tip三类分桶·T2 Kn节奏主图）',
    );
    buf.writeln('时间=$ts');
    buf.writeln(
      '代码=$code 周期=$period($periodLabel) 区间=$beginDate ~ $endDate',
    );
    buf.writeln('stepIdx=$stepIdx bars=${bars.length}');
    buf.writeln('用法：跳末后点本按钮，全文粘贴给助手。');
    buf.writeln();

    if (bars.isEmpty || stepIdx < 0) {
      buf.writeln('【中止】尚无已步进数据。');
      return buf.toString();
    }

    final lastIdx = bars[stepIdx.clamp(0, bars.length - 1)].idx;

    buf.writeln('======== T1：tooltip 三类分桶（背驰 / 比例+节奏 / 其它） ========');
    buf.writeln(
      '期望：层内用 -。- 分隔三类；序=…→背驰_*→比例+节奏*→均线等其它；'
      '禁把背驰/均线塞进比例节奏桶。',
    );
    _writeTipThreeCats(
      buf,
      bars: bars,
      sessionLevels: sessionLevels,
      barFeatures: barFeatures,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
      focusX: lastIdx,
    );
    buf.writeln();

    buf.writeln('======== T2：Kn节奏主图归属（干净迁移） ========');
    buf.writeln(
      '期望：MainIndicatorKind.stepRhythm 进主图 catalog+Kn指标层全选；'
      'Sub 无 stepRhythm；默认静音；与连线同号 0..maxKn-1；价轴挂点。',
    );
    _writeRhythmMainOwnership(buf, sessionLevels: sessionLevels);
    buf.writeln();

    buf.writeln('======== 结束 ========');
    return buf.toString();
  }

  static void _writeTipThreeCats(
    StringBuffer buf, {
    required List<KlineBar> bars,
    required List<LevelBundle> sessionLevels,
    required List<BarCrosshairFeature> barFeatures,
    required Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn,
    required int focusX,
  }) {
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
    // 只扫 K0 块（到第一个层间 === 之前的内容已含 K0 三类）
    final k0 = <CrosshairTooltipRow>[];
    var seenDate = false;
    for (final r in rows) {
      if (r.isSeparator) {
        if (seenDate && k0.isNotEmpty) break; // 下一层 ===
        seenDate = true;
        continue;
      }
      if (!seenDate) continue;
      k0.add(r);
    }

    int? iDiver;
    int? iRatio;
    int? iOther;
    for (var i = 0; i < k0.length; i++) {
      final lab = k0[i].label;
      if (iDiver == null && lab.startsWith('K0背驰')) iDiver = i;
      if (iRatio == null &&
          (lab == 'K0比例' || lab.startsWith('K0节奏'))) {
        iRatio = i;
      }
      if (iOther == null &&
          (lab == 'K0均线' ||
              lab == 'K0通道' ||
              lab.contains('连线斜率') ||
              lab.contains('MACD') ||
              lab.contains('Demark'))) {
        iOther = i;
      }
    }

    buf.writeln('扫 tip @x=$focusX（K0 块行数=${k0.length}）');
    buf.writeln(
      '首背驰行=${iDiver == null ? "null" : k0[iDiver].label} idx=$iDiver',
    );
    buf.writeln(
      '首比例/节奏行=${iRatio == null ? "null" : k0[iRatio].label} idx=$iRatio',
    );
    buf.writeln(
      '首其它指标行=${iOther == null ? "null" : k0[iOther].label} idx=$iOther',
    );

    bool hasStarBetween(int a, int b) {
      if (a < 0 || b < 0 || a >= b) return false;
      for (var i = a + 1; i < b; i++) {
        if (k0[i].isStar) return true;
      }
      return false;
    }

    final d = iDiver;
    final r = iRatio;
    final o = iOther;
    var orderOk = false;
    var sepDiverRatio = false;
    var sepRatioOther = false;
    var mixed = false;
    if (d != null && r != null && o != null && d < r && r < o) {
      orderOk = true;
      sepDiverRatio = hasStarBetween(d, r);
      sepRatioOther = hasStarBetween(r, o);
      // 抽查：背驰块内不应出现均线；比例节奏块内不应出现背驰/均线
      for (var i = d; i < r; i++) {
        final lab = k0[i].label;
        if (lab.contains('均线') || lab == 'K0比例' || lab.startsWith('K0节奏')) {
          mixed = true;
          buf.writeln('混桶？背驰区出现 $lab @i=$i');
        }
      }
      for (var i = r; i < o; i++) {
        final lab = k0[i].label;
        if (lab.startsWith('K0背驰') || lab.contains('均线')) {
          mixed = true;
          buf.writeln('混桶？比例节奏区出现 $lab @i=$i');
        }
      }
    }

    buf.writeln(
      '序OK=${orderOk ? "Y" : "N"} '
      '背驰|-。-|比例节奏=${sepDiverRatio ? "Y" : "N"} '
      '比例节奏|-。-|其它=${sepRatioOther ? "Y" : "N"} '
      '混桶=${mixed ? "Y" : "N"}',
    );
    if (orderOk && sepDiverRatio && sepRatioOther && !mixed) {
      buf.writeln('判定=OK_FIXED tip三类分桶');
    } else if (d == null || r == null || o == null) {
      buf.writeln('判定=BUG_TIP_缺类行（背驰/比例节奏/其它）');
    } else {
      buf.writeln('判定=BUG_TIP_分桶序或分隔');
    }
  }

  static void _writeRhythmMainOwnership(
    StringBuffer buf, {
    required List<LevelBundle> sessionLevels,
  }) {
    final maxKn = chartMaxKn(levels: sessionLevels);
    final mainCat = buildMainIndicatorCatalog(maxKn < 1 ? 1 : maxKn);
    final subCat = buildSubIndicatorCatalog(maxKn < 1 ? 1 : maxKn);
    final mainRhythm =
        mainCat.where((e) => e.kind == MainIndicatorKind.stepRhythm).toList();
    final subRhythmGone = !subCat.any((e) => e.label.contains('节奏'));
    // 枚举已删：用 label 兜底再确认无「K*节奏」副图项
    final lv0 = mainIndicatorsForLevel(0, mainCat);
    final subLv0 = subIndicatorsForLevel(0, subCat);
    final inLevel = lv0.any((e) => e.kind == MainIndicatorKind.stepRhythm);
    final notInSubLevel = !subLv0.any((e) => e.label.contains('节奏'));
    final mutedDefault = mainRhythm.isNotEmpty &&
        mainRhythm.every((e) => !isDefaultDrawnMain(e));
    final kns = mainRhythm.map((e) => e.kn).toList()..sort();
    final expectHi = maxKn < 1 ? 0 : maxKn - 1;
    final knRangeOk = kns.isNotEmpty &&
        kns.first == 0 &&
        kns.last == (expectHi < 0 ? 0 : expectHi);

    buf.writeln('chartMaxKn=$maxKn main节奏kn=$kns');
    buf.writeln(
      'main含stepRhythm=${mainRhythm.isNotEmpty} '
      'sub无节奏=$subRhythmGone '
      '层全选含=$inLevel 副层无=$notInSubLevel '
      '默认静音=$mutedDefault knRangeOK=$knRangeOk',
    );
    if (mainRhythm.isNotEmpty &&
        subRhythmGone &&
        inLevel &&
        notInSubLevel &&
        mutedDefault &&
        knRangeOk) {
      buf.writeln('判定=OK_FIXED 节奏主图归属干净');
    } else {
      buf.writeln('判定=BUG_节奏归属残留或层关联缺失');
    }
  }
}
