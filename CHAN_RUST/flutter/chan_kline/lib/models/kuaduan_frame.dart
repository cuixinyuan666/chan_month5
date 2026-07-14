/// 跨段中枢镜像框（Rust `KuaDuanFrame`；展示名「K(n-1)跨段中枢」）。
/// 字段与 `KlineCombineFrame` 对齐：x 锚定 1 分钟 K，`high`=ZD 上沿(更高价)、`low`=ZG 下沿(更低价)。
class KuaDuanFrame {
  final int x1;
  final int x2;
  final double high; // ZD 上沿（更高价）
  final double low; // ZG 下沿（更低价）
  final int level; // 所属层号（与 combine/line 同号：1=笔跨段中枢, 2=线段跨段中枢…）
  final int count; // 覆盖段数（种子3 + 延伸）

  const KuaDuanFrame({
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
    required this.level,
    this.count = 0,
  });

  factory KuaDuanFrame.fromJson(Map<String, dynamic> json) {
    return KuaDuanFrame(
      x1: (json['x1'] as num?)?.toInt() ?? 0,
      x2: (json['x2'] as num?)?.toInt() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 1,
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }
}
