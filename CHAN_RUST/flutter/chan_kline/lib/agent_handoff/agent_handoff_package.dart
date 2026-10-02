import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../key_point_stats/key_point_stat_runner.dart';
import '../settings/indicator_search_last_result_store.dart';

/// 「智能体交流」交接包：把一次寻优/计优的结论层数据整理成结构化 JSON，
/// 落盘 + 复制到剪贴板，供智能体直接读取以设计后续逻辑。
///
/// 边界：**只导出结论层**（口径、Top-N 差异、门控统计、复现参数）。
/// 全量明细仍走各模式自己的 TSV/JSON 文件，不塞进剪贴板（避免几百行刷屏）。
abstract final class AgentHandoffPackage {
  static const int currentSchema = 1;

  static String encode(Map<String, dynamic> payload) =>
      const JsonEncoder.withIndent('  ').convert(payload);

  /// 落盘到 app 支持目录下的 agent_handoff 目录，返回文件。
  static Future<File> _write(String name, Map<String, dynamic> payload) async {
    final dir = await getApplicationSupportDirectory();
    final out = Directory('${dir.path}${Platform.pathSeparator}agent_handoff');
    if (!out.existsSync()) out.createSync(recursive: true);
    final f = File('${out.path}${Platform.pathSeparator}$name');
    await f.writeAsString(encode(payload), flush: true);
    return f;
  }

  /// 弹窗提示语。
  static String handoffHint(String filePath) =>
      '交接包已生成并复制到剪贴板，请粘贴给智能体。'
      '\n文件：$filePath';

  /// 计优 → 交接包。
  static Future<File> buildKeyPointStats(KeyPointStatResult r, {int topN = 20}) async {
    final payload = keyPointStatsPayload(r, topN: topN);
    return _write('jiyou_handoff_${r.code}_${r.period}.json', payload);
  }

  static Map<String, dynamic> keyPointStatsPayload(KeyPointStatResult r, {int topN = 20}) {
    return {
      'v': currentSchema,
      'kind': 'jiyou',
      'purpose': '计优结论交接包：供智能体设计后续统计筛判逻辑。',
      'scope': {
        'code': r.code,
        'period': r.period,
        'begin': r.beginText,
        'end': r.endText,
        'bars': r.barCount,
        'maxKn': r.maxKn,
        'finishedAt': r.finishedAt.toIso8601String(),
        'elapsedMs': r.elapsedMs,
      },
      'keyPoints': {
        'count': r.collect.keyPoints.length,
        'skippedNoPole': r.collect.skippedNoPole,
        'skippedUnconfirmed': r.collect.skippedUnconfirmed,
      },
      'groups': r.groups
          .map((g) => {
            'key': g.groupKey,
            'label': g.groupLabel,
            'points': g.pointCount,
            'numeric': g.numericCount,
            'categorical': g.categoricalCount,
          })
          .toList(),
      'topContrast': r.contrasts.take(topN).map((c) => c.toJson()).toList(),
      'replay': {
        'splitTopBottom': r.settings.splitTopBottom,
        'modeDigits': r.settings.modeDigits,
        'minPoints': r.settings.minPoints,
        'modeMinShare': r.settings.modeMinShare,
        'headerLine': r.settings.replayLine,
        'align': r.align.toJson(),
      },
      'note': '仅结论层；全量指标明细见该次计优落盘的文件。',
    };
  }


  /// 寻优→交接包。
  static Future<File> buildIndicatorSearch(IndicatorSearchLastResult r, {int topN = 20}) async {
    final payload = indicatorSearchPayload(r, topN: topN);
    return _write('xunyou_handoff_${r.code}_${r.period}.json', payload);
  }

  static Map<String, dynamic> indicatorSearchPayload(IndicatorSearchLastResult r, {int topN = 20}) {
    return {
      'v': currentSchema,
      'kind': 'xunyou',
      'scope': {
        'code': r.code,
        'period': r.period,
        'begin': r.beginText,
        'end': r.endText,
        'bars': r.barCount,
        'splitX': r.splitX,
        'maxKn': r.maxKn,
        'finishedAt': r.finishedAt.toIso8601String(),
      },
      'pipeline': {
        'compiled': r.compiled,
        'ran': r.ran,
        'passed': r.passed,
        'elapsedSeconds': r.elapsedSeconds,
      },
      'options': {
        'maxCandidates': r.maxCandidates,
        'skipOosEarly': r.skipOosEarly,
        'useOptimizedBuild': r.useOptimizedBuild,
      },
      'top': r.verdicts.take(topN).map((v) => v.toJson()).toList(),
      'resultsFilePath': r.resultsFilePath,
    };
  }
}
