import 'package:chan_kline/compute/bar_feature_compute.dart';
import 'package:chan_kline/compute/bi_virtual_bar_compute.dart';
import 'package:chan_kline/compute/bi_virtual_bar_view_compute.dart';
import 'package:chan_kline/models/bi_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
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

void main() {
  test('笔确认当步：冻结上一笔并起笔 provisional（含半侧衔接）', () {
    final bars = _bars(10);
    final confirms = [
      const BiConfirmSignal(
        x: 2,
        fx: 'BOTTOM',
        value: 1,
        fractalX1: 1,
        fractalX2: 1,
      ),
      const BiConfirmSignal(
        x: 5,
        fx: 'TOP',
        value: -1,
        fractalX1: 4,
        fractalX2: 4,
      ),
    ];
    final segments = computeBiSegments(bars, confirms);
    expect(segments.length, 1);

    final atConfirm = computeBiVirtualBarsAsOf(
      bars,
      segments,
      confirms,
      'purged',
      5,
    );
    expect(atConfirm.length, 2, reason: '确认当步应有冻结笔+新 provisional 笔');

    final views = buildBiVirtualBarViews(atConfirm);
    expect(views[0].endAtLeftHalf, isTrue);
    expect(views[1].startAtRightHalf, isTrue);
    expect(views[0].viewX2, views[1].viewX1);
  });
}
