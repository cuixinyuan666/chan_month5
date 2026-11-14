import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/math_indicator_config.dart';

/// 逐根步进地填满冻结仓，返回建好的仓。
///
/// **为什么必须有这个 helper（2026-10-10）**：
/// `mergeMathSeriesForStep` 内部调 `store.mergeLevel(onlyX: asOf)`，
/// **每次只写当根那一格**，历史格一律留空（见 `math_series_freeze_store.dart`
/// 里 `mergeLevel` 的 `onlyX` 分支与「只写当根，避免整表拷贝」注释）。
///
/// 这是「逐根步进冻结」的设计本意 —— 不能为了回填历史而破坏它。
/// 但它带来一条容易踩的约束：
/// **冻结仓只有逐根步进才会填满；一次性跳到末根建仓，拿到的永远是单格仓。**
///
/// 2026-10-10 之前有 4 条测试踩了这条（signal_data_catalog ×2 / indicator_var_ext /
/// mini_loop），症状统一是「读历史格得 null」「序列长度只有 1」「找不到 CROSS」。
/// 它们的错不在产品逻辑，而在**建仓姿势**：跳步建仓后当完整历史用。
///
/// 用法：
/// ```dart
/// final store = fillMathFreezeByStepping(
///   bars: bars,
///   levels: bundle.levels,
///   config: const MathIndicatorConfig(bollN: 20),
///   maxDisplayKn: 1,
///   asOf: 80,
/// );
/// ```
MathSeriesFreezeStore fillMathFreezeByStepping({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required MathIndicatorConfig config,
  required int maxDisplayKn,
  required int asOf,
  int? startX,
}) {
  final store = MathSeriesFreezeStore();
  final from = startX ?? 0;
  final to = asOf < bars.last.idx ? asOf : bars.last.idx;
  for (var x = from; x <= to; x++) {
    mergeMathSeriesForStep(
      store: store,
      bars: bars,
      levels: levels,
      config: config,
      maxDisplayKn: maxDisplayKn,
      asOf: x,
    );
  }
  return store;
}
