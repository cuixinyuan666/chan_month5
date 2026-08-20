import '../compute/chip_profile_compute.dart';
import '../compute/profile_peak_classify.dart';
import '../compute/tick_dist_profile_compute.dart';
import '../models/kline_bar.dart';

/// 筹码峰 / 笔数峰价：与十字同一套编号，按当根高低框编 -1/+1。
///
/// 格点首次写入后冻结；没有那一颗就是空，不填 0、不沿用上一根。
class ChipPeakFreezeStore {
  /// kind (chip|tick) → suffix ('' / '-1' / '+1') → 按 K0 下标的价
  final Map<String, Map<String, List<double?>>> _cells = {};
  final Set<int> _written = {};
  final Set<String> _kindWritten = {};
  double? _bucketStep;

  bool get isEmpty => _written.isEmpty;

  void clear() {
    _cells.clear();
    _written.clear();
    _kindWritten.clear();
    _bucketStep = null;
  }

  /// 0..asOf 缺格补写；桶宽变了整仓清空再写。
  void ingestThrough({
    required int asOf,
    required List<KlineBar> bars,
    required double bucketStep,
  }) {
    if (asOf < 0 || bars.isEmpty) return;
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    if (_bucketStep != null && (step - _bucketStep!).abs() > 1e-12) {
      clear();
    }
    _bucketStep = step;
    for (var x = 0; x <= asOf; x++) {
      if (_written.contains(x)) continue;
      _ingestOne(asOf: x, bars: bars, bucketStep: step);
    }
  }

  /// 测试用：直接喂已编号的峰，不跑筹码计算。
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
    final series = _cells[kind]?[suffix];
    if (series == null || asOf < 0 || asOf >= series.length) return null;
    return series[asOf];
  }

  void _ingestOne({
    required int asOf,
    required List<KlineBar> bars,
    required double bucketStep,
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
    );
    final tick = classifyProfilePeaks(
      profile: TickDistProfileCompute.compute(
        bars: bars,
        cutoffX: asOf,
        bucketStep: bucketStep,
      ),
      low: bar.low,
      high: bar.high,
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
    final suffixes = <String>{'', for (final r in rows) r.nameSuffix};
    for (final s in suffixes) {
      final v = pickProfilePeakPrice(rows: rows, suffix: s, close: close);
      _put(kind, s, asOf, v);
    }
  }

  void _put(String kind, String suffix, int asOf, double? v) {
    final bySuffix = _cells.putIfAbsent(kind, () => {});
    final list = bySuffix.putIfAbsent(suffix, () => <double?>[]);
    while (list.length <= asOf) {
      list.add(null);
    }
    list[asOf] = v;
  }
}

/// 框内无号多峰时取离收盘更近的那颗；外侧按 -1/+1 精确后缀。没有就 null。
double? pickProfilePeakPrice({
  required List<ProfilePeakRow> rows,
  required String suffix,
  required double close,
}) {
  if (suffix.isEmpty) {
    final inBox = [for (final r in rows) if (r.nameSuffix.isEmpty) r];
    if (inBox.isEmpty) return null;
    inBox.sort(
      (a, b) => (a.price - close).abs().compareTo((b.price - close).abs()),
    );
    return inBox.first.price;
  }
  for (final r in rows) {
    if (r.nameSuffix == suffix) return r.price;
  }
  return null;
}

/// 无冻结仓时按 asOf 前缀现算（与十字同一套 classify）。
double? liveProfilePeakPrice({
  required String kind,
  required String suffix,
  required int asOf,
  required List<KlineBar> bars,
  required double bucketStep,
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
  );
  return pickProfilePeakPrice(rows: rows, suffix: suffix, close: bar.close);
}
