import '../models/kline_combine_bundle.dart';
import '../models/zs_frame.dart';
import '../models/zs_signal_event.dart';

export '../models/zs_signal_event.dart';

// =============================================================================
// Kn中枢确认 / Kn中枢判断（副图·全层无差别同构）
//
// 【口径】对象=尚未确认的中枢，不是新芽/新中枢（与分型判断/确认同一精神）。
// K0 无动态 Kn：离开常与定型同拍 → 判断与确认同 x、同 x1 → 副图标记重叠（预期）。
// Kn≥1 动态离开可多步打判断；定型当步仍与确认共点。规则无层特例。
//
// 判断：
// - ≥2 不确定（离开窗/动态离开）：对尚未确认的上个框（倒数第二）可逐K打点。
// - 本步刚确认的框：同拍再打一点判断（身份=刚定型的原先未确认框）→ 与确认重叠。
// - 禁止单开放给新种子/唯一新芽打「首次可判」。
// 确认：is_sure 首次当步。
// 色/值：相对前一中枢中轴抬高红、下移绿；禁 first.dir。
// 冻结：写入后不回写；十字 asOf 只滤 x>asOf。
//
// 【经验/踩坑·2026-08-06】
// 1) 勿用 first.dir 配色——常与空间升降相反。
// 2) 勿给同拍新芽打判断（idx=7：确认 x1=6 / 误判 x1=7）——对象永远是未确认上个。
// 3) 勿把「对齐分型首次可判」套到中枢新芽：会破坏 K0「判断=确认重叠」预期。
// 4) 「只离开窗、确认当步不共点」→ K0 判断易全 0；须确认同拍对刚定型框补判断。
// 5) 先 merge 确认再判断，把 confirmedX1ThisStep 传入判断。
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

/// 颗粒度键：含 x（离开窗内可多点；确认同拍与确认共点）。
String zsSignalEventKey(ZsSignalEvent e) =>
    '${zsSignalStableKey(e.kn, e.x1)}|${e.x}';

/// 打点身份用 [anchor]；值/色用 [refDir]（空间趋势）。
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

void _tryAppendJudgment(
  List<ZsSignalEvent> history,
  Set<String> seen, {
  required ZSFrame anchor,
  required List<ZSFrame> fresh,
  required int kn,
  required int discoveryX,
}) {
  if (anchor.x1 < 0) return;
  final refDir = zsSpatialTrendDir(anchor, zsFrameBefore(fresh, anchor));
  final ev = _eventFromFrame(
    anchor: anchor,
    refDir: refDir,
    kn: kn,
    discoveryX: discoveryX,
  );
  if (seen.add(zsSignalEventKey(ev))) {
    history.add(ev);
  }
}

/// 中枢判断（全层同构）：
/// - 离开窗：对尚未确认的上个框打点。
/// - [confirmedX1ThisStep]：对刚确认的框同拍打判断 → 与确认重叠。
/// - 不打新芽/单开放首次。
void mergeZsJudgmentEventLog(
  List<ZsSignalEvent> history,
  List<ZSFrame> fresh, {
  required int kn,
  required int discoveryX,
  Set<int> confirmedX1ThisStep = const {},
}) {
  final seen = <String>{for (final e in history) zsSignalEventKey(e)};
  final unsure = [for (final f in fresh) if (!f.isSure) f];

  // 离开窗 / 动态离开：对尚未确认的上个框（倒数第二）
  if (unsure.length >= 2) {
    _tryAppendJudgment(
      history,
      seen,
      anchor: unsure[unsure.length - 2],
      fresh: fresh,
      kn: kn,
      discoveryX: discoveryX,
    );
  }

  // 确认同拍：判断身份=刚定型的原先未确认框（与确认同 x/x1 → 重叠）
  for (final x1 in confirmedX1ThisStep) {
    ZSFrame? anchor;
    for (final f in fresh) {
      if (f.isSure && f.x1 == x1) {
        anchor = f;
        break;
      }
    }
    if (anchor == null) continue;
    _tryAppendJudgment(
      history,
      seen,
      anchor: anchor,
      fresh: fresh,
      kn: kn,
      discoveryX: discoveryX,
    );
  }
}

/// 中枢确认：is_sure 首次当步打点；返回本步新确认的 x1 集合。
Set<int> mergeZsConfirmEventLog(
  List<ZsSignalEvent> history,
  List<ZSFrame> fresh, {
  required int kn,
  required int discoveryX,
}) {
  final addedX1 = <int>{};
  if (fresh.isEmpty) return addedX1;
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
      addedX1.add(f.x1);
    }
  }
  return addedX1;
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
