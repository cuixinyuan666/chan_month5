import '../models/bar_crosshair_feature.dart';
import '../models/fractal_judgment_event.dart';
import '../models/k1_bar.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'chart_view_compute.dart';
import 'k0_combine_compute.dart';
import 'k1_combine_compute.dart';

export '../models/fractal_judgment_event.dart';

/// TOP=-1，BOTTOM=+1，其它=0（与分型确认 value 同号约定）。
int fxToSigned(String fx) {
  if (fx == 'TOP') return -1;
  if (fx == 'BOTTOM') return 1;
  return 0;
}

String _eventKey(FractalJudgmentEvent e) =>
    '${e.x}|${e.fx}|${e.truncated ? 1 : 0}';

/// 步进累积：把本步事件追加进历史日志（按 x+fx+截断 去重；绝不删旧点）。
void mergeFractalJudgmentEventLog(
  List<FractalJudgmentEvent> history,
  List<FractalJudgmentEvent> fresh,
) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) _eventKey(e)};
  for (final e in fresh) {
    if (e.fx != 'TOP' && e.fx != 'BOTTOM') continue;
    if (e.x < 0) continue;
    final k = _eventKey(e);
    if (seen.add(k)) {
      history.add(e);
    }
  }
}

/// 采集本步展示轨分型判断事件（确认式；不回写 LevelConfirm）。
List<FractalJudgmentEvent> collectFractalJudgmentEvents({
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
  return events;
}

/// 事件 → 稀疏序列（同 x 后者覆盖；[maxX] 藏未来；绘制优先直接扫事件列表）。
List<String> expandJudgmentEventsToSeries(
  List<FractalJudgmentEvent> events,
  int barCount, {
  int? maxX,
}) {
  if (barCount <= 0) return const [];
  final out = List<String>.filled(barCount, 'UNKNOWN');
  for (final e in events) {
    if (e.x < 0 || e.x >= barCount) continue;
    if (maxX != null && e.x > maxX) continue;
    if (e.fx != 'TOP' && e.fx != 'BOTTOM') continue;
    out[e.x] = e.fx;
  }
  return out;
}

/// @Deprecated 请用 [collectFractalJudgmentEvents] + 事件日志累积
List<String> computeFractalJudgmentSeries({
  required int kn,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  int? asOf,
  bool truncationCheck = true,
}) {
  if (bars.isEmpty) return const [];
  final events = collectFractalJudgmentEvents(
    kn: kn,
    bars: bars,
    levels: levels,
    barFeatures: barFeatures,
    asOf: asOf,
    truncationCheck: truncationCheck,
  );
  return expandJudgmentEventsToSeries(events, bars.last.idx + 1);
}

/// 判断序列 → 副图 ±1 值（按 bars 顺序）。
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
