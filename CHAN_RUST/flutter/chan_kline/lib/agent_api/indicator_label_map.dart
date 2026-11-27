/// @file lib/agent_api/indicator_label_map.dart
/// @brief 指标 label → 枚举映射（纯 Dart，可离线单测）。
///
/// 唯一实现：主界面 `setIndicators` 与测试都走这里。
/// label 一律从目录（`buildMainIndicatorCatalog` / `buildSubIndicatorCatalog`）反查，
/// **禁止硬编码指标名**（AGENTS.md 指标同步清单）。
import '../models/chart_indicator.dart';

/// label 反查结果：命中的枚举 + 查不到的 label（查不到必须报错，不能静默丢）。
class IndicatorLabelResolution {
  final Set<MainChartIndicator> main;
  final Set<SubChartIndicator> sub;
  final List<String> unknownMain;
  final List<String> unknownSub;

  const IndicatorLabelResolution({
    required this.main,
    required this.sub,
    required this.unknownMain,
    required this.unknownSub,
  });

  bool get hasUnknown => unknownMain.isNotEmpty || unknownSub.isNotEmpty;

  /// 可读的错误说明（供 Agent API 回 `ok:false`）。
  String get unknownMessage =>
      '未知指标 label：'
      '${unknownMain.isEmpty ? '' : '主图[${unknownMain.join(",")}] '}'
      '${unknownSub.isEmpty ? '' : '副图[${unknownSub.join(",")}]'}'
      '（label 必须是目录项，可先读 GET /state 的 main_indicators/sub_indicators）';
}

/// 按 label 从真实目录反查枚举。
IndicatorLabelResolution resolveIndicatorLabels({
  required Iterable<String> mainLabels,
  required Iterable<String> subLabels,
  required List<MainChartIndicator> mainCatalog,
  required List<SubChartIndicator> subCatalog,
}) {
  final mainByLabel = {for (final e in mainCatalog) e.label: e};
  final subByLabel = {for (final e in subCatalog) e.label: e};
  final unknownMain = <String>[];
  final unknownSub = <String>[];
  final main = <MainChartIndicator>{};
  final sub = <SubChartIndicator>{};
  for (final l in mainLabels) {
    final hit = mainByLabel[l];
    if (hit == null) {
      unknownMain.add(l);
    } else {
      main.add(hit);
    }
  }
  for (final l in subLabels) {
    final hit = subByLabel[l];
    if (hit == null) {
      unknownSub.add(l);
    } else {
      sub.add(hit);
    }
  }
  return IndicatorLabelResolution(
    main: main,
    sub: sub,
    unknownMain: unknownMain,
    unknownSub: unknownSub,
  );
}
