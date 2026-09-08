import 'dart:io';

/// 仓库不再带股票导出 txt 时，依赖本地 002003 分笔的测试应 skip。
const kNoOffline002003Skip = '仓库已去掉 002003 离线分笔，本测试仍走文件加载';

bool hasOffline002003TickFiles() {
  final dir = Directory(
    '${Directory.current.path}${Platform.pathSeparator}..'
    '${Platform.pathSeparator}..${Platform.pathSeparator}..'
    '${Platform.pathSeparator}a_Data${Platform.pathSeparator}002003',
  );
  if (!dir.existsSync()) return false;
  return dir.listSync().any(
        (e) => e is File && e.path.toLowerCase().endsWith('.txt'),
      );
}
