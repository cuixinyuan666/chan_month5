import '../compute/divergence_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../models/zs_frame.dart';
import 'divergence_relation.dart';
import 'structure_object.dart';
import 'trade_clock.dart';
import 'trade_value.dart';

/// 背驰关系仓：只读现有冻结仓 + 中枢帧，不重算背驰。
///
/// 同一对比较对象动态延伸 → 同一 relationId；旧 asOf 快照不回写。
/// 确认程度变化 → 追加新快照/新 EXISTS 边沿，不改历史事件。
class DivergenceRelationStore {
  final Map<String, List<DivergenceRelation>> _snaps = {};
  /// 稳定键 → 首次发现 x（关系身份）
  final Map<String, int> _discoveryX = {};
  /// 稳定键 → 上次是否已确认（用来判断确认翻转要不要新事件）
  final Map<String, bool> _lastConfirmed = {};
  /// 稳定键 → 已发出的 EXISTS 边沿 availableAt（不回写）
  final Map<String, List<int>> _existsAt = {};

  bool get isEmpty => _snaps.isEmpty;

  void clear() {
    _snaps.clear();
    _discoveryX.clear();
    _lastConfirmed.clear();
    _existsAt.clear();
  }

  /// 测试/直接喂入一条当时快照（仍遵守同 asOf 不回写）。
  void ingestRelation(DivergenceRelation rel) {
    _append(rel);
  }

  /// 从现有背驰冻结仓喂入一层当步。只认 MACD 面积；必须能解析比较对象。
  void ingestFromFreeze({
    required int displayKn,
    required int asOf,
    required DivergenceFreezeStore freeze,
    required List<ZSFrame> zsFrames,
  }) {
    if (asOf < 0) return;
    final series = freeze.series(displayKn, DivergenceAlgo.area);
    if (series == null) return;
    if (asOf >= series.diverAt.length) return;
    final flag = series.diverAt[asOf];
    if (flag != 1) return; // 交易关系只收已确认背驰

    final span = freeze.spanAt(displayKn, asOf);
    if (span == null) return;

    final refZs = _zsForSeg(
      frames: zsFrames,
      segIdx: span.inSegIdx,
      lo: span.inLoX,
      hi: span.inHiX,
    );
    final srcZs = _zsForSeg(
      frames: zsFrames,
      segIdx: span.outSegIdx,
      lo: span.outLoX,
      hi: span.outHiX,
    );
    final referenceObjectId = refZs != null
        ? zsObjectId(displayKn, refZs.x1)
        : segObjectId(displayKn, span.inSegIdx);
    final sourceObjectId = srcZs != null
        ? zsObjectId(displayKn, srcZs.x1)
        : segObjectId(displayKn, span.outSegIdx);

    final rid = diverRelationId(
      displayKn: displayKn,
      referenceObjectId: referenceObjectId,
      sourceObjectId: sourceObjectId,
      inSeg: span.inSegIdx,
      outSeg: span.outSegIdx,
      mode: span.mode,
    );
    final discovery = _discoveryX.putIfAbsent(rid, () => asOf);
    final ratio =
        asOf < series.ratioAt.length ? series.ratioAt[asOf] : null;
    final indicator =
        asOf < series.outAt.length ? series.outAt[asOf] : null;
    final amp = freeze.series(displayKn, DivergenceAlgo.amp);
    final priceForce =
        amp != null && asOf < amp.outAt.length ? amp.outAt[asOf] : null;

    _append(DivergenceRelation(
      relationId: rid,
      displayKn: displayKn,
      clockFamily: TradeClockFamily.zsMath,
      availableAt: asOf,
      discoveryX: discovery,
      direction: divergenceDirectionFromSegDir(span.outDir),
      sourceObjectId: sourceObjectId,
      referenceObjectId: referenceObjectId,
      sourceSegment: span.outSegIdx,
      sourceZs: srcZs != null ? zsObjectId(displayKn, srcZs.x1) : null,
      referenceSegment: span.inSegIdx,
      referenceZs: refZs != null ? zsObjectId(displayKn, refZs.x1) : null,
      priceForce: priceForce,
      indicatorForce: indicator,
      ratio: ratio,
      confirmed: true,
      source: '背驰冻结仓 MACD面积 + 比较段区间，不重算背驰',
    ));
  }

  /// 该层 asOf 下最新一个已确认且当时可见的背驰关系。
  DivergenceRelation? resolveCurrent({
    required int displayKn,
    required int asOf,
  }) {
    DivergenceRelation? best;
    for (final list in _snaps.values) {
      for (final s in list) {
        if (s.displayKn != displayKn) continue;
        if (!s.confirmed) continue;
        if (s.availableAt > asOf) continue;
        if (best == null ||
            s.availableAt > best.availableAt ||
            (s.availableAt == best.availableAt &&
                s.discoveryX > best.discoveryX)) {
          best = s;
        }
      }
    }
    return best;
  }

  double? projectRatio({required int displayKn, required int asOf}) =>
      resolveCurrent(displayKn: displayKn, asOf: asOf)?.ratio;

  DivergenceDirection? projectDirection({
    required int displayKn,
    required int asOf,
  }) =>
      resolveCurrent(displayKn: displayKn, asOf: asOf)?.direction;

  /// EXISTS：确认边沿。同一关系确认翻转后再确认会追加新边沿，不改旧的。
  List<TradeChanEvent> listExistsEvents({
    required int displayKn,
    required int asOf,
  }) {
    final out = <TradeChanEvent>[];
    for (final e in _existsAt.entries) {
      final snaps = _snaps[e.key];
      if (snaps == null || snaps.isEmpty) continue;
      if (snaps.first.displayKn != displayKn) continue;
      for (final x in e.value) {
        if (x > asOf) continue;
        DivergenceRelation? rel;
        for (final s in snaps) {
          if (s.availableAt == x) {
            rel = s;
            break;
          }
        }
        rel ??= snaps.first;
        out.add(TradeChanEvent(
          eventId: '${e.key}|$x',
          displayKn: displayKn,
          discoveryX: x,
          availableAt: x,
          label: '背驰',
          price: rel.ratio ?? 0,
          source: rel.source,
          relationId: e.key,
        ));
      }
    }
    out.sort((a, b) => a.availableAt.compareTo(b.availableAt));
    return out;
  }

  DivergenceRelation? snapshotOf(String relationId, int asOf) {
    final list = _snaps[relationId];
    if (list == null) return null;
    DivergenceRelation? last;
    for (final s in list) {
      if (s.availableAt > asOf) break;
      last = s;
    }
    return last;
  }

  void _append(DivergenceRelation rel) {
    final list = _snaps.putIfAbsent(rel.relationId, () => []);
    if (list.any((s) => s.availableAt == rel.availableAt)) return;
    _discoveryX.putIfAbsent(rel.relationId, () => rel.discoveryX);
    list.add(rel);
    list.sort((a, b) => a.availableAt.compareTo(b.availableAt));

    final prev = _lastConfirmed[rel.relationId];
    if (rel.confirmed && prev != true) {
      final xs = _existsAt.putIfAbsent(rel.relationId, () => []);
      if (!xs.contains(rel.availableAt)) xs.add(rel.availableAt);
    }
    _lastConfirmed[rel.relationId] = rel.confirmed;
  }
}

ZSFrame? _zsForSeg({
  required List<ZSFrame> frames,
  required int segIdx,
  required int lo,
  required int hi,
}) {
  for (final f in frames) {
    if (f.endIdx == segIdx) return f;
  }
  ZSFrame? best;
  var bestOv = -1;
  for (final f in frames) {
    final ovLo = f.x1 > lo ? f.x1 : lo;
    final ovHi = f.x2 < hi ? f.x2 : hi;
    final ov = ovHi - ovLo;
    if (ov > bestOv) {
      bestOv = ov;
      best = f;
    }
  }
  return bestOv >= 0 ? best : null;
}
