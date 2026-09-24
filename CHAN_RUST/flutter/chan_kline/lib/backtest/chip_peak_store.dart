import '../compute/chip_profile_compute.dart';
import '../compute/profile_peak_classify.dart';
import '../compute/tick_dist_profile_compute.dart';
import '../models/kline_bar.dart';
import '../models/peak_rank_config.dart';

/// 单格峰读数（价 + 峰位 B/S/G）。
class PeakCell {
  const PeakCell({
    required this.price,
    required this.b,
    required this.s,
    required this.g,
  });

  final double price;
  final double b;
  final double s;
  final double g;
}

/// 筹码峰 / 笔数峰：与十字同一套编号。
///
/// 格点首次写入后冻结；峰价没有那一颗就是空，不填 0、不沿用上一根。
class ChipPeakFreezeStore {
  final Map<String, Map<String, List<PeakCell?>>> _cells = {};
  final Set<int> _written = {};
  final Set<String> _kindWritten = {};
  double? _bucketStep;
  String? _rankFingerprint;

  bool get isEmpty => _written.isEmpty;

  /// 已写入 K 下标个数（用于主图重绘；仓体引用不变时仍可能增长）。
  int get ingestedBarCount => _written.length;

  PeakRankConfig get rankConfig => _rankConfig;
  PeakRankConfig _rankConfig = PeakRankConfig.defaults;

  void clear() {
    _cells.clear();
    _written.clear();
    _kindWritten.clear();
    _bucketStep = null;
    _rankFingerprint = null;
  }

  void ingestThrough({
    required int asOf,
    required List<KlineBar> bars,
    required double bucketStep,
    PeakRankConfig rank = PeakRankConfig.defaults,
  }) {
    if (asOf < 0 || bars.isEmpty) return;
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    final fp = rank.fingerprint;
    if (_bucketStep != null && (step - _bucketStep!).abs() > 1e-12) {
      clear();
    }
    if (_rankFingerprint != null && _rankFingerprint != fp) {
      clear();
    }
    _bucketStep = step;
    _rankFingerprint = fp;
    _rankConfig = rank;
    for (var x = 0; x <= asOf; x++) {
      if (_written.contains(x)) continue;
      _ingestOne(asOf: x, bars: bars, bucketStep: step, rank: rank);
    }
  }

  void ingestClassified({
    required int asOf,
    required String kind,
    required List<ProfilePeakRow> rows,
    required double close,
  }) {
    if (asOf < 0) return;
    final key = '$kind|$asOf';
    if (_kindWritten.contains(key)) return;
    _writeKind(kind: kind, asOf: asOf, rows: rows, close: close);
    _kindWritten.add(key);
    _written.add(asOf);
  }

  double? at({
    required String kind,
    required String suffix,
    required int asOf,
  }) {
    return cellAt(kind: kind, suffix: suffix, asOf: asOf)?.price;
  }

  /// 与 [bars] 列表对齐的峰价序列（无峰为 null）。
  List<double?> priceSeriesForBars({
    required String kind,
    required String suffix,
    required List<KlineBar> bars,
  }) {
    return [
      for (final b in bars) at(kind: kind, suffix: suffix, asOf: b.idx),
    ];
  }

  PeakCell? cellAt({
    required String kind,
    required String suffix,
    required int asOf,
  }) {
    final key = canonicalPeakSuffix(suffix);
    final series = _cells[kind]?[key];
    if (series == null || asOf < 0 || asOf >= series.length) return null;
    return series[asOf];
  }

  void _ingestOne({
    required int asOf,
    required List<KlineBar> bars,
    required double bucketStep,
    required PeakRankConfig rank,
  }) {
    KlineBar? bar;
    for (final b in bars) {
      if (b.idx == asOf) {
        bar = b;
        break;
      }
    }
    if (bar == null) {
      _written.add(asOf);
      return;
    }
    final chip = classifyProfilePeaks(
      profile: ChipProfileCompute.compute(
        bars: bars,
        cutoffX: asOf,
        bucketStep: bucketStep,
      ),
      low: bar.low,
      high: bar.high,
      close: bar.close,
      rank: rank,
    );
    final tick = classifyProfilePeaks(
      profile: TickDistProfileCompute.compute(
        bars: bars,
        cutoffX: asOf,
        bucketStep: bucketStep,
      ),
      low: bar.low,
      high: bar.high,
      close: bar.close,
      rank: rank,
    );
    _writeKind(kind: 'chip', asOf: asOf, rows: chip, close: bar.close);
    _writeKind(kind: 'tick', asOf: asOf, rows: tick, close: bar.close);
    _kindWritten.add('chip|$asOf');
    _kindWritten.add('tick|$asOf');
    _written.add(asOf);
  }

  void _writeKind({
    required String kind,
    required int asOf,
    required List<ProfilePeakRow> rows,
    required double close,
  }) {
    final suffixes = <String>{for (final r in rows) r.nameSuffix};
    suffixes.addAll(registeredPeakSuffixes());
    for (final s in suffixes) {
      final cell = pickProfilePeakCell(rows: rows, suffix: s, close: close);
      _put(kind, canonicalPeakSuffix(s), asOf, cell);
      if (canonicalPeakSuffix(s) == 'IN1') {
        _put(kind, '', asOf, cell);
      }
    }
  }

  void _put(String kind, String suffix, int asOf, PeakCell? v) {
    final bySuffix = _cells.putIfAbsent(kind, () => {});
    final list = bySuffix.putIfAbsent(suffix, () => <PeakCell?>[]);
    while (list.length <= asOf) {
      list.add(null);
    }
    list[asOf] = v;
  }
}

/// 登记在 catalog 中的外侧/框内后缀（用于 EXISTS=0 补格）。
List<String> registeredPeakSuffixes() {
  final out = <String>['IN1', 'IN2', 'IN3'];
  for (var n = 1; n <= kCatalogChipPeakMaxOuter; n++) {
    out.add('-$n');
    out.add('+$n');
  }
  return out;
}

/// catalog 外侧档上限（与默认配置一致）。
const int kCatalogChipPeakMaxOuter = 5;

String canonicalPeakSuffix(String suffix) {
  if (suffix.isEmpty) return 'IN1';
  return suffix;
}

PeakCell? pickProfilePeakCell({
  required List<ProfilePeakRow> rows,
  required String suffix,
  required double close,
}) {
  final key = canonicalPeakSuffix(suffix);
  for (final r in rows) {
    if (r.nameSuffix == key) {
      return PeakCell(price: r.price, b: r.b, s: r.s, g: r.g);
    }
  }
  if (key == 'IN1') {
    final legacy = [for (final r in rows) if (r.nameSuffix.isEmpty) r];
    if (legacy.isEmpty) return null;
    legacy.sort(
      (a, b) => (a.price - close).abs().compareTo((b.price - close).abs()),
    );
    final r = legacy.first;
    return PeakCell(price: r.price, b: r.b, s: r.s, g: r.g);
  }
  return null;
}

double? pickProfilePeakPrice({
  required List<ProfilePeakRow> rows,
  required String suffix,
  required double close,
}) {
  return pickProfilePeakCell(rows: rows, suffix: suffix, close: close)?.price;
}

double? liveProfilePeakScalar({
  required String kind,
  required String suffix,
  String? field,
  required int asOf,
  required List<KlineBar> bars,
  required double bucketStep,
  PeakRankConfig rank = PeakRankConfig.defaults,
}) {
  KlineBar? bar;
  for (final b in bars) {
    if (b.idx == asOf) {
      bar = b;
      break;
    }
  }
  if (bar == null) return null;
  final profile = kind == 'tick'
      ? TickDistProfileCompute.compute(
          bars: bars,
          cutoffX: asOf,
          bucketStep: bucketStep,
        )
      : ChipProfileCompute.compute(
          bars: bars,
          cutoffX: asOf,
          bucketStep: bucketStep,
        );
  final rows = classifyProfilePeaks(
    profile: profile,
    low: bar.low,
    high: bar.high,
    close: bar.close,
    rank: rank,
  );
  return peakScalarAt(
    rows: rows,
    suffix: suffix,
    field: field,
    close: bar.close,
  );
}

/// field=null 为峰价；DIST / EXISTS / BS。
double? peakScalarAt({
  required List<ProfilePeakRow> rows,
  required String suffix,
  String? field,
  required double close,
}) {
  if (field == null || field.isEmpty) {
    return pickProfilePeakPrice(rows: rows, suffix: suffix, close: close);
  }
  if (field == 'EXISTS') {
    final cell = pickProfilePeakCell(rows: rows, suffix: suffix, close: close);
    return cell != null ? 1.0 : 0.0;
  }
  final cell = pickProfilePeakCell(rows: rows, suffix: suffix, close: close);
  if (cell == null) return null;
  switch (field) {
    case 'DIST':
      return close - cell.price;
    case 'BS':
      if (cell.s <= 0) return null;
      return cell.b / cell.s;
    default:
      return null;
  }
}

/// 兼容旧调用名。
double? liveProfilePeakPrice({
  required String kind,
  required String suffix,
  required int asOf,
  required List<KlineBar> bars,
  required double bucketStep,
  PeakRankConfig rank = PeakRankConfig.defaults,
}) {
  return liveProfilePeakScalar(
    kind: kind,
    suffix: suffix,
    asOf: asOf,
    bars: bars,
    bucketStep: bucketStep,
    rank: rank,
  );
}

double? peakScalarFromStore({
  required ChipPeakFreezeStore? store,
  required String kind,
  required String suffix,
  String? field,
  required int asOf,
  required List<KlineBar> bars,
}) {
  if (field == 'EXISTS') {
    final cell = store?.cellAt(
      kind: kind,
      suffix: suffix,
      asOf: asOf,
    );
    return cell != null ? 1.0 : 0.0;
  }
  final cell = store?.cellAt(kind: kind, suffix: suffix, asOf: asOf);
  if (cell == null) return null;
  if (field == null || field.isEmpty) return cell.price;
  KlineBar? bar;
  for (final b in bars) {
    if (b.idx == asOf) {
      bar = b;
      break;
    }
  }
  if (bar == null) return null;
  switch (field) {
    case 'DIST':
      return bar.close - cell.price;
    case 'BS':
      if (cell.s <= 0) return null;
      return cell.b / cell.s;
    default:
      return null;
  }
}
