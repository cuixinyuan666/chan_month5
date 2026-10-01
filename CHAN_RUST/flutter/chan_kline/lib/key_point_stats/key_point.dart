/// 计优 · 关键点位模型。
///
/// 本阶段「关键点位」= 各级别连线的转折点（顶 TOP / 底 BOTTOM）。
/// 取值口径：**读极点 K 那一行**（图形上转折真正发生的那根 K0），
/// 同时记录 `confirmX`（确认当步 K0）供审计。
///
/// 注意：计优是 AGENTS.md「当下性」条款里明确的**事后统计例外** ——
/// 转折点是回头认定的，但读到的每个指标值仍只来自该 K 及之前（BarFeatureLookup 冻结账）。
class KeyPoint {
  /// 层级：0 = K0 连线（旧称笔）；1..n = K{n} 连线（旧称 N 段）。
  final int level;

  /// 转折方向：TOP（顶）/ BOTTOM（底）。
  final String fx;

  /// 转折真正发生的 K0 索引（取指标值就用这一根）。
  final int poleX;

  /// 确认当步 K0 索引（审计用，不参与取值）。
  final int confirmX;

  /// 来源：k0_confirm / k0_line / kn_segment / kn_confirm。
  final String source;

  const KeyPoint({
    required this.level,
    required this.fx,
    required this.poleX,
    required this.confirmX,
    required this.source,
  });

  /// 去重键：同层 + 同 x + 同方向只算一次。
  String get dedupKey => '$level|$poleX|$fx';

  bool get isTop => fx == 'TOP';

  /// 'K0连线' / 'K1连线' / …
  String get levelLabel => 'K$level 连线';

  /// 'K1 顶' / 'K1 底' / …
  String get sideLabel => 'K$level ${isTop ? '顶' : '底'}';

  Map<String, dynamic> toJson() => {
        'level': level,
        'fx': fx,
        'pole_x': poleX,
        'confirm_x': confirmX,
        'source': source,
      };

  @override
  String toString() => 'KeyPoint($sideLabel@$poleX, confirm=$confirmX, $source)';
}