import '../models/zs_frame.dart';
import 'structure_object.dart';

/// 中枢结构对象仓：只消费现有 ZSFrame，不重算中枢。
///
/// 每步喂入当时帧 → 动态延伸保持同一个 objectId → 历史 asOf 快照冻结不回写。
/// 交易变量只解析 CURRENT_CONFIRMED_ZS（已确认且当时可见的最新一个）。
class ZhongshuObjectStore {
  /// objectId → 身份（discovery/confirm 只写一次）
  final Map<String, _ZsIdent> _idents = {};
  /// objectId → 按 availableAt 追加的快照（禁止改旧格）
  final Map<String, List<ZhongshuObject>> _snaps = {};

  ZhongshuObjectStore();

  bool get isEmpty => _idents.isEmpty;

  void clear() {
    _idents.clear();
    _snaps.clear();
  }

  /// 本步各层中枢帧（与 collectZsFramesByKn 同口径：key=displayKn）。
  void ingestCollected(Map<int, List<ZSFrame>> byKn, {required int asOf}) {
    for (final e in byKn.entries) {
      ingestLevel(displayKn: e.key, frames: e.value, asOf: asOf);
    }
  }

  /// 喂入一层当时帧。未确认只记身份；确认后才有可交易快照。
  void ingestLevel({
    required int displayKn,
    required List<ZSFrame> frames,
    required int asOf,
  }) {
    if (asOf < 0) return;
    final srcLv = zsSourceLevel(displayKn);
    const src = '现有中枢帧步进快照，不重算中枢';

    // 先过一遍：建/补身份；已确认的记下本步高低
    final confirmedNow = <String>[];
    for (final f in frames) {
      if (f.x1 < 0) continue;
      final id = zsObjectId(displayKn, f.x1);
      final ident = _idents.putIfAbsent(
        id,
        () => _ZsIdent(
          objectId: id,
          displayKn: displayKn,
          sourceLevel: srcLv,
          startX: f.x1,
          discoveryX: asOf,
        ),
      );
      if (f.isSure) {
        ident.confirmX ??= asOf;
        confirmedNow.add(id);
        _appendConfirmedSnap(
          ident: ident,
          asOf: asOf,
          endX: f.x2,
          high: f.high,
          low: f.low,
          source: src,
        );
      }
    }

    // 本步 CURRENT = 当时可见的最新已确认（confirmX<=asOf）
    final currentId = _pickCurrentId(displayKn, asOf);

    // 给「本步没再出现、但早已确认」的对象补一格持值快照（高低不回写成末态）
    for (final ident in _idents.values) {
      if (ident.displayKn != displayKn) continue;
      if (ident.confirmX == null || ident.confirmX! > asOf) continue;
      if (confirmedNow.contains(ident.objectId)) continue;
      final last = _latestSnap(ident.objectId, asOf);
      if (last == null) continue;
      _appendConfirmedSnap(
        ident: ident,
        asOf: asOf,
        endX: last.endX,
        high: last.high,
        low: last.low,
        source: src,
      );
    }

    // 回填本步快照的 ACTIVE/EXTENDED/ENDED（不改更早的格子）
    for (final ident in _idents.values) {
      if (ident.displayKn != displayKn) continue;
      final list = _snaps[ident.objectId];
      if (list == null || list.isEmpty) continue;
      final i = list.lastIndexWhere((s) => s.availableAt == asOf);
      if (i < 0) continue;
      final s = list[i];
      if (!s.confirmed) continue;
      final state = _stateAt(
        ident: ident,
        snap: s,
        currentId: currentId,
      );
      if (state == s.state) continue;
      list[i] = ZhongshuObject(
        objectId: s.objectId,
        displayKn: s.displayKn,
        sourceLevel: s.sourceLevel,
        discoveryX: s.discoveryX,
        confirmX: s.confirmX,
        availableAt: s.availableAt,
        startX: s.startX,
        endX: s.endX,
        high: s.high,
        low: s.low,
        center: s.center,
        confirmed: s.confirmed,
        state: state,
        source: s.source,
      );
    }
  }

  /// 指定层在 asOf 下最新一个已确认且当时可见的中枢。没有 → null（UNAVAILABLE）。
  ZhongshuObject? resolveCurrentConfirmedZs({
    required int displayKn,
    required int asOf,
  }) {
    final id = _pickCurrentId(displayKn, asOf);
    if (id == null) return null;
    return _latestSnap(id, asOf);
  }

  double? projectCurrent({
    required int displayKn,
    required int asOf,
    required ZsProjection projection,
  }) {
    final obj = resolveCurrentConfirmedZs(displayKn: displayKn, asOf: asOf);
    if (obj == null) return null;
    return switch (projection) {
      ZsProjection.high => obj.high,
      ZsProjection.low => obj.low,
      ZsProjection.center => obj.center,
    };
  }

  /// 测试/诊断：某身份在 asOf 当时的快照（含未确认则没有可交易快照）。
  ZhongshuObject? snapshotOf(String objectId, int asOf) =>
      _latestSnap(objectId, asOf);

  _ZsIdent? identOf(String objectId) => _idents[objectId];

  void _appendConfirmedSnap({
    required _ZsIdent ident,
    required int asOf,
    required int endX,
    required double high,
    required double low,
    required String source,
  }) {
    final list = _snaps.putIfAbsent(ident.objectId, () => <ZhongshuObject>[]);
    // 同一根 asOf 已有快照：不回写（重算/重复喂入不能改当时值）
    if (list.any((s) => s.availableAt == asOf)) return;
    list.add(ZhongshuObject(
      objectId: ident.objectId,
      displayKn: ident.displayKn,
      sourceLevel: ident.sourceLevel,
      discoveryX: ident.discoveryX,
      confirmX: ident.confirmX,
      availableAt: asOf,
      startX: ident.startX,
      endX: endX,
      high: high,
      low: low,
      center: zsCenterOf(high: high, low: low),
      confirmed: true,
      state: StructureObjectState.confirmed,
      source: source,
    ));
  }

  String? _pickCurrentId(int displayKn, int asOf) {
    _ZsIdent? best;
    for (final ident in _idents.values) {
      if (ident.displayKn != displayKn) continue;
      final cx = ident.confirmX;
      if (cx == null || cx > asOf) continue;
      if (best == null) {
        best = ident;
        continue;
      }
      final bx = best.confirmX!;
      if (cx > bx || (cx == bx && ident.startX > best.startX)) {
        best = ident;
      }
    }
    return best?.objectId;
  }

  ZhongshuObject? _latestSnap(String objectId, int asOf) {
    final list = _snaps[objectId];
    if (list == null || list.isEmpty) return null;
    ZhongshuObject? last;
    for (final s in list) {
      if (s.availableAt > asOf) break;
      last = s;
    }
    return last;
  }

  StructureObjectState _stateAt({
    required _ZsIdent ident,
    required ZhongshuObject snap,
    required String? currentId,
  }) {
    if (currentId != ident.objectId) return StructureObjectState.ended;
    final cx = ident.confirmX ?? snap.availableAt;
    if (snap.availableAt == cx) return StructureObjectState.confirmed;
    final atConfirm = _latestSnap(ident.objectId, cx);
    if (atConfirm != null &&
        (snap.endX != atConfirm.endX ||
            snap.high != atConfirm.high ||
            snap.low != atConfirm.low)) {
      return StructureObjectState.extended;
    }
    return StructureObjectState.active;
  }
}

class _ZsIdent {
  final String objectId;
  final int displayKn;
  final int sourceLevel;
  final int startX;
  final int discoveryX;
  int? confirmX;

  _ZsIdent({
    required this.objectId,
    required this.displayKn,
    required this.sourceLevel,
    required this.startX,
    required this.discoveryX,
  });
}
