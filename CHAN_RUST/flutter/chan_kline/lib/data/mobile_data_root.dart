import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Android 端 a_Data：首次启动从 assets 解压到应用私有目录。
class MobileDataRoot {
  MobileDataRoot._();

  static const assetZip = 'assets/a_data_seed.zip';
  static const seedVersion = '2025q1-v1';
  static const bundledStockCode = '002003';
  static final bundledBeginDate = DateTime(2025, 1, 2, 9, 30, 0);
  static final bundledEndDate = DateTime(2025, 3, 31, 15, 0, 0);

  static Future<String> ensureReady() async {
    if (!Platform.isAndroid) {
      throw StateError('MobileDataRoot 仅用于 Android');
    }
    final docs = await getApplicationDocumentsDirectory();
    final rootDir = Directory('${docs.path}${Platform.pathSeparator}a_Data');
    final marker = File(
      '${rootDir.path}${Platform.pathSeparator}.seed_$seedVersion',
    );
    if (marker.existsSync() && rootDir.existsSync()) {
      return rootDir.path;
    }

    final bytes = await rootBundle.load(assetZip);
    final archive = ZipDecoder().decodeBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    for (final entry in archive) {
      if (entry.isFile) {
        final outPath = '${docs.path}${Platform.pathSeparator}${entry.name}';
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>);
      }
    }

    if (!rootDir.existsSync()) {
      throw StateError('解压后未找到 a_Data 目录：${rootDir.path}');
    }
    await marker.writeAsString(seedVersion);
    return rootDir.path;
  }
}
