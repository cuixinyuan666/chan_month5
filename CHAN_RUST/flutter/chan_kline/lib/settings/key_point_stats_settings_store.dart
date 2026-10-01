import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 设置 · 计优：分组方式、数值众数桶宽、分组样本下限。
class KeyPointStatSettings {
  /// 是否按「级别 × 顶/底」分组（关闭=每级只出一张合并表，顶底不分）。
  final bool splitTopBottom;

  /// 数值型众数的分桶精度（小数位）；0=整数桶。面板会标注这是近似众数。
  final int modeDigits;

  /// 分组转折点数低于此值就不出表（避免 1~2 个样本的「统计」误导）。
  final int minPoints;

  const KeyPointStatSettings({
    this.splitTopBottom = true,
    this.modeDigits = 4,
    this.minPoints = 1,
  });

  KeyPointStatSettings copyWith({
    bool? splitTopBottom,
    int? modeDigits,
    int? minPoints,
  }) =>
      KeyPointStatSettings(
        splitTopBottom: splitTopBottom ?? this.splitTopBottom,
        modeDigits: modeDigits ?? this.modeDigits,
        minPoints: minPoints ?? this.minPoints,
      );

  /// 面板顶部口径行（写清桶宽与分组，免得把近似众数当精确值读）。
  String get replayLine =>
      '分组=${splitTopBottom ? "级别×顶/底" : "级别（顶底合并）"} · '
      '数值众数桶宽=$_bucketLabel · 分组样本下限=$minPoints';

  String get _bucketLabel =>
      modeDigits <= 0 ? '整数' : '10^-$modeDigits';

  Map<String, dynamic> toJson() => {
        'splitTopBottom': splitTopBottom,
        'modeDigits': modeDigits,
        'minPoints': minPoints,
      };

  static KeyPointStatSettings fromJson(Map<String, dynamic>? map) {
    if (map == null) return const KeyPointStatSettings();
    return KeyPointStatSettings(
      splitTopBottom: map['splitTopBottom'] != false,
      modeDigits: ((map['modeDigits'] as num?)?.toInt() ?? 4).clamp(0, 8),
      minPoints: ((map['minPoints'] as num?)?.toInt() ?? 1).clamp(1, 10000),
    );
  }
}

abstract final class KeyPointStatSettingsStore {
  static const _fileName = '.chan_key_point_stat_settings.json';
  static KeyPointStatSettings _cached = const KeyPointStatSettings();

  static KeyPointStatSettings get current => _cached;

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final obj = jsonDecode(await f.readAsString());
      if (obj is Map) {
        _cached = KeyPointStatSettings.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {}
  }

  static Future<void> save(KeyPointStatSettings cfg) async {
    _cached = cfg;
    try {
      final f = await _file();
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {}
  }

  static Future<File> resultsFile({String code = '', String period = ''}) async {
    final base = await getApplicationSupportDirectory();
    final tag = [
      if (code.isNotEmpty) code,
      if (period.isNotEmpty) period,
    ].join('_');
    final name = tag.isEmpty
        ? 'key_point_stats.json'
        : 'key_point_stats_$tag.json';
    return File('${base.path}${Platform.pathSeparator}$name');
  }

  static Future<File> resultsTsvFile({
    String code = '',
    String period = '',
  }) async {
    final base = await getApplicationSupportDirectory();
    final tag = [
      if (code.isNotEmpty) code,
      if (period.isNotEmpty) period,
    ].join('_');
    final name = tag.isEmpty
        ? 'key_point_stats.tsv'
        : 'key_point_stats_$tag.tsv';
    return File('${base.path}${Platform.pathSeparator}$name');
  }

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}$_fileName');
  }
}