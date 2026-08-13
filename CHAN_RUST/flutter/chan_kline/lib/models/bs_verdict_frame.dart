/// Rust `BsVerdictFrame`：独立于 BSP 的在线对错（Pending/Correct/Wrong）。
class BsVerdictFrame {
  final int level;
  /// B / S
  final String side;
  /// 类号 1..n，不封顶
  final int cls;
  final String label;
  final int segIdx;
  /// BSP 出现 x（≠ 评判 x）
  final int bspX;
  final double price;
  final int zsSeq;
  /// pending / correct / wrong
  final String state;
  final int createX;
  final int? confirmX;
  final int? invalidX;
  final String reason;

  const BsVerdictFrame({
    required this.level,
    required this.side,
    required this.cls,
    required this.label,
    this.segIdx = 0,
    required this.bspX,
    this.price = 0,
    this.zsSeq = 0,
    this.state = 'pending',
    this.createX = 0,
    this.confirmX,
    this.invalidX,
    this.reason = '',
  });

  factory BsVerdictFrame.fromJson(Map<String, dynamic> json) {
    return BsVerdictFrame(
      level: (json['level'] as num?)?.toInt() ?? 0,
      side: json['side'] as String? ?? 'B',
      cls: (json['cls'] as num?)?.toInt() ?? 1,
      label: json['label'] as String? ?? '',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      bspX: (json['bsp_x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      state: json['state'] as String? ?? 'pending',
      createX: (json['create_x'] as num?)?.toInt() ?? 0,
      confirmX: (json['confirm_x'] as num?)?.toInt(),
      invalidX: (json['invalid_x'] as num?)?.toInt(),
      reason: json['reason'] as String? ?? '',
    );
  }

  bool get isCorrect => state == 'correct';
  bool get isWrong => state == 'wrong';
  bool get isPending => !isCorrect && !isWrong;

  /// 终态事件 x；Pending 为 null。
  int? get verdictX => isCorrect ? confirmX : (isWrong ? invalidX : null);

  /// 稳定键：层|向|类|段|标签（与 Rust 同构；同 seg/label 多 x 共用）。
  String get stableKey => '$level|$side|$cls|$segIdx|$label';
}
