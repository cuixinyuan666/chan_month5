import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../chart/level_window_layout.dart';

/// 层级分窗本机偏好（落盘 `.chan_level_windows.json`）。
///
/// 只存「开不开 / 几窗 / 每窗哪一层」，不存任何行情或缠论结果。
/// 总开关默认关闭：关掉时主界面与分窗功能上线前完全一致。
abstract final class LevelWindowSettingsStore {
  static const _fileName = '.chan_level_windows.json';

  static bool _enabled = false;
  static int _count = kLevelWindowDefaultCount;
  static List<int> _slots = defaultLevelWindowSlots();

  /// 层级早生成动态单元：开=每层首个单元在父层首确认当根以动态态出现。
  /// 默认开；关闭时回到经典口径。与「层级分窗」总开关相互独立。
  static bool _earlyDynamicUnit = true;

  static bool get enabled => _enabled;

  static bool get earlyDynamicUnit => _earlyDynamicUnit;

  static int get count => _count;

  /// 全部 10 个槽位（超出当前窗口数的部分只做记忆）。
  static List<int> get slots => List<int>.unmodifiable(_slots);

  /// 当前生效的层级：前 [count] 个槽位，按左→右、上→下排列。
  static List<int> get activeLevels =>
      List<int>.unmodifiable(_slots.take(_count));

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final obj = jsonDecode(await f.readAsString());
      if (obj is! Map) return;
      _enabled = obj['enabled'] == true;
      // 缺省 true：旧设置文件没有该键时按新默认口径。
      _earlyDynamicUnit = obj['early_dynamic_unit'] != false;
      _count = normalizeLevelWindowCount(
        obj['count'] is int ? obj['count'] as int : null,
      );
      final rawSlots = obj['slots'];
      final parsed = <int>[];
      if (rawSlots is List) {
        for (final e in rawSlots) {
          if (e is int && e >= 0 && e <= kLevelWindowMaxLevel) {
            parsed.add(e);
          }
        }
      }
      _slots = parsed.isEmpty
          ? defaultLevelWindowSlots()
          : fillLevelWindowSlots(count: kLevelWindowSlotCount, slots: parsed);
      // 落盘内容若已不合法（缺 K0 / 重复），按默认补齐，避免启动即进坏态。
      if (!checkLevelWindowSlots(count: _count, slots: _slots).ok) {
        _slots = fillLevelWindowSlots(
          count: kLevelWindowSlotCount,
          slots: defaultLevelWindowSlots(),
        );
      }
    } catch (_) {}
  }

  static Future<void> save({
    bool? enabled,
    bool? earlyDynamicUnit,
    int? count,
    List<int>? slots,
  }) async {
    if (enabled != null) _enabled = enabled;
    if (earlyDynamicUnit != null) _earlyDynamicUnit = earlyDynamicUnit;
    if (count != null) _count = normalizeLevelWindowCount(count);
    if (slots != null) {
      _slots = fillLevelWindowSlots(
        count: kLevelWindowSlotCount,
        slots: slots,
      );
    }
    try {
      final f = await _file();
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'enabled': _enabled,
          'early_dynamic_unit': _earlyDynamicUnit,
          'count': _count,
          'slots': _slots,
        }),
      );
    } catch (_) {}
  }

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}${Platform.pathSeparator}$_fileName');
  }
}
