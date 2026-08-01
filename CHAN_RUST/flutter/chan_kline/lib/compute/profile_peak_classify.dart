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

  /// 动态名后缀：''=落在高低之间；'-1'/'+2'=相对低/高外侧序号
  final String nameSuffix;
  final double price;
  final double b;
  final double s;
  final double g;

  /// 完整标签，如 `K0筹码峰-1` / `K0笔数峰+2` / `K0筹码峰`
  String label(String prefix) => '$prefix$nameSuffix';

  /// 值：【价】/B：【】S：【】G：【】
  String valueText() {
    String fmt(num v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
    return '【${fmt(price)}】/B：【${fmt(b)}】S：【${fmt(s)}】G：【${fmt(g)}】';
  }
}

/// 按当前 K0 高低给峰编号（仅 K0 颗粒度）。
///
/// - 峰价落在 [low, high] 内：无 -/＋后缀
/// - 低于 low：由近到远 `-1,-2,…`
/// - 高于 high：由近到远 `+1,+2,…`
List<ProfilePeakRow> classifyProfilePeaks({
  required ChipProfileData profile,
  required double low,
  required double high,
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
  // 外侧：离边界越近序号越小
  below.sort((a, b) => profile.prices[b].compareTo(profile.prices[a]));
  above.sort((a, b) => profile.prices[a].compareTo(profile.prices[b]));

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

  final out = <ProfilePeakRow>[
    for (final i in inRange) row(i, ''),
    for (var n = 0; n < below.length; n++) row(below[n], '-${n + 1}'),
    for (var n = 0; n < above.length; n++) row(above[n], '+${n + 1}'),
  ];
  // 显示序：外侧下 → 框内 → 外侧上（价格升序）
  out.sort((a, b) => a.price.compareTo(b.price));
  return out;
}
