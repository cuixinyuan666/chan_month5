import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 安卓/Windows 交互模式：默认跟随系统，可手动覆盖。
abstract final class InteractionModeStore {
  static const _fileName = '.chan_interaction_mode.json';

  /// null = 自动（Android 用安卓逻辑，其它用桌面逻辑）
  static bool? _manualAndroidLogic;

  static bool? get manualOverride => _manualAndroidLogic;

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final obj = jsonDecode(await f.readAsString());
      if (obj is! Map) return;
      final v = obj['useAndroidLogic'];
      if (v == null) {
        _manualAndroidLogic = null;
      } else {
        _manualAndroidLogic = v == true;
      }
    } catch (_) {}
  }

  static Future<void> saveManualOverride(bool? useAndroidLogic) async {
    _manualAndroidLogic = useAndroidLogic;
    try {
      final f = await _file();
      final map = <String, dynamic>{};
      if (useAndroidLogic != null) {
        map['useAndroidLogic'] = useAndroidLogic;
      }
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(map),
      );
    } catch (_) {}
  }

  /// 是否走安卓交互壳层与手势（mobileLayout）。
  static bool resolveUseAndroidLogic() {
    final manual = _manualAndroidLogic;
    if (manual != null) return manual;
    return Platform.isAndroid;
  }

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}$_fileName');
  }
}
