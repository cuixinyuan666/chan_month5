/// ML 特征 schema（商业化 v1）。
/// 固定键目录；禁止 tip 动态行名（如「K0筹码峰-1」）作 JSON 键。
class MlFeatureSchema {
  MlFeatureSchema._();

  static const int schemaVersion = 1;
  static const String rulesRef = 'tooltip_four_rules';

  /// 顶层稳定键（每行样本应优先包含；缺省可空）。
  static const List<String> coreKeys = [
    'idx',
    'time_ms',
    'time_text',
    'weekday',
    'open',
    'high',
    'low',
    'close',
    'volume',
    'amount',
    'merge_inner_seq',
    'merge_count',
    'merge_box_seq',
    'combine_fx',
    'combine_high',
    'combine_low',
    'k1_idx',
    'k1_merge_inner_seq',
    'k1_merge_count',
    'k1_open',
    'k1_high',
    'k1_low',
    'k1_close',
    'k1_volume',
    'k1_combine_high',
    'k1_combine_low',
    'k1_combine_fx',
    'levels',
    'sub',
    'metrics',
  ];

  /// tip 动态名模式：导出时不得出现在 JSON 键里。
  static final List<RegExp> forbiddenKeyPatterns = [
    RegExp(r'^K0筹码峰'),
    RegExp(r'^K0笔数峰'),
    RegExp(r'筹码峰[-＋+]'),
    RegExp(r'笔数峰[-＋+]'),
  ];

  static bool isForbiddenKey(String key) {
    for (final p in forbiddenKeyPatterns) {
      if (p.hasMatch(key)) return true;
    }
    return false;
  }
}
