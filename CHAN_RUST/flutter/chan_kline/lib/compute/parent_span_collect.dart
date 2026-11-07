import 'dart:math' as math;

import '../models/level_models.dart';

/// 父段区间（冻段或 active）；供 Kn趋势线 / 极贴合线共用。
class ParentSpan {
  final int beginX;
  final int endX;
  final int confirmMax;
  final int idx;
  final int dir; // +1 up / -1 down

  const ParentSpan({
    required this.beginX,
    required this.endX,
    required this.confirmMax,
    required this.idx,
    required this.dir,
  });
}

LevelBundle? bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

/// 收集父层段（asOf 截断 endConfirmX）。
List<ParentSpan> collectParentSpans(LevelBundle parentLv, int? asOf) {
  final out = <ParentSpan>[];
  for (final s in parentLv.segments) {
    if (s.dir != 1 && s.dir != -1) continue;
    if (asOf != null && s.endConfirmX > asOf) continue;
    if (s.beginPoleX < 0 || s.endPoleX < 0) continue;
    out.add(ParentSpan(
      beginX: math.min(s.beginPoleX, s.endPoleX),
      endX: math.max(s.beginPoleX, s.endPoleX),
      confirmMax: s.endConfirmX,
      idx: s.idx,
      dir: s.dir,
    ));
  }
  final act = parentLv.activeUnit;
  if (act != null && (act.dir == 1 || act.dir == -1)) {
    if (asOf == null || act.x1 <= asOf) {
      final lo = math.min(act.x1, act.x2);
      final hi = asOf != null
          ? math.min(math.max(act.x1, act.x2), asOf)
          : math.max(act.x1, act.x2);
      if (lo >= 0 && hi >= lo) {
        final i = out.indexWhere((e) => e.idx == act.idx);
        final span = ParentSpan(
          beginX: lo,
          endX: hi,
          confirmMax: asOf ?? act.x2,
          idx: act.idx,
          dir: act.dir,
        );
        if (i >= 0) {
          out[i] = span;
        } else {
          out.add(span);
        }
      }
    }
  }
  out.sort((a, b) {
    final c = a.beginX.compareTo(b.beginX);
    return c != 0 ? c : a.idx.compareTo(b.idx);
  });
  return out;
}
