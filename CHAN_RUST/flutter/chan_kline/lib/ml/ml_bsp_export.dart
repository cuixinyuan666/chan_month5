import 'dart:convert';
import 'dart:io';

import 'ml_bsp_sample.dart';
import 'ml_dataset_split.dart';
import 'ml_feature_flat.dart';
import 'ml_feature_schema.dart';
import 'ml_split_config.dart';

/// 导出 demo5 同构：训练集 libsvm + 考试集 libsvm + meta + samples.jsonl。
class MlBspExport {
  MlBspExport._();

  static Future<MlBspExportResult> write({
    required List<MlBspSample> samples,
    required String dataRoot,
    required String code,
    required String period,
    required int stepIdx,
    String? beginDate,
    String? endDate,
    MlSplitConfig splitConfig = const MlSplitConfig(),
  }) async {
    // 导出前按配置重切，避免未打 split 或比例变更后不一致
    MlDatasetSplit.apply(samples, splitConfig);

    final dir = Directory('$dataRoot${Platform.pathSeparator}ml_exports');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final stamp =
        '${code.isEmpty ? "unknown" : code}_${period}_step$stepIdx';
    final metaPath = '${dir.path}${Platform.pathSeparator}feature.meta';
    final trainPath =
        '${dir.path}${Platform.pathSeparator}feature_train.libsvm';
    final examPath = '${dir.path}${Platform.pathSeparator}feature_exam.libsvm';
    // 兼容旧名：feature.libsvm = 训练集
    final libsvmPath = '${dir.path}${Platform.pathSeparator}feature.libsvm';
    final samplesPath =
        '${dir.path}${Platform.pathSeparator}${stamp}_samples.jsonl';
    final runMetaPath =
        '${dir.path}${Platform.pathSeparator}${stamp}_ml_run_meta.json';
    final examReportPath =
        '${dir.path}${Platform.pathSeparator}${stamp}_exam_report.json';

    final names = <String>{};
    for (final s in samples) {
      names.addAll(s.features.keys);
    }
    final sorted = names.toList()..sort();
    final meta = <String, int>{
      for (var i = 0; i < sorted.length; i++) sorted[i]: i,
    };

    String toLibsvm(List<MlBspSample> subset) {
      final buf = StringBuffer();
      for (final s in subset) {
        final pairs = <MapEntry<int, double>>[];
        s.features.forEach((name, value) {
          final idx = meta[name];
          if (idx == null) return;
          if (value == MlFeatureFlat.missing) return;
          pairs.add(MapEntry(idx, value));
        });
        pairs.sort((a, b) => a.key.compareTo(b.key));
        final body = pairs.map((e) => '${e.key}:${e.value}').join(' ');
        buf.writeln('${s.libsvmLabel} $body');
      }
      return buf.toString();
    }

    final train = MlDatasetSplit.trainOf(samples);
    final exam = MlDatasetSplit.examOf(samples);
    final trainLib = toLibsvm(train);
    final examLib = toLibsvm(exam);

    final samplesJsonl = StringBuffer();
    for (final s in samples) {
      samplesJsonl.writeln(jsonEncode(s.toJson()));
    }

    final trainM = MlDatasetSplit.metrics(train);
    final examM = MlDatasetSplit.metrics(exam);

    final runMeta = {
      'schema_version': MlFeatureSchema.schemaVersion,
      'rules_ref': 'vespa_demo5_bsp_alpha',
      'code': code,
      'period': period,
      'begin': beginDate,
      'end': endDate,
      'step_idx': stepIdx,
      'sample_count': samples.length,
      'train_count': train.length,
      'exam_count': exam.length,
      'train_ratio': splitConfig.trainRatio,
      'train_alpha_acc': trainM.alphaAccuracy,
      'exam_alpha_acc': examM.alphaAccuracy,
      'feature_count': meta.length,
      'missing_value': MlFeatureFlat.missing,
      'exported_at': DateTime.now().toIso8601String(),
    };

    final examReport = {
      'total': examM.total,
      'correct': examM.correct,
      'wrong': examM.wrong,
      'alpha_accuracy': examM.alphaAccuracy,
      'pred_accuracy': examM.predAccuracy,
      'pred_evaluated': examM.predEvaluated,
      'samples': exam.map((e) => e.toJson()).toList(),
    };

    await File(metaPath).writeAsString(jsonEncode(meta), flush: true);
    await File(trainPath).writeAsString(trainLib, flush: true);
    await File(examPath).writeAsString(examLib, flush: true);
    await File(libsvmPath).writeAsString(trainLib, flush: true);
    await File(samplesPath).writeAsString(samplesJsonl.toString(), flush: true);
    await File(runMetaPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(runMeta),
      flush: true,
    );
    await File(examReportPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(examReport),
      flush: true,
    );

    return MlBspExportResult(
      metaPath: metaPath,
      libsvmPath: libsvmPath,
      trainPath: trainPath,
      examPath: examPath,
      samplesPath: samplesPath,
      runMetaPath: runMetaPath,
      examReportPath: examReportPath,
      featureCount: meta.length,
      sampleCount: samples.length,
      trainCount: train.length,
      examCount: exam.length,
      meta: meta,
    );
  }
}

class MlBspExportResult {
  const MlBspExportResult({
    required this.metaPath,
    required this.libsvmPath,
    required this.trainPath,
    required this.examPath,
    required this.samplesPath,
    required this.runMetaPath,
    required this.examReportPath,
    required this.featureCount,
    required this.sampleCount,
    required this.trainCount,
    required this.examCount,
    required this.meta,
  });

  final String metaPath;
  final String libsvmPath;
  final String trainPath;
  final String examPath;
  final String samplesPath;
  final String runMetaPath;
  final String examReportPath;
  final int featureCount;
  final int sampleCount;
  final int trainCount;
  final int examCount;
  final Map<String, int> meta;
}
