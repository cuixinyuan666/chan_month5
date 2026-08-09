import 'ml_feature_schema.dart';

/// 把 tip/lookup 行压成数值特征（demo5/6 meta 对齐用）。
class MlFeatureFlat {
  MlFeatureFlat._();

  static const double missing = -9999999;

  /// 递归扁平化；跳过禁止键；非数值尽量跳过或编码为 0/1。
  static Map<String, double> flattenRow(Map<String, dynamic> row) {
    final out = <String, double>{};
    void walk(String prefix, dynamic v) {
      if (v == null) return;
      if (prefix.isNotEmpty && MlFeatureSchema.isForbiddenKey(prefix)) return;
      if (v is num) {
        if (prefix.isNotEmpty) out[prefix] = v.toDouble();
        return;
      }
      if (v is bool) {
        if (prefix.isNotEmpty) out[prefix] = v ? 1.0 : 0.0;
        return;
      }
      if (v is String) {
        if (prefix.isEmpty) return;
        // 分型等枚举：TOP=-1 BOTTOM=1 其它 hash 稳定小数
        if (v == 'TOP') {
          out[prefix] = -1;
        } else if (v == 'BOTTOM') {
          out[prefix] = 1;
        } else if (v == 'UNKNOWN' || v == '-' || v.isEmpty) {
          out[prefix] = 0;
        } else {
          out['${prefix}__has'] = 1;
        }
        return;
      }
      if (v is Map) {
        v.forEach((k, val) {
          final key = '$k';
          if (MlFeatureSchema.isForbiddenKey(key)) return;
          final next = prefix.isEmpty ? key : '$prefix.$key';
          walk(next, val);
        });
        return;
      }
      if (v is Iterable) {
        var i = 0;
        for (final e in v) {
          walk('$prefix[$i]', e);
          i++;
          if (i >= 32) break; // 防爆炸
        }
      }
    }

    walk('', row);
    // 去掉非数值污染：只保留 finite
    out.removeWhere((_, v) => v.isNaN || v.isInfinite);
    return out;
  }

  /// 按 meta 名→index 填稠密向量（缺省=missing）。
  static List<double> denseFromMeta(
    Map<String, int> meta,
    Map<String, double> features,
  ) {
    final n = meta.length;
    final arr = List<double>.filled(n, missing);
    features.forEach((name, value) {
      final idx = meta[name];
      if (idx != null && idx >= 0 && idx < n) {
        arr[idx] = value;
      }
    });
    return arr;
  }
}
