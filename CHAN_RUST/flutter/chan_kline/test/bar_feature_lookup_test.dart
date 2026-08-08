import 'package:chan_kline/compute/step_rhythm_compute.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

List<KlineBar> _bars(int n) => List.generate(
      n,
      (i) => KlineBar(
        idx: i,
        timeMs: i,
        timeText: '2024/01/01 09:${i.toString().padLeft(2, '0')}',
        open: 10.0 + i * 0.1,
        high: 10.5 + i * 0.1,
        low: 9.5 + i * 0.1,
        close: 10.2 + i * 0.1,
        volume: 100.0 + i,
        amount: 1.0,
        metrics: const {},
      ),
    );

/// 模拟 Rust 逐K快照：首段确认前 unitIdx=null（purged 口径）
BarCrosshairFeature _feat(int idx, {int? unitIdx, int level2Unit = -1}) {
  return BarCrosshairFeature(
    idx: idx,
    weekday: '周一',
    mergeInnerSeq: 0,
    levels: [
      // 方案B：structure 0=K0连线 → K1 块
      LevelSnap(
        level: 0,
        unitIdx: unitIdx,
        unitDir: 1,
        unitX1: unitIdx == null ? -1 : 0,
        unitX2: unitIdx == null ? -1 : idx,
        unitOpen: 10.0,
        unitHigh: 11.0,
        unitLow: 9.5,
        unitClose: 10.5,
        unitVolume: 300,
        mergeInnerSeq: 0,
        mergeCount: 1,
        combineHigh: 11.0,
        combineLow: 9.5,
      ),
      if (level2Unit >= 0)
        LevelSnap(
          level: 1,
          unitIdx: level2Unit,
          unitDir: -1,
          unitX1: 0,
          unitX2: idx,
          unitOpen: 10.0,
          unitHigh: 12.0,
          unitLow: 9.0,
          unitClose: 9.5,
          unitVolume: 900,
          mergeInnerSeq: 1,
          mergeCount: 2,
          combineHigh: 12.0,
          combineLow: 9.0,
        ),
    ],
  );
}

void main() {
  test('首段确认前：全部 N 段块输出占位行', () {
    final bars = _bars(3);
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: [for (var i = 0; i < 3; i++) _feat(i)],
      levels: const [LevelBundle(level: 0), LevelBundle(level: 1)],
    );
    final lines = lookup.crosshairTooltipLines(0, timePart: '2024/01/01 09:00');
    expect(lines.first, startsWith('日期时间:2024/01/01 09:00'));
    expect(lines.first, contains('w1'));
    expect(lines.any((l) => l == '==============================='), isTrue);
    expect(lines.any((l) => l == 'K1 idx:首K1确认前'), isTrue);
    expect(lines.any((l) => l == 'K2 idx:首K2确认前'), isTrue);
    expect(lines.any((l) => l.startsWith('K0分型确认:')), isTrue);
  });

  test('K1/K2 快照齐全时：Kn 块按模板输出序号/OHLCV/合并/确认', () {
    final bars = _bars(6);
    final feats = [for (var i = 0; i < 6; i++) _feat(i, unitIdx: i >= 2 ? 0 : null, level2Unit: i >= 4 ? 0 : -1)];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [
        K0ConfirmSignal(x: 2, fx: 'BOTTOM', value: 1, fractalX1: 1, fractalX2: 1),
      ],
      barFeatures: feats,
      levels: [
        const LevelBundle(level: 0, confirms: [
          LevelConfirm(x: 2, fx: 'BOTTOM', value: 1),
        ]),
        const LevelBundle(level: 1, confirms: [
          LevelConfirm(x: 4, fx: 'TOP', value: -1),
        ]),
      ],
    );

    final atConfirm = lookup.crosshairTooltipLines(2, timePart: '2024/01/01 09:02');
    // K0分型确认 = 原始K分型 k0_confirm（与峰距/截断同宗；非「K1端点」旧口径）
    expect(atConfirm.any((l) => l == 'K0分型确认:【1】'), isTrue);
    // K1 块顺序：idx → OHLCV → 合并GG/DD/MG/MD → 合并K序 → 分型确认
    final seqIdx = atConfirm.indexWhere((l) => l.startsWith('K1 idx:【0】'));
    final ohlcvIdx = atConfirm.indexWhere((l) => l.startsWith('K1:O'));
    final mergeHlIdx = atConfirm.indexWhere((l) => l.startsWith('K1合并:GG'));
    final mergeSeqIdx = atConfirm.indexWhere((l) => l.startsWith('K1合并K1 idx:【'));
    expect(seqIdx, greaterThanOrEqualTo(0));
    expect(seqIdx, lessThan(ohlcvIdx));
    expect(ohlcvIdx, lessThan(mergeHlIdx));
    expect(mergeHlIdx, lessThan(mergeSeqIdx));
    // 合并行：GG/DD=逐K当下区间极值；MG/MD=合并框框体高低点（无框体时回退同值）
    expect(
      atConfirm.any((l) => l == 'K1合并:GG【11.00】/DD【9.50】/MG【11.00】/MD【9.50】'),
      isTrue,
      reason: '无 combineFrames 时 MG/MD 应回退为区间极值',
    );

    // x=4 当步：K1 块「分型确认」= K2 确认值 -1
    final at2 = lookup.crosshairTooltipLines(4, timePart: '2024/01/01 09:04');
    expect(at2.any((l) => l == 'K1分型确认:【-1】'), isTrue);
    expect(at2.any((l) => l.startsWith('K2 idx:【0】')), isTrue);
    expect(at2.any((l) => l.startsWith('K2合并K2 idx:【1】')), isTrue);
  });

  test('Kn合并 MG/MD 取合并框框体高低点（无框体回退极值）', () {
    final bars = _bars(6);
    final feats = [for (var i = 0; i < 6; i++) _feat(i, unitIdx: i >= 2 ? 0 : null)];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: feats,
      // 方案B：K1合并=level==1 / k1CombineFrames，勿再用 level0 框冒充
      k1CombineFrames: const [
        KlineCombineFrame(
            x1: 0, x2: 5, t1: '', t2: '', high: 12.0, low: 8.0, fx: 'UNKNOWN', count: 3),
      ],
      levels: const [
        LevelBundle(level: 0),
        LevelBundle(level: 1),
      ],
    );
    final lines = lookup.crosshairTooltipLines(3, timePart: 't');
    // snap 区间极值 GG/DD=11.00/9.50；框体高低点 MG/MD=12.00/8.00（取 k1CombineFrames）
    expect(
      lines.any((l) => l == 'K1合并:GG【11.00】/DD【9.50】/MG【12.00】/MD【8.00】'),
      isTrue,
    );
  });

  test('K0合并 GG/DD=组内原始区间极值（区别于框体 MG/MD：向上包含取高低）', () {
    // 10:47 11.66/11.66、10:48 H11.70 L11.68、10:49 11.70/11.70：后两根向上包含合并
    final bars = [
      KlineBar(idx: 0, timeMs: 0, timeText: '2004/07/19 10:47', open: 11.66, high: 11.66, low: 11.66, close: 11.66, volume: 1, amount: 1, metrics: const {}),
      KlineBar(idx: 1, timeMs: 1, timeText: '2004/07/19 10:48', open: 11.68, high: 11.70, low: 11.68, close: 11.70, volume: 1, amount: 1, metrics: const {}),
      KlineBar(idx: 2, timeMs: 2, timeText: '2004/07/19 10:49', open: 11.70, high: 11.70, low: 11.70, close: 11.70, volume: 1, amount: 1, metrics: const {}),
    ];
    final feats = [
      BarCrosshairFeature(idx: 0, weekday: '周一', mergeInnerSeq: 0, combineHigh: 11.66, combineLow: 11.66),
      BarCrosshairFeature(idx: 1, weekday: '周一', mergeInnerSeq: 0, combineHigh: 11.70, combineLow: 11.68),
      BarCrosshairFeature(idx: 2, weekday: '周一', mergeInnerSeq: 1, combineHigh: 11.70, combineLow: 11.70),
    ];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [
        KlineCombineFrame(x1: 0, x2: 0, t1: '', t2: '', high: 11.66, low: 11.66, fx: 'UNKNOWN', count: 1),
        KlineCombineFrame(x1: 1, x2: 2, t1: '', t2: '', high: 11.70, low: 11.70, fx: 'UNKNOWN', count: 2),
      ],
      k0Confirms: const [],
      barFeatures: feats,
    );
    final lines = lookup.crosshairTooltipLines(2, timePart: '2004/07/19 10:49');
    // GG/DD=组内原始K极值：DD=min(11.68,11.70)=11.68；MG/MD=合并框框体高低点=11.70（Rust 向上合并取「高低」）
    expect(
      lines.any((l) => l == 'K0合并:GG【11.70】/DD【11.68】/MG【11.70】/MD【11.70】'),
      isTrue,
      reason: '向上包含时 DD 应为组内最低 low=11.68，非框体低点 11.70',
    );
  });

  test('tooltip 成交量独立行 B/S/G，并含笔数/比例/节奏；不按副图勾选门控', () {
    final bars = _bars(4); // vol = 100,101,102,103；无 tick → 全归 G
    final feats = [for (var i = 0; i < 4; i++) _feat(i, unitIdx: 0)];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: feats,
      levels: [
        const LevelBundle(
          level: 0,
          unitBars: [
            LevelUnitBar(idx: 0, dir: 1, x1: 0, x2: 2, confirmX: 3, volume: 303),
          ],
        ),
      ],
      // 故意不勾选任何副图——仍应显尽显
      subIndicators: const {},
    );
    final lines = lookup.crosshairTooltipLines(2, timePart: 't');
    // Kn OHLC 不含 VOL；成交量独立行
    expect(lines.any((l) => l.startsWith('K0:') && !l.contains('VOL')), isTrue);
    expect(
      lines.any((l) => l == 'K0成交量:B【0】/S【0】/G【102】'),
      isTrue,
    );
    expect(
      lines.any((l) => l == 'K1成交量:B【0】/S【0】/G【303】'),
      isTrue,
    );
    expect(lines.any((l) => l.startsWith('K0笔数:')), isTrue);
    expect(lines.any((l) => l.startsWith('K1笔数:')), isTrue);
    expect(lines.any((l) => l.startsWith('K0一类BS:【')), isTrue);
    expect(lines.any((l) => l.startsWith('K0比例:【')), isTrue);
    expect(lines.any((l) => l.startsWith('K0节奏')), isTrue);
    // 类别之后若下一层：只见 ===，不见 star 紧贴 ===
    final sep = '===============================';
    final star = '-。-。-。-。-。-。-。-。-。-';
    for (var i = 1; i < lines.length; i++) {
      if (lines[i] == sep) {
        expect(lines[i - 1], isNot(star),
            reason: '层切换前不应挂类别尾分隔');
      }
    }
  });

  test('tooltip 成交量 B/S/G 按 chip_tick_bins 三分解；节奏动态多行', () {
    final bars = [
      KlineBar(
        idx: 0,
        timeMs: 0,
        timeText: 't0',
        open: 10,
        high: 10,
        low: 10,
        close: 10,
        volume: 100,
        amount: 1,
        metrics: {
          'chip_tick_bins': {
            'b': [30.0],
            's': [50.0],
            'w': [20.0],
          },
          'tick_count': 3,
          'buy_tick_count': 1,
          'sell_tick_count': 1,
        },
      ),
    ];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: [
        BarCrosshairFeature(idx: 0, weekday: '周一', mergeInnerSeq: 0),
      ],
      stepRhythmHistoryByKn: {
        0: const [
          StepRhythmLinePoint(
            x: 0,
            displayKn: 0,
            key: 'k1',
            value: 11.5,
            ratio: 0.5,
            dir: 'up',
            roundCurrent: 0,
            roundRef: 0,
            layer: 0,
            label: '0-0',
            currentBiIdx: 0,
            refBiIdx: 0,
            retraceBiIdx: 0,
          ),
          StepRhythmLinePoint(
            x: 0,
            displayKn: 0,
            key: 'k2',
            value: 12.25,
            ratio: 0.8,
            dir: 'up',
            roundCurrent: 0,
            roundRef: 0,
            layer: 1,
            label: '0-1',
            currentBiIdx: 0,
            refBiIdx: 0,
            retraceBiIdx: 0,
          ),
        ],
      },
    );
    final lines = lookup.crosshairTooltipLines(0, timePart: 't0');
    expect(lines.any((l) => l == 'K0成交量:B【30】/S【50】/G【20】'), isTrue);
    expect(
      lines.any((l) =>
          l.startsWith('K0笔数:') &&
          l.contains('B【1】') &&
          l.contains('S【1】') &&
          l.contains('G【1】')),
      isTrue,
    );
    expect(lines.any((l) => l == 'K0节奏0-0:【11.500】'), isTrue);
    expect(lines.any((l) => l == 'K0节奏0-1:【12.250】'), isTrue);
    // tip 三类：背驰 | 比例+节奏 | 其它（均线）用 -。- 分隔
    final rows = lookup.crosshairTooltipRows(0, timePart: 't0');
    final labs = rows.map((e) => e.label).toList();
    final iDiver = labs.indexWhere((l) => l.startsWith('K0背驰'));
    final iRatio = labs.indexWhere((l) => l == 'K0比例');
    final iMean = labs.indexWhere((l) => l == 'K0均线');
    expect(iDiver, greaterThanOrEqualTo(0));
    expect(iRatio, greaterThan(iDiver));
    expect(iMean, greaterThan(iRatio));
    expect(rows.sublist(iDiver, iRatio).any((e) => e.isStar), isTrue);
    expect(rows.sublist(iRatio, iMean).any((e) => e.isStar), isTrue);
  });
}
