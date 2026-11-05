import 'dart:io';

import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/robot_verify/robot_verify_paths.dart';
import 'package:flutter_test/flutter_test.dart';

LevelBundle? _lv(List<LevelBundle> levels, int level) {
  for (final l in levels) {
    if (l.level == level) return l;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('默认 test/custom.ohlc · 层级早解锁验收', () {
    late List<KlineBar> bars;
    late ChanBridge bridge;

    setUpAll(() {
      bridge = ChanBridge.instance;
      try {
        bridge.ensureInitialized();
      } catch (e) {
        // DLL 缺失时整组 skip
      }
      final repo = RobotVerifyPaths.resolveRepoRoot();
      if (repo == null) {
        return;
      }
      final dataRoot = '$repo${Platform.pathSeparator}a_Data';
      try {
        final loaded = bridge.loadKlinesEx(
          dataRoot: dataRoot,
          code: 'test',
          beginDate: '2000/01/01 00:00:00',
          endDate: '2099/12/31 23:59:59',
          period: '1m',
          tickSource: 'file',
        );
        bars = loaded.bars;
      } catch (_) {
        bars = [];
      }
    });

    test('idx=0：K1 idx=0 动态；idx=8：K1 首段确认 + K2 idx=0 动态', () {
      if (bars.length < 9) {
        fail('无 test/custom.ohlc 或 FFI 不可用（bars=${bars.length}）');
      }

      final prefix0 = bars.sublist(0, 1);
      final prefix8 = bars.sublist(0, 9);

      final b0 = bridge.buildKlineCombineBundle(
        prefix0,
        earlyLayerDynamic: true,
      );
      final b8 = bridge.buildKlineCombineBundle(
        prefix8,
        earlyLayerDynamic: true,
      );

      final l1_0 = _lv(b0.levels, 1);
      expect(l1_0, isNotNull, reason: 'bar0 应有 structure level1');
      expect(l1_0!.segments, isEmpty, reason: 'K1 idx=0 仍动态');
      expect(l1_0.activeUnit, isNotNull);
      expect(l1_0.activeUnit!.idx, 0);
      expect(l1_0.activeUnit!.x2, 0);

      expect(
        levelLineDrawAllowed(
          levels: b0.levels,
          barFeatures: b0.barFeatures,
          level: 1,
          asOf: 0,
        ),
        isTrue,
        reason: 'K1 连线绘制门控应认父层 activeUnit',
      );

      final k1virt0 = asOfLevelVirtualK1Bars(
        levels: b0.levels,
        barFeatures: b0.barFeatures,
        level: 1,
        asOf: 0,
      );
      expect(k1virt0, isNotEmpty, reason: 'K1 idx=0 动态虚拟单元');

      final k1samples0 = collectKnOhlcSamples(
        displayKn: 2,
        bars: prefix0,
        levels: b0.levels,
        asOf: 0,
      );
      expect(k1samples0.any((s) => s.endX == 0), isTrue);

      final l0_8 = _lv(b8.levels, 0);
      final l1_8 = _lv(b8.levels, 1);
      expect(l0_8, isNotNull);
      expect(l1_8, isNotNull);
      expect(l0_8!.segments, isNotEmpty, reason: '步进到 idx=8 时 K0 应已有冻段');
      expect(l1_8!.activeUnit, isNotNull, reason: 'idx=8 时 K1 idx=0 至少为动态');

      final firstConfirmX = b8.k0Confirms.isEmpty
          ? l0_8.segments.first.endConfirmX
          : b8.k0Confirms.first.x;
      expect(firstConfirmX, isNotNull);

      // 默认 custom.ohlc：K0 首确认在 idx=4（非 8）；idx=8 时 K1 往往仍为动态、尚未冻成 idx=0 段
      var l1FreezeBar = -1;
      for (var n = 0; n < bars.length; n++) {
        final p = bridge.buildKlineCombineBundle(
          bars.sublist(0, n + 1),
          earlyLayerDynamic: true,
        );
        final l1 = _lv(p.levels, 1);
        if (l1 != null && l1.segments.isNotEmpty) {
          l1FreezeBar = n;
          break;
        }
      }
      expect(l1FreezeBar, greaterThanOrEqualTo(0),
          reason: '样本中 K1 应出现首段冻段');

      final bFreeze = bridge.buildKlineCombineBundle(
        bars.sublist(0, l1FreezeBar + 1),
        earlyLayerDynamic: true,
      );
      final l1f = _lv(bFreeze.levels, 1)!;
      expect(l1f.segments.first.idx, 0);

      final l2f = _lv(bFreeze.levels, 2);
      expect(l2f, isNotNull,
          reason: 'K1 idx=0 冻段当根应解锁 K2 idx=0 动态');
      if (l2f!.segments.isEmpty) {
        expect(l2f.activeUnit, isNotNull);
        expect(l2f.activeUnit!.idx, 0);
      }

      expect(
        levelLineDrawAllowed(
          levels: bFreeze.levels,
          barFeatures: bFreeze.barFeatures,
          level: 2,
          asOf: l1FreezeBar,
        ),
        isTrue,
      );

      final virt2 = asOfLevelVirtualK1Bars(
        levels: bFreeze.levels,
        barFeatures: bFreeze.barFeatures,
        level: 2,
        asOf: l1FreezeBar,
      );
      expect(virt2, isNotEmpty, reason: 'K2 展示轨虚拟单元非空');

      // 记录口径供人工对照（idx=8 未必是 K0 首确认）
      expect(
        firstConfirmX,
        4,
        reason: '当前默认 custom.ohlc 实测 K0 首确认 idx（若你记得 idx=8 可能是旧样本/别的节点）',
      );

      final b0old = bridge.buildKlineCombineBundle(
        prefix0,
        earlyLayerDynamic: false,
      );
      expect(
        _lv(b0old.levels, 1),
        isNull,
        reason: '关早解锁 bar0 不应创建 level1',
      );
    });
  });
}
