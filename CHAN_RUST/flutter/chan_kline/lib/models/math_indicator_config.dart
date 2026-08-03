import 'trend_model_config.dart';

/// 数学指标参数（均线/通道/MACD/BOLL/RSI/KDJ/Demark/背驰）。
class MathIndicatorConfig {
  const MathIndicatorConfig({
    this.meanPeriods = TrendModelConfig.defaultMeanPeriods,
    this.channelPeriods = TrendModelConfig.defaultChannelPeriods,
    this.macdFast = 12,
    this.macdSlow = 26,
    this.macdSignal = 9,
    this.bollN = 20,
    this.rsiPeriod = 14,
    this.kdjPeriod = 9,
    this.demarkLen = 9,
    this.demarkSetupBias = 4,
    this.demarkCountdownBias = 2,
    this.demarkMaxCountdown = 13,
    /// >100 保送背驰（突破即 diver=1）；默认很大
    this.divergenceRate = 1e9,
  });

  final List<int> meanPeriods;
  final List<int> channelPeriods;
  final int macdFast;
  final int macdSlow;
  final int macdSignal;
  final int bollN;
  final int rsiPeriod;
  final int kdjPeriod;
  final int demarkLen;
  final int demarkSetupBias;
  final int demarkCountdownBias;
  final int demarkMaxCountdown;
  final double divergenceRate;

  TrendModelConfig get asTrendModel => TrendModelConfig(
        meanPeriods: meanPeriods,
        channelPeriods: channelPeriods,
      );

  MathIndicatorConfig copyWith({
    List<int>? meanPeriods,
    List<int>? channelPeriods,
    int? macdFast,
    int? macdSlow,
    int? macdSignal,
    int? bollN,
    int? rsiPeriod,
    int? kdjPeriod,
    int? demarkLen,
    int? demarkSetupBias,
    int? demarkCountdownBias,
    int? demarkMaxCountdown,
    double? divergenceRate,
  }) {
    return MathIndicatorConfig(
      meanPeriods: meanPeriods ?? this.meanPeriods,
      channelPeriods: channelPeriods ?? this.channelPeriods,
      macdFast: macdFast ?? this.macdFast,
      macdSlow: macdSlow ?? this.macdSlow,
      macdSignal: macdSignal ?? this.macdSignal,
      bollN: bollN ?? this.bollN,
      rsiPeriod: rsiPeriod ?? this.rsiPeriod,
      kdjPeriod: kdjPeriod ?? this.kdjPeriod,
      demarkLen: demarkLen ?? this.demarkLen,
      demarkSetupBias: demarkSetupBias ?? this.demarkSetupBias,
      demarkCountdownBias: demarkCountdownBias ?? this.demarkCountdownBias,
      demarkMaxCountdown: demarkMaxCountdown ?? this.demarkMaxCountdown,
      divergenceRate: divergenceRate ?? this.divergenceRate,
    );
  }

  Map<String, dynamic> toJson() => {
        'meanPeriods': meanPeriods,
        'channelPeriods': channelPeriods,
        'macdFast': macdFast,
        'macdSlow': macdSlow,
        'macdSignal': macdSignal,
        'bollN': bollN,
        'rsiPeriod': rsiPeriod,
        'kdjPeriod': kdjPeriod,
        'demarkLen': demarkLen,
        'demarkSetupBias': demarkSetupBias,
        'demarkCountdownBias': demarkCountdownBias,
        'demarkMaxCountdown': demarkMaxCountdown,
        'divergenceRate': divergenceRate,
      };

  factory MathIndicatorConfig.fromJson(Map<String, dynamic>? map) {
    if (map == null) return const MathIndicatorConfig();
    int i(dynamic v, int fb) {
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? fb;
    }

    List<int> parseList(dynamic raw, List<int> fallback) {
      if (raw is! List) return fallback;
      final out = <int>[];
      for (final e in raw) {
        final v = e is num ? e.toInt() : int.tryParse('$e');
        if (v != null && v >= 1) out.add(v);
      }
      return out.isEmpty ? fallback : out;
    }

    double d(dynamic v, double fb) {
      if (v is num) return v.toDouble();
      return double.tryParse('$v') ?? fb;
    }

    return MathIndicatorConfig(
      meanPeriods:
          parseList(map['meanPeriods'], TrendModelConfig.defaultMeanPeriods),
      channelPeriods: parseList(
          map['channelPeriods'], TrendModelConfig.defaultChannelPeriods),
      macdFast: i(map['macdFast'], 12),
      macdSlow: i(map['macdSlow'], 26),
      macdSignal: i(map['macdSignal'], 9),
      bollN: i(map['bollN'], 20),
      rsiPeriod: i(map['rsiPeriod'], 14),
      kdjPeriod: i(map['kdjPeriod'], 9),
      demarkLen: i(map['demarkLen'], 9),
      demarkSetupBias: i(map['demarkSetupBias'], 4),
      demarkCountdownBias: i(map['demarkCountdownBias'], 2),
      demarkMaxCountdown: i(map['demarkMaxCountdown'], 13),
      divergenceRate: d(map['divergenceRate'], 1e9),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MathIndicatorConfig &&
      _listEq(meanPeriods, other.meanPeriods) &&
      _listEq(channelPeriods, other.channelPeriods) &&
      macdFast == other.macdFast &&
      macdSlow == other.macdSlow &&
      macdSignal == other.macdSignal &&
      bollN == other.bollN &&
      rsiPeriod == other.rsiPeriod &&
      kdjPeriod == other.kdjPeriod &&
      demarkLen == other.demarkLen &&
      demarkSetupBias == other.demarkSetupBias &&
      demarkCountdownBias == other.demarkCountdownBias &&
      demarkMaxCountdown == other.demarkMaxCountdown &&
      divergenceRate == other.divergenceRate;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(meanPeriods),
        Object.hashAll(channelPeriods),
        macdFast,
        macdSlow,
        macdSignal,
        bollN,
        rsiPeriod,
        kdjPeriod,
        demarkLen,
        demarkSetupBias,
        demarkCountdownBias,
        Object.hash(demarkMaxCountdown, divergenceRate),
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
