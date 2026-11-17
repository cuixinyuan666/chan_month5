/// 设置项「层级早生成 / 首分型前合并框」的**唯一控件口径**（四档）。
///
/// 背景（2026-11-17 用户确认合并）：原先设置面板是两个并列控件 ——
/// 「层级早生成动态单元」开关 + 「首分型前合并框」下拉，但后者被前者硬门控
/// （`applyPreFirstFractalMode` 里 `if (!earlyDynamicUnit) return frames;`），
/// 关掉早生成后那个下拉静默失效。两控件都只在回答「首框长什么样」，
/// 因此合并成一个四档下拉：关 / 开·种子框 / 开·高高 / 开·低低。
///
/// **本类是界面与落盘的唯一来源**，内部仍派生回原来的两个字段：
/// - [earlyDynamicUnit] → 喂 Rust 管道与 `chan_bridge`（总闸）
/// - [preFirstFractalMode] → 喂绘制与 tooltip 的 MG/MD（闸下口径）
///
/// 计算层（`compute/pre_first_fractal_compute.dart` / `first_fractal_rule.dart`）
/// 一行未改，仍按两个字段工作。
library;

import 'pre_first_fractal_mode.dart';

/// 层级早生成动态单元 + 首分型前合并框的合并口径。
enum PreFirstFractalUnitMode {
  /// 关闭：经典口径（等引擎自己攒够输入；种子框、种子开口、种子 ABC 照旧）。
  off('关闭（经典口径）'),

  /// 开启 + 种子框：动态 K 提前出现；首分型前**不合并**，按引擎原框画。
  seedBox('开启 · 种子框'),

  /// 开启 + 高高（默认）：动态 K 提前出现；首分型前并一个框，high、low 都取最高。
  highHigh('开启 · 高高（默认）'),

  /// 开启 + 低低：动态 K 提前出现；首分型前并一个框，high、low 都取最低。
  lowLow('开启 · 低低');

  const PreFirstFractalUnitMode(this.label);

  /// 界面展示名（设置下拉、帮助弹窗标题统一用它）。
  final String label;

  /// 默认口径：开启 + 高高（与合并前的默认组合一致）。
  static const PreFirstFractalUnitMode defaultMode =
      PreFirstFractalUnitMode.highHigh;

  /// 总闸：是否开启「层级早生成动态单元」。
  bool get earlyDynamicUnit => this != PreFirstFractalUnitMode.off;

  /// 闸下口径。关闭档返回默认（高高）——门控关着，取值不参与绘制。
  PreFirstFractalMode get preFirstFractalMode {
    switch (this) {
      case PreFirstFractalUnitMode.off:
      case PreFirstFractalUnitMode.highHigh:
        return PreFirstFractalMode.highHigh;
      case PreFirstFractalUnitMode.seedBox:
        return PreFirstFractalMode.seedBox;
      case PreFirstFractalUnitMode.lowLow:
        return PreFirstFractalMode.lowLow;
    }
  }

  /// 落盘值（settings json 用枚举名，稳定可读）。
  String get storageValue => name;

  /// 从落盘值还原；缺键 / 脏值一律回落默认（开启 · 高高）。
  static PreFirstFractalUnitMode fromStorage(Object? raw) {
    if (raw is! String) return defaultMode;
    for (final m in values) {
      if (m.name == raw) return m;
    }
    return defaultMode;
  }

  /// 老设置文件（只有 `early_dynamic_unit` + `pre_first_fractal_mode` 两键）推导。
  static PreFirstFractalUnitMode fromLegacy({
    required bool earlyDynamicUnit,
    required PreFirstFractalMode mode,
  }) {
    if (!earlyDynamicUnit) return PreFirstFractalUnitMode.off;
    switch (mode) {
      case PreFirstFractalMode.seedBox:
        return PreFirstFractalUnitMode.seedBox;
      case PreFirstFractalMode.highHigh:
        return PreFirstFractalUnitMode.highHigh;
      case PreFirstFractalMode.lowLow:
        return PreFirstFractalUnitMode.lowLow;
    }
  }

  /// 设置面板副标题用的一句话口径说明。
  String get shortHint {
    switch (this) {
      case PreFirstFractalUnitMode.off:
        return '经典口径：等引擎攒够输入才出该层首个单元，种子框照旧';
      case PreFirstFractalUnitMode.seedBox:
        return '每层首个单元提前出现；首分型前不合并，按引擎原框画';
      case PreFirstFractalUnitMode.highHigh:
        return '每层首个单元提前出现；首分型前并一个框（最高 high + 最高 low）';
      case PreFirstFractalUnitMode.lowLow:
        return '每层首个单元提前出现；首分型前并一个框（最低 high + 最低 low）';
    }
  }
}
