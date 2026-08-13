import '../models/buy1_frame.dart';
import '../models/sell1_frame.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';

/// 稳定身份：层|段|标签（首次发现；不随 active 延伸改写旧点）。
/// 踩坑：若只用此键去重且不含 x，同动态 Kn 延伸（如 26→27）会被跳过，
/// 副图/十字在当前 K0 步无颗粒度结果（Rust 仍输出、Flutter 以为已有）。
String buy1StableKey(Buy1Frame p) => '${p.level}|${p.segIdx}|${p.label}';

String sell1StableKey(Sell1Frame p) => '${p.level}|${p.segIdx}|${p.label}';

/// 颗粒度键：含 x（对齐分型判断事件键含 x；同动态 Kn 延伸可多点）。
String buy1EventKey(Buy1Frame p) => '${buy1StableKey(p)}|${p.x}';

String sell1EventKey(Sell1Frame p) => '${sell1StableKey(p)}|${p.x}';

/// 步进累积（对齐 Kn分型判断：K0 步进颗粒度 + 动态 Kn 作判断元素）：
/// - 首次发现：x=discoveryX（stepIdx），稳定身份入库后不删；
/// - Kn≥1 且本步仍落在 active 段：再追加本步 x（同 seg/label 可多 x）；
/// - 非 active 旧点：本步 Rust 再吐出也不重复打点。
void mergeBuy1EventLog(
  List<Buy1Frame> history,
  List<Buy1Frame> fresh, {
  required int discoveryX,
  int? activeSegIdx,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) buy1EventKey(e)};
  final seenStable = <String>{for (final e in history) buy1StableKey(e)};
  for (final p in fresh) {
    if (p.segIdx < 0) continue;
    final stable = buy1StableKey(p);
    final isActive = activeSegIdx != null && p.segIdx == activeSegIdx;
    // 非动态段：只首次入库；动态 Kn：每步可追加本步 x（K0 颗粒度）
    if (seenStable.contains(stable) && !isActive) continue;
    final frame = Buy1Frame(
      seq: p.seq,
      zsSeq: p.zsSeq,
      x: discoveryX,
      price: p.price,
      label: p.label,
      segIdx: p.segIdx,
      level: p.level,
    );
    final k = buy1EventKey(frame);
    if (seen.add(k)) {
      history.add(frame);
      seenStable.add(stable);
    }
  }
}

void mergeSell1EventLog(
  List<Sell1Frame> history,
  List<Sell1Frame> fresh, {
  required int discoveryX,
  int? activeSegIdx,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) sell1EventKey(e)};
  final seenStable = <String>{for (final e in history) sell1StableKey(e)};
  for (final p in fresh) {
    if (p.segIdx < 0) continue;
    final stable = sell1StableKey(p);
    final isActive = activeSegIdx != null && p.segIdx == activeSegIdx;
    if (seenStable.contains(stable) && !isActive) continue;
    final frame = Sell1Frame(
      seq: p.seq,
      zsSeq: p.zsSeq,
      x: discoveryX,
      price: p.price,
      label: p.label,
      segIdx: p.segIdx,
      level: p.level,
    );
    final k = sell1EventKey(frame);
    if (seen.add(k)) {
      history.add(frame);
      seenStable.add(stable);
    }
  }
}

/// 从本步 bundle 采集各层一类买（K0 + levels）。
/// 方案B：out[0]=k0；写 out[lv.level+1]（禁盖 K0）。
Map<int, List<Buy1Frame>> collectBuy1EventsByKn(KlineCombineBundle bundle) {
  final out = <int, List<Buy1Frame>>{
    0: List<Buy1Frame>.from(bundle.buy1K0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level + 1] = List<Buy1Frame>.from(lv.buy1Frames);
  }
  return out;
}

/// 从本步 bundle 采集各层一类卖。
Map<int, List<Sell1Frame>> collectSell1EventsByKn(KlineCombineBundle bundle) {
  final out = <int, List<Sell1Frame>>{
    0: List<Sell1Frame>.from(bundle.sell1K0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level + 1] = List<Sell1Frame>.from(lv.sell1Frames);
  }
  return out;
}

/// 事件 → 稀疏标签序列（同 x 后者覆盖；maxX 藏未来；对齐 expandJudgmentEventsToSeries）。
List<String?> expandBuy1LabelsToSeries(
  List<Buy1Frame> events,
  int barCount, {
  int? maxX,
}) {
  if (barCount <= 0) return const [];
  final out = List<String?>.filled(barCount, null);
  for (final e in events) {
    if (e.x < 0 || e.x >= barCount) continue;
    if (maxX != null && e.x > maxX) continue;
    out[e.x] = e.label;
  }
  return out;
}

List<String?> expandSell1LabelsToSeries(
  List<Sell1Frame> events,
  int barCount, {
  int? maxX,
}) {
  if (barCount <= 0) return const [];
  final out = List<String?>.filled(barCount, null);
  for (final e in events) {
    if (e.x < 0 || e.x >= barCount) continue;
    if (maxX != null && e.x > maxX) continue;
    out[e.x] = e.label;
  }
  return out;
}

/// 取某层会话历史买点（无则空）。
List<Buy1Frame> buy1HistoryForKn(
  Map<int, List<Buy1Frame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

List<Sell1Frame> sell1HistoryForKn(
  Map<int, List<Sell1Frame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

/// 用会话冻结覆盖 LevelBundle 的一类BS 字段（快照/兼容；绘制优先扫 history）。
List<LevelBundle> levelsWithFrozenClass1Bs(
  List<LevelBundle> levels, {
  required Map<int, List<Buy1Frame>> buy1HistoryByKn,
  required Map<int, List<Sell1Frame>> sell1HistoryByKn,
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
          // 方案B：history 键用 display=lv.level+1
          buy1Frames: buy1HistoryByKn[lv.level + 1] ?? lv.buy1Frames,
          sell1Frames: sell1HistoryByKn[lv.level + 1] ?? lv.sell1Frames,
          buy2Frames: lv.buy2Frames,
          sell2Frames: lv.sell2Frames,
          buyNFrames: lv.buyNFrames,
          sellNFrames: lv.sellNFrames,
          bsVerdictFrames: lv.bsVerdictFrames,
          firstDir: lv.firstDir,
          firstDirX: lv.firstDirX,
          activeUnit: lv.activeUnit,
          segmentPolicy: lv.segmentPolicy,
          pendingUnit: lv.pendingUnit,
        ),
      )
      .toList();
}
