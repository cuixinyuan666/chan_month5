import '../models/bar_feature_lookup.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/chart_indicator.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';
import '../models/zs_frame.dart';

/// 从 Rust 末态 JSON 取某层中枢帧（主图/tooltip 同源，不做本地 find_zs）。
List<ZSFrame> rustZsFramesForKn({
  required int kn,
  required List<ZSFrame> zsK0Frames,
  required List<LevelBundle> levels,
}) {
  if (kn == 0) {
    return zsK0Frames;
  }
  for (final b in levels) {
    if (b.level == kn) {
      return b.zsFrames;
    }
  }
  return const [];
}

/// 从 as-of bundle 取中枢帧（十字线逐K当下）。
List<ZSFrame> rustZsFramesFromBundle({
  required KlineCombineBundle bundle,
  required int kn,
}) {
  return rustZsFramesForKn(
    kn: kn,
    zsK0Frames: bundle.zsK0Frames,
    levels: bundle.levels,
  );
}

/// 十字 as-of / 末态：读 Rust 帧。
/// asOf!=null 时必须有 asOfBundle；失败/缺失则空列表（禁回落会话末态，无未来）。
List<ZSFrame> computeZsFramesAtAsOf({
  required int kn,
  required List<KlineCombineFrame> combineFrames,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  int? asOf,
  List<KlineBar>? bars,
  bool truncationCheck = true,
  List<ZSFrame> zsK0Frames = const [],
  KlineCombineBundle? asOfBundle,
}) {
  if (asOf != null) {
    if (asOfBundle == null) return const [];
    return rustZsFramesFromBundle(bundle: asOfBundle, kn: kn);
  }
  return rustZsFramesForKn(
    kn: kn,
    zsK0Frames: zsK0Frames,
    levels: levels,
  );
}

/// 十字线 tooltip：命中 asOf 坐标的中枢 GG/DD/ZG/ZD（与主图框同源）。
/// 仿照 Kn合并 模式：每帧输出 4 行（GG/DD/ZG/ZD / K{层} idx / idx / 确认）。
List<CrosshairTooltipRow> zsCrosshairTooltipRows({
  required int asOfIdx,
  required Set<MainChartIndicator> mainIndicators,
  required List<KlineCombineFrame> combineFrames,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  int? asOf,
  List<KlineBar>? bars,
  bool truncationCheck = true,
  List<ZSFrame> zsK0Frames = const [],
  KlineCombineBundle? asOfBundle,
}) {
  final rows = <CrosshairTooltipRow>[];
  for (final ind in mainIndicators) {
    if (ind.kind != MainIndicatorKind.zs) {
      continue;
    }
    final frames = computeZsFramesAtAsOf(
      kn: ind.kn,
      combineFrames: combineFrames,
      levels: levels,
      barFeatures: barFeatures,
      asOf: asOf,
      bars: bars,
      truncationCheck: truncationCheck,
      zsK0Frames: zsK0Frames,
      asOfBundle: asOfBundle,
    );
    for (var fi = 0; fi < frames.length; fi++) {
      final f = frames[fi];
      if (asOfIdx < f.x1 || asOfIdx > f.x2) continue;
      final prefix = 'K${ind.kn}中枢';
      // 价格行：标签只留「K{n}中枢」，值仍为 GG/DD/ZG/ZD
      rows.add(CrosshairTooltipRow.kv(
        prefix,
        CrosshairTooltipRow.boxNumInString(
            'GG${f.gg.toStringAsFixed(2)}/DD${f.dd.toStringAsFixed(2)}/ZG${f.high.toStringAsFixed(2)}/ZD${f.low.toStringAsFixed(2)}'),
      ));
      // 中枢内数量行：「Kn序」里的 Kn 换为对应层级（K0中枢K0 idx / K1中枢K1 idx）
      rows.add(CrosshairTooltipRow.kv(
        '${prefix}K${ind.kn} idx',
        CrosshairTooltipRow.boxNum(f.count),
      ));
      rows.add(CrosshairTooltipRow.kv(
        '$prefix idx',
        CrosshairTooltipRow.boxNum(f.seq),
      ));
      // 上一中枢确认：仅当当前K为本中枢首根K（x1）时，检测上一框 isSure（算法不变，标签正名）
      final isFirstBar = asOfIdx == f.x1;
      final prevSure = (isFirstBar && fi > 0) ? (frames[fi - 1].isSure ? 1 : 0) : 0;
      rows.add(CrosshairTooltipRow.kv(
        'K${ind.kn}上一中枢确认',
        CrosshairTooltipRow.boxNum(prevSure),
      ));
    }
  }
  return rows;
}
