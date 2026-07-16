/// 三类买卖点（BSP）镜像框（Rust `BSPFrame`；展示名「K(n-1)买卖点」）。
/// 字段对齐合并框坐标系：直接在 Rust 末态逐K产出的 `bsp_frames` 上消费，Flutter 不做本地重算。
///
/// 口径（纯结构趋势末端，无背驰）：
/// - cls=1 → 一类买卖点（≥min_zs_cnt 个中枢构成趋势的末段端点）；
/// - cls=2 → 二类买卖点（一类之后回踩不破一类极值）；
/// - cls=3 → 三类买卖点（一类之后离开中枢并返回但不回中枢带 [ZG,ZD]）；
/// - is_buy=true 买点 / false 卖点（涨红跌绿：买=红、卖=绿）。
class BSPFrame {
  /// 类：1/2/3
  final int cls;

  /// 是否买点（true=买，false=卖）
  final bool isBuy;

  /// 点位价格（买点=段低点；卖点=段高点）
  final double price;

  /// 主图 x（端点段 end_pole_x，锚定 1 分钟 K）
  final int x;

  /// 所属层号（与 combine/line/跨段中枢/原生中枢同号：1=K0买卖点, 2=K1买卖点…）
  final int level;

  /// 端点 LevelSegment.idx
  final int segIdx;

  /// 关联一类端点 LevelSegment.idx（二类/三类；一类为 null）
  final int? relateSegIdx;

  const BSPFrame({
    required this.cls,
    required this.isBuy,
    required this.price,
    required this.x,
    required this.level,
    required this.segIdx,
    this.relateSegIdx,
  });

  factory BSPFrame.fromJson(Map<String, dynamic> json) {
    return BSPFrame(
      cls: (json['cls'] as num?)?.toInt() ?? 1,
      isBuy: json['is_buy'] as bool? ?? false,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      x: (json['x'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 1,
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      relateSegIdx:
          json['relate_seg_idx'] is num ? (json['relate_seg_idx'] as num).toInt() : null,
    );
  }
}
