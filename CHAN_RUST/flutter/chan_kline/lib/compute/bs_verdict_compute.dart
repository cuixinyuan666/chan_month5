/// BSP 在线对错会话冻结（Rust 是唯一评判源；Flutter 只收/冻/按 asOf 展示）。
import '../models/bs_verdict_frame.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';

String bsVerdictStableKey(BsVerdictFrame p) => p.stableKey;

/// 步进合并：终态只写一次（Pending→Correct/Wrong），禁止回翻。
void mergeBsVerdictLog(
  List<BsVerdictFrame> history,
  List<BsVerdictFrame> fresh,
) {
  if (fresh.isEmpty) return;
  final byKey = <String, int>{
    for (var i = 0; i < history.length; i++) history[i].stableKey: i,
  };
  for (final p in fresh) {
    final k = p.stableKey;
    final idx = byKey[k];
    if (idx == null) {
      byKey[k] = history.length;
      history.add(p);
      continue;
    }
    final old = history[idx];
    if (old.isCorrect || old.isWrong) continue; // 终态冻结
    if (p.isPending) continue;
    history[idx] = p; // Pending → Correct/Wrong
  }
}

/// 方案B：out[0]=k0；写 out[lv.level+1]（禁盖 K0）。
Map<int, List<BsVerdictFrame>> collectBsVerdictByKn(KlineCombineBundle bundle) {
  final out = <int, List<BsVerdictFrame>>{
    0: List<BsVerdictFrame>.from(bundle.bsVerdictK0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level + 1] = List<BsVerdictFrame>.from(lv.bsVerdictFrames);
  }
  return out;
}

List<BsVerdictFrame> bsVerdictHistoryForKn(
  Map<int, List<BsVerdictFrame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

/// asOf 展示：终态 x > asOf 则仍当 Pending（禁止提前亮 Correct/Wrong）。
BsVerdictFrame? verdictAtAsOf(
  Iterable<BsVerdictFrame> frames, {
  required int level,
  required String side,
  required int cls,
  required int segIdx,
  required String label,
  required int asOf,
}) {
  for (final v in frames) {
    if (v.level != level ||
        v.side != side ||
        v.cls != cls ||
        v.segIdx != segIdx ||
        v.label != label) {
      continue;
    }
    if (v.isPending) return v;
    final vx = v.verdictX;
    if (vx == null || vx > asOf) {
      return BsVerdictFrame(
        level: v.level,
        side: v.side,
        cls: v.cls,
        label: v.label,
        segIdx: v.segIdx,
        bspX: v.bspX,
        price: v.price,
        zsSeq: v.zsSeq,
        state: 'pending',
        createX: v.createX,
        reason: 'asof_pending',
      );
    }
    return v;
  }
  return null;
}

List<LevelBundle> levelsWithFrozenBsVerdict(
  List<LevelBundle> levels, {
  required Map<int, List<BsVerdictFrame>> historyByKn,
}) {
  return levels
      .map(
        (lv) => LevelBundle(
          level: lv.level,
          confirms: lv.confirms,
          segments: lv.segments,
          unitBars: lv.unitBars,
          combineFrames: lv.combineFrames,
          zsFrames: lv.zsFrames,
          buy1Frames: lv.buy1Frames,
          sell1Frames: lv.sell1Frames,
          buy2Frames: lv.buy2Frames,
          sell2Frames: lv.sell2Frames,
          buyNFrames: lv.buyNFrames,
          sellNFrames: lv.sellNFrames,
          bsVerdictFrames: historyByKn[lv.level + 1] ?? lv.bsVerdictFrames,
          firstDir: lv.firstDir,
          firstDirX: lv.firstDirX,
          activeUnit: lv.activeUnit,
          segmentPolicy: lv.segmentPolicy,
          pendingUnit: lv.pendingUnit,
        ),
      )
      .toList();
}
