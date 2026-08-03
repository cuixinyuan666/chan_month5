import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import 'demark_compute.dart';
import 'math_classic_compute.dart';
import 'trend_model_compute.dart';

/// 连续序列当下冻结：格点首次非空写入后禁止回写（对齐一类BS会话冻结）。
List<double?> freezeNullableSeries(List<double?>? prev, List<double?> fresh) {
  final prevLen = prev?.length ?? 0;
  final n = fresh.length > prevLen ? fresh.length : prevLen;
  if (n <= 0) return const [];
  final out = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final p = (prev != null && i < prevLen) ? prev[i] : null;
    final f = i < fresh.length ? fresh[i] : null;
    out[i] = p ?? f;
  }
  return out;
}

/// Demark 标记：格点首次非空写入后冻结（内容也不许改）。
List<List<DemarkMark>?> freezeDemarkMarks(
  List<List<DemarkMark>?>? prev,
  List<List<DemarkMark>?> fresh,
) {
  final prevLen = prev?.length ?? 0;
  final n = fresh.length > prevLen ? fresh.length : prevLen;
  if (n <= 0) return const [];
  final out = List<List<DemarkMark>?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final p = (prev != null && i < prevLen) ? prev[i] : null;
    final f = i < fresh.length ? fresh[i] : null;
    out[i] = p ?? f;
  }
  return out;
}

MacdK0Series freezeMacd(MacdK0Series? prev, MacdK0Series fresh) {
  return MacdK0Series(
    dif: freezeNullableSeries(prev?.dif, fresh.dif),
    dea: freezeNullableSeries(prev?.dea, fresh.dea),
    macd: freezeNullableSeries(prev?.macd, fresh.macd),
  );
}

BollK0Series freezeBoll(BollK0Series? prev, BollK0Series fresh) {
  return BollK0Series(
    mid: freezeNullableSeries(prev?.mid, fresh.mid),
    up: freezeNullableSeries(prev?.up, fresh.up),
    down: freezeNullableSeries(prev?.down, fresh.down),
  );
}

KdjK0Series freezeKdj(KdjK0Series? prev, KdjK0Series fresh) {
  return KdjK0Series(
    k: freezeNullableSeries(prev?.k, fresh.k),
    d: freezeNullableSeries(prev?.d, fresh.d),
    j: freezeNullableSeries(prev?.j, fresh.j),
  );
}

DemarkK0Series freezeDemark(DemarkK0Series? prev, DemarkK0Series fresh) {
  return DemarkK0Series(freezeDemarkMarks(prev?.marksAt, fresh.marksAt));
}

Map<int, List<double?>> freezeMeanMap(
  Map<int, List<double?>>? prev,
  Map<int, List<double?>> fresh,
) {
  final keys = {...?prev?.keys, ...fresh.keys};
  final out = <int, List<double?>>{};
  for (final t in keys) {
    out[t] = freezeNullableSeries(prev?[t], fresh[t] ?? const []);
  }
  return out;
}

Map<int, ({List<double?> max, List<double?> min})> freezeChannelMap(
  Map<int, ({List<double?> max, List<double?> min})>? prev,
  Map<int, ({List<double?> max, List<double?> min})> fresh,
) {
  final keys = {...?prev?.keys, ...fresh.keys};
  final out = <int, ({List<double?> max, List<double?> min})>{};
  for (final t in keys) {
    final p = prev?[t];
    final f = fresh[t];
    out[t] = (
      max: freezeNullableSeries(p?.max, f?.max ?? const []),
      min: freezeNullableSeries(p?.min, f?.min ?? const []),
    );
  }
  return out;
}

/// 会话级 Math/趋势序列冻结仓（按 displayKn）。
/// 仅 merge 写入；绘制/十字读仓，禁止整表覆盖消点。
class MathSeriesFreezeStore {
  final Map<int, MacdK0Series> macdByKn = {};
  final Map<int, BollK0Series> bollByKn = {};
  final Map<int, List<double?>> rsiByKn = {};
  final Map<int, KdjK0Series> kdjByKn = {};
  final Map<int, DemarkK0Series> demarkByKn = {};
  final Map<int, Map<int, List<double?>>> meanByKn = {};
  final Map<int, Map<int, ({List<double?> max, List<double?> min})>>
      channelByKn = {};

  void clear() {
    macdByKn.clear();
    bollByKn.clear();
    rsiByKn.clear();
    kdjByKn.clear();
    demarkByKn.clear();
    meanByKn.clear();
    channelByKn.clear();
  }

  /// 本步新鲜值并入冻结仓（全层同构）。
  void mergeLevel({
    required int displayKn,
    required MacdK0Series macd,
    required BollK0Series boll,
    required List<double?> rsi,
    required KdjK0Series kdj,
    required DemarkK0Series demark,
    required Map<int, List<double?>> mean,
    required Map<int, ({List<double?> max, List<double?> min})> channel,
  }) {
    macdByKn[displayKn] = freezeMacd(macdByKn[displayKn], macd);
    bollByKn[displayKn] = freezeBoll(bollByKn[displayKn], boll);
    rsiByKn[displayKn] = freezeNullableSeries(rsiByKn[displayKn], rsi);
    kdjByKn[displayKn] = freezeKdj(kdjByKn[displayKn], kdj);
    demarkByKn[displayKn] = freezeDemark(demarkByKn[displayKn], demark);
    meanByKn[displayKn] = freezeMeanMap(meanByKn[displayKn], mean);
    channelByKn[displayKn] = freezeChannelMap(channelByKn[displayKn], channel);
  }

  MacdK0Series? macd(int kn) => macdByKn[kn];
  BollK0Series? boll(int kn) => bollByKn[kn];
  List<double?>? rsi(int kn) => rsiByKn[kn];
  KdjK0Series? kdj(int kn) => kdjByKn[kn];
  DemarkK0Series? demark(int kn) => demarkByKn[kn];
  Map<int, List<double?>>? mean(int kn) => meanByKn[kn];
  Map<int, ({List<double?> max, List<double?> min})>? channel(int kn) =>
      channelByKn[kn];
}

/// 本步 0..maxDisplayKn 新鲜算完并入冻结仓。
void mergeMathSeriesForStep({
  required MathSeriesFreezeStore store,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required MathIndicatorConfig config,
  required int maxDisplayKn,
  int? asOf,
}) {
  if (bars.isEmpty || maxDisplayKn < 0) return;
  for (var kn = 0; kn <= maxDisplayKn; kn++) {
    final classic = computeClassicMathForLevel(
      displayKn: kn,
      bars: bars,
      levels: levels,
      config: config,
      asOf: asOf,
    );
    final demark = computeDemarkForLevel(
      displayKn: kn,
      bars: bars,
      levels: levels,
      config: config,
      asOf: asOf,
    );
    final mean = computeMeanSeriesForLevel(
      displayKn: kn,
      bars: bars,
      levels: levels,
      periods: config.meanPeriods,
      asOf: asOf,
    );
    final channel = computeChannelSeriesForLevel(
      displayKn: kn,
      bars: bars,
      levels: levels,
      periods: config.channelPeriods,
      asOf: asOf,
    );
    store.mergeLevel(
      displayKn: kn,
      macd: classic.macd,
      boll: classic.boll,
      rsi: classic.rsi,
      kdj: classic.kdj,
      demark: demark,
      mean: mean,
      channel: channel,
    );
  }
}
