import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/zs_signal_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/zs_frame.dart';

void main() {
  test('catalog / 层全选含 Kn中枢判断与确认', () {
    final cat = buildSubIndicatorCatalog(2, truncationCheck: true);
    expect(cat.any((e) => e.kind == SubIndicatorKind.zsConfirm && e.kn == 0),
        isTrue);
    expect(cat.any((e) => e.kind == SubIndicatorKind.zsJudgment && e.kn == 1),
        isTrue);
    expect(cat.any((e) => e.label == 'K0中枢确认'), isTrue);
    expect(cat.any((e) => e.label == 'K1中枢判断'), isTrue);

    final lvl0 = subIndicatorsForLevel(0, cat);
    expect(lvl0.any((e) => e.kind == SubIndicatorKind.zsConfirm), isTrue);
    expect(lvl0.any((e) => e.kind == SubIndicatorKind.zsJudgment), isTrue);

    final def = defaultSubIndicatorsK0();
    expect(def.any((e) => e.kind == SubIndicatorKind.zsConfirm && e.kn == 0),
        isTrue);
    expect(def.any((e) => e.kind == SubIndicatorKind.zsJudgment && e.kn == 0),
        isTrue);
  });

  test('空间趋势：抬高升红、下移降绿（可与 first.dir 相反）', () {
    const low = ZSFrame(
      x1: 0,
      x2: 2,
      high: 10,
      low: 9,
      level: 1,
      dir: 1,
      isSure: true,
      seq: 0,
    );
    const highUp = ZSFrame(
      x1: 3,
      x2: 5,
      high: 12,
      low: 11,
      level: 1,
      dir: -1, // first.dir 降，但位置抬高
      isSure: false,
      seq: 1,
    );
    const lower = ZSFrame(
      x1: 6,
      x2: 7,
      high: 11.5,
      low: 10.5,
      level: 1,
      dir: 1, // first.dir 升，但位置下移
      isSure: false,
      seq: 2,
    );
    expect(zsSpatialTrendDir(highUp, low), 1);
    expect(zsSpatialTrendDir(lower, highUp), -1);
    expect(zsSpatialTrendDir(low, null), 1);
  });

  test('中枢判断：单开放只首次；离开窗逐步追加；合回归零', () {
    final hist = <ZsSignalEvent>[];
    mergeZsJudgmentEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 1,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: false,
          seq: 0,
        ),
      ],
      kn: 0,
      discoveryX: 0,
    );
    expect(hist.length, 1);
    expect(hist.first.value, 1);

    mergeZsJudgmentEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: false,
          seq: 0,
        ),
      ],
      kn: 0,
      discoveryX: 1,
    );
    expect(hist.length, 1);

    // 离开窗：身份=新候选；色=上个框相对再前一框（此处上个无前框，回退 dir）
    mergeZsJudgmentEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: false,
          seq: 0,
        ),
        ZSFrame(
          x1: 3,
          x2: 3,
          high: 12,
          low: 11,
          level: 0,
          dir: -1,
          isSure: false,
          seq: 1,
        ),
      ],
      kn: 0,
      discoveryX: 2,
    );
    expect(hist.where((e) => e.x1 == 3).length, 1);
    expect(hist.last.value, 1);
    expect(hist.last.x, 2);

    mergeZsJudgmentEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: false,
          seq: 0,
        ),
        ZSFrame(
          x1: 3,
          x2: 4,
          high: 12,
          low: 11,
          level: 0,
          dir: -1,
          isSure: false,
          seq: 1,
        ),
      ],
      kn: 0,
      discoveryX: 3,
    );
    expect(hist.where((e) => e.x1 == 3).length, 2);

    mergeZsJudgmentEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 5,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: false,
          seq: 0,
        ),
      ],
      kn: 0,
      discoveryX: 4,
    );
    expect(hist.where((e) => e.x == 4).length, 0);
    expect(hist.length, 3);
  });

  test('离开窗/确认：色跟空间抬高下移，不跟 first.dir', () {
    final judge = <ZsSignalEvent>[];
    // 前枢低位 + 上个抬高(dir=-1) + 新候选 → 判断红
    mergeZsJudgmentEventLog(
      judge,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 1,
          dir: 1,
          isSure: true,
          seq: 0,
        ),
        ZSFrame(
          x1: 3,
          x2: 5,
          high: 12,
          low: 11,
          level: 1,
          dir: -1,
          isSure: false,
          seq: 1,
        ),
        ZSFrame(
          x1: 6,
          x2: 6,
          high: 11,
          low: 10,
          level: 1,
          dir: 1,
          isSure: false,
          seq: 2,
        ),
      ],
      kn: 1,
      discoveryX: 77,
    );
    expect(judge.single.value, 1);
    expect(judge.single.x1, 6);

    // 确认抬高枢：dir=-1 仍红（对齐 85）；先冻结前枢再确认抬高枢
    final confirm = <ZsSignalEvent>[];
    mergeZsConfirmEventLog(
      confirm,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 1,
          dir: 1,
          isSure: true,
          seq: 0,
        ),
      ],
      kn: 1,
      discoveryX: 50,
    );
    mergeZsConfirmEventLog(
      confirm,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 1,
          dir: 1,
          isSure: true,
          seq: 0,
        ),
        ZSFrame(
          x1: 3,
          x2: 5,
          high: 12,
          low: 11,
          level: 1,
          dir: -1,
          isSure: true,
          seq: 1,
        ),
      ],
      kn: 1,
      discoveryX: 85,
    );
    expect(confirm.length, 2);
    expect(confirm.last.x1, 3);
    expect(confirm.last.value, 1);

    // 离开下移枢：dir=1 仍绿（对齐 90）
    judge.clear();
    mergeZsJudgmentEventLog(
      judge,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 12,
          low: 11,
          level: 1,
          dir: -1,
          isSure: true,
          seq: 0,
        ),
        ZSFrame(
          x1: 3,
          x2: 5,
          high: 11,
          low: 10,
          level: 1,
          dir: 1,
          isSure: false,
          seq: 1,
        ),
        ZSFrame(
          x1: 6,
          x2: 6,
          high: 10.5,
          low: 9.5,
          level: 1,
          dir: 1,
          isSure: false,
          seq: 2,
        ),
      ],
      kn: 1,
      discoveryX: 90,
    );
    expect(judge.single.value, -1);
  });

  test('中枢确认：首次 is_sure 打点后冻结', () {
    final hist = <ZsSignalEvent>[];
    mergeZsConfirmEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 2,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: true,
          seq: 0,
        ),
      ],
      kn: 0,
      discoveryX: 5,
    );
    expect(hist.length, 1);
    expect(hist.first.x, 5);
    expect(hist.first.value, 1);

    mergeZsConfirmEventLog(
      hist,
      const [
        ZSFrame(
          x1: 0,
          x2: 4,
          high: 10,
          low: 9,
          level: 0,
          dir: 1,
          isSure: true,
          seq: 0,
        ),
      ],
      kn: 0,
      discoveryX: 8,
    );
    expect(hist.length, 1);
  });

  test('collectZsFramesByKn 含 K0 与 levels', () {
    final bundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      levels: [
        const LevelBundle(
          level: 1,
          zsFrames: [
            ZSFrame(
              x1: 1,
              x2: 2,
              high: 1,
              low: 0,
              level: 1,
              dir: 1,
              isSure: false,
            ),
          ],
        ),
      ],
      zsK0Frames: const [
        ZSFrame(
          x1: 0,
          x2: 1,
          high: 1,
          low: 0,
          level: 0,
          dir: -1,
          isSure: true,
        ),
      ],
    );
    final m = collectZsFramesByKn(bundle);
    expect(m[0]!.length, 1);
    expect(m[1]!.length, 1);
  });

  test('expandZsSignalToSeries asOf 截断', () {
    final events = [
      const ZsSignalEvent(x: 1, kn: 0, seq: 0, x1: 0, dir: 1, value: 1),
      const ZsSignalEvent(x: 3, kn: 0, seq: 0, x1: 0, dir: 1, value: 1),
    ];
    final series = expandZsSignalToSeries(events, 5, maxX: 2);
    expect(series[1], 1);
    expect(series[3], 0);
  });

  test('默认绘制白名单：主图四类 + 副图五类；其余静音', () {
    expect(isDefaultDrawnMain(const MainChartIndicator.kn(1)), isTrue);
    expect(isDefaultDrawnMain(const MainChartIndicator.combine(1)), isTrue);
    expect(isDefaultDrawnMain(const MainChartIndicator.zs(0)), isTrue);
    expect(isDefaultDrawnMain(const MainChartIndicator.line(1)), isTrue);
    expect(isDefaultDrawnMain(const MainChartIndicator.meanLine(0)), isFalse);
    expect(isDefaultDrawnMain(const MainChartIndicator.boll(0)), isFalse);

    expect(isDefaultDrawnSub(const SubChartIndicator.fractalConfirm(0)), isTrue);
    expect(isDefaultDrawnSub(const SubChartIndicator.fractalJudgment(0)), isTrue);
    expect(isDefaultDrawnSub(const SubChartIndicator.truncation(0)), isTrue);
    expect(isDefaultDrawnSub(const SubChartIndicator.zsConfirm(0)), isTrue);
    expect(isDefaultDrawnSub(const SubChartIndicator.zsJudgment(0)), isTrue);
    expect(isDefaultDrawnSub(const SubChartIndicator.volume(0)), isFalse);
    expect(isDefaultDrawnSub(const SubChartIndicator.macd(0)), isFalse);
    expect(isDefaultDrawnSub(const SubChartIndicator.rsi(0)), isFalse);
  });
}
