import 'package:chan_kline/compute/bs_verdict_compute.dart';
import 'package:chan_kline/models/bs_verdict_frame.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

BsVerdictFrame v({
  required int level,
  required String side,
  required int cls,
  required String label,
  required int seg,
  required int bspX,
  required String state,
  int? confirmX,
  int? invalidX,
}) {
  return BsVerdictFrame(
    level: level,
    side: side,
    cls: cls,
    label: label,
    segIdx: seg,
    bspX: bspX,
    createX: bspX,
    state: state,
    confirmX: confirmX,
    invalidX: invalidX,
  );
}

void main() {
  test('merge 只允许 Pending→终态，禁止回翻', () {
    final hist = <BsVerdictFrame>[
      v(level: 0, side: 'B', cls: 1, label: '1Ba', seg: 1, bspX: 10, state: 'pending'),
    ];
    mergeBsVerdictLog(hist, [
      v(
        level: 0,
        side: 'B',
        cls: 1,
        label: '1Ba',
        seg: 1,
        bspX: 10,
        state: 'correct',
        confirmX: 40,
      ),
    ]);
    expect(hist.single.state, 'correct');
    mergeBsVerdictLog(hist, [
      v(
        level: 0,
        side: 'B',
        cls: 1,
        label: '1Ba',
        seg: 1,
        bspX: 10,
        state: 'wrong',
        invalidX: 60,
      ),
    ]);
    expect(hist.single.state, 'correct');
    expect(hist.single.confirmX, 40);
  });

  test('asOf 在 verdict_x 之前仍显示 Pending', () {
    final frame = v(
      level: 1,
      side: 'S',
      cls: 4,
      label: '4Sa',
      seg: 3,
      bspX: 100,
      state: 'correct',
      confirmX: 108,
    );
    final early = verdictAtAsOf(
      [frame],
      level: 1,
      side: 'S',
      cls: 4,
      segIdx: 3,
      label: '4Sa',
      asOf: 105,
    );
    expect(early, isNotNull);
    expect(early!.isPending, isTrue);
    final late = verdictAtAsOf(
      [frame],
      level: 1,
      side: 'S',
      cls: 4,
      segIdx: 3,
      label: '4Sa',
      asOf: 108,
    );
    expect(late!.isCorrect, isTrue);
  });

  test('collect 方案B：K0 与 levels 分槽，不写死 1/2/3', () {
    const bundle = KlineCombineBundle(
      frames: [],
      k0Confirms: [],
      bsVerdictK0Frames: [
        BsVerdictFrame(
          level: 0,
          side: 'B',
          cls: 7,
          label: '7Ba',
          bspX: 3,
        ),
      ],
      levels: [
        LevelBundle(
          level: 0,
          bsVerdictFrames: [
            BsVerdictFrame(
              level: 1,
              side: 'S',
              cls: 12,
              label: '12Sa',
              bspX: 9,
            ),
          ],
        ),
      ],
    );
    final byKn = collectBsVerdictByKn(bundle);
    expect(byKn[0]!.single.cls, 7);
    expect(byKn[1]!.single.cls, 12);
  });
}
