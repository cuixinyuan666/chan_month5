import '../ml/ml_feature_label.dart';
import '../ml/ml_feature_schema.dart';
import '../models/bar_feature_lookup.dart';
import '../settings/key_point_stats_settings_store.dart';

import 'key_point.dart';
import 'key_point_collect.dart';
import 'key_point_contrast.dart';
import 'key_point_stat_align.dart';
import 'stat_metrics.dart';

/// 一张统计表 = 一个分组（级别 ×顶/底，或某级顶底合并，或全部汇总）。
class KeyPointStatGroup {
  final String groupKey;

  /// 'K1 顶' / 'K1（顶底合并）' / '全部转折点'
  final String groupLabel;

  /// 该组的转折点数。
  final int pointCount;

  final List<StatSummary> stats;

  const KeyPointStatGroup({
    required this.groupKey,
    required this.groupLabel,
    required this.pointCount,
    required this.stats,
  });

  int get numericCount => stats.where((e) => e.kind == StatValueKind.numeric).length;

  int get categoricalCount =>
      stats.where((e) => e.kind == StatValueKind.categorical).length;

  Map<String, dynamic> toJson() => {
        'group': groupKey,
        'label': groupLabel,
        'points': pointCount,
        'stats': stats.map((e) => e.toJson()).toList(),
      };
}

/// 计优一次完整结果（供面板、落盘、机器人验证共用）。
class KeyPointStatResult {
  final DateTime finishedAt;
  final String code;
  final String period;
  final String beginText;
  final String endText;
  final int barCount;
  final int maxKn;
  final KeyPointStatSettings settings;

  /// 复现参数（点位口径 + 指标参数两层）。
  final KeyPointStatAlign align;

  final KeyPointCollectResult collect;
  final List<KeyPoint> keyPoints;
  final List<KeyPointStatGroup> groups;

  /// 全部顶底差异度，按差异度降序（跨级别混排：差异越大的越靠前）。
  final List<KeyPointContrast> contrasts;

  final int elapsedMs;

  const KeyPointStatResult({
    required this.finishedAt,
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.barCount,
    required this.maxKn,
    required this.settings,
    required this.align,
    required this.collect,
    required this.keyPoints,
    required this.groups,
    required this.contrasts,
    required this.elapsedMs,
  });

  /// 取某级别的顶底差异清单（降序）。
  List<KeyPointContrast> contrastsForLevel(int level) {
    final out = <KeyPointContrast>[];
    for (final c in contrasts) {
      if (c.level == level) out.add(c);
    }
    return out;
  }

  /// 该分组所属级别（汇总组 ALL 返回 -1）。
  int levelOfGroup(String groupKey) {
    if (groupKey == 'ALL' || !groupKey.startsWith('L')) return -1;
    final us = groupKey.indexOf('_');
    if (us <= 1) return -1;
    return int.tryParse(groupKey.substring(1, us)) ?? -1;
  }

  int get metricCount =>
      groups.isEmpty ? 0 : groups.first.stats.length;

  Duration get elapsed => Duration(milliseconds: elapsedMs);

  /// 面板顶部口径行：**复现参数两行** + 统计口径 + 事后统计声明。
  ///
  /// 前两行是复现参数（点位口径 / 指标参数），缺了就无法解释这张表 ——
  /// 截断开关会改转折点位置，布林 N 会改每格的值；
  /// 后两行是统计口径与「事后统计」声明，防止把数值众数当精确值、把转折点当事前可知。
  String get headerLine =>
      '${align.headerLines}\n'
      '统计口径：关键点位=各级别连线转折点（顶/底）；取值=转折极点 K 那一根的指标冻结值'
      '（主图逐K冻结账，与十字线/ML同源）；${settings.replayLine}。\n'
      '这是事后统计（AGENTS.md「当下性」例外）：转折点是回头认定的，'
      '但读到的每个值仍只用该 K 及之前的数据。数值众数为分桶近似，类别众数才是精确值。';

  Map<String, dynamic> toJson() => {
        'type': 'key_point_stat_report',
        'finished_at': finishedAt.toIso8601String(),
        'code': code,
        'period': period,
        'begin': beginText,
        'end': endText,
        'bar_count': barCount,
        'max_kn': maxKn,
        'elapsed_ms': elapsedMs,
        'settings': settings.toJson(),
        'align': align.toJson(),
        'collect': collect.toJson(),
        'key_points': keyPoints.map((e) => e.toJson()).toList(),
        'groups': groups.map((e) => e.toJson()).toList(),
        'contrasts': [for (final c in contrasts) c.toJson()],
      };
}

/// 顶层键黑名单：定位/时间类没有统计意义；结构对象与筹码分箱粒度过细。
const Set<String> kKeyPointStatTopLevelSkip = {
  'idx',
  'time_ms',
  'time_text',
  'weekday',
  'levels',
  'level_confirms',
  'k0_confirm',
  'k0_line',
  'k1_snapshot',
  'k1_confirm_signal',
  'combine',
  'metrics',
};

/// 计优编排：冻结账 + 关键点位 → 统计表。
///
/// **只读** [BarFeatureLookup]，不写冻结仓、不回写任何指标、不改主图语义。
class KeyPointStatRunner {
  const KeyPointStatRunner._();

  static KeyPointStatResult run({
    required BarFeatureLookup lookup,
    required KeyPointCollectResult collect,
    required KeyPointStatSettings settings,
    String code = '',
    String period = '',
    String beginText = '',
    String endText = '',
    int barCount = 0,
    int maxKn = 0,
    KeyPointStatAlign? align,
  }) {
    final started = DateTime.now();
    final points = collect.keyPoints;
    final alignSnapshot = align ??
        KeyPointStatAlign(
          code: code,
          period: period,
          beginText: beginText,
          endText: endText,
          barCount: barCount > 0 ? barCount : points.length,
          asOf: points.isEmpty ? -1 : points.last.poleX,
          maxKn: maxKn,
        );

    // 分组：级别×顶/底（可关），外加「全部转折点」汇总。
    final groups = <KeyPointStatGroup>[];
    final levels = <int>{for (final p in points) p.level}.toList()..sort();

    for (final lv in levels) {
      final inLevel = points.where((p) => p.level == lv).toList();
      if (settings.splitTopBottom) {
        for (final fx in const ['TOP', 'BOTTOM']) {
          final side = inLevel.where((p) => p.fx == fx).toList();
          if (side.length < settings.minPoints) continue;
          groups.add(_buildGroup(
            lookup: lookup,
            groupKey: 'L${lv}_$fx',
            groupLabel: 'K$lv ${fx == 'TOP' ? '顶' : '底'}',
            points: side,
            settings: settings,
          ));
        }
      } else {
        if (inLevel.length < settings.minPoints) continue;
        groups.add(_buildGroup(
          lookup: lookup,
          groupKey: 'L${lv}_ALL',
          groupLabel: 'K$lv（顶底合并）',
          points: inLevel,
          settings: settings,
        ));
      }
    }

    if (points.length >= settings.minPoints) {
      groups.add(_buildGroup(
        lookup: lookup,
        groupKey: 'ALL',
        groupLabel: '全部转折点',
        points: points,
        settings: settings,
      ));
    }

    // 顶底差异度：逐级配对「顶组」与「底组」，只算两侧都达样本下限的指标。
    // 这是计优相对寻优唯一不可替代的价值 —— 把顶/底的差别放到第一屏。
    final contrasts = <KeyPointContrast>[];
    if (settings.splitTopBottom) {
      for (final lv in levels) {
        final top = groups.where((g) => g.groupKey == 'L${lv}_TOP').toList();
        final bottom =
            groups.where((g) => g.groupKey == 'L${lv}_BOTTOM').toList();
        if (top.isEmpty || bottom.isEmpty) continue;
        contrasts.addAll(computeContrasts(
          topStats: top.first.stats,
          bottomStats: bottom.first.stats,
          level: lv,
          minPoints: settings.minPoints,
        ));
      }
      contrasts.sort((a, b) {
        final c = b.contrast.compareTo(a.contrast);
        if (c != 0) return c;
        final l = a.labelCn.compareTo(b.labelCn);
        if (l != 0) return l;
        return a.metricKey.compareTo(b.metricKey);
      });
    }

    return KeyPointStatResult(
      finishedAt: DateTime.now(),
      code: code,
      period: period,
      beginText: beginText,
      endText: endText,
      barCount: barCount > 0 ? barCount : points.length,
      maxKn: maxKn,
      settings: settings,
      align: alignSnapshot,
      collect: collect,
      keyPoints: points,
      groups: groups,
      contrasts: contrasts,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
    );
  }
static KeyPointStatGroup _buildGroup({
    required BarFeatureLookup lookup,
    required String groupKey,
    required String groupLabel,
    required List<KeyPoint> points,
    required KeyPointStatSettings settings,
  }) {
    final nums = <String, List<double>>{};
    final cats = <String, List<String>>{};

    for (final p in points) {
      final row = lookup.byIdx[p.poleX];
      if (row == null) continue;
      _walk(row, '', nums: nums, cats: cats);
    }

    final labels = <String, String>{};
    final keys = <String>{...nums.keys, ...cats.keys}.toList()
      ..sort((a, b) {
        final la = labels[a] ??= KeyPointStatRunner.labelOf(a);
        final lb = labels[b] ??= KeyPointStatRunner.labelOf(b);
        final c = la.compareTo(lb);
        if (c != 0) return c;
        return a.compareTo(b);
      });

    final stats = <StatSummary>[];
    for (final key in keys) {
      final label = labels[key] ?? KeyPointStatRunner.labelOf(key);
      final numValues = nums[key];
      if (numValues != null && numValues.isNotEmpty) {
        stats.add(numericStat(
          metricKey: key,
          labelCn: label,
          rawValues: numValues,
          totalCount: points.length,
          modeDigits: settings.modeDigits,
        ));
        continue;
      }
      final catValues = cats[key];
      if (catValues != null && catValues.isNotEmpty) {
        stats.add(categoricalStat(
          metricKey: key,
          labelCn: label,
          values: catValues,
          totalCount: points.length,
        ));
      }
    }

    return KeyPointStatGroup(
      groupKey: groupKey,
      groupLabel: groupLabel,
      pointCount: points.length,
      stats: stats,
    );
  }

  /// 递归摊平一行冻结账：数值入 [nums]，字符串/布尔入 [cats]。
  ///
  /// 口径与 ML 一致：动态 tip 名与字符串汇总键（[MlFeatureSchema.isForbiddenKey]）不进统计，
  /// 免得每根 K 的「K0筹码峰-1」这类动态键把统计表撑爆。
  static void _walk(
    dynamic node,
    String prefix, {
    required Map<String, List<double>> nums,
    required Map<String, List<String>> cats,
  }) {
    if (node == null) return;

    if (node is bool) {
      if (prefix.isEmpty) return;
      (cats[prefix] ??= []).add(statBoolLabel(node));
      return;
    }
    if (node is num) {
      if (prefix.isEmpty) return;
      (nums[prefix] ??= []).add(node.toDouble());
      return;
    }
    if (node is String) {
      if (prefix.isEmpty) return;
      if (MlFeatureSchema.isForbiddenKey(prefix)) return;
      (cats[prefix] ??= []).add(node);
      return;
    }
    if (node is Map) {
      // 顶层走黑名单（定位/结构对象/筹码分箱）；其余层只按 ML 禁止键过滤。
      final topLevel = prefix.isEmpty;
      node.forEach((k, v) {
        final key = '$k';
        if (topLevel && kKeyPointStatTopLevelSkip.contains(key)) return;
        if (MlFeatureSchema.isForbiddenKey(key)) return;
        _walk(v, topLevel ? key : '$prefix.$key', nums: nums, cats: cats);
      });
      return;
    }
    if (node is Iterable) {
      var i = 0;
      for (final e in node) {
        _walk(e, '$prefix[$i]', nums: nums, cats: cats);
        i++;
        if (i >= 32) break; // 与 MlFeatureFlat 同口径：防列表爆炸
      }
    }
    // 其它自定义结构对象（LevelSnap / LevelConfirm 等）：其数值已在 sub/顶层镜像，不重复统计。
  }

  /// 供面板排序用：指标中文名。
  static String labelOf(String metricKey) => MlFeatureLabel.toChinese(metricKey);
}