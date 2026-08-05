import '../models/kline_combine_bundle.dart';
import '../models/zs_frame.dart';
import '../models/zs_signal_event.dart';

export '../models/zs_signal_event.dart';

// =============================================================================
// Kn中枢确认 / Kn中枢判断（副图·全层同构）
//
// 语义：都是对「上个中枢」的确认或判断（对齐分型确认/判断的稀疏打点）。
// 色/值：相对前一中枢中轴——抬高=升红(+1)，下移=降绿(-1)。
// 踩坑：禁止用框 first.dir 上色（常与位置升降相反，如 85 确认 dir=-1 却抬高=红）。
// 冻结：写入会话后不回写；十字 asOf 只滤 x>asOf。
// =============================================================================

/// 符号：升 +1 / 降 -1。
int zsDirToSigned(int dir) => dir >= 0 ? 1 : -1;

/// 「上个中枢」升降趋势（确认/判断统一色源）。
/// 相对前一中枢中轴：抬高→升(+1红)，下移→降(-1绿)；无前枢回退 first.dir。
/// 踩坑：勿用框自身 first.dir——与位置升降常相反（例 x1=51 dir=-1 却抬高=升红）。
int zsSpatialTrendDir(ZSFrame cur, ZSFrame? prev) {
  if (prev == null) return zsDirToSigned(cur.dir);
  final cm = (cur.high + cur.low) / 2.0;
  final pm = (prev.high + prev.low) / 2.0;
  if (cm > pm) return 1;
  if (cm < pm) return -1;
  return zsDirToSigned(cur.dir);
}

/// [all] 中 [target] 的前一框（按列表序=时间序）。
ZSFrame? zsFrameBefore(List<ZSFrame> all, ZSFrame target) {
  for (var i = 0; i < all.length; i++) {
    final f = all[i];
    if (f.x1 == target.x1 &&
        f.x2 == target.x2 &&
        f.isSure == target.isSure &&
        f.dir == target.dir) {
      return i > 0 ? all[i - 1] : null;
    }
  }
  return null;
}

/// 稳定身份：层|中枢左端（seq 合并会变号，勿用）。
String zsSignalStableKey(int kn, int x1) => '$kn|$x1';

/// 颗粒度键：含 x（离开窗内可多点；单开放只首次）。
String zsSignalEventKey(ZsSignalEvent e) =>
    '${zsSignalStableKey(e.kn, e.x1)}|${e.x}';

/// 打点身份用 [anchor]；值/色用 [refDir]（上个中枢空间趋势）。
ZsSignalEvent _eventFromFrame({
  required ZSFrame anchor,
  required int refDir,
  required int kn,
  required int discoveryX,
}) {
  return ZsSignalEvent(
    x: discoveryX,
    kn: kn,
    seq: anchor.seq,
    x1: anchor.x1,
    dir: refDir,
    value: zsDirToSigned(refDir),
  );
}

/// 中枢判断：对齐分型判断的稀疏呈现。
/// - 仅 1 个不确定框：稳定键首次出现打一点；已见过不再刷。
/// - ≥2 个不确定：末个=离开候选可逐K追加；色/值跟被离开的上个框之空间趋势。
/// - 禁止对「单独开放枢」逐步刷点。
void mergeZsJudgmentEventLog(
  List<ZsSignalEvent> history,
  List<ZSFrame> fresh, {
  required int kn,
  required int discoveryX,
}) {
  final unsure = [for (final f in fresh) if (!f.isSure) f];
  if (unsure.isEmpty) return;
  final seen = <String>{for (final e in history) zsSignalEventKey(e)};
  final seenStable = <String>{
    for (final e in history) zsSignalStableKey(e.kn, e.x1),
  };

  if (unsure.length >= 2) {
    // 离开窗：身份=新候选；色=被离开上个框相对再前一框的抬高/下移
    final old = unsure[unsure.length - 2];
    final f = unsure.last;
    if (f.x1 < 0) return;
    final refDir = zsSpatialTrendDir(old, zsFrameBefore(fresh, old));
    final ev = _eventFromFrame(
      anchor: f,
      refDir: refDir,
      kn: kn,
      discoveryX: discoveryX,
    );
    if (seen.add(zsSignalEventKey(ev))) {
      history.add(ev);
      seenStable.add(zsSignalStableKey(kn, f.x1));
    }
    return;
  }

  // 单开放：色=该框相对上一枢的空间趋势
  final f = unsure.first;
  if (f.x1 < 0) return;
  final stable = zsSignalStableKey(kn, f.x1);
  if (seenStable.contains(stable)) return;
  final refDir = zsSpatialTrendDir(f, zsFrameBefore(fresh, f));
  final ev = _eventFromFrame(
    anchor: f,
    refDir: refDir,
    kn: kn,
    discoveryX: discoveryX,
  );
  if (seen.add(zsSignalEventKey(ev))) {
    history.add(ev);
  }
}

/// 中枢确认：is_sure 首次当步打点；色/值=刚定型上个框相对前一枢的空间趋势。
void mergeZsConfirmEventLog(
  List<ZsSignalEvent> history,
  List<ZSFrame> fresh, {
  required int kn,
  required int discoveryX,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) zsSignalEventKey(e)};
  final seenStable = <String>{
    for (final e in history) zsSignalStableKey(e.kn, e.x1),
  };
  for (final f in fresh) {
    if (!f.isSure || f.x1 < 0) continue;
    final stable = zsSignalStableKey(kn, f.x1);
    if (seenStable.contains(stable)) continue;
    final refDir = zsSpatialTrendDir(f, zsFrameBefore(fresh, f));
    final ev = _eventFromFrame(
      anchor: f,
      refDir: refDir,
      kn: kn,
      discoveryX: discoveryX,
    );
    if (seen.add(zsSignalEventKey(ev))) {
      history.add(ev);
      seenStable.add(stable);
    }
  }
}

/// 本步各层中枢帧（K0 + levels）。
Map<int, List<ZSFrame>> collectZsFramesByKn(KlineCombineBundle bundle) {
  final out = <int, List<ZSFrame>>{
    0: List<ZSFrame>.from(bundle.zsK0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level] = List<ZSFrame>.from(lv.zsFrames);
  }
  return out;
}

/// 事件 → 稀疏 ± 序列（同 x 后者覆盖；maxX 藏未来）。
List<int> expandZsSignalToSeries(
  List<ZsSignalEvent> events,
  int barCount, {
  int? maxX,
}) {
  if (barCount <= 0) return const [];
  final out = List<int>.filled(barCount, 0);
  for (final e in events) {
    if (e.x < 0 || e.x >= barCount) continue;
    if (maxX != null && e.x > maxX) continue;
    if (e.value == 0) continue;
    out[e.x] = e.value;
  }
  return out;
}

/// 十字读数：取 asOf 处值（无点=0）。
int zsSignalValueAt(List<ZsSignalEvent> events, int asOfIdx) {
  var v = 0;
  for (final e in events) {
    if (e.x == asOfIdx && e.value != 0) v = e.value;
  }
  return v;
}
