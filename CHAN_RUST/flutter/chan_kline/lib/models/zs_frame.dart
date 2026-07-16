/// 原生缠论中枢镜像框（Rust `ZSFrame`；展示名「K(n-1)原生中枢」）。
/// 字段对齐合并框坐标系：`high`=ZD 上沿(更高价)、`low`=ZG 下沿(更低价)；
/// 额外携带方向 dir、进出段 idx(biInIdx/biOutIdx)、单段/九段升级/末态确认标记。
class ZSFrame {
  /// 本层原生中枢序号（1-based，按时间先后）
  final int seq;
  final int x1;
  final int x2;
  final double high; // ZD 上沿（更高价）
  final double low; // ZG 下沿（更低价）
  final int level; // 所属层号（与 combine/line/跨段中枢同号：1=K0原生中枢, 2=K1原生中枢…）
  final int count; // 覆盖段数（种子3 + 延伸；combine 合并后可能更多）
  final int dir; // 中枢方向（首段方向：1 向上，-1 向下）
  final bool isOneBiZs; // 是否单段（单笔）中枢
  final bool isNineSegUpgrade; // 是否九段重叠升级
  final bool isSure; // 是否末态确认
  final int? biInIdx; // 进段相邻 LevelSegment.idx（预留三类买卖点）
  final int? biOutIdx; // 出段相邻 LevelSegment.idx（预留三类买卖点）

  const ZSFrame({
    this.seq = 0,
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
    required this.level,
    this.count = 0,
    this.dir = 0,
    this.isOneBiZs = false,
    this.isNineSegUpgrade = false,
    this.isSure = true,
    this.biInIdx,
    this.biOutIdx,
  });

  factory ZSFrame.fromJson(Map<String, dynamic> json) {
    return ZSFrame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      x1: (json['x1'] as num?)?.toInt() ?? 0,
      x2: (json['x2'] as num?)?.toInt() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 1,
      count: (json['count'] as num?)?.toInt() ?? 0,
      dir: (json['dir'] as num?)?.toInt() ?? 0,
      isOneBiZs: json['is_one_bi_zs'] as bool? ?? false,
      isNineSegUpgrade: json['is_nine_seg_upgrade'] as bool? ?? false,
      isSure: json['is_sure'] as bool? ?? true,
      biInIdx: json['in_seg_idx'] is num ? (json['in_seg_idx'] as num).toInt() : null,
      biOutIdx: json['out_seg_idx'] is num ? (json['out_seg_idx'] as num).toInt() : null,
    );
  }
}
