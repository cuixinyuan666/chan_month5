import 'dart:convert';

import 'task_demo_walkthrough_step.dart';

/// test/demos 下单条任务演示元数据（manifest.json）
class TaskDemoManifest {
  const TaskDemoManifest({
    required this.id,
    required this.title,
    required this.completedAt,
    required this.agent,
    required this.isNewFeature,
    required this.beforeSummary,
    required this.afterSummary,
    required this.verificationPoints,
    required this.keySteps,
    required this.demoCsv,
    required this.walkthroughSteps,
    this.autoLaunchOnStartup = true,
    this.defaultStockCode,
    this.defaultStockPeriod,
    this.defaultStockNote,
    required this.demoDirPath,
  });

  final String id;
  final String title;
  final String completedAt;
  final String agent;
  final bool isNewFeature;
  final String beforeSummary;
  final String afterSummary;
  final List<String> verificationPoints;
  final List<int> keySteps;
  /// 相对 demo 目录的 CSV 文件名；空=不覆盖 custom.ohlc.csv
  final String demoCsv;
  final List<TaskDemoWalkthroughStep> walkthroughSteps;
  /// false=启动时不自动加载本条目（仍可在列表选手动打开）
  final bool autoLaunchOnStartup;
  final String? defaultStockCode;
  final String? defaultStockPeriod;
  final String? defaultStockNote;
  final String demoDirPath;

  factory TaskDemoManifest.fromJson(
    Map<String, dynamic> json, {
    required String demoDirPath,
  }) {
    final ds = json['defaultStock'];
    Map<String, dynamic>? dsMap;
    if (ds is Map<String, dynamic>) {
      dsMap = ds;
    } else if (ds is Map) {
      dsMap = Map<String, dynamic>.from(ds);
    }
    final rawSteps = json['keySteps'];
    final steps = <int>[];
    if (rawSteps is List) {
      for (final e in rawSteps) {
        if (e is int) {
          steps.add(e);
        } else if (e is num) {
          steps.add(e.toInt());
        }
      }
    }
    final rawVp = json['verificationPoints'];
    final vp = <String>[];
    if (rawVp is List) {
      for (final e in rawVp) {
        vp.add(e.toString());
      }
    }
    final rawWt = json['walkthroughSteps'];
    final wt = <TaskDemoWalkthroughStep>[];
    if (rawWt is List) {
      for (final e in rawWt) {
        if (e is Map<String, dynamic>) {
          wt.add(TaskDemoWalkthroughStep.fromJson(e));
        } else if (e is Map) {
          wt.add(TaskDemoWalkthroughStep.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return TaskDemoManifest(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? json['id']?.toString() ?? '',
      completedAt: json['completedAt']?.toString() ?? '',
      agent: json['agent']?.toString() ?? '',
      isNewFeature: json['isNewFeature'] == true,
      beforeSummary: json['beforeSummary']?.toString() ?? '',
      afterSummary: json['afterSummary']?.toString() ?? '',
      verificationPoints: vp,
      keySteps: steps,
      demoCsv: json['demoCsv']?.toString() ?? '',
      walkthroughSteps: wt,
      autoLaunchOnStartup: json['autoLaunchOnStartup'] as bool? ?? true,
      defaultStockCode: dsMap?['code']?.toString(),
      defaultStockPeriod: dsMap?['period']?.toString(),
      defaultStockNote: dsMap?['note']?.toString(),
      demoDirPath: demoDirPath,
    );
  }

  /// manifest 未写 walkthroughSteps 时，由 keySteps + verificationPoints 生成默认可点下一步序列
  List<TaskDemoWalkthroughStep> resolvedWalkthroughSteps() {
    if (walkthroughSteps.isNotEmpty) return walkthroughSteps;
    final out = <TaskDemoWalkthroughStep>[
      TaskDemoWalkthroughStep(
        stepIdx: 0,
        phase: TaskDemoWalkPhase.both,
        caption: '任务：$title（${completedAt} · $agent）',
      ),
    ];
    if (!isNewFeature && beforeSummary.isNotEmpty) {
      out.add(
        TaskDemoWalkthroughStep(
          stepIdx: 0,
          phase: TaskDemoWalkPhase.before,
          caption: '改之前：$beforeSummary',
        ),
      );
    }
    if (afterSummary.isNotEmpty) {
      out.add(
        TaskDemoWalkthroughStep(
          stepIdx: 0,
          phase: TaskDemoWalkPhase.after,
          caption: '改之后：$afterSummary',
        ),
      );
    }
    final n = verificationPoints.isNotEmpty
        ? verificationPoints.length
        : keySteps.length;
    for (var i = 0; i < n; i++) {
      final idx = i < keySteps.length ? keySteps[i] : 0;
      final cap = i < verificationPoints.length
          ? verificationPoints[i]
          : '第 ${i + 1} 个验证点';
      if (!isNewFeature) {
        out.add(
          TaskDemoWalkthroughStep(
            stepIdx: idx,
            phase: TaskDemoWalkPhase.before,
            caption: '改之前（大约第 $idx 根 K）：对照左边「原本」说明',
          ),
        );
      }
      out.add(
        TaskDemoWalkthroughStep(
          stepIdx: idx,
          phase: TaskDemoWalkPhase.after,
          caption: cap,
        ),
      );
    }
    return out;
  }

  static TaskDemoManifest? tryParseFile(String demoDirPath, String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) return null;
      final m = TaskDemoManifest.fromJson(decoded, demoDirPath: demoDirPath);
      if (m.id.isEmpty) return null;
      return m;
    } catch (_) {
      return null;
    }
  }
}
