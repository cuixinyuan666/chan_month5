/// Kn buy1 marker (Rust Buy1Frame; same level id as ZS).
class Buy1Frame {
  final int seq;
  final int zsSeq;
  final int x;
  final double price;
  /// "1a" / "1b" / ...
  final String label;
  final int segIdx;
  final int level;

  const Buy1Frame({
    this.seq = 0,
    this.zsSeq = 0,
    required this.x,
    required this.price,
    required this.label,
    this.segIdx = 0,
    required this.level,
  });

  factory Buy1Frame.fromJson(Map<String, dynamic> json) {
    return Buy1Frame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? '1a',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}