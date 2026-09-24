/// 所选区间分笔质量：笔数是否有 0、买/卖/中性是否缺。
class TickQuality {
  const TickQuality({
    this.zeroTickCount = false,
    this.hasBuy = false,
    this.hasSell = false,
    this.hasNeutral = false,
    this.source = 'file',
    this.skipPrompts = false,
  });

  final bool zeroTickCount;
  final bool hasBuy;
  final bool hasSell;
  final bool hasNeutral;
  /// file / protocol / ohlc
  final String source;
  /// 自定义 OHLC 等无分笔：不要弹窗
  final bool skipPrompts;

  /// 仅当「笔数分布」已开启，且区间里有笔数为 0 时才提示。
  bool shouldPrompt({required bool tickDistEnabled}) {
    if (skipPrompts) return false;
    if (!tickDistEnabled) return false;
    return zeroTickCount;
  }

  factory TickQuality.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TickQuality();
    return TickQuality(
      zeroTickCount: json['zero_tick_count'] == true,
      hasBuy: json['has_buy'] == true,
      hasSell: json['has_sell'] == true,
      hasNeutral: json['has_neutral'] == true,
      source: json['source']?.toString() ?? 'file',
      skipPrompts: json['skip_prompts'] == true,
    );
  }
}
