import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/robot_verify/robot_verify_data.dart';
import 'package:flutter_test/flutter_test.dart';

LevelBundle? lv(List<LevelBundle> ls, int n) {
  for (final l in ls) {
    if (l.level == n) return l;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('002003 默认区间 · 层级早解锁 + K0确认级联', () {
    test('idx=0 K1动态；idx=8 K0确认 + K1 idx=0确认 + K1 idx=1动态 + K2动态', () async {
      final bridge = ChanBridge.instance..ensureInitialized();
      final plan = await resolveRobotVerify002003LoadPlan();
      if (plan == null) {
        fail('本机无 002003 分笔');
      }
      final bars = loadRobotVerifyBars(plan: plan, period: '1m');
      expect(bars.length, greaterThan(9));

      final b0 = bridge.buildKlineCombineBundle(
        bars.sublist(0, 1),
        earlyLayerDynamic: true,
      );
      final l1_0 = lv(b0.levels, 1);
      expect(l1_0, isNotNull);
      expect(l1_0!.segments, isEmpty);
      expect(l1_0.activeUnit, isNotNull);
      expect(l1_0.activeUnit!.idx, 0);

      final b8 = bridge.buildKlineCombineBundle(
        bars.sublist(0, 9),
        earlyLayerDynamic: true,
      );
      expect(b8.k0Confirms.any((c) => c.x == 8), isTrue,
          reason: '002003 首颗 K0 分型确认在 idx=8');

      final l1 = lv(b8.levels, 1)!;
      expect(l1.segments, isNotEmpty, reason: 'K1 idx=0 应已冻段');
      expect(l1.segments.first.idx, 0);
      expect(
        l1.confirms.any((c) => c.x == 8 && (c.fx == 'TOP' || c.fx == 'BOTTOM')),
        isTrue,
        reason: 'K1分型确认当根应对齐 idx=8',
      );
      expect(l1.activeUnit, isNotNull, reason: 'K1 idx=1 动态');
      expect(l1.activeUnit!.idx, 1, reason: '进行中应为 idx=1');

      final l2 = lv(b8.levels, 2);
      expect(l2, isNotNull, reason: 'K1 idx=0 确认后应有 K2 层');
      expect(l2!.segments, isEmpty);
      expect(l2.activeUnit, isNotNull, reason: 'K2 idx=0 动态');
      expect(l2.activeUnit!.idx, 0);
    });
  });
}
