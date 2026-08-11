import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/ml/ml_bsp_export.dart';
import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_dataset_split.dart';
import 'package:chan_kline/ml/ml_experience_trainer.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/ml/ml_feature_schema.dart';
import 'package:chan_kline/ml/ml_split_config.dart';
import 'package:chan_kline/ml/ml_xgb_trainer.dart';

void main() {
  test('XGB 模型文件名含 code/period/schema', () {
    final name = MlXgbTrainer.modelFileName(code: '000001', period: '1m');
    expect(name, 'model_xgb_000001_1m_sv${MlFeatureSchema.schemaVersion}.json');
  });

  test('导出 index_base=0 且 valid 路径可用', () async {
    final dir = await Directory.systemTemp.createTemp('ml_xgb_');
    final samples = [
      for (var i = 0; i < 6; i++)
        MlBspSample(
          x: i,
          side: i.isEven ? 'B' : 'S',
          label: i.isEven ? '1Ba' : '1Sa',
          price: 10.0 + i,
          segIdx: 0,
          openTime: 't$i',
          featureFrozenAt: i,
          features: {
            'open': 1.0 + i,
            if (i % 2 == 0) 'sub.volume_0': 2.0,
          },
        )..isCorrect = i % 3 != 0,
    ];
    final result = await MlBspExport.write(
      samples: samples,
      dataRoot: dir.path,
      code: '000001',
      period: '1m',
      stepIdx: 5,
      splitConfig: const MlSplitConfig(),
    );
    expect(File(result.validPath).existsSync(), isTrue);
    final runMeta =
        jsonDecode(await File(result.runMetaPath).readAsString()) as Map;
    expect(runMeta['index_base'], 0);
    expect(runMeta['missing_value'], MlFeatureFlat.missing);
    expect(runMeta['schema_version'], MlFeatureSchema.schemaVersion);

    final trainLine = (await File(result.trainPath).readAsLines()).first;
    expect(RegExp(r'\b0:').hasMatch(trainLine), isTrue);

    await dir.delete(recursive: true);
  });

  test('已打分样本可按阈值选参', () {
    final samples = [
      for (var i = 0; i < 6; i++)
        MlBspSample(
          x: i,
          side: 'B',
          label: '1Ba',
          price: 1,
          segIdx: 0,
          openTime: 't',
          featureFrozenAt: i,
          features: const {},
          predictScore: i < 3 ? 0.8 : 0.2,
        )..isCorrect = i < 3,
    ];
    MlDatasetSplit.apply(samples, const MlSplitConfig());
    final valid = MlDatasetSplit.validOf(samples);
    final thr = MlExperienceTrainer.tuneThresholdOnValid(
      valid.isEmpty ? samples : valid,
    );
    expect(MlExperienceTrainer.thrGrid.contains(thr), isTrue);
    final st = MlExperienceTrainer.statsOfScored(samples, threshold: thr);
    expect(st.total, 6);
  });

  test('Python ml_train_xgb 0-based 训练冒烟', () async {
    File? found;
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      final p = File('${dir.path}${Platform.pathSeparator}ml_train_xgb.py');
      if (p.existsSync()) {
        found = p;
        break;
      }
      dir = dir.parent;
    }
    if (found == null) {
      // ignore: avoid_print
      print('skip: ml_train_xgb.py not found near ${Directory.current.path}');
      return;
    }
    final tmp = await Directory.systemTemp.createTemp('ml_xgb_py_');
    final meta = {'a': 0, 'b': 1};
    final metaPath = '${tmp.path}${Platform.pathSeparator}feature.meta';
    final trainPath =
        '${tmp.path}${Platform.pathSeparator}feature_train.libsvm';
    final validPath =
        '${tmp.path}${Platform.pathSeparator}feature_valid.libsvm';
    final runMetaPath = '${tmp.path}${Platform.pathSeparator}run_meta.json';
    await File(metaPath).writeAsString(jsonEncode(meta));
    await File(trainPath).writeAsString(
      '1 0:1.0 1:0.1\n'
      '0 0:0.1 1:1.0\n'
      '1 0:0.9 1:0.2\n'
      '0 0:0.2 1:0.8\n',
    );
    await File(validPath).writeAsString(
      '1 0:0.95 1:0.15\n'
      '0 0:0.15 1:0.9\n',
    );
    await File(runMetaPath).writeAsString(
      jsonEncode({'schema_version': MlFeatureSchema.schemaVersion}),
    );
    final modelPath =
        '${tmp.path}${Platform.pathSeparator}model_xgb_t_1m_sv1.json';
    final payload = jsonEncode({
      'libsvm_path': trainPath,
      'valid_path': validPath,
      'meta_path': metaPath,
      'output_dir': tmp.path,
      'model_path': modelPath,
      'run_meta_path': runMetaPath,
      'schema_version': MlFeatureSchema.schemaVersion,
      'code': 't',
      'period': '1m',
      'force_retrain': true,
      'params': {
        'max_depth': 2,
        'num_round': 10,
        'learning_rate': 0.3,
        'early_stopping_rounds': 5,
      },
    });
    final proc = await Process.start('python', [found.path]);
    proc.stdin.write(payload);
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    expect(code, 0, reason: 'stderr=$err\nstdout=$out');
    final line = out
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.startsWith('{'))
        .last;
    final resp = jsonDecode(line) as Map;
    expect(resp['ok'], true);
    expect(File(modelPath).existsSync(), isTrue);
    final side = jsonDecode(
      await File(modelPath.replaceFirst('.json', '.meta.json')).readAsString(),
    ) as Map;
    expect(side['index_base'], 0);
    expect(side['feature_names'], ['a', 'b']);
    expect(side['missing_value'], MlFeatureFlat.missing);
    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
