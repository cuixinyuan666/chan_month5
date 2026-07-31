/// Kn 三类+卖点（Rust SellNFrame；cls>=3；label 如 3Sa）。
class SellNFrame {
  final int seq;
  final int zsSeq;
  final int cls;
  final int x;
  final double price;
  /// "3Sa" / "4Sb" / ...
  final String label;
  final int segIdx;
  final int level;

  const SellNFrame({
    this.seq = 0,
    this.zsSeq = 0,
    required this.cls,
    required this.x,
    required this.price,
    required this.label,
    this.segIdx = 0,
    required this.level,
  });

  factory SellNFrame.fromJson(Map<String, dynamic> json) {
    return SellNFrame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      cls: (json['cls'] as num?)?.toInt() ?? 3,
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? '3Sa',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}
