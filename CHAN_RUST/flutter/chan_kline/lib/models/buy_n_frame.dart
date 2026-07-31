/// Kn 三类+买点（Rust BuyNFrame；cls>=3；label 如 3Ba）。
class BuyNFrame {
  final int seq;
  final int zsSeq;
  /// 类号：3=三类，4=四类…
  final int cls;
  final int x;
  final double price;
  /// "3Ba" / "4Bb" / ...
  final String label;
  final int segIdx;
  final int level;

  const BuyNFrame({
    this.seq = 0,
    this.zsSeq = 0,
    required this.cls,
    required this.x,
    required this.price,
    required this.label,
    this.segIdx = 0,
    required this.level,
  });

  factory BuyNFrame.fromJson(Map<String, dynamic> json) {
    return BuyNFrame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      cls: (json['cls'] as num?)?.toInt() ?? 3,
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? '3Ba',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}
