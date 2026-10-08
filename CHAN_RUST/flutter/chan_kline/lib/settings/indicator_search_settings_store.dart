import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../indicator_search/candidate_builder.dart';

/// 设置 · 寻优：枚举模式、候选上限。
class IndicatorSearchSettings {
  final bool useOptimizedBuild;
  final int maxCandidates;

  const IndicatorSearchSettings({
    this.useOptimizedBuild = true,
    this.maxCandidates = 12000,
  });

  CandidateBuildOptions toBuildOptions() => useOptimizedBuild
      ? CandidateBuildOptions.optimized(maxCandidates: maxCandidates)
      : const CandidateBuildOptions.legacyFull();

  IndicatorSearchSettings copyWith({
    bool? useOptimizedBuild,
    int? maxCandidates,
  }) =>
      IndicatorSearchSettings(
        useOptimizedBuild: useOptimizedBuild ?? this.useOptimizedBuild,
        maxCandidates: maxCandidates ?? this.maxCandidates,
      );

  Map<String, dynamic> toJson() => {
        'useOptimizedBuild': useOptimizedBuild,
        'maxCandidates': maxCandidates,
      };

  static IndicatorSearchSettings fromJson(Map<String, dynamic>? map) {
    if (map == null) return const IndicatorSearchSettings();
    return IndicatorSearchSettings(
      useOptimizedBuild: _readBool(map['useOptimizedBuild'], defaultValue: true),
      maxCandidates: _readMaxCandidates(map['maxCandidates']),
    );
  }

  static int _readMaxCandidates(dynamic raw) {
    if (raw == null) return 12000;
    final v = (raw as num).toInt();
    if (v <= 0) return 12000;
    return v.clamp(2000, 50000);
  }

  static bool _readBool(dynamic raw, {required bool defaultValue}) {
    if (raw == null) return defaultValue;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final s = raw.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return defaultValue;
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
