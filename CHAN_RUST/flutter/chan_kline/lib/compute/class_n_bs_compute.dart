/// 三类及以上 BS 会话冻结/合并/扩展（全层同构）。
///
/// 链：一/二类资格框为起点；买侧连续 zd_k>zg_{k-1} 升类；卖侧镜像下移；
/// 中间环不满足则断开。同框成员按序 3Ba… 字母不复位。
/// 双键（稳定键+颗粒度键含 x）与一类/二类同构。
import '../models/buy_n_frame.dart';
import '../models/sell_n_frame.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';

String buyNStableKey(BuyNFrame p) => '${p.level}|${p.segIdx}|${p.label}';

String sellNStableKey(SellNFrame p) => '${p.level}|${p.segIdx}|${p.label}';

String buyNEventKey(BuyNFrame p) => '${buyNStableKey(p)}|${p.x}';

String sellNEventKey(SellNFrame p) => '${sellNStableKey(p)}|${p.x}';

void mergeBuyNEventLog(
  List<BuyNFrame> history,
  List<BuyNFrame> fresh, {
  required int discoveryX,
  int? activeSegIdx,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) buyNEventKey(e)};
  final seenStable = <String>{for (final e in history) buyNStableKey(e)};
  for (final p in fresh) {
    if (p.segIdx < 0) continue;
    final stable = buyNStableKey(p);
    final isActive = activeSegIdx != null && p.segIdx == activeSegIdx;
    if (seenStable.contains(stable) && !isActive) continue;
    final frame = BuyNFrame(
      seq: p.seq,
      zsSeq: p.zsSeq,
      cls: p.cls,
      x: discoveryX,
      price: p.price,
      label: p.label,
      segIdx: p.segIdx,
      level: p.level,
    );
    final k = buyNEventKey(frame);
    if (seen.add(k)) {
      history.add(frame);
      seenStable.add(stable);
    }
  }
}

void mergeSellNEventLog(
  List<SellNFrame> history,
  List<SellNFrame> fresh, {
  required int discoveryX,
  int? activeSegIdx,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) sellNEventKey(e)};
  final seenStable = <String>{for (final e in history) sellNStableKey(e)};
  for (final p in fresh) {
    if (p.segIdx < 0) continue;
    final stable = sellNStableKey(p);
    final isActive = activeSegIdx != null && p.segIdx == activeSegIdx;
    if (seenStable.contains(stable) && !isActive) continue;
    final frame = SellNFrame(
      seq: p.seq,
      zsSeq: p.zsSeq,
      cls: p.cls,
      x: discoveryX,
      price: p.price,
      label: p.label,
      segIdx: p.segIdx,
      level: p.level,
    );
    final k = sellNEventKey(frame);
    if (seen.add(k)) {
      history.add(frame);
      seenStable.add(stable);
    }
  }
}

Map<int, List<BuyNFrame>> collectBuyNEventsByKn(KlineCombineBundle bundle) {
  final out = <int, List<BuyNFrame>>{
    0: List<BuyNFrame>.from(bundle.buyNK0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level] = List<BuyNFrame>.from(lv.buyNFrames);
  }
  return out;
}

Map<int, List<SellNFrame>> collectSellNEventsByKn(KlineCombineBundle bundle) {
  final out = <int, List<SellNFrame>>{
    0: List<SellNFrame>.from(bundle.sellNK0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level] = List<SellNFrame>.from(lv.sellNFrames);
  }
  return out;
}

List<String?> expandBuyNLabelsToSeries(
  List<BuyNFrame> events,
  int barCount, {
  int? maxX,
  int? cls,
}) {
  if (barCount <= 0) return const [];
  final out = List<String?>.filled(barCount, null);
  for (final e in events) {
    if (cls != null && e.cls != cls) continue;
    if (e.x < 0 || e.x >= barCount) continue;
    if (maxX != null && e.x > maxX) continue;
    // 同柱多标签用空格拼接，允许同 K0 多类叠字
    final prev = out[e.x];
    out[e.x] = prev == null || prev.isEmpty ? e.label : '$prev ${e.label}';
  }
  return out;
}

List<String?> expandSellNLabelsToSeries(
  List<SellNFrame> events,
  int barCount, {
  int? maxX,
  int? cls,
}) {
  if (barCount <= 0) return const [];
  final out = List<String?>.filled(barCount, null);
  for (final e in events) {
    if (cls != null && e.cls != cls) continue;
    if (e.x < 0 || e.x >= barCount) continue;
    if (maxX != null && e.x > maxX) continue;
    final prev = out[e.x];
    out[e.x] = prev == null || prev.isEmpty ? e.label : '$prev ${e.label}';
  }
  return out;
}

List<BuyNFrame> buyNHistoryForKn(
  Map<int, List<BuyNFrame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

List<SellNFrame> sellNHistoryForKn(
  Map<int, List<SellNFrame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

/// 会话内观察到的最大类号（至少 3；用于 catalog 动态扩）
int maxBuyNClassObserved({
  required Map<int, List<BuyNFrame>> buyNHistoryByKn,
  required Map<int, List<SellNFrame>> sellNHistoryByKn,
}) {
  var m = 3;
  for (final list in buyNHistoryByKn.values) {
    for (final e in list) {
      if (e.cls > m) m = e.cls;
    }
  }
  for (final list in sellNHistoryByKn.values) {
    for (final e in list) {
      if (e.cls > m) m = e.cls;
    }
  }
  return m;
}

List<LevelBundle> levelsWithFrozenClassNBs(
  List<LevelBundle> levels, {
  required Map<int, List<BuyNFrame>> buyNHistoryByKn,
  required Map<int, List<SellNFrame>> sellNHistoryByKn,
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
          buyNFrames: buyNHistoryByKn[lv.level] ?? lv.buyNFrames,
          sellNFrames: sellNHistoryByKn[lv.level] ?? lv.sellNFrames,
          firstDir: lv.firstDir,
          firstDirX: lv.firstDirX,
          activeUnit: lv.activeUnit,
          segmentPolicy: lv.segmentPolicy,
          pendingUnit: lv.pendingUnit,
        ),
      )
      .toList();
}
