import '../models/bar_feature_lookup.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/chart_indicator.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';
import '../models/zs_frame.dart';

/// 中枢算法（对齐 Rust `ZSAlgo`；Auto 已放弃）
enum ZSAlgoKind {
  normal,
  overSeg,
}

/// 从 Rust 末态 JSON 取某层中枢帧（主图/tooltip 同源，不做本地 find_zs）。
List<ZSFrame> rustZsFramesForKn({
  required int kn,
  required ZSAlgoKind algo,
  required List<ZSFrame> zsK0NormalFrames,
  required List<ZSFrame> zsK0OverSegFrames,
  required List<LevelBundle> levels,
}) {
  final overSeg = algo == ZSAlgoKind.overSeg;
  if (kn == 0) {
    return overSeg ? zsK0OverSegFrames : zsK0NormalFrames;
  }
  for (final b in levels) {
    if (b.level == kn) {
      return overSeg ? b.zsOverSegFrames : b.zsNormalFrames;
    }
  }
  return const [];
}

/// 从 as-of bundle 取中枢帧（十字线逐K当下）。
List<ZSFrame> rustZsFramesFromBundle({
  required KlineCombineBundle bundle,
  required int kn,
  required ZSAlgoKind algo,
}) {
  return rustZsFramesForKn(
    kn: kn,
    algo: algo,
    zsK0NormalFrames: bundle.zsK0NormalFrames,
    zsK0OverSegFrames: bundle.zsK0OverSegFrames,
    levels: bundle.levels,
  );
}

/// 十字 as-of / 末态：读 Rust 帧；asOf!=null 时须传入对应 as-of bundle。
List<ZSFrame> computeZsFramesAtAsOf({
  required int kn,
  required ZSAlgoKind algo,
  required List<KlineCombineFrame> combineFrames,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  int? asOf,
  List<KlineBar>? bars,
  bool truncationCheck = true,
  List<ZSFrame> zsK0NormalFrames = const [],
  List<ZSFrame> zsK0OverSegFrames = const [],
  KlineCombineBundle? asOfBundle,
}) {
  if (asOf != null && asOfBundle != null) {
    return rustZsFramesFromBundle(bundle: asOfBundle, kn: kn, algo: algo);
  }
  return rustZsFramesForKn(
    kn: kn,
    algo: algo,
    zsK0NormalFrames: zsK0NormalFrames,
    zsK0OverSegFrames: zsK0OverSegFrames,
    levels: levels,
  );
}

/// 十字线 tooltip：命中 asOf 坐标的中枢 ZG/ZD（与主图框同源）。
List<CrosshairTooltipRow> zsCrosshairTooltipRows({
  required int asOfIdx,
  required Set<MainChartIndicator> mainIndicators,
  required List<KlineCombineFrame> combineFrames,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  int? asOf,
  List<KlineBar>? bars,
  bool truncationCheck = true,
  List<ZSFrame> zsK0NormalFrames = const [],
  List<ZSFrame> zsK0OverSegFrames = const [],
  KlineCombineBundle? asOfBundle,
}) {
  final rows = <CrosshairTooltipRow>[];
  for (final ind in mainIndicators) {
    if (ind.kind != MainIndicatorKind.zsNormal &&
        ind.kind != MainIndicatorKind.zsOverSeg) {
      continue;
    }
    final algo = ind.kind == MainIndicatorKind.zsOverSeg
        ? ZSAlgoKind.overSeg
        : ZSAlgoKind.normal;
    final algoTag = algo == ZSAlgoKind.overSeg ? 'OverSeg' : 'Normal';
    final frames = computeZsFramesAtAsOf(
      kn: ind.kn,
      algo: algo,
      combineFrames: combineFrames,
      levels: levels,
      barFeatures: barFeatures,
      asOf: asOf,
      bars: bars,
      truncationCheck: truncationCheck,
      zsK0NormalFrames: zsK0NormalFrames,
      zsK0OverSegFrames: zsK0OverSegFrames,
      asOfBundle: asOfBundle,
    );
    for (final f in frames) {
      if (asOfIdx < f.x1 || asOfIdx > f.x2) continue;
      final seq = f.seq > 0 ? f.seq : 0;
      final dirMark = f.dir > 0 ? '↑' : (f.dir < 0 ? '↓' : '');
      rows.add(
        CrosshairTooltipRow.kv(
          'K${ind.kn}中枢($algoTag)$seq·${f.count}$dirMark ZG/ZD',
          'ZG${f.low.toStringAsFixed(2)}/ZD${f.high.toStringAsFixed(2)}',
        ),
      );
    }
  }
  return rows;
}
