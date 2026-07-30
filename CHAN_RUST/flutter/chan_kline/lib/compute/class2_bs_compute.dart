/// 二类BS 会话冻结/合并/扩展（方案A·全层同构）。
///
/// 与一类同一资格中枢框：一类负责建框+严格新极值，二类处理等高/更弱。
/// 买：low ≥ 已见最低 → 2Ba/2Bb…（参照由一类维护，二类不抬）
/// 卖：high ≤ 已见最高 → 2Sa/2Sb…（镜像）
/// 一类建框/新极值复位时二类字母同步重起（2Ba/2Sa）。
/// 会话冻结双键（稳定键+颗粒度键含 x）与一类完全同构。
import '../models/buy2_frame.dart';
import '../models/sell2_frame.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';

/// 稳定身份：层|段|标签（与一类同构；禁止只用此键去重）。
String buy2StableKey(Buy2Frame p) => '${p.level}|${p.segIdx}|${p.label}';

String sell2StableKey(Sell2Frame p) => '${p.level}|${p.segIdx}|${p.label}';

/// 颗粒度键：含 x（对齐分型判断 / 一类BS）。
String buy2EventKey(Buy2Frame p) => '${buy2StableKey(p)}|${p.x}';

String sell2EventKey(Sell2Frame p) => '${sell2StableKey(p)}|${p.x}';

/// 步进累积：首次 x=discoveryX；Kn≥1 active 可多 x。
void mergeBuy2EventLog(
  List<Buy2Frame> history,
  List<Buy2Frame> fresh, {
  required int discoveryX,
  int? activeSegIdx,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) buy2EventKey(e)};
  final seenStable = <String>{for (final e in history) buy2StableKey(e)};
  for (final p in fresh) {
    if (p.segIdx < 0) continue;
    final stable = buy2StableKey(p);
    final isActive = activeSegIdx != null && p.segIdx == activeSegIdx;
    if (seenStable.contains(stable) && !isActive) continue;
    final frame = Buy2Frame(
      seq: p.seq,
      zsSeq: p.zsSeq,
      x: discoveryX,
      price: p.price,
      label: p.label,
      segIdx: p.segIdx,
      level: p.level,
    );
    final k = buy2EventKey(frame);
    if (seen.add(k)) {
      history.add(frame);
      seenStable.add(stable);
    }
  }
}

void mergeSell2EventLog(
  List<Sell2Frame> history,
  List<Sell2Frame> fresh, {
  required int discoveryX,
  int? activeSegIdx,
}) {
  if (fresh.isEmpty) return;
  final seen = <String>{for (final e in history) sell2EventKey(e)};
  final seenStable = <String>{for (final e in history) sell2StableKey(e)};
  for (final p in fresh) {
    if (p.segIdx < 0) continue;
    final stable = sell2StableKey(p);
    final isActive = activeSegIdx != null && p.segIdx == activeSegIdx;
    if (seenStable.contains(stable) && !isActive) continue;
    final frame = Sell2Frame(
      seq: p.seq,
      zsSeq: p.zsSeq,
      x: discoveryX,
      price: p.price,
      label: p.label,
      segIdx: p.segIdx,
      level: p.level,
    );
    final k = sell2EventKey(frame);
    if (seen.add(k)) {
      history.add(frame);
      seenStable.add(stable);
    }
  }
}

Map<int, List<Buy2Frame>> collectBuy2EventsByKn(KlineCombineBundle bundle) {
  final out = <int, List<Buy2Frame>>{
    0: List<Buy2Frame>.from(bundle.buy2K0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level] = List<Buy2Frame>.from(lv.buy2Frames);
  }
  return out;
}

Map<int, List<Sell2Frame>> collectSell2EventsByKn(KlineCombineBundle bundle) {
  final out = <int, List<Sell2Frame>>{
    0: List<Sell2Frame>.from(bundle.sell2K0Frames),
  };
  for (final lv in bundle.levels) {
    out[lv.level] = List<Sell2Frame>.from(lv.sell2Frames);
  }
  return out;
}

List<String?> expandBuy2LabelsToSeries(
  List<Buy2Frame> events,
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

List<String?> expandSell2LabelsToSeries(
  List<Sell2Frame> events,
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

List<Buy2Frame> buy2HistoryForKn(
  Map<int, List<Buy2Frame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

List<Sell2Frame> sell2HistoryForKn(
  Map<int, List<Sell2Frame>> historyByKn,
  int kn,
) =>
    historyByKn[kn] ?? const [];

/// 用会话冻结覆盖 LevelBundle 的二类BS 字段（保留一类等其它字段）。
List<LevelBundle> levelsWithFrozenClass2Bs(
  List<LevelBundle> levels, {
  required Map<int, List<Buy2Frame>> buy2HistoryByKn,
  required Map<int, List<Sell2Frame>> sell2HistoryByKn,
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
          buy2Frames: buy2HistoryByKn[lv.level] ?? lv.buy2Frames,
          sell2Frames: sell2HistoryByKn[lv.level] ?? lv.sell2Frames,
          firstDir: lv.firstDir,
          firstDirX: lv.firstDirX,
          activeUnit: lv.activeUnit,
          segmentPolicy: lv.segmentPolicy,
          pendingUnit: lv.pendingUnit,
        ),
      )
      .toList();
}
