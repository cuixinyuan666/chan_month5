import 'dart:io';

import '../bridge/chan_bridge.dart';
import '../models/kline_bar.dart';
import 'task_demo_loader.dart';
import 'task_demo_manifest.dart';

/// 按 manifest 准备演示数据（test CSV 或默认股票）
abstract final class TaskDemoDataLoader {
  static Future<List<KlineBar>?> loadDemoBars({
    required String dataRoot,
    required TaskDemoManifest manifest,
  }) async {
    final csvPath = TaskDemoLoader.demoCsvPath(manifest);
    if (csvPath != null && await File(csvPath).exists()) {
      final bars = await TaskDemoLoader.parseDemoCsv(csvPath);
      if (bars.isEmpty) return null;
      ChanBridge.instance.saveTestOhlc(dataRoot: dataRoot, bars: bars);
      return bars;
    }
    return null;
  }

  /// 返回是否应切到 test；bars 非空表示已写入 custom.ohlc.csv
  static Future<({bool useTest, List<KlineBar>? bars})> prepareForManifest({
    required String dataRoot,
    required TaskDemoManifest manifest,
  }) async {
    final bars = await loadDemoBars(dataRoot: dataRoot, manifest: manifest);
    if (bars != null) {
      return (useTest: true, bars: bars);
    }
    final code = manifest.defaultStockCode?.trim();
    if (code != null && code.isNotEmpty) {
      return (useTest: code == 'test', bars: null);
    }
    return (useTest: true, bars: null);
  }
}
