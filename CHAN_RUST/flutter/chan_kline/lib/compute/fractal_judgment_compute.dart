import '../models/bar_crosshair_feature.dart';
import '../models/fractal_judgment_event.dart';
import '../models/k1_bar.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'chart_view_compute.dart';
import 'k0_combine_compute.dart';
import 'k1_combine_compute.dart';

export '../models/fractal_judgment_event.dart';

/// 判断事件 → 逐 K0 稀疏序列（仅成立当步有 TOP/BOTTOM，其余 UNKNOWN；禁止整框回填）。
List<String> expandJudgmentEventsToSeries(
  List<FractalJudgmentEvent> events,
  int barCount,
) {
  if (barCount <= 0) return const [];
  final out = List<String>.filled(barCount, 'UNKNOWN');
  for (final e in events) {
    if (e.x < 0 || e.x >= barCount) continue;
    if (e.fx != 'TOP' && e.fx != 'BOTTOM') continue;
    out[e.x] = e.fx;
  }
  return out;
}

/// TOP=-1，BOTTOM=+1，其它=0（与分型确认 value 同号约定）。
int fxToSigned(String fx) {
  if (fx == 'TOP') return -1;
  if (fx == 'BOTTOM') return 1;
  return 0;
}

/// 全层同构：展示轨分型判断（确认式打点，不回写 LevelConfirm）。
/// 只在三元素/截断使分型成立的当步打点；无合并框整段向前赋值。
List<String> computeFractalJudgmentSeries({
  required int kn,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  int? asOf,
  bool truncationCheck = true,
}) {
  if (bars.isEmpty || kn < 1) return const [];
  final end = asOf ?? bars.last.idx;
  final barsSlice = bars.where((b) => b.idx <= end).toList();
  if (barsSlice.isEmpty) return const [];

  final events = <FractalJudgmentEvent>[];
  if (kn == 1) {
    computeK0CombineFrames(
      barsSlice,
      truncationCheck: truncationCheck,
      judgmentEvents: events,
    );
  } else {
    final unitLevel = kn - 1;
    final List<K1Bar> virtualUnits;
    if (asOf != null) {
      virtualUnits = asOfLevelVirtualK1Bars(
        levels: levels,
        barFeatures: barFeatures,
        level: unitLevel,
        asOf: asOf,
        includeBuilding: true,
      );
    } else {
      LevelBundle? bundle;
      for (final lv in levels) {
        if (lv.level == unitLevel) {
          bundle = lv;
          break;
        }
      }
      virtualUnits =
          bundle == null ? const <K1Bar>[] : levelBundleVirtualK1Bars(bundle);
    }
    computeK1CombineFrames(
      barsSlice,
      virtualUnits,
      truncationCheck: truncationCheck,
      judgmentEvents: events,
    );
  }

  final maxIdx = bars.last.idx;
  return expandJudgmentEventsToSeries(events, maxIdx + 1);
}

/// 判断序列 → 副图 ±1 值（按 bars 顺序；越界 idx 跳过）。
List<int> fractalJudgmentSignedSeries(
  List<String> fxSeries,
  List<KlineBar> bars,
) {
  return [
    for (final b in bars)
      b.idx >= 0 && b.idx < fxSeries.length
          ? fxToSigned(fxSeries[b.idx])
          : 0,
  ];
}
