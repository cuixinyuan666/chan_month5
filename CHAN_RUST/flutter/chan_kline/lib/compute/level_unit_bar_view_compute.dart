import '../models/level_models.dart';

/// Kn 单元线展示视图：与 K1 bar [K1BarView] 同构（半侧衔接）。
class LevelUnitBarView {
  final LevelUnitBar bar;
  final int viewX1;
  final int viewX2;
  final bool endAtLeftHalf;
  final bool startAtRightHalf;

  const LevelUnitBarView({
    required this.bar,
    required this.viewX1,
    required this.viewX2,
    this.endAtLeftHalf = false,
    this.startAtRightHalf = false,
  });

  int get idx => bar.idx;
  int get dir => bar.dir;
  double get open => bar.open;
  double get high => bar.high;
  double get low => bar.low;
  double get close => bar.close;
  bool get isUp => close >= open;
}

/// 由层内 unitBars（+可选 active）生成半侧衔接视图，仿 K1 bar 合并底层。
List<LevelUnitBarView> buildLevelUnitBarViews(
  List<LevelUnitBar> unitBars, {
  LevelUnitBar? activeUnit,
}) {
  final bars = <LevelUnitBar>[...unitBars];
  if (activeUnit != null) {
    final last = bars.isEmpty ? null : bars.last;
    // 进行中单元尚未进 unitBars，或末根仍在延伸时补画
    if (last == null ||
        activeUnit.idx != last.idx ||
        activeUnit.x2 != last.x2 ||
        activeUnit.high != last.high ||
        activeUnit.low != last.low) {
      if (last != null && activeUnit.idx == last.idx) {
        bars[bars.length - 1] = activeUnit;
      } else {
        bars.add(activeUnit);
      }
    }
  }
  if (bars.isEmpty) return const [];

  final n = bars.length;
  final viewX1 = List<int>.generate(n, (i) => bars[i].x1);
  final viewX2 = List<int>.generate(n, (i) => bars[i].x2);
  final endAtLeftHalf = List<bool>.filled(n, false);
  final startAtRightHalf = List<bool>.filled(n, false);

  for (var i = 0; i < n - 1; i++) {
    final cur = bars[i];
    final next = bars[i + 1];
    if (next.x1 <= cur.x2) {
      final junction = cur.x2.clamp(cur.x1, next.x2);
      viewX2[i] = junction;
      viewX1[i + 1] = junction;
      endAtLeftHalf[i] = true;
      startAtRightHalf[i + 1] = true;
    }
  }

  for (var i = 0; i < n; i++) {
    if (viewX2[i] < viewX1[i]) viewX2[i] = viewX1[i];
  }

  return List.generate(
    n,
    (i) => LevelUnitBarView(
      bar: bars[i],
      viewX1: viewX1[i],
      viewX2: viewX2[i],
      endAtLeftHalf: endAtLeftHalf[i],
      startAtRightHalf: startAtRightHalf[i],
    ),
  );
}
