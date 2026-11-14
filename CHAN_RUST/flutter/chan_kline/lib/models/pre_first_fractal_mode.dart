/// 首分型前合并框的取值口径（设置项「首分型前合并框」）。
///
/// 只影响「首个分型之前」那一段合并框的**绘制**与**tooltip 的 MG/MD**：
/// - [seedBox] 种子框：**不合并**。首分型前各框按引擎原样画（第一根框就是种子框），
///   横向范围仍取各框自身 `x1..x2`，后续框不再并进种子框。
/// - [highHigh] 高高：把首分型前的各框并成一个框，`high` 取各框最高、`low` 也取各框最高。
/// - [lowLow] 低低：同样并成一个框，`high` 取各框最低、`low` 也取各框最低。
///
/// 默认 [highHigh]（与历史上线口径一致，老设置文件缺键时也按它）。
enum PreFirstFractalMode {
  /// 种子框：首分型前不合并，按引擎原框画。
  seedBox('种子框'),

  /// 高高：并框后 high / low 都取各框最大。
  highHigh('高高'),

  /// 低低：并框后 high / low 都取各框最小。
  lowLow('低低');

  const PreFirstFractalMode(this.label);

  /// 界面展示名（设置下拉、tooltip 标题统一用它）。
  final String label;

  /// 默认口径：高高（历史行为）。
  static const PreFirstFractalMode defaultMode = PreFirstFractalMode.highHigh;

  /// 落盘值（settings json 用枚举名，稳定可读）。
  String get storageValue => name;

  /// 从落盘值还原；缺键 / 脏值一律回落默认（高高）。
  static PreFirstFractalMode fromStorage(Object? raw) {
    if (raw is! String) return defaultMode;
    for (final m in PreFirstFractalMode.values) {
      if (m.name == raw) return m;
    }
    return defaultMode;
  }

  /// 设置面板副标题用的一句话口径说明。
  String get shortHint {
    switch (this) {
      case PreFirstFractalMode.seedBox:
        return '种子框（首分型前不合并，按原框画）';
      case PreFirstFractalMode.highHigh:
        return '高高（首分型前并一个框：最高 high + 最高 low）';
      case PreFirstFractalMode.lowLow:
        return '低低（首分型前并一个框：最低 high + 最低 low）';
    }
  }
}
