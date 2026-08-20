import '../compute/adjacent_ratio_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/step_rhythm_compute.dart';

/// 回测只读现有会话历史：斜率 / 比例 / 节奏。不现场重算连线。
class ChartLineStore {
  final Map<int, List<AdjacentRatioPoint>> adjacentRatioByKn;
  final Map<int, List<LineSlopePoint>> lineSlopeByKn;
  final Map<int, List<StepRhythmLinePoint>> stepRhythmByKn;

  const ChartLineStore({
    this.adjacentRatioByKn = const {},
    this.lineSlopeByKn = const {},
    this.stepRhythmByKn = const {},
  });

  static const empty = ChartLineStore();

  bool get isEmpty =>
      adjacentRatioByKn.isEmpty &&
      lineSlopeByKn.isEmpty &&
      stepRhythmByKn.isEmpty;
}

double? lineSlopeAt(ChartLineStore store, int kn, int asOf) {
  for (final p in store.lineSlopeByKn[kn] ?? const <LineSlopePoint>[]) {
    if (p.x == asOf) return p.slope;
  }
  return null;
}

double? adjacentRatioAt(ChartLineStore store, int kn, int asOf) {
  for (final p in store.adjacentRatioByKn[kn] ?? const <AdjacentRatioPoint>[]) {
    if (p.x == asOf) return p.ratio;
  }
  return null;
}

/// 当根第一条节奏投影价（关窗持值已写在历史里）；没有线=空。
double? stepRhythmAt(ChartLineStore store, int kn, int asOf) {
  for (final p in store.stepRhythmByKn[kn] ?? const <StepRhythmLinePoint>[]) {
    if (p.x == asOf) return p.value;
  }
  return null;
}
