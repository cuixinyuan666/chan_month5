import 'dart:convert';
import 'dart:io';

import '../models/bar_feature_lookup.dart';
import '../models/k0_confirm_signal.dart';
import '../models/level_models.dart';
import 'ml_feature_schema.dart';

/// 从只读 BarFeatureLookup 导出 JSONL（商业化样本）。
/// 不修改 tip/lookup 生产逻辑；禁止 tip 动态行名作键。
class MlFeatureExport {
  MlFeatureExport._();

  /// 组装 JSONL 全文（首行 meta，其后逐 K0 样本）。
  static String buildJsonl({
    required BarFeatureLookup lookup,
    required String code,
    required String period,
    required String beginDate,
    required String endDate,
    required int stepIdx,
    required String dataRoot,
  }) {
    final idxs = lookup.byIdx.keys.toList()..sort();
    final buf = StringBuffer();
    final meta = <String, dynamic>{
      'type': 'ml_feature_meta',
      'schema_version': MlFeatureSchema.schemaVersion,
      'rules_ref': MlFeatureSchema.rulesRef,
      'ui_owner': 'ml',
      'code': code,
      'period': period,
      'begin': beginDate,
      'end': endDate,
      'step_idx': stepIdx,
      'bar_count': idxs.length,
      'data_root': dataRoot,
      'exported_at': DateTime.now().toIso8601String(),
    };
    buf.writeln(jsonEncode(meta));

    var forbiddenHits = 0;
    for (final idx in idxs) {
      final row = lookup.byIdx[idx];
      if (row == null) continue;
      final sample = _sanitizeRow(row, onForbidden: () => forbiddenHits++);
      sample['type'] = 'ml_feature_row';
      sample['schema_version'] = MlFeatureSchema.schemaVersion;
      buf.writeln(jsonEncode(sample));
    }
    if (forbiddenHits > 0) {
      // 开发期可见：不应出现；仍写出文件但 meta 可另记
    }
    return buf.toString();
  }

  /// 落盘到 dataRoot/ml_exports/...
  static Future<File> writeJsonlFile({
    required String jsonl,
    required String dataRoot,
    required String code,
    required String period,
    required int stepIdx,
  }) async {
    final dir = Directory(
      '$dataRoot${Platform.pathSeparator}ml_exports',
    );
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final safeCode = code.isEmpty ? 'unknown' : code;
    final name =
        '${safeCode}_${period}_step${stepIdx}_v${MlFeatureSchema.schemaVersion}.jsonl';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(jsonl, flush: true);
    return file;
  }

  /// 递归转 JSON 安全值；剔除禁止键。
  static Map<String, dynamic> _sanitizeRow(
    Map<String, dynamic> row, {
    void Function()? onForbidden,
  }) {
    final out = <String, dynamic>{};
    row.forEach((k, v) {
      if (MlFeatureSchema.isForbiddenKey(k)) {
        onForbidden?.call();
        return;
      }
      out[k] = _encodeValue(v, onForbidden: onForbidden);
    });
    return out;
  }

  static dynamic _encodeValue(
    dynamic v, {
    void Function()? onForbidden,
  }) {
    if (v == null || v is num || v is String || v is bool) return v;
    if (v is LevelSnap) return _levelSnapToMap(v);
    if (v is LevelConfirm) return _levelConfirmToMap(v);
    if (v is K0ConfirmSignal) {
      return {
        'x': v.x,
        'fx': v.fx,
        'value': v.value,
        'truncated': v.truncated,
      };
    }
    if (v is Map) {
      final m = <String, dynamic>{};
      v.forEach((key, val) {
        final ks = '$key';
        if (MlFeatureSchema.isForbiddenKey(ks)) {
          onForbidden?.call();
          return;
        }
        m[ks] = _encodeValue(val, onForbidden: onForbidden);
      });
      return m;
    }
    if (v is Iterable) {
      return [for (final e in v) _encodeValue(e, onForbidden: onForbidden)];
    }
    // 其它自定义对象：尽量 toString，避免导出失败
    return v.toString();
  }

  static Map<String, dynamic> _levelSnapToMap(LevelSnap s) => {
        'level': s.level,
        'unit_idx': s.unitIdx,
        'unit_dir': s.unitDir,
        'unit_x1': s.unitX1,
        'unit_x2': s.unitX2,
        'unit_open': s.unitOpen,
        'unit_high': s.unitHigh,
        'unit_low': s.unitLow,
        'unit_close': s.unitClose,
        'unit_volume': s.unitVolume,
        'merge_inner_seq': s.mergeInnerSeq,
        'merge_count': s.mergeCount,
        'combine_high': s.combineHigh,
        'combine_low': s.combineLow,
        'combine_fx': s.combineFx,
        'combine_x1': s.combineX1,
        'merge_box_seq': s.mergeBoxSeq,
        'seed_confirmed': s.seedConfirmed,
        'seed_box_seq': s.seedBoxSeq,
        'seed_box_x1': s.seedBoxX1,
        'seed_box_x2': s.seedBoxX2,
        'seed_box_high': s.seedBoxHigh,
        'seed_box_low': s.seedBoxLow,
        'seed_fx': s.seedFx,
        'draw_a_x': s.drawAX,
        'draw_b_x': s.drawBX,
        'draw_c_x': s.drawCX,
        'first_fx_state': s.firstFxState,
        'seed_leave_dir': s.seedLeaveDir,
      };

  static Map<String, dynamic> _levelConfirmToMap(LevelConfirm c) => {
        'x': c.x,
        'fx': c.fx,
        'value': c.value,
        'fractal_x1': c.fractalX1,
        'fractal_x2': c.fractalX2,
        'truncated': c.truncated,
      };

  /// 校验 JSONL：首行 meta + 无禁止键。
  static List<String> validateJsonl(String jsonl) {
    final errors = <String>[];
    final lines =
        jsonl.split('\n').where((e) => e.trim().isNotEmpty).toList();
    if (lines.isEmpty) {
      errors.add('empty');
      return errors;
    }
    final meta = jsonDecode(lines.first) as Map<String, dynamic>;
    if (meta['schema_version'] != MlFeatureSchema.schemaVersion) {
      errors.add('schema_version');
    }
    if (meta['type'] != 'ml_feature_meta') {
      errors.add('meta_type');
    }
    for (var i = 1; i < lines.length; i++) {
      final row = jsonDecode(lines[i]) as Map<String, dynamic>;
      _walkKeys(row, (k) {
        if (MlFeatureSchema.isForbiddenKey(k)) {
          errors.add('forbidden:$k');
        }
      });
    }
    return errors;
  }

  static void _walkKeys(dynamic v, void Function(String) onKey) {
    if (v is Map) {
      v.forEach((k, val) {
        onKey('$k');
        _walkKeys(val, onKey);
      });
    } else if (v is Iterable) {
      for (final e in v) {
        _walkKeys(e, onKey);
      }
    }
  }
}
