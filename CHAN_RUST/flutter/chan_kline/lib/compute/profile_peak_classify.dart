import '../models/peak_rank_config.dart';
import '../widgets/kline_chip.dart';

/// 单条峰读数（tooltip 用）。
class ProfilePeakRow {
  const ProfilePeakRow({
    required this.nameSuffix,
    required this.price,
    required this.b,
    required this.s,
    required this.g,
  });

  /// 动态名后缀：IN1/IN2=框内；'-1'/'+2'=外侧序号；'PURE1'..=纯量级全局序
  final String nameSuffix;
  final double price;
  final double b;
  final double s;
  final double g;

  String label(String prefix) {
    if (nameSuffix.startsWith('PURE')) {
      final n = nameSuffix.substring(4);
      return '$prefix·纯$n';
    }
    if (nameSuffix.startsWith('IN')) {
      final n = nameSuffix.substring(2);
      return '$prefix·框内$n';
    }
    return '$prefix$nameSuffix';
  }

  /// 值：【价】/B：【】S：【】G：【】
  String valueText() {
    String fmt(num v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
    return '【${fmt(price)}】/B：【${fmt(b)}】S：【${fmt(s)}】G：【${fmt(g)}】';
  }
}

/// 按当前 K0 高低与 [rank] 给峰编号（仅 K0 颗粒度）。
List<ProfilePeakRow> classifyProfilePeaks({
  required ChipProfileData profile,
  required double low,
  required double high,
  required double close,
  PeakRankConfig rank = PeakRankConfig.defaults,
}) {
  if (profile.isEmpty) return const [];
  final lo = low <= high ? low : high;
  final hi = low >= high ? low : high;
  final peaks = profile.peakIndices();
  if (peaks.isEmpty) return const [];

  final inRange = <int>[];
  final below = <int>[];
  final above = <int>[];
  for (final i in peaks) {
    final p = profile.prices[i];
    if (p >= lo && p <= hi) {
      inRange.add(i);
    } else if (p < lo) {
      below.add(i);
    } else {
      above.add(i);
    }
  }

  final maxOut = rank.clampedMaxOuter;
  final maxIn = rank.clampedMaxInBox;

  int cmpVolume(int a, int b) {
    final ta = profile.total[a];
    final tb = profile.total[b];
    final c = tb.compareTo(ta);
    if (c != 0) return c;
    return profile.prices[a].compareTo(profile.prices[b]);
  }

  ProfilePeakRow row(int i, String suffix) {
    final wv = i < profile.w.length ? profile.w[i] : 0.0;
    return ProfilePeakRow(
      nameSuffix: suffix,
      price: profile.prices[i],
      b: i < profile.b.length ? profile.b[i] : 0.0,
      s: i < profile.s.length ? profile.s[i] : 0.0,
      g: wv,
    );
  }

  /// 纯量级：忽略 K 的 OHLC 区间，全局按峰位 total 降序取前 N。
  if (rank.mode == PeakRankMode.pure) {
    final all = [...peaks]..sort(cmpVolume);
    final out = <ProfilePeakRow>[
      for (var n = 0; n < all.length && n < rank.clampedMaxPure; n++)
        row(all[n], 'PURE${n + 1}'),
    ];
    out.sort((a, b) => a.price.compareTo(b.price));
    return out;
  }

  if (rank.mode == PeakRankMode.spatial) {
    below.sort((a, b) => profile.prices[b].compareTo(profile.prices[a]));
    above.sort((a, b) => profile.prices[a].compareTo(profile.prices[b]));
    inRange.sort(
      (a, b) => (profile.prices[a] - close)
          .abs()
          .compareTo((profile.prices[b] - close).abs()),
    );
  } else {
    below.sort(cmpVolume);
    above.sort(cmpVolume);
    inRange.sort(cmpVolume);
  }

  final out = <ProfilePeakRow>[
    for (var n = 0; n < below.length && n < maxOut; n++)
      row(below[n], '-${n + 1}'),
    for (var n = 0; n < inRange.length && n < maxIn; n++)
      row(inRange[n], 'IN${n + 1}'),
    for (var n = 0; n < above.length && n < maxOut; n++)
      row(above[n], '+${n + 1}'),
  ];
  out.sort((a, b) => a.price.compareTo(b.price));
  return out;
}
