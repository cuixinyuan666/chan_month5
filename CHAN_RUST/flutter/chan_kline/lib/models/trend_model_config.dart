/// 均线/通道周期配置（对齐旧 `mean_metrics` / `trend_metrics`）。
class TrendModelConfig {
  const TrendModelConfig({
    this.meanPeriods = defaultMeanPeriods,
    this.channelPeriods = defaultChannelPeriods,
  });

  /// 旧工程示例：5,10,20
  static const List<int> defaultMeanPeriods = [5, 10, 20];

  /// 旧工程示例：20,60
  static const List<int> defaultChannelPeriods = [20, 60];

  final List<int> meanPeriods;
  final List<int> channelPeriods;

  TrendModelConfig copyWith({
    List<int>? meanPeriods,
    List<int>? channelPeriods,
  }) {
    return TrendModelConfig(
      meanPeriods: meanPeriods ?? this.meanPeriods,
      channelPeriods: channelPeriods ?? this.channelPeriods,
    );
  }

  Map<String, dynamic> toJson() => {
        'meanPeriods': meanPeriods,
        'channelPeriods': channelPeriods,
      };

  factory TrendModelConfig.fromJson(Map<String, dynamic>? map) {
    if (map == null) return const TrendModelConfig();
    List<int> parseList(dynamic raw, List<int> fallback) {
      if (raw is! List) return fallback;
      final out = <int>[];
      for (final e in raw) {
        final v = e is num ? e.toInt() : int.tryParse('$e');
        if (v != null && v >= 1) out.add(v);
      }
      return out.isEmpty ? fallback : out;
    }

    return TrendModelConfig(
      meanPeriods: parseList(map['meanPeriods'], defaultMeanPeriods),
      channelPeriods: parseList(map['channelPeriods'], defaultChannelPeriods),
    );
  }

  /// 解析「5,10,20」文本；非法/空 → fallback。
  static List<int> parsePeriodsText(String text, List<int> fallback) {
    final parts = text.split(RegExp(r'[,，\s]+'));
    final out = <int>[];
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      final v = int.tryParse(t);
      if (v != null && v >= 1) out.add(v);
    }
    return out.isEmpty ? fallback : out;
  }

  String meanPeriodsText() => meanPeriods.join(',');
  String channelPeriodsText() => channelPeriods.join(',');

  @override
  bool operator ==(Object other) =>
      other is TrendModelConfig &&
      _listEq(meanPeriods, other.meanPeriods) &&
      _listEq(channelPeriods, other.channelPeriods);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(meanPeriods),
        Object.hashAll(channelPeriods),
      );

  static bool _listEq(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
