/// K0合并分型确认柱：合并框顶/底分型确认当步 K（连接即 K0连线，逐K当下冻结）。
class K0ConfirmSignal {
  final int x;
  final String fx;
  /// 向上K0连线=1，向下K0连线=-1
  final int value;
  final int fractalX1;
  final int fractalX2;

  /// 截断确认（上升/下降截断触发，非常规三元素路径）
  final bool truncated;

  const K0ConfirmSignal({
    required this.x,
    required this.fx,
    required this.value,
    required this.fractalX1,
    required this.fractalX2,
    this.truncated = false,
  });

  factory K0ConfirmSignal.fromJson(Map<String, dynamic> json) {
    return K0ConfirmSignal(
      x: (json['x'] as num).toInt(),
      fx: json['fx'] as String? ?? 'UNKNOWN',
      value: (json['value'] as num?)?.toInt() ?? 0,
      fractalX1: (json['fractal_x1'] as num?)?.toInt() ?? -1,
      fractalX2: (json['fractal_x2'] as num?)?.toInt() ?? -1,
      truncated: json['truncated'] as bool? ?? false,
    );
  }
}
