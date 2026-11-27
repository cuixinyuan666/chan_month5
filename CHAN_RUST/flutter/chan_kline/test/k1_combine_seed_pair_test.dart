import 'package:chan_kline/compute/k1_combine_compute.dart';
import 'package:chan_kline/models/fractal_judgment_event.dart';
import 'package:chan_kline/models/k1_bar.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// 默认 TEST 股（`a_Data/test/custom.1m.csv` 11 根）K1 合并框回归。
///
/// 首分型前口径（2026-11-17 用户确认，2026-11-18 与 Rust `feed_guarded` 对齐）：
/// - 包含关系先并入首组（首组方向恒 Up：高高低高），不包含则开新组；
/// - 两种情况都跑「两元素分型」（中组 vs 右组），只盖章、不改价、不拆组；
/// - 该阶段**禁用截断**：不再出现 `10.1699999` 尾差、也不出现伪 BOTTOM。
void main() {
  List<KlineBar> bars(int n) => [
        for (var i = 0; i < n; i++)
          KlineBar(
            idx: i,
            timeMs: DateTime.utc(2026, 7, 10, 9, 30).millisecondsSinceEpoch +
                i * 60000,
            timeText: '2026/07/10 09:${(30 + i).toString().padLeft(2, '0')}:00',
            open: 10.17,
            high: 10.22,
            low: 9.98,
            close: 10.13,
            volume: 1,
            amount: 0,
          ),
      ];

  K1Bar unit(int idx, int x1, int x2, double high, double low) => K1Bar(
        idx: idx,
        dir: 1,
        x1: x1,
        x2: x2,
        open: high,
        high: high,
        low: low,
        close: low,
        confirmX: x2,
      );

  void expectNoTruncationArtifacts(List<KlineCombineFrame> frames) {
    for (final f in frames) {
      expect(
        f.high,
        isNot(closeTo(10.1699999, 1e-6)),
        reason: '首分型前禁用截断，不应出现 trunc_price_step 尾差',
      );
      expect(f.fx, isNot('BOTTOM'), reason: '不应出现伪底分型');
    }
  }

  test('asOf=5：首帧 0..4 = 高 10.22 / 低 10.17 / 顶分型 / 两根合并', () {
    final b = bars(11);
    final units = [
      unit(0, 0, 0, 10.17, 10.17), // 首段退化：四价全等
      unit(1, 0, 4, 10.22, 10.02), // 严格包含首组 → 并入首组（高高）
      unit(2, 4, 5, 10.19, 10.07), // 双高双低成组 → 两元素分型判首帧顶
    ];
    final events = <FractalJudgmentEvent>[];
    final frames = computeK1CombineFrames(b, units, judgmentEvents: events);

    expect(frames.length, 2);
    final f0 = frames.first;
    expect(f0.x1, 0);
    expect(f0.x2, 4);
    expect(f0.count, 2, reason: '0..0 与 0..4 应并成一组');
    expect(f0.high, closeTo(10.22, 1e-9));
    expect(f0.low, closeTo(10.17, 1e-9));
    expect(f0.fx, 'TOP');

    final f1 = frames.last;
    expect(f1.x1, 4);
    expect(f1.x2, 5);
    expect(f1.high, closeTo(10.19, 1e-9));
    expect(f1.low, closeTo(10.07, 1e-9));

    expectNoTruncationArtifacts(frames);

    final tops = events.where((e) => e.fx == 'TOP').toList();
    expect(tops.length, 1, reason: '两元素分型当步写一条判断事件');
    expect(tops.single.x, 5, reason: '判断成立当步 = 第三单元末端 K0');
    expect(tops.single.truncated, isFalse);
  });

  test('asOf=6：首帧不随后续单元漂移，第二帧继续合并', () {
    final b = bars(11);
    final units = [
      unit(0, 0, 0, 10.17, 10.17),
      unit(1, 0, 4, 10.22, 10.02),
      unit(2, 4, 5, 10.19, 10.07),
      unit(3, 5, 6, 10.19, 10.13),
    ];
    final frames = computeK1CombineFrames(b, units);

    expect(frames.length, 2);
    final f0 = frames.first;
    expect([f0.x1, f0.x2, f0.count], [0, 4, 2]);
    expect(f0.high, closeTo(10.22, 1e-9));
    expect(f0.low, closeTo(10.17, 1e-9));
    expect(f0.fx, 'TOP');

    final f1 = frames.last;
    expect([f1.x1, f1.x2, f1.count], [4, 6, 2]);
    expect(f1.high, closeTo(10.19, 1e-9));
    // 二元素顶分型之后，右组向下，包含按低低取最小：10.07 与 10.13 取 10.07。
    expect(f1.low, closeTo(10.07, 1e-9));

    expectNoTruncationArtifacts(frames);
  });

  test('低低口径：首分型前首组包含吸收 high/low 都取最小', () {
    final b = bars(6);
    final units = [
      unit(0, 0, 0, 10.17, 10.17),
      unit(1, 0, 4, 10.22, 10.02), // 严格包含首组 → 低低并成首框
      unit(2, 4, 5, 10.19, 10.07),
    ];
    final frames = computeK1CombineFrames(
      b,
      units,
      mode: PreFirstFractalMode.lowLow,
    );
    final f0 = frames.first;
    expect(f0.x1, 0);
    expect(f0.x2, 4);
    expect(f0.high, closeTo(10.17, 1e-9));
    expect(f0.low, closeTo(10.02, 1e-9));
    expect(f0.count, 2);
    expect(f0.beforeFirstStandardFx, isTrue,
        reason: '两元素章不算正式，仍标首分型前（单根也画框）');
  });

  test('两元素章不解除首分型前：beforeFirstStandardFx 保持 true', () {
    final b = bars(11);
    final units = [
      unit(0, 0, 0, 10.17, 10.17),
      unit(1, 0, 4, 10.22, 10.02),
      unit(2, 4, 5, 10.19, 10.07),
      unit(3, 5, 6, 10.19, 10.13),
    ];
    final frames = computeK1CombineFrames(b, units);
    expect(frames.first.fx, 'TOP');
    expect(frames.first.beforeFirstStandardFx, isTrue);
  });
}
