import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/robot_verify/robot_verify_data.dart';
import 'package:flutter_test/flutter_test.dart';

/// 002003 默认区间（App 默认加载的样本）· 层级早解锁验收
///
/// 用户预期（默认数据）：
///  1. K0 idx=0 → K1 idx=0 已初生成且是**动态**；
///  2. K0 idx=8 → K0 分型确认，且 K1 idx=0 为**确认态**、K1 idx=1 为**动态**；
///  3. K1 idx=0 确认当根 → K2 idx=0 初生成且**动态**；以此类推向上递归。
///
/// 层级命名对照（方案B）：
///  - structure level0 = K0连线（笔）；level1 = K1连线（段）；level2 = K2连线。
///  - 用户口中的「K1」= structure level1；「K2」= structure level2。
///  - 「K0 分型确认」= level0 的分型确认（= bundle.k0Confirms）。
LevelBundle? lv(List<LevelBundle> ls, int n) {
  for (final l in ls) {
    if (l.level == n) return l;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('002003 默认区间 · 层级早解锁', () {
    late List<KlineBar> bars;
    late ChanBridge bridge;

    setUpAll(() async {
      bridge = ChanBridge.instance..ensureInitialized();
      final plan = await resolveRobotVerify002003LoadPlan();
      if (plan == null) {
        fail('本机无 002003 分笔备份，无法做默认数据验收');
      }
      bars = loadRobotVerifyBars(plan: plan, period: '1m');
    });

    test('K0 idx=0：K1 idx=0 已初生成且为动态', () {
      final b0 = bridge.buildKlineCombineBundle(
        bars.sublist(0, 1),
        earlyLayerDynamic: true,
      );
      final l1 = lv(b0.levels, 1)!;
      expect(l1.segments, isEmpty, reason: 'K1 此刻尚无冻段');
      expect(l1.activeUnit, isNotNull, reason: 'K1 idx=0 应为动态');
      expect(l1.activeUnit!.idx, 0);
    });

    test('K0 idx=8：K0 分型确认 + K1 idx=0 确认态 + K1 idx=1 动态 + K2 idx=0 动态', () {
      final b8 = bridge.buildKlineCombineBundle(
        bars.sublist(0, 9),
        earlyLayerDynamic: true,
      );

      // ① K0 分型确认在 idx=8
      expect(
        b8.k0Confirms.any((c) => c.x == 8),
        isTrue,
        reason: '002003 K0 首次分型确认应在 idx=8',
      );

      // ② K1 idx=0 确认态
      final l1 = lv(b8.levels, 1)!;
      expect(l1.segments, isNotEmpty, reason: 'K1 idx=0 应已冻段（确认态）');
      expect(l1.segments.first.idx, 0);
      expect(
        l1.segments.first.endConfirmX,
        8,
        reason: 'K1 idx=0 应在 K0 确认当根（idx=8）冻结',
      );

      // ③ K1 idx=1 动态
      expect(l1.activeUnit, isNotNull, reason: 'K1 idx=1 应为动态');
      expect(l1.activeUnit!.idx, 1);

      // ④ K2 idx=0 动态
      final l2 = lv(b8.levels, 2)!;
      expect(l2.segments, isEmpty, reason: 'K2 此刻尚无冻段');
      expect(l2.activeUnit, isNotNull, reason: 'K2 idx=0 应为动态');
      expect(l2.activeUnit!.idx, 0);
    });

    test('递归向上：K1 确认后 K2 idx=0 确认 + K2 idx=1 动态 + K3 idx=0 动态', () {
      // 002003 上 L1 idx=0 由「层级早解锁」在 x=8 冻结（K0 首确认当根）。
      // 引擎自己的 L1 首段要到 x=39 才冻结（引擎走完首段策略）。
      // 递归向上：L1 的**引擎原生**首段确认当根 → L2 idx=0 确认 + L2 idx=1 动态 + L3 idx=0 动态。
      int l1EngineFreezeBar = -1;
      for (var n = 9; n < 80; n++) {
        final p = bridge.buildKlineCombineBundle(
          bars.sublist(0, n + 1),
          earlyLayerDynamic: true,
        );
        final l1 = lv(p.levels, 1)!;
        // 引擎原生段 = idx>=1（idx=0 是早解锁写的）
        if (l1.segments.any((s) => s.idx >= 1 && s.endConfirmX == n)) {
          l1EngineFreezeBar = n;
          break;
        }
      }
      expect(l1EngineFreezeBar, greaterThanOrEqualTo(0),
          reason: 'L1 引擎原生首段应在某根冻结');

      final bf = bridge.buildKlineCombineBundle(
        bars.sublist(0, l1EngineFreezeBar + 1),
        earlyLayerDynamic: true,
      );
      final l2 = lv(bf.levels, 2)!;
      expect(l2.segments, isNotEmpty, reason: 'K2 idx=0 应确认');
      expect(l2.activeUnit, isNotNull, reason: 'K2 idx=1 应动态');
      expect(l2.activeUnit!.idx, 1);

      final l3 = lv(bf.levels, 3)!;
      expect(l3.activeUnit, isNotNull, reason: 'K3 idx=0 应动态');
      expect(l3.activeUnit!.idx, 0);
    });

    test('idx 唯一：各层段编号不得重复（早解锁占用 idx=0 后引擎须接续）', () {
      for (final n in [8, 39, 46, 60, 80]) {
        final b = bridge.buildKlineCombineBundle(
          bars.sublist(0, n + 1),
          earlyLayerDynamic: true,
        );
        for (final lv in b.levels) {
          final segIdx = lv.segments.map((s) => s.idx).toList();
          expect(
            segIdx.toSet().length,
            segIdx.length,
            reason: 'n=$n L${lv.level} 段 idx 重复：$segIdx',
          );
          final unitIdx = lv.unitBars.map((u) => u.idx).toList();
          expect(
            unitIdx.toSet().length,
            unitIdx.length,
            reason: 'n=$n L${lv.level} 单元 idx 重复：$unitIdx',
          );
        }
      }
    });

    test('旧口径对照：关掉早解锁则 K1/K2 不存在', () {
      final b0 = bridge.buildKlineCombineBundle(
        bars.sublist(0, 1),
        earlyLayerDynamic: false,
      );
      expect(lv(b0.levels, 1), isNull, reason: '旧口径 bar0 不应有 level1');

      final b8 = bridge.buildKlineCombineBundle(
        bars.sublist(0, 9),
        earlyLayerDynamic: false,
      );
      expect(lv(b8.levels, 1)?.segments, isEmpty,
          reason: '旧口径 idx=8 时 K1 尚无冻段');
      expect(lv(b8.levels, 2), isNull,
          reason: '旧口径 idx=8 时 K2 不应存在');
    });
  });
}
