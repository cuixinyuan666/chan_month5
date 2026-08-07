import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import '../models/zs_frame.dart';
import 'divergence_compute.dart';
import 'math_series_freeze_store.dart';
import 'zs_compute.dart';

/// diver 格点：首次非 0 后冻结（禁止整表重算盖成 0 消点）。
List<int> freezeDiverSeries(List<int>? prev, List<int> fresh) {
  final prevLen = prev?.length ?? 0;
  final n = fresh.length > prevLen ? fresh.length : prevLen;
  if (n <= 0) return const [];
  final out = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final p = (prev != null && i < prevLen) ? prev[i] : 0;
    final f = i < fresh.length ? fresh[i] : 0;
    out[i] = p != 0 ? p : f;
  }
  return out;
}

/// 比较段区间：首次非空后冻结（十字 asOf 读仓高亮）。
List<DivergenceCompareSpan?> freezeSpanSeries(
  List<DivergenceCompareSpan?>? prev,
  List<DivergenceCompareSpan?> fresh,
) {
  final prevLen = prev?.length ?? 0;
  final n = fresh.length > prevLen ? fresh.length : prevLen;
  if (n <= 0) return const [];
  final out = List<DivergenceCompareSpan?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final p = (prev != null && i < prevLen) ? prev[i] : null;
    final f = i < fresh.length ? fresh[i] : null;
    out[i] = p ?? f;
  }
  return out;
}

DivergenceAlgoK0Series freezeDivergenceSeries(
  DivergenceAlgoK0Series? prev,
  DivergenceAlgoK0Series fresh,
) {
  return DivergenceAlgoK0Series(
    inAt: freezeNullableSeries(prev?.inAt, fresh.inAt),
    outAt: freezeNullableSeries(prev?.outAt, fresh.outAt),
    ratioAt: freezeNullableSeries(prev?.ratioAt, fresh.ratioAt),
    diverAt: freezeDiverSeries(prev?.diverAt, fresh.diverAt),
  );
}

/// 会话级背驰冻结仓（按 displayKn → 算法）。
/// 绘制/十字读仓；本枢身份会话随步进更新；旧格不改、新 x 追加。
class DivergenceFreezeStore {
  /// kn → algo → series
  final Map<int, Map<DivergenceAlgo, DivergenceAlgoK0Series>> byKn = {};

  /// kn → 本枢会话（中枢判断启动 / 合并重映射）
  final Map<int, DivergenceOwnSession> ownByKn = {};

  /// kn → 每步比较段区间（学习高亮；与 diver 同颗粒度）
  final Map<int, List<DivergenceCompareSpan?>> spanByKn = {};

  void clear() {
    byKn.clear();
    ownByKn.clear();
    spanByKn.clear();
  }

  Map<DivergenceAlgo, DivergenceAlgoK0Series>? level(int kn) => byKn[kn];

  DivergenceAlgoK0Series? series(int kn, DivergenceAlgo algo) =>
      byKn[kn]?[algo];

  DivergenceOwnSession ownSession(int kn) =>
      ownByKn[kn] ?? DivergenceOwnSession();

  void setOwnSession(int kn, DivergenceOwnSession session) {
    ownByKn[kn] = session.copy();
  }

  DivergenceCompareSpan? spanAt(int kn, int x) {
    final list = spanByKn[kn];
    if (list == null || x < 0 || x >= list.length) return null;
    return list[x];
  }

  /// asOf 处有效区间：本格无值则向前找最近非空（便于十字落在空档仍看见上一段比较）。
  DivergenceCompareSpan? spanAtOrBefore(int kn, int asOf) {
    final list = spanByKn[kn];
    if (list == null || asOf < 0) return null;
    final last = mathMin(asOf, list.length - 1);
    for (var i = last; i >= 0; i--) {
      final s = list[i];
      if (s != null) return s;
    }
    return null;
  }

  void mergeLevel({
    required int displayKn,
    required Map<DivergenceAlgo, DivergenceAlgoK0Series> fresh,
  }) {
    final prev = byKn[displayKn] ?? {};
    final out = <DivergenceAlgo, DivergenceAlgoK0Series>{};
    for (final a in DivergenceAlgoMeta.all) {
      final f = fresh[a];
      if (f == null) continue;
      out[a] = freezeDivergenceSeries(prev[a], f);
    }
    byKn[displayKn] = out;
  }

  void mergeSpan({
    required int displayKn,
    required List<DivergenceCompareSpan?> fresh,
  }) {
    spanByKn[displayKn] = freezeSpanSeries(spanByKn[displayKn], fresh);
  }
}

int mathMin(int a, int b) => a < b ? a : b;

/// 本步 0..maxDisplayKn 背驰新鲜算完并入冻结仓（力度优先读 Math 仓）。
void mergeDivergenceForStep({
  required DivergenceFreezeStore store,
  required MathSeriesFreezeStore? mathStore,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<ZSFrame> zsK0Frames,
  required MathIndicatorConfig config,
  required int maxDisplayKn,
  int? asOf,
  Map<int, Set<int>> confirmedX1ByKn = const {},
}) {
  if (bars.isEmpty || maxDisplayKn < 0) return;
  final eventX = asOf ?? (bars.length - 1);
  for (var kn = 0; kn <= maxDisplayKn; kn++) {
    final zsList = rustZsFramesForKn(
      kn: kn,
      zsK0Frames: zsK0Frames,
      levels: levels,
    );
    final sess = updateDivergenceOwnSession(
      prev: store.ownSession(kn),
      zsList: zsList,
      confirmedX1ThisStep: confirmedX1ByKn[kn] ?? const {},
    );
    store.setOwnSession(kn, sess);
    final fresh = computeDivergenceForLevel(
      displayKn: kn,
      bars: bars,
      levels: levels,
      zsK0Frames: zsK0Frames,
      config: config,
      asOf: asOf,
      mathFreezeStore: mathStore,
      ownSession: sess,
      confirmedX1ThisStep: const {},
    );
    store.mergeLevel(displayKn: kn, fresh: fresh);

    // 学习观察：同步冻结比较段区间
    final spanFresh =
        List<DivergenceCompareSpan?>.filled(bars.length, null);
    if (eventX >= 0 && eventX < bars.length) {
      spanFresh[eventX] = resolveDivergenceCompareSpan(
        displayKn: kn,
        bars: bars,
        levels: levels,
        zsK0Frames: zsK0Frames,
        asOf: asOf,
        ownSession: sess,
      );
    }
    store.mergeSpan(displayKn: kn, fresh: spanFresh);
  }
}

/// asOf 截断视图：只暴露 x<=asOf 的格（右侧当未发生）。
Map<DivergenceAlgo, DivergenceAlgoK0Series> truncateDivergenceMap(
  Map<DivergenceAlgo, DivergenceAlgoK0Series> src,
  int barCount, {
  int? asOf,
}) {
  if (asOf == null) return src;
  final last = asOf;
  final out = <DivergenceAlgo, DivergenceAlgoK0Series>{};
  for (final e in src.entries) {
    final s = e.value;
    final inAt = List<double?>.filled(barCount, null);
    final outAt = List<double?>.filled(barCount, null);
    final ratioAt = List<double?>.filled(barCount, null);
    final diverAt = List<int>.filled(barCount, 0);
    for (var i = 0; i < barCount && i <= last; i++) {
      if (i < s.inAt.length) inAt[i] = s.inAt[i];
      if (i < s.outAt.length) outAt[i] = s.outAt[i];
      if (i < s.ratioAt.length) ratioAt[i] = s.ratioAt[i];
      if (i < s.diverAt.length) diverAt[i] = s.diverAt[i];
    }
    out[e.key] = DivergenceAlgoK0Series(
      inAt: inAt,
      outAt: outAt,
      ratioAt: ratioAt,
      diverAt: diverAt,
    );
  }
  return out;
}
