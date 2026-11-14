import '../compute/chart_view_compute.dart';
import '../models/k0_confirm_signal.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

import 'key_point.dart';

/// 关键点位收集结果（顺带带出被跳过的原因，便于面板/报告说明）。
class KeyPointCollectResult {
  final List<KeyPoint> keyPoints;

  /// 分型组内找不到极值 K 而被跳过的条数。
  final int skippedNoPole;

  /// 进行中未确认段（endConfirmX > asOf）被排除的条数。
  final int skippedUnconfirmed;

  const KeyPointCollectResult({
    required this.keyPoints,
    this.skippedNoPole = 0,
    this.skippedUnconfirmed = 0,
  });

  Map<String, dynamic> toJson() => {
        'count': keyPoints.length,
        'skipped_no_pole': skippedNoPole,
        'skipped_unconfirmed': skippedUnconfirmed,
      };
}

/// 从已冻结的连线里收集「各级别转折点」。
///
/// 口径：
/// - K0 连线（旧称笔）：以 [K0ConfirmSignal] 为主源（自带 fx 与分型组），
///   极点 K = 分型组 `[fractalX1,fractalX2]` 内极值（TOP 首个最高 high，BOTTOM 首个最低 low）；
///   [K0Line] 端点作为补源（确认信号缺失时兜底）。
/// - K{n} 连线（旧称 N 段）：以 [LevelBundle.segments] 的 `beginPoleX/endPoleX` 为主源，
///   方向优先取本层 [LevelConfirm] 同 `poleX` 的 `fx`，取不到才按 `dir` 推断。
/// - 只收 `confirmX <= asOf` 的已确认转折点；进行中段不统计。
/// - 去重：同层 + 同 x + 同方向只留一条（先到先得，主源优先）。
KeyPointCollectResult collectKeyPoints({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<K0Line> k0Lines = const [],
  required int asOf,
}) {
  final out = <String, KeyPoint>{};
  var skippedNoPole = 0;
  var skippedUnconfirmed = 0;

  void put(KeyPoint p) {
    if (p.poleX < 0 || p.poleX > asOf) return;
    if (p.confirmX > asOf) {
      skippedUnconfirmed++;
      return;
    }
    out.putIfAbsent(p.dedupKey, () => p);
  }

  // ---- K0 连线：确认信号为主源 ----
  for (final sig in k0Confirms) {
    if (sig.fx != 'TOP' && sig.fx != 'BOTTOM') continue;
    final pole = fractalExtremeBarIdxRaw(
      bars,
      fx: sig.fx,
      fractalX1: sig.fractalX1,
      fractalX2: sig.fractalX2,
    );
    if (pole == null) {
      skippedNoPole++;
      continue;
    }
    put(KeyPoint(
      level: 0,
      fx: sig.fx,
      poleX: pole,
      confirmX: sig.x,
      source: 'k0_confirm',
    ));
  }

  // ---- K0 连线：端点兜底（dir>0 = 向上：起点底、终点顶）----
  for (final line in k0Lines) {
    if (line.endConfirmX > asOf) {
      skippedUnconfirmed++;
      continue;
    }
    final up = line.dir >= 0;
    final beginFx = up ? 'BOTTOM' : 'TOP';
    final endFx = up ? 'TOP' : 'BOTTOM';
    final bp = fractalExtremeBarIdxRaw(
      bars,
      fx: beginFx,
      fractalX1: line.beginFractalX1,
      fractalX2: line.beginFractalX2,
    );
    if (bp != null) {
      put(KeyPoint(
        level: 0,
        fx: beginFx,
        poleX: bp,
        confirmX: line.beginConfirmX,
        source: 'k0_line',
      ));
    } else {
      skippedNoPole++;
    }
    final ep = fractalExtremeBarIdxRaw(
      bars,
      fx: endFx,
      fractalX1: line.endFractalX1,
      fractalX2: line.endFractalX2,
    );
    if (ep != null) {
      put(KeyPoint(
        level: 0,
        fx: endFx,
        poleX: ep,
        confirmX: line.endConfirmX,
        source: 'k0_line',
      ));
    } else {
      skippedNoPole++;
    }
  }

  // ---- K{n} 连线：各层冻结段端点 + 本层确认分型交叉校验 ----
  for (final lv in levels) {
    final fxByPoleX = <int, String>{};
    for (final c in lv.confirms) {
      if (c.value != 1 && c.value != -1) continue;
      if (c.poleX < 0) continue;
      fxByPoleX.putIfAbsent(c.poleX, () => c.value == -1 ? 'TOP' : 'BOTTOM');
    }

    for (final seg in lv.segments) {
      if (seg.endConfirmX > asOf) {
        skippedUnconfirmed++;
        continue;
      }
      final up = seg.dir >= 0;
      final beginFx = fxByPoleX[seg.beginPoleX] ?? (up ? 'BOTTOM' : 'TOP');
      final endFx = fxByPoleX[seg.endPoleX] ?? (up ? 'TOP' : 'BOTTOM');
      if (seg.beginPoleX >= 0) {
        put(KeyPoint(
          level: lv.level,
          fx: beginFx,
          poleX: seg.beginPoleX,
          confirmX: seg.beginConfirmX,
          source: 'kn_segment',
        ));
      }
      if (seg.endPoleX >= 0) {
        put(KeyPoint(
          level: lv.level,
          fx: endFx,
          poleX: seg.endPoleX,
          confirmX: seg.endConfirmX,
          source: 'kn_segment',
        ));
      }
    }

    // 补源：已确认但还没成段的端点（段一旦成段，上面的主源已收过，这里只填空）
    for (final c in lv.confirms) {
      if (c.value != 1 && c.value != -1) continue;
      if (c.x > asOf) {
        skippedUnconfirmed++;
        continue;
      }
      final pole = c.poleX >= 0
          ? c.poleX
          : fractalExtremeBarIdxRaw(
              bars,
              fx: c.value == -1 ? 'TOP' : 'BOTTOM',
              fractalX1: c.fractalX1,
              fractalX2: c.fractalX2,
            );
      if (pole == null) {
        skippedNoPole++;
        continue;
      }
      put(KeyPoint(
        level: lv.level,
        fx: c.value == -1 ? 'TOP' : 'BOTTOM',
        poleX: pole,
        confirmX: c.x,
        source: 'kn_confirm',
      ));
    }
  }

  final list = out.values.toList()
    ..sort((a, b) {
      final c = a.level.compareTo(b.level);
      if (c != 0) return c;
      return a.poleX.compareTo(b.poleX);
    });
  return KeyPointCollectResult(
    keyPoints: list,
    skippedNoPole: skippedNoPole,
    skippedUnconfirmed: skippedUnconfirmed,
  );
}