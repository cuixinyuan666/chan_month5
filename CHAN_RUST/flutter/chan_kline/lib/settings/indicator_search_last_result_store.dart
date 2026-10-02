import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../indicator_search/indicator_search_runner.dart';
import '../indicator_search/search_core.dart';
import '../indicator_search/search_env.dart';

/// 最近一次寻优快照（供设置里「上次寻优结果」查看，不依赖 TSV 解析）。
class IndicatorSearchLastResult {
  final DateTime finishedAt;
  final String code;
  final String period;
  final String beginText;
  final String endText;
  final int barCount;
  final int splitX;
  final int compiled;
  final int ran;
  final int passed;
  final int elapsedSeconds;
  final String resultsFilePath;
  final List<ComboVerdict> verdicts;
  final int maxKn;
  final bool skipOosEarly;
  final bool useOptimizedBuild;
  final int maxCandidates;
  final IndicatorSearchAlignSnapshot? align;

  const IndicatorSearchLastResult({
    required this.finishedAt,
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.barCount,
    required this.splitX,
    required this.compiled,
    required this.ran,
    required this.passed,
    required this.elapsedSeconds,
    required this.resultsFilePath,
    required this.verdicts,
    this.maxKn = 16,
    this.skipOosEarly = true,
    this.useOptimizedBuild = true,
    this.maxCandidates = 12000,
    this.align,
  });

  Duration get elapsed => Duration(seconds: elapsedSeconds);

  Map<String, dynamic> toJson() => {
        'finishedAt': finishedAt.toIso8601String(),
        'code': code,
        'period': period,
        'beginText': beginText,
        'endText': endText,
        'barCount': barCount,
        'splitX': splitX,
        'compiled': compiled,
        'ran': ran,
        'passed': passed,
        'elapsedSeconds': elapsedSeconds,
        'resultsFilePath': resultsFilePath,
        'maxKn': maxKn,
        'skipOosEarly': skipOosEarly,
        'useOptimizedBuild': useOptimizedBuild,
        'maxCandidates': maxCandidates,
        if (align != null) 'align': align!.toJson(),
        'verdicts': verdicts.map((e) => e.toJson()).toList(),
      };

  static IndicatorSearchLastResult? fromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    final list = m['verdicts'];
    final verdicts = <ComboVerdict>[];
    if (list is List) {
      for (final e in list) {
        if (e is Map) {
          verdicts.add(ComboVerdict.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    final finished = m['finishedAt'] as String?;
    return IndicatorSearchLastResult(
      finishedAt: finished != null
          ? DateTime.tryParse(finished) ?? DateTime.now()
          : DateTime.now(),
      code: m['code'] as String? ?? '',
      period: m['period'] as String? ?? '',
      beginText: m['beginText'] as String? ?? '',
      endText: m['endText'] as String? ?? '',
      barCount: (m['barCount'] as num?)?.toInt() ?? 0,
      splitX: (m['splitX'] as num?)?.toInt() ?? 0,
      compiled: (m['compiled'] as num?)?.toInt() ?? 0,
      ran: (m['ran'] as num?)?.toInt() ?? 0,
      passed: (m['passed'] as num?)?.toInt() ?? 0,
      elapsedSeconds: (m['elapsedSeconds'] as num?)?.toInt() ?? 0,
      resultsFilePath: m['resultsFilePath'] as String? ?? '',
      maxKn: (m['maxKn'] as num?)?.toInt() ?? 16,
      skipOosEarly: m.containsKey('skipOosEarly')
          ? m['skipOosEarly'] == true
          : true,
      useOptimizedBuild: m['useOptimizedBuild'] != false,
      maxCandidates: (m['maxCandidates'] as num?)?.toInt() ?? 12000,
      align: IndicatorSearchAlignSnapshot.fromJsonMap(
        m['align'] is Map
            ? Map<String, dynamic>.from(m['align'] as Map)
            : null,
      ),
      verdicts: verdicts,
    );
  }

  static IndicatorSearchLastResult fromRun({
    required DateTime finishedAt,
    required String code,
    required String period,
    required String beginText,
    required String endText,
    required int barCount,
    required IndicatorSearchRunStats stats,
    required String resultsFilePath,
    int maxKn = 16,
    bool skipOosEarly = true,
    bool useOptimizedBuild = true,
    int maxCandidates = 12000,
    IndicatorSearchAlignSnapshot? align,
  }) {
    return IndicatorSearchLastResult(
      finishedAt: finishedAt,
      code: code,
      period: period,
      beginText: beginText,
      endText: endText,
      barCount: barCount,
      splitX: stats.splitX,
      compiled: stats.compiled,
      ran: stats.ran,
      passed: stats.passed,
      elapsedSeconds: stats.elapsed.inSeconds,
      resultsFilePath: resultsFilePath,
      maxKn: maxKn,
      skipOosEarly: skipOosEarly,
      useOptimizedBuild: useOptimizedBuild,
      maxCandidates: maxCandidates,
      align: align,
      verdicts: stats.verdicts,
    );
  }
}

abstract final class IndicatorSearchLastResultStore {
  static const _fileName = 'indicator_search_last_result.json';
  static IndicatorSearchLastResult? _cached;

  static IndicatorSearchLastResult? get current => _cached;

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final obj = jsonDecode(await f.readAsString());
      if (obj is Map<String, dynamic>) {
        _cached = IndicatorSearchLastResult.fromJson(obj);
      } else if (obj is Map) {
        _cached = IndicatorSearchLastResult.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {}
  }

  static Future<void> save(IndicatorSearchLastResult result) async {
    _cached = result;
    try {
      final f = await _file();
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(result.toJson()),
      );
    } catch (e, st) {
      debugPrint('IndicatorSearchLastResultStore.save failed: $e\n$st');
    }
  }

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}$_fileName');
  }
}
