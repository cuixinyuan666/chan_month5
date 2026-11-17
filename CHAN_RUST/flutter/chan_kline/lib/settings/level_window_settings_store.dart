import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../chart/level_window_layout.dart';
import '../models/pre_first_fractal_mode.dart';
import '../models/pre_first_fractal_unit_mode.dart';

/// 层级分窗本机偏好（落盘 `.chan_level_windows.json`）。
///
/// 只存「开不开 / 几窗 / 每窗哪一层」，不存任何行情或缠论结果。
/// 总开关默认关闭：关掉时主界面与分窗功能上线前完全一致。
abstract final class LevelWindowSettingsStore {
  static const _fileName = '.chan_level_windows.json';

  static bool _enabled = false;
  static int _count = kLevelWindowDefaultCount;
  static List<int> _slots = defaultLevelWindowSlots();

  /// 「层级早生成动态单元 + 首分型前合并框」合并后的四档口径（2026-11-17 起）。
  /// 默认「开启 · 高高」，与合并前的默认组合一致。
  static PreFirstFractalUnitMode _unitMode = PreFirstFractalUnitMode.defaultMode;

  static bool get enabled => _enabled;

  /// 四档合并口径（设置面板唯一控件读这份）。
  static PreFirstFractalUnitMode get unitMode => _unitMode;

  /// 总闸：每层首个单元是否提前出现（派生，不再是独立落盘项）。
  static bool get earlyDynamicUnit => _unitMode.earlyDynamicUnit;

  /// 闸下口径：首分型前合并框（派生）。
  static PreFirstFractalMode get preFirstFractalMode =>
      _unitMode.preFirstFractalMode;

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
      // 新键优先；老设置文件只有旧两键时按它们推导（early_dynamic_unit=false → 关闭档）。
      final rawUnit = obj['pre_first_fractal_unit_mode'];
      _unitMode = rawUnit is String
          ? PreFirstFractalUnitMode.fromStorage(rawUnit)
          : PreFirstFractalUnitMode.fromLegacy(
              earlyDynamicUnit: obj['early_dynamic_unit'] != false,
              mode: PreFirstFractalMode.fromStorage(
                obj['pre_first_fractal_mode'],
              ),
            );
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
    PreFirstFractalUnitMode? unitMode,
    int? count,
    List<int>? slots,
  }) async {
    if (enabled != null) _enabled = enabled;
    if (unitMode != null) _unitMode = unitMode;
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
          // 新键是权威；旧两键继续双写，保证旧版 App / 外部读盘脚本可回滚。
          'pre_first_fractal_unit_mode': _unitMode.storageValue,
          'early_dynamic_unit': _unitMode.earlyDynamicUnit,
          'pre_first_fractal_mode': _unitMode.preFirstFractalMode.storageValue,
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
