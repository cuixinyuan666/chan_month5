import 'dart:convert';
import 'dart:io';

import '../bridge/chan_bridge.dart';
import 'ml_bsp_export.dart';
import 'ml_bsp_sample.dart';
import 'ml_dataset_split.dart';
import 'ml_drift_report.dart';
import 'ml_experience_trainer.dart';
import 'ml_feature_flat.dart';
import 'ml_feature_schema.dart';
import 'ml_split_config.dart';

/// XGB 超参（与 Python stdin params 对齐；非 LR 网格）。
class XgbTrainParams {
  const XgbTrainParams({
    this.maxDepth = 6,
    this.numRound = 100,
    this.learningRate = 0.1,
    this.subsample = 0.8,
    this.colsampleBytree = 0.8,
    this.regAlpha = 0.0,
    this.regLambda = 1.0,
    this.minChildWeight = 3,
    this.gamma = 0.0,
    this.earlyStoppingRounds = 20,
  });

  final int maxDepth;
  final int numRound;
  final double learningRate;
  final double subsample;
  final double colsampleBytree;
  final double regAlpha;
  final double regLambda;
  final double minChildWeight;
  final double gamma;
  final int earlyStoppingRounds;

  XgbTrainParams copyWith({
    int? maxDepth,
    int? numRound,
    double? learningRate,
    double? subsample,
    double? colsampleBytree,
    double? regAlpha,
    double? regLambda,
    double? minChildWeight,
    double? gamma,
    int? earlyStoppingRounds,
  }) =>
      XgbTrainParams(
        maxDepth: maxDepth ?? this.maxDepth,
        numRound: numRound ?? this.numRound,
        learningRate: learningRate ?? this.learningRate,
        subsample: subsample ?? this.subsample,
        colsampleBytree: colsampleBytree ?? this.colsampleBytree,
        regAlpha: regAlpha ?? this.regAlpha,
        regLambda: regLambda ?? this.regLambda,
        minChildWeight: minChildWeight ?? this.minChildWeight,
        gamma: gamma ?? this.gamma,
        earlyStoppingRounds:
            earlyStoppingRounds ?? this.earlyStoppingRounds,
      );

  Map<String, dynamic> toJson() => {
        'max_depth': maxDepth,
        'num_round': numRound,
        'learning_rate': learningRate,
        'subsample': subsample,
        'colsample_bytree': colsampleBytree,
        'reg_alpha': regAlpha,
        'reg_lambda': regLambda,
        'min_child_weight': minChildWeight,
        'gamma': gamma,
        'early_stopping_rounds': earlyStoppingRounds,
      };
}

class MlXgbTrainResult {
  const MlXgbTrainResult({
    required this.ok,
    this.modelPath,
    this.sidecarPath,
    this.trainAuc,
    this.validAuc,
    this.numRounds,
    this.elapsedSec,
    this.skipped = false,
    this.error,
  });

  final bool ok;
  final String? modelPath;
  final String? sidecarPath;
  final double? trainAuc;
  final double? validAuc;
  final int? numRounds;
  final double? elapsedSec;
  final bool skipped;
  final String? error;

  factory MlXgbTrainResult.fromJson(Map<String, dynamic> m) {
    return MlXgbTrainResult(
      ok: m['ok'] == true,
      modelPath: m['model_path'] as String?,
      sidecarPath: m['sidecar_path'] as String?,
      trainAuc: (m['train_auc'] as num?)?.toDouble(),
      validAuc: (m['valid_auc'] as num?)?.toDouble(),
      numRounds: (m['num_rounds'] as num?)?.toInt(),
      elapsedSec: (m['elapsed_sec'] as num?)?.toDouble(),
      skipped: m['skipped'] == true,
      error: m['error'] as String?,
    );
  }
}

/// Flutter 侧：导出 → Python 子进程训练 → Rust FFI 打分 → 验证选阈值。
class MlXgbTrainer {
  MlXgbTrainer._();

  static String modelFileName({
    required String code,
    required String period,
    int schemaVersion = MlFeatureSchema.schemaVersion,
  }) {
    final safe = code.isEmpty ? 'unknown' : code;
    return 'model_xgb_${safe}_${period}_sv$schemaVersion.json';
  }

  /// 与 chan_ffi.dll 同目录找 EXE；开发态还扫仓库根脚本。
  static Future<String?> findExePath() async {
    final candidates = <String>[];
    final nativeRel =
        '${Directory.current.path}${Platform.pathSeparator}windows'
        '${Platform.pathSeparator}native${Platform.pathSeparator}ml_train_xgb.exe';
    candidates.add(nativeRel);
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir${Platform.pathSeparator}ml_train_xgb.exe');
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// 仓库根 ml_train_xgb.py（无 EXE 时开发回退）。
  static Future<String?> findScriptPath() async {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      final p = '${dir.path}${Platform.pathSeparator}ml_train_xgb.py';
      if (File(p).existsSync()) return p;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    // CHAN_RUST/flutter/chan_kline → 上溯到 chan.py 根
    final fromNative = File(
      '${Directory.current.path}${Platform.pathSeparator}..'
      '${Platform.pathSeparator}..${Platform.pathSeparator}..'
      '${Platform.pathSeparator}..${Platform.pathSeparator}ml_train_xgb.py',
    );
    if (fromNative.existsSync()) return fromNative.resolveSymbolicLinksSync();
    return null;
  }

  static Future<MlXgbTrainResult> train({
    required String trainPath,
    required String validPath,
    required String metaPath,
    required String outputDir,
    required String code,
    required String period,
    String? runMetaPath,
    XgbTrainParams params = const XgbTrainParams(),
    bool forceRetrain = true,
  }) async {
    final modelPath =
        '$outputDir${Platform.pathSeparator}${modelFileName(code: code, period: period)}';
    final sidecarPath = modelPath.replaceFirst(RegExp(r'\.json$'), '.meta.json');

    final payload = <String, dynamic>{
      'libsvm_path': trainPath,
      'train_path': trainPath,
      'valid_path': validPath,
      'meta_path': metaPath,
      'output_dir': outputDir,
      'model_path': modelPath,
      'sidecar_path': sidecarPath,
      'run_meta_path': ?runMetaPath,
      'schema_version': MlFeatureSchema.schemaVersion,
      'params': params.toJson(),
      'code': code,
      'period': period,
      'force_retrain': forceRetrain,
    };

    final exe = await findExePath();
    final script = exe == null ? await findScriptPath() : null;
    if (exe == null && script == null) {
      return const MlXgbTrainResult(
        ok: false,
        error:
            '未找到 ml_train_xgb.exe（windows/native）或 ml_train_xgb.py；'
            '请 pyinstaller 打包或安装 xgboost 后用脚本',
      );
    }

    try {
      final result = await _runTrainProcess(
        exePath: exe,
        scriptPath: script,
        stdinJson: jsonEncode(payload),
      );
      if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
        return MlXgbTrainResult(
          ok: false,
          error:
              '训练进程退出码 ${result.exitCode}: ${result.stderr}'.trim(),
        );
      }
      final line = _lastJsonLine(result.stdout);
      if (line == null) {
        return MlXgbTrainResult(
          ok: false,
          error:
              'stdout 无 JSON。stderr=${result.stderr}\nstdout=${result.stdout}',
        );
      }
      final map = jsonDecode(line) as Map<String, dynamic>;
      final parsed = MlXgbTrainResult.fromJson(map);
      if (!parsed.ok) {
        return MlXgbTrainResult(
          ok: false,
          error: parsed.error ?? '训练失败',
        );
      }
      return parsed;
    } catch (e) {
      return MlXgbTrainResult(ok: false, error: '$e');
    }
  }

  /// 按 sidecar/meta 组 dense，走 Rust FFI 打分；验证集选阈值；测试只评一次。
  static Future<MlRunReport> scoreTuneAndTest({
    required List<MlBspSample> samples,
    required String modelPath,
    required String metaPath,
    MlXgbTrainResult? trainResult,
  }) async {
    final metaRaw = jsonDecode(await File(metaPath).readAsString());
    if (metaRaw is! Map) {
      throw StateError('feature.meta 非对象');
    }
    final meta = <String, int>{
      for (final e in metaRaw.entries)
        e.key.toString(): (e.value as num).toInt(),
    };

    // sidecar 特征名校验（防漂移）
    final sidecarPath =
        modelPath.replaceFirst(RegExp(r'\.json$'), '.meta.json');
    if (File(sidecarPath).existsSync()) {
      final side =
          jsonDecode(await File(sidecarPath).readAsString()) as Map;
      final names = (side['feature_names'] as List?)
          ?.map((e) => '$e')
          .toList();
      if (names != null) {
        final ordered = List<String?>.filled(meta.length, null);
        meta.forEach((k, i) {
          if (i >= 0 && i < ordered.length) ordered[i] = k;
        });
        final cur = ordered.map((e) => e ?? '').toList();
        if (cur.length != names.length) {
          throw StateError(
            '特征维不一致：sidecar=${names.length} meta=${cur.length}',
          );
        }
        for (var i = 0; i < names.length; i++) {
          if (cur[i] != names[i]) {
            throw StateError(
              '特征名漂移 idx=$i sidecar=${names[i]} meta=${cur[i]}',
            );
          }
        }
      }
      if (side['index_base'] != null && side['index_base'] != 0) {
        throw StateError('sidecar index_base 必须为 0');
      }
    }

    final bridge = ChanBridge.instance;
    for (final s in samples) {
      final dense = MlFeatureFlat.denseFromMeta(meta, s.features);
      s.predictScore = bridge.mlPredict(modelPath: modelPath, dense: dense);
    }

    final train = MlDatasetSplit.trainOf(samples);
    final valid = MlDatasetSplit.validOf(samples);
    final test = MlDatasetSplit.testOf(samples);
    final thr = MlExperienceTrainer.tuneThresholdOnValid(valid);
    final trainWin = train.where((e) => e.isCorrect == true).length;

    final xgb = MlXgbExtras(
      modelPath: modelPath,
      sidecarPath: sidecarPath,
      trainAuc: trainResult?.trainAuc,
      validAuc: trainResult?.validAuc,
      numRounds: trainResult?.numRounds ?? 0,
      elapsedSec: trainResult?.elapsedSec ?? 0,
      skipped: trainResult?.skipped ?? false,
    );

    return MlRunReport(
      trainTotal: train.length,
      trainWinRate: train.isEmpty ? 0.0 : trainWin / train.length,
      validStats:
          MlExperienceTrainer.statsOfScored(valid, threshold: thr),
      testStats: MlExperienceTrainer.statsOfScored(test, threshold: thr),
      bestEpochs: 0,
      bestLr: 0,
      bestL2: 0,
      bestThreshold: thr,
      tuneTrials: MlExperienceTrainer.thrGrid.length,
      drift: MlDriftReport.build(samples),
      trainerKind: 'xgb',
      xgb: xgb,
    );
  }

  /// 导出 + 训练 + 打分（一站式，供「加载」XGB 模式）。
  static Future<MlRunReport> exportTrainAndEvaluate({
    required List<MlBspSample> samples,
    required String dataRoot,
    required String code,
    required String period,
    required int stepIdx,
    MlSplitConfig splitConfig = const MlSplitConfig(),
    XgbTrainParams params = const XgbTrainParams(),
    bool forceRetrain = true,
    String? beginDate,
    String? endDate,
  }) async {
    MlDatasetSplit.apply(samples, splitConfig);
    final exported = await MlBspExport.write(
      samples: samples,
      dataRoot: dataRoot,
      code: code,
      period: period,
      stepIdx: stepIdx,
      beginDate: beginDate,
      endDate: endDate,
      splitConfig: splitConfig,
    );

    final trainRes = await train(
      trainPath: exported.trainPath,
      validPath: exported.validPath,
      metaPath: exported.metaPath,
      outputDir: File(exported.metaPath).parent.path,
      code: code,
      period: period,
      runMetaPath: exported.runMetaPath,
      params: params,
      forceRetrain: forceRetrain,
    );
    if (!trainRes.ok || trainRes.modelPath == null) {
      throw StateError(trainRes.error ?? 'XGB 训练失败');
    }

    return scoreTuneAndTest(
      samples: samples,
      modelPath: trainRes.modelPath!,
      metaPath: exported.metaPath,
      trainResult: trainRes,
    );
  }

  static Future<({int exitCode, String stdout, String stderr})>
      _runTrainProcess({
    required String? exePath,
    required String? scriptPath,
    required String stdinJson,
  }) async {
    late final Process process;
    if (exePath != null) {
      process = await Process.start(exePath, const []);
    } else {
      process = await Process.start(
        Platform.isWindows ? 'python' : 'python3',
        [scriptPath!],
      );
    }
    process.stdin.write(stdinJson);
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return (exitCode: code, stdout: out, stderr: err);
  }

  static String? _lastJsonLine(String stdout) {
    final lines = stdout
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.startsWith('{') && e.endsWith('}'))
        .toList();
    if (lines.isEmpty) return null;
    return lines.last;
  }
}
