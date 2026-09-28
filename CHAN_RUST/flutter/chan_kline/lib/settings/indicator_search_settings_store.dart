import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../indicator_search/candidate_builder.dart';

/// 设置 · 寻优：枚举模式、候选上限、样本外早停等。
class IndicatorSearchSettings {
  final bool useOptimizedBuild;
  final int maxCandidates;
  final bool skipOosEarly;

  const IndicatorSearchSettings({
    this.useOptimizedBuild = true,
    this.maxCandidates = 12000,
    this.skipOosEarly = true,
  });

  CandidateBuildOptions toBuildOptions() => useOptimizedBuild
      ? CandidateBuildOptions.optimized(maxCandidates: maxCandidates)
      : const CandidateBuildOptions.legacyFull();

  IndicatorSearchSettings copyWith({
    bool? useOptimizedBuild,
    int? maxCandidates,
    bool? skipOosEarly,
  }) =>
      IndicatorSearchSettings(
        useOptimizedBuild: useOptimizedBuild ?? this.useOptimizedBuild,
        maxCandidates: maxCandidates ?? this.maxCandidates,
        skipOosEarly: skipOosEarly ?? this.skipOosEarly,
      );

  Map<String, dynamic> toJson() => {
        'useOptimizedBuild': useOptimizedBuild,
        'maxCandidates': maxCandidates,
        'skipOosEarly': skipOosEarly,
      };

  static IndicatorSearchSettings fromJson(Map<String, dynamic>? map) {
    if (map == null) return const IndicatorSearchSettings();
    return IndicatorSearchSettings(
      useOptimizedBuild: map['useOptimizedBuild'] != false,
      maxCandidates: (map['maxCandidates'] as num?)?.toInt() ?? 12000,
      skipOosEarly: map['skipOosEarly'] != false,
    );
  }
}

abstract final class IndicatorSearchSettingsStore {
  static const _fileName = '.chan_indicator_search_settings.json';
  static IndicatorSearchSettings _cached = const IndicatorSearchSettings();

  static IndicatorSearchSettings get current => _cached;

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final obj = jsonDecode(await f.readAsString());
      if (obj is Map<String, dynamic>) {
        _cached = IndicatorSearchSettings.fromJson(obj);
      } else if (obj is Map) {
        _cached = IndicatorSearchSettings.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {}
  }

  static Future<void> save(IndicatorSearchSettings cfg) async {
    _cached = cfg;
    try {
      final f = await _file();
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {}
  }

  static Future<File> logFile() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}indicator_search_progress.log');
  }

  static Future<File> resultsFile() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}indicator_search_results.tsv');
  }

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}$_fileName');
  }
}
