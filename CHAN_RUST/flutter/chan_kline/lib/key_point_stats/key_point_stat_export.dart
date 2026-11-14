import 'dart:convert';
import 'dart:io';

import '../settings/key_point_stats_settings_store.dart';

import 'key_point_stat_runner.dart';
import 'stat_metrics.dart';

/// 计优结果落盘：JSON（完整，含关键点位清单）+ TSV（表格，人工可读）。
abstract final class KeyPointStatExport {
  static String buildJson(KeyPointStatResult result) =>
      const JsonEncoder.withIndent('  ').convert(result.toJson());

  /// 「众数」一列对数值型放桶值、对类别型放精确众数标签（同一列，按类型二选一）；
  /// 「众数占比」是显著性判据 —— 数值型低于阈值的，「众数」列留空表示**无显著众数**，
  /// 不是 0。
  static const List<String> tsvHeader = [
    '分组',
    '转折点数',
    '指标键',
    '中文名',
    '类型',
    '样本数',
    '非空率',
    '平均数',
    '中位数',
    '标准差',
    '最小',
    '最大',
    'P25',
    'P75',
    '众数/众数标签',
    '众数命中数',
    '众数占比',
  ];

  static String buildTsv(KeyPointStatResult result) {
    final buf = StringBuffer()
      ..writeln(tsvHeader.join('\t'))
      ..writeln('# ${result.headerLine}'.replaceAll('\n', ' | '));
    final thr = result.settings.modeMinShare;
    for (final g in result.groups) {
      for (final s in g.stats) {
        buf.writeln([
          g.groupLabel,
          g.pointCount,
          s.metricKey,
          s.labelCn,
          s.kind == StatValueKind.numeric ? '数值' : '类别',
          s.sampleCount,
          _ratio(s.coverage),
          _num(s.mean),
          _num(s.median),
          _num(s.stddev),
          _num(s.min),
          _num(s.max),
          _num(s.p25),
          _num(s.p75),
          // 众数显著性门控：桶命中占比过低时留空（留空=无显著众数，不是 0）
          _modeCell(s, thr),
          s.modeCount,
          _ratio(s.modeShare),
        ].join('\t'));
      }
    }
    return buf.toString();
  }

  /// 众数列：数值型未达显著性阈值时留空；类别型照常给精确众数标签。
  static String _modeCell(StatSummary s, double threshold) {
    if (s.kind == StatValueKind.categorical) return s.modeLabel ?? '';
    final share = s.modeShare;
    if (s.mode == null) return '';
    if (share == null || share < threshold) return '';
    return _num(s.mode);
  }

  static String _num(double? v) {
    if (v == null || !v.isFinite) return '';
    return v.toStringAsFixed(6);
  }

  static String _ratio(double? v) {
    if (v == null || !v.isFinite) return '';
    return v.toStringAsFixed(4);
  }

  static Future<File> writeAll(KeyPointStatResult result) async {
    final json = await KeyPointStatSettingsStore.resultsFile(
      code: result.code,
      period: result.period,
    );
    await json.writeAsString(buildJson(result), flush: true);
    final tsv = await KeyPointStatSettingsStore.resultsTsvFile(
      code: result.code,
      period: result.period,
    );
    await tsv.writeAsString(buildTsv(result), flush: true);
    return tsv;
  }
}