/// K线合并线框（Rust `KlineCombineFrame`；展示名「K0合并」）。
class KlineCombineFrame {
  final int x1;
  final int x2;
  final String t1;
  final String t2;
  final double high;
  final double low;
  final String fx;
  final int count;
  /// 末端落在 x2 分钟 K 左半侧（右边界=该 K 中轴）
  final bool endAtLeftHalf;
  /// 起始落在 x1 分钟 K 右半侧（左边界=该 K 中轴）
  final bool startAtRightHalf;

  /// 该帧所在层是否仍处于「首分型正式成立前」（两元素章也算首分型前）。
  /// 绘制层用它决定「单根框是否也画」；Rust 回传帧默认 false（由调用方另行判定）。
  final bool beforeFirstStandardFx;

  /// 首分型前并框时，被并进来的「第一个框」是否只有 1 根 K（首合并框仅单个）。
  /// 由 [applyPreFirstFractalMode] 并框时写入，其它来源一律 false。
  /// 首分型前动态 K 靠它判断「首框只有 1 根」：并框后 count=2 与真正的包含合并长得一样，
  /// 不能靠 count 区分（全层同构）。
  final bool firstBoxWasSingle;

  const KlineCombineFrame({
    required this.x1,
    required this.x2,
    required this.t1,
    required this.t2,
    required this.high,
    required this.low,
    required this.fx,
    required this.count,
    this.endAtLeftHalf = false,
    this.startAtRightHalf = false,
    this.beforeFirstStandardFx = false,
    this.firstBoxWasSingle = false,
  });

  factory KlineCombineFrame.fromJson(Map<String, dynamic> json) {
    return KlineCombineFrame(
      x1: (json['x1'] as num).toInt(),
      x2: (json['x2'] as num).toInt(),
      t1: json['t1'] as String? ?? '',
      t2: json['t2'] as String? ?? '',
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      fx: json['fx'] as String? ?? 'UNKNOWN',
      count: (json['count'] as num?)?.toInt() ?? 1,
      endAtLeftHalf: json['end_at_left_half'] as bool? ?? false,
      startAtRightHalf: json['start_at_right_half'] as bool? ?? false,
      beforeFirstStandardFx:
          json['before_first_standard_fx'] as bool? ?? false,
    );
  }
}

// 主/副图指标定义见 chart_indicator.dart（按加载后 maxKn 动态生成）
